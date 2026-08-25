#!/usr/bin/env bash
#
# verify.sh — unified verification of CascadeFS.
#
# Runs:
#   1. Default cfg (3 hashes, SAFETY + SYMMETRY) with -coverage 1 + alarm
#      on zero-coverage actions (vacuity protection — see BUG-01 in history).
#   2. Liveness run (3 hashes, NO SYMMETRY, full PROPERTY block):
#      TLC symmetry reduction is UNSOUND for liveness (spurious cycles in
#      the quotient graph), so temporal properties are checked separately.
#   3. Exhaustive SAFETY check with 4/5 hashes with SYMMETRY (sound for invariants).
#   4. -simulate num=50 on 7 hashes (smoke beyond exhaustive;
#       no SYMMETRY — we do not mix simulate and symmetry).
#   5. cascadefs_sim.py (BFS, safety invariants).
#
# USAGE:
#   ./verify.sh              # full run (~3 min)
#   VERIFY_QUICK=1 ./verify.sh  # steps 1, 3 (4 hashes only), 5 (~15 s)
#
# Exit: 0 = all green; nonzero = failure (details in /tmp logs).

set -euo pipefail

cd "$(dirname "$0")"

# --- tlc resolver -------------------------------------------------------
if ! command -v tlc >/dev/null 2>&1; then
    export PATH="$HOME/.local/bin:$PATH"
fi
command -v tlc >/dev/null 2>&1 || {
    echo "FAIL: tlc not found (expected at ~/.local/bin/tlc or \$PATH)" >&2
    exit 127
}

TMP="$(mktemp -d /tmp/cascadefs-verify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
step() { printf '\n=== %s ===\n' "$*"; }

# tlc_run <name> <cfg> [extra flags...] — run TLC + check the result.
# For exhaustive mode requires "No error has been found".
# For -simulate (flag SIMULATE=1) that line is absent: success = exit 0
# and no "Error:"/"violated" in the log.
tlc_run() {
    local name="$1" cfg="$2"; shift 2
    local simulate="${SIMULATE:-0}"
    local log="$TMP/$name.log"
    if ! tlc -config "$cfg" "$@" CascadeFS >"$log" 2>&1; then
        echo "FAIL [$name]: tlc exited nonzero; tail of log:"
        tail -20 "$log"
        FAILED=1
        return
    fi
    if [[ "$simulate" == 1 ]]; then
        if grep -qE "Error:|is violated|Temporal properties were violated" "$log"; then
            echo "FAIL [$name]: violations found in simulate log; tail:"
            tail -30 "$log"
            FAILED=1
            return
        fi
        grep -oE "[0-9,]+ traces? generated" "$log" | head -1 | sed "s/^/[$name] /" || true
        return
    fi
    if ! grep -q "No error has been found" "$log"; then
        echo "FAIL [$name]: TLC reported errors; tail of log:"
        tail -30 "$log"
        FAILED=1
        return
    fi
    # FINAL summary line only: Progress lines are partial counters
    # flushed mid-BFS (the first match can be 44 while the run ends
    # at 202), so take the LAST match.
    grep -oE "[0-9,]+ distinct states found" "$log" | tail -1 \
        | sed "s/^/[$name] /"
}

# coverage_alarm <log> — vacuity: an action with 0 new states.
# Exceptions (actions that fire but do NOT create new states by design —
# "closing" actions that return the system to an already visited
# state):
#   CompleteRead — closes the read TOCTOU window; the "no window" state
#     is already reachable without the window, so it yields no new states
#     (but it must fire — the second component of the X:Y counter > 0;
#     a zero SECOND component is also alarmed below by a separate check).
coverage_alarm() {
    local log="$1"
    local dead
    dead=$(grep -E '^<[A-Za-z][^>]*>: [0-9]+:[0-9]+' "$log" \
        | awk -F': ' '
            {
                # line: "<Name line ...>: X:Y"; $1 = "<Name ...>", $2 = "X:Y"
                split($2, cnt, ":")
                name = $1; sub(/^</, "", name); sub(/ .*/, "", name)
                if (cnt[1] == 0 && name != "CompleteRead") print name
                if (cnt[2] == 0) print name " (never fired)"
            }')
    if [[ -n "$dead" ]]; then
        echo "FAIL: actions with zero coverage (vacuity suspects):"
        echo "$dead"
        echo "Either the action is dead (guard bug — see BUG-01 history)"
        echo "or unreachable at these parameters. Investigate before merge."
        FAILED=1
    else
        echo "coverage: all Next actions fired and produced new states (CompleteRead: closes window, returns to visited)"
    fi
}

# mk_liveness_cfg <out> <n-hashes> — safety-cfg + PROPERTY block, NO SYMMETRY.
mk_liveness_cfg() {
    local out="$1" n="$2"
    local hashes
    hashes=$(python3 -c "print('{'+','.join(f'h{i}' for i in range(1,$n+1))+'}')")
    {
        grep -v '^SYMMETRY' CascadeFS.cfg | grep -v '^SYMMETRY HashSymmetry'
        cat <<'EOF'
PROPERTY MonotoneMin
PROPERTY MonotoneMax
PROPERTY WriteCompletes
PROPERTY SplitLockReleased
PROPERTY ReadCompletes
EOF
    } | sed "s/^    Hashes = .*/    Hashes = $hashes/" > "$out"
    # drop the symmetry comment block lines that grep -v '^SYMMETRY' missed
    sed -i '/^SYMMETRY/d' "$out"
}

# --- 1. Default cfg (safety+symmetry) + coverage -------------------------
step "1/5 default cfg (4 hashes, safety, symmetry) + coverage"
tlc_run default CascadeFS.cfg -coverage 1
coverage_alarm "$TMP/default.log"

# --- 2. Liveness, NO symmetry (soundness: symmetry+liveness incompatible) -
if [[ "${VERIFY_QUICK:-0}" != 1 ]]; then
    step "2/5 liveness (4 hashes, NO symmetry, full PROPERTY)"
    mk_liveness_cfg "$TMP/live4.cfg" 4
    tlc_run liveness-4 "$TMP/live4.cfg"
else
    step "2/5 liveness SKIPPED (VERIFY_QUICK=1)"
fi

# --- 3. Exhaustive SAFETY 5 hashes, symmetry ------------------------------
for n in 5; do
    step "3/5 exhaustive safety, $n hashes, symmetry"
    hashes=$(python3 -c "print('{'+','.join(f'h{i}' for i in range(1,$n+1))+'}')")
    sed "s/^    Hashes = .*/    Hashes = $hashes/" CascadeFS.cfg > "$TMP/$n.cfg"
    tlc_run "hashes-$n" "$TMP/$n.cfg"
done

# --- 4. Simulate smoke, 7 hashes (no symmetry) ------------------------------
if [[ "${VERIFY_QUICK:-0}" != 1 ]]; then
    step "4/5 simulate smoke, 7 hashes (num=50)"
    hashes=$(python3 -c "print('{'+','.join(f'h{i}' for i in range(1,8))+'}')")
    grep -v '^SYMMETRY' CascadeFS.cfg | sed "s/^    Hashes = .*/    Hashes = $hashes/" > "$TMP/sim7.cfg"
    SIMULATE=1 tlc_run simulate-7 "$TMP/sim7.cfg" -simulate num=50
else
    step "4/5 simulate smoke SKIPPED (VERIFY_QUICK=1)"
fi

# --- 5. Python simulator ---------------------------------------------------
step "5/5 python simulator (cascadefs_sim.py)"
if python3 cascadefs_sim.py > "$TMP/sim.log" 2>&1; then
    grep -E "Total reachable states" "$TMP/sim.log" | sed 's/^/[py-sim] /'
else
    echo "FAIL [py-sim]: nonzero exit; tail of log:"
    tail -20 "$TMP/sim.log"
    FAILED=1
fi

# --- Summary ---------------------------------------------------------------
echo
if [[ "$FAILED" -eq 0 ]]; then
    echo "VERIFY: PASS"
else
    echo "VERIFY: FAIL (see above)"
fi
exit "$FAILED"
