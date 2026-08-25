# CascadeFS

Content-addressable key-value store built on a cascade directory layout.
Files are addressed by their SHA-256 hash, and directories are split
("sharded") when they fill up past 4096 entries.

The repository is documentation-first. The functional behavior is described
in two complementary forms:

- **`spec.md`** — prose specification: storage model, the WRITE/READ/SPLIT
  algorithms, `.depth_map` mmap + CAS layout, and platform-specific
  locking (`flock` on Linux/macOS vs `.lock.<dirname>` on Windows).
- **`CascadeFS.tla`** — TLA+ formal model of the same algorithms, executable
  by the TLC model-checker. Models the state machine of the storage
  algorithm and verifies safety invariants on every reachable state.

## Quickstart

Run the full verification suite (recommended):

```sh
./verify.sh                  # default + 4/5/6 hashes + simulate + py-sim, ~2 min
VERIFY_QUICK=1 ./verify.sh   # fast mode: default + 4 hashes + py-sim, ~10 s
```

The suite enables `-coverage 1` on the default run and FAILS if any
`Next` action produced zero new states (vacuity guard — see the
Vacuity note below).

Or run TLC directly:

```sh
# 1. Make sure you have Java 17+ and tlc on PATH.
java -version
tlc -help | head -1

# 2. Verify CascadeFS.tla against CascadeFS.cfg.
tlc -coverage 1 -config CascadeFS.cfg CascadeFS
```

Expected output (defaults: 3 hashes, 5 levels, capacity 2, safety
run with symmetry on):

```
Model checking completed. No error has been found.
1360 distinct states found
The depth of the complete state graph search is 24.
```

If `tlc` is not installed, see the **Formal model (TLA+)** section
below for installation instructions.

If Java is unavailable, the Python simulator is a drop-in fallback:

```sh
python3 cascadefs_sim.py
```

Expected output: `Total reachable states: 70`, exit code 0.

## Project structure

```
.
├── spec.md            — functional specification (storage model, algorithms)
├── TLA.md             — TLA+ spec narrative (abstractions, invariants, mapping)
├── CascadeFS.tla         — TLA+ module (machine-readable, parsed by TLC)
├── CascadeFS.cfg         — TLC configuration (constants: Hashes, Levels, …)
├── cascadefs_sim.py      — Python simulator of CascadeFS.tla (TLC fallback)
├── AGENTS.md          — project structure index and maintenance rules
└── README.md          — this file
```

### Specifications

- **`spec.md`** — what CascadeFS *is*: SHA-256 keys, 4096-entry
  directory limit, `.depth_map` global metadata via mmap + CAS, WRITE
  (section 4), READ (section 5), SPLIT (section 6), and platform-specific
  locking (`flock` on Linux/macOS vs `.lock.<dirname>` on Windows).
- **`TLA.md`** — what the TLA+ spec says and *why*. Explains the
  abstractions used (abstract hash set, uninterpreted levels, function
  `store: [hash → level ∪ {Absent}]`), the safety and liveness
  properties, and what is intentionally **not** modeled.
- **`AGENTS.md`** — how to keep the project in shape. Defines the file
  index, the linkage rule (any change to `spec.md` requires a revision
  of `TLA.md` and `CascadeFS.tla`), and the verification rule for TLC.

## Formal model (TLA+)

The TLA+ spec is an abstract state machine:

- **State** — `store: [hash → level ∪ {Absent}]`, `min_depth`, `max_depth`,
  `split_lock`, `root_lock`, the READ TOCTOU window `read_pending`, and
  the granular writer's registers (`w_pc`, `w_h`, `w_D`, `w_min`, `w_max`).
- **Actions** — the WRITE state machine (`WStart`, `WDirAbsentStep`,
  `WMinNoDir`, `WWriteAtLevel`, `WOverflowWrite`, `WLockFail`/
  `WLockSuccess`, `WSplitMove`, `WSplitRelease`, `WFinish` — every
  spec 4.1→4.2.5 step is a standalone action, so writer-side TOCTOU
  windows are observable), the two-step READ (`BeginRead` /
  `CompleteRead`), and the atomic `UpdateStep`.
- **Top-level** — `Spec == Init /\ [][Next]_vars` with fairness
  (`WF_vars(WStart)`, `WF_vars(WStep)`, `SF_vars(WSplitRelease)`,
  `WF_vars(UpdateStep)`, per-hash `WF_vars(CompleteRead(h))`).
- **Safety invariants** — `TypeOK`, `DepthInv` (spec 2.4:
  `max_depth ≥ min_depth`), `FilesAboveMin` (which the granular model
  once violated — see the WU-01 note below — and the spec now enforces
  via commit-time min re-checks), `ReadNoLost`.
- **Liveness properties** — `MonotoneMin`, `MonotoneMax`,
  `WriteCompletes`, `SplitLockReleased`, `ReadCompletes`.

Files:

- **`CascadeFS.tla`** — the TLA+ module. Defines state, actions, and
  invariants.
- **`CascadeFS.cfg`** — TLC model-checker configuration. Default constants:
  `Hashes = {h1, h2}`, `Levels = {0, 1, 2, 3, 4}`, `DirLimit = 2`,
  `NumSub = 2`. The state space is small enough for exhaustive BFS
  in ~1 second.
- **`TLA.md`** — human-readable description of the spec.
- **`cascadefs_sim.py`** — Python simulator of the same state machine.
  Used when Java is unavailable. Explores all reachable states
  exhaustively on tiny parameters and checks safety invariants.

### Requirements

- Java 17+ (TLC runs on the JVM; OpenJDK or any other JDK works).
- `tla2tools.jar` (the TLA+ tools jar).
- A `tlc` launcher script on `$PATH`.

### Install the TLC launcher

The repo expects `tlc` to wrap `java -jar tla2tools.jar`. The launcher
resolves the jar from the following locations, in order:

1. `$TLA2TOOLS_JAR` (explicit override)
2. `~/.local/share/tla2tools/tla2tools.jar` (user-managed install)
3. `/usr/local/share/tla2tools/tla2tools.jar` (system install)
4. `/tmp/tla2tools.jar` (volatile; common when freshly downloaded)
5. `~/tla2tools.jar` (home)

Default Java options: `-Xss4m -Xmx4g` (override via `$TLA_JAVA_OPTS`).

To install:

```sh
# Download tla2tools.jar from a TLA+ release.
curl -L -o tla2tools.jar \
    https://github.com/tlaplus/tlaplus/releases/download/v2026.08.21.155922/tla2tools.jar

# Put it where the launcher expects it.
mkdir -p ~/.local/share/tla2tools
mv tla2tools.jar ~/.local/share/tla2tools/

# Or expose it via env var.
export TLA2TOOLS_JAR=/path/to/tla2tools.jar
```

A reference launcher is at `~/.local/bin/tlc`:

```sh
#!/usr/bin/env bash
set -euo pipefail
find_jar() {
    local candidates=(
        "${TLA2TOOLS_JAR:-}"
        "${HOME}/.local/share/tla2tools/tla2tools.jar"
        "/usr/local/share/tla2tools/tla2tools.jar"
        "/tmp/tla2tools.jar"
        "${HOME}/tla2tools.jar"
    )
    for jar in "${candidates[@]}"; do
        if [[ -n "${jar}" && -f "${jar}" ]]; then
            echo "${jar}"; return 0
        fi
    done
    return 1
}
JAR="$(find_jar)" || { echo "tlc: tla2tools.jar not found" >&2; exit 127; }
[[ -n "$(command -v java)" ]] || { echo "tlc: java not found" >&2; exit 127; }
JAVA_OPTS="${TLA_JAVA_OPTS:--Xss4m -Xmx4g}"
exec java ${JAVA_OPTS} -jar "${JAR}" "$@"
```

### Run the model checker

From the repository root:

```sh
tlc -coverage 1 -config CascadeFS.cfg CascadeFS
```

Expected output (final lines):

```
TLC2 Version ...
Running breadth-first search Model-Checking with fp 95 and seed ... on 32 cores ...
Computing initial states...
Finished computing initial states: 1 distinct state generated.
Model checking completed. No error has been found.
8074 states generated, 1360 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 24.
```

With `-coverage 1` TLC also prints an action histogram. After every
run, check that each action in `Next` fired and shows `> 0` new
distinct states (the only exception is `CompleteRead` — a
window-closing action that returns the system to an already-visited
state, so it fires a lot but never discovers new states). A zero
counter means the action is dead — most likely an unsatisfiable
guard conjunction (see the Vacuity note) — and must be investigated
before merging.

Useful flags:

```sh
# Show progress and a state trace on invariant violation.
tlc -config CascadeFS.cfg CascadeFS -note -debugger nosuspend

# Increase fingerprinting precision if state space gets large.
tlc -config CascadeFS.cfg CascadeFS -fp 100

# Simulate N random runs instead of exhaustive BFS.
tlc -config CascadeFS.cfg CascadeFS -simulate num=100

# Force a re-check from a saved checkpoint.
tlc -config CascadeFS.cfg CascadeFS -recover <id>
```

### Scaling the model

The default `CascadeFS.cfg` is a SAFETY-only run (1360 reachable
states after symmetry reduction, ~3 seconds; 4 hashes). The granular
writer registers (`w_pc`/`w_h`/`w_D`/`w_min`/`w_max`) and the READ
TOCTOU window (`read_pending`) shape the space, so the tiers are:
exhaustive safety with symmetry at 4-5 hashes, liveness without
symmetry at 4 hashes (symmetry is UNSOUND for liveness — see below),
and `-simulate` beyond that.

```sh
cat > /tmp/cascadefs-bigger.cfg <<'EOF'
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT DepthInv
INVARIANT FilesAboveMin
INVARIANT Raise01Commit
INVARIANT Raise12Commit
INVARIANT Raise23Commit
INVARIANT WriteIsLinearizable
INVARIANT ReadNoLost
CONSTANTS
    Hashes = {h1, h2, h3, h4, h5}
    Levels = {0, 1, 2, 3, 4}
    DirLimit = 2
    NumSub = 2
SYMMETRY HashSymmetry
CHECK_DEADLOCK FALSE
EOF

tlc -config /tmp/cascadefs-bigger.cfg CascadeFS
```

Measured scaling (SAFETY + symmetry; all actions live — see the
vacuity note below):

| `|Hashes|` | distinct states (safety, symmetry) |
|---|---|
| 4 | 1 360 |
| 5 | 6 919 |
| 6 | — (exhaustive no longer tractable) |

Liveness (full PROPERTY block, NO symmetry — mandatory):
4 hashes = 17 109 states, ~47 s. That run is wired into `verify.sh`.

**Symmetry is sound for safety only.** The canonical argument is in
`TLA.md` section 2.5; the critical caveat: fair cycles in the
quotient graph need not correspond to fair cycles in the full graph,
so `SYMMETRY` + `PROPERTY` can produce FALSE violations (observed in
practice: a phantom `ReadCompletes` counterexample that vanished
without symmetry) and, worse, can mask real ones. `CascadeFS.cfg`
therefore contains no `PROPERTY` block; liveness is checked by
`verify.sh` in a separate no-symmetry run.

**WU-01 — the race the granular model found (and the spec fix).**
Modeling WRITE as a state machine (every 4.1→4.2.5 step standalone,
all intermediate states observable) exposed a real hole in the
original spec text: the writer snapshots `min_depth` at 4.1 and the
literal algorithm never re-reads it before committing at 4.2.5 /
4.2.2.2. If UPDATE raises `min_depth` past the writer's target level
*inside the write window*, the writer commits a file BELOW
`min_depth` — invisible to READ forever (orphan on disk). TLC's
counterexample was fully realistic (overflow → split → empty L0 →
full L1 → UPDATE raises min while the 4th writer descends; see the
`issue-granular-write` history). **Spec fix (adopted):** 4.2.5 and
4.2.2.2 now re-read the current `min_depth` (mmap — cheap) at commit
time; `D < min_depth` ⇒ no commit, restart from 4.1. In the model
this is the `w_D >= min_depth` / `(w_D + 1) >= min_depth` guards in
`WWriteAtLevel` / `WMinNoDir`.

**Vacuity note — read before composing actions.** One orchestrator
is deliberately a single atomic action: `UpdateStep` (functional LET
chain). It was previously written as a granular composition
(`AcquireLock /\ ... /\ ReleaseLock`) and was **unsatisfiable**:
the release guard refers to the *original* lock value while the
acquire conjunct requires the lock free — so the action never fired
and every check on it passed vacuously. Its former companion
`WriteAndMaybeSplit` (same BUG-01 pattern, fixed earlier by
atomization) has now been superseded by the granular writer machine
altogether. The coverage histogram (`-coverage 1`, wired into
`verify.sh` as a hard failure) is the systematic guard against this
bug class: a zero-new-states action is a dead action.

Larger parameters (production-scale `DirLimit=4096`, full 256-bit
hash space) are not model-checkable directly — they would require
further abstraction and a cluster.

### If Java is unavailable

The Python simulator covers the same state machine on small inputs:

```sh
python3 cascadefs_sim.py
```

Output:

```
Total reachable states: 70
min_depth range: [0, 1]
max_depth range: [0, 1, 2]
```

The simulator asserts `DepthInv` and `FilesAboveMin` on every
transition; a non-zero exit code indicates an invariant violation
(which would be a bug in the spec, not the simulation).

### What the TLA+ spec proves (and doesn't)

**Proven by exhaustive model checking (safety + temporal):**

- Every reachable state satisfies `TypeOK`, `DepthInv`, `FilesAboveMin`,
  `WriteIsLinearizable`, `ReadNoLost`.
- `ReadNoLost` (the READ TOCTOU window): while a read of h is pending
  (observed at stat time, open not yet done), the file h never
  disappears from the store — SPLIT may move it up a level, but the
  open-after-retry always finds it. Every interleaving inside the
  window is explored exhaustively.
- Post-conditions of UPDATE (`Raise01Commit`, `Raise12Commit`,
  `Raise23Commit`): if `min_depth` has been raised past level k,
  level k is empty.
- `min_depth` and `max_depth` are monotonically non-decreasing
  (`MonotoneMin`, `MonotoneMax`).
- Under the model's fair interleaving, a started WRITE session
  terminates (`WriteCompletes`: the writer machine returns to idle —
  no livelock inside 4.1→4.2.5), every `split_lock = TRUE` state is
  followed by `split_lock = FALSE` (`SplitLockReleased`), and every
  begun read completes (`ReadCompletes`). All rely on the `WF`/`SF`
  clauses in `Spec` — `ReadCompletes` specifically needs per-hash
  fairness (`∀h : WF(CompleteRead(h))`); a quantified `WF(∃h : ...)`
  admits a starving-read counterexample.
- The granular WRITE machine never commits below the CURRENT
  `min_depth` (commit-time re-check per the spec fix) — the WU-01
  window is closed under every interleaving with UPDATE.
- The `UpdateStep` orchestrator (one atomic action implementing
  6.4.1–6.4.6, including the candidate reset of 6.4.2 and the
  monotone commit of 6.4.5) never leaves `min_depth > max_depth`
  and never lowers `min_depth`.
- The parent sharding check (6.5.1) collapses into the writer's
  `WSplitMove` on the parent level in the count-based abstraction
  (identical guards and effects; TLC coverage measured the separate
  action as fully redundant) — the composition violates no invariant.

**Not modeled (out of scope for the abstract spec):**

- Filesystem primitives (`open(2)`, `rename(2)`, `unlink(2)`,
  `flock(2)`).
- The actual SHA-256 distribution of `HashToInt`. The spec uses
  abstract uninterpreted hash constants.
- The 4096-entry directory limit. `DirLimit` is a parameter; model
  checking uses small values.
- Crash recovery. There is no fault model in the spec; `spec.md` 6.4
  is the recovery procedure, but TLA+ cannot express process death.
