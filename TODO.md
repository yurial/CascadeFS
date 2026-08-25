# TODO

Active problems and plans for improving CascadeFS verification.
Resolved items are removed from the file.

## 1. Medium (1-2 hours each)

| # | What | Why | Difficulty | Status |
|---|---|---|---|---|
| 6 | Crash-recovery model: `crashed: BOOLEAN`, `Crash`/`Recover`, `Recover` = UPDATE | A new dimension — fault-tolerance; spec 6.4 is the recovery procedure | Medium | todo |
| 8 | Lock retry/wait (6.1.1): `waiting: SUBSET Hashes`, FAIL-branch of try_lock | Real EAGAIN semantics + waiting; currently acquisition is atomic | Medium | todo |
| 9 | Rewrite orchestrators in PlusCal (→ compilation to TLA+) | The compiler correctly unrolls sequences with intermediate states — eliminates an **entire class** of vacuity bugs (see Vacuity note in README) | Medium, structural | todo |
| 10 | ~~Full WRITE 4.1→4.2.5 granularly~~ | DONE: the granular writer machine found race WU-01 (commit below the current min_depth — stale snapshot from 4.1); spec 4.2.5/4.2.2.2 fixed (re-reading min at commit), the model reflects the fix, verify.sh is green | — | done |

## 2. Large (research level)

| # | What | Why | Difficulty | Status |
|---|---|---|---|---|
| 11 | Per-process state: `store: [Process → [Hash → Level]]`, per-process locks | True multiprocess behavior instead of the interleaving abstraction | Large (state × \|Process\|) | todo |
| 12 | Refinement: two-level specs + proof of `Low ⊑ High` | Formal connection between the abstract model and a future implementation | Large | todo |
| 13 | Parameterized fault-injection: crash between steps X and Y (former FS-01/02, DM-03) | Targeted checking of crash windows, unavailable to a single `Crash` (#6) | Large | todo |

## 3. What TLA+ will not cover in principle

Do not attempt to model (see also TLA.md §5, AGENTS.md 2.5):

- Real behavior of `rename(2)` under load (kernel/FS level).
- SHA-256 distribution on a specific dataset (uniformity).
- Disk full / memory pressure.
- Performance (throughput/latency).

## 4. Recommended order

1. #6 (crash-model) — the next qualitative leap.
2. #9 (PlusCal) — structural elimination of a class of vacuity bugs.
3. #7, #8 — as needed.

## History (for context, completed)

- #10 (granular WRITE) — completed with a finding: the writer machine
  (each step 4.1→4.2.5 standalone) found WU-01 — the literal text of
  the spec allowed a commit below the current min_depth (UPDATE wedged
  into the write window; the file is invisible to READ). Spec
  4.2.5/4.2.2.2 fixed: re-reading min_depth before commit, D < min →
  restart from 4.1. Model: guards in WWriteAtLevel/WMinNoDir.
  Along the way: WLockFail moved to a may-branch (concurrent master),
  default cfg → 4 hashes (the descent branch is unreachable at 3 hashes,
  coverage 0:0), WriteProgress → WriteCompletes (global absence of
  starvation — a scheduler property, outside the single-writer
  abstraction). Cross-validation: py-sim 3 hashes = TLC 3 hashes no-sym
  = 1074 states.
- TOCTOU read window (former #7) — completed: two-step READ
  (`BeginRead`/`CompleteRead`), invariant `ReadNoLost`, property
  `ReadCompletes`. Also found and documented along the way: (a) TLC
  symmetry is unsound for liveness (a false counterexample in practice) —
  verify.sh split into safety+sym / liveness no-sym runs;
  (b) `ReadCompletes` requires per-hash fairness
  `∀h : WF(CompleteRead(h))` — the quantified `WF(∃h : ...)` allows
  read starvation (reopenable windows). The state space has grown
  (3 hashes: 84 → 1794 sym), the exhaustive tier rebuilt: 3-5
  hashes safety+sym, liveness no-sym on 3 hashes.
- BUG-01 (vacuity of `WriteAndMaybeSplit`) — fixed: atomic
  form + standalone `SplitMaster` in Next; the overflow WRITE path is now
  covered (coverage 4:7 on 3 hashes). Along the way: `ParentShardingCheck`
  degenerate (collapsed into `SplitMaster(D-1)`) — removed; in
  `SplitMaster` a duplicate `max_depth` in UNCHANGED fixed (silent
  no-bump). Default cfg raised to 3 hashes (at 2 the overflow branch is
  structurally unreachable).
- Coverage mode (`-coverage 1`) integrated into `verify.sh` with hard-fail
  on zero actions; codified in AGENTS 2.3.
