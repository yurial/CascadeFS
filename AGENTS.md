# AGENTS.md

Description of the project structure and file maintenance rules.

## 1. File index

### math.md
Analytical model of the algorithms for performance estimation: cascade level capacities (binomial load distribution, thresholds adjusted for max-load), split wave dynamics (hazard, amplification, amortization), READ/WRITE/UPDATE costs in syscalls, concurrency, SHA-256 collisions. The data consumer is perf.md. Fixes the notation (B, h, k_ℓ, μ, σ, N_ℓ, L*(N)).

### perf.md
Numerical performance model: calibration of operation costs on a reference machine (stat/readdir-entry/rename/write/flock, ext4 warm), READ and WRITE latency/throughput by phase (epoch/wave), the cost of a split and of UPDATE promotion, the N scale, applicability limits. All formulas are from math.md §9; recalculating for another FS = substituting your own costs into the calibration table.

### hint.md
Catalog of hints for efficient implementations and optimizations for various OS/FS: replacing the readdir count (st_size proxy, mmap counter, APFS ATTR_DIR_ENTRYCOUNT), descent acceleration (openat/statx), SPLIT optimizations (renameat2, io_uring, master throttling), UPDATE (early exit, deferred promotion), platform equivalents (Windows). Each hint: idea/conditions/FSes where it fails/required changes/status (idea|proposed|adopted). Rules for adding new entries — at the end of the file; anything touching behavior — via AGENTS 2.1.

### spec.md
Functional specification of the CascadeFS v1.0 storage. Contains:
- Basic principles (key = SHA-256, file name = HEX hash, limit of 4096 entries per directory).
- Global metadata `.depth_map` (fields `min_depth`, `max_depth`), mmap + CAS.
- Cascade path generation (1 → 2 → 3 → 1 → 2 → 3 → ...).
- Algorithms: WRITE (section 4), READ (section 5), SPLIT (section 6).
- Handling platform differences: `flock` (Linux/macOS) vs lock files `.lock.<dirname>` (Windows).
- Multi-level step numbering (`X.Y`, `X.Y.Z`, `X.Y.Z.W`).

### TLA.md
Human-readable description of the TLA+ specification (see CascadeFS.tla). Contains:
- Section 1 — purpose and relation to spec.md.
- Section 2 — justification of abstractions (what exactly is captured and what is left out).
- Section 3 — table of invariants and temporal properties.
- Section 4 — instructions for running TLC.
- Section 5 — what is NOT modeled (file primitives, lock semantics, crash recovery, the real hash distribution).
- Section 6 — table mapping spec.md steps → TLA+ actions/operators.

### CascadeFS.tla
Machine-readable TLA+ specification. Checked with `tla2tools.jar` (TLC). Valid syntax; on small parameters model checking passes in <2 s, 0 violations.

### CascadeFS.cfg
TLC configuration: `SPECIFICATION Spec`, invariants, `CONSTANTS` (`Hashes`, `Levels`, `DirLimit`, `NumSub`), `CHECK_DEADLOCK FALSE`. The parameters are chosen so that a full exhaustive check takes a few seconds.

### verify.sh
Unified verification script. Runs: (1) the default cfg (SAFETY + SYMMETRY) with `-coverage 1` and an alarm on actions with zero coverage (vacuity protection); (2) a liveness run WITHOUT symmetry with the full PROPERTY block (symmetry+liveness are incompatible); (3) exhaustive SAFETY with 5 hashes with `SYMMETRY HashSymmetry`; (4) `-simulate num=50` on 7 hashes (smoke beyond exhaustive); (5) `cascadefs_sim.py`. Modes: full (`./verify.sh`, ~1 min) and fast (`VERIFY_QUICK=1 ./verify.sh`, ~15 s). Exit 0 = PASS.

### cascadefs_sim.py
Python simulator of the same state machine as CascadeFS.tla. Used as a fallback when Java is unavailable. Traverses all reachable states via BFS, checking safety invariants on each transition.

### README.md
Entry point to the project for new members. Contains:
- Brief description of CascadeFS (SHA-256, cascade, 4096 limit).
- ASCII tree of the project structure.
- Summary of the roles of `spec.md`, `TLA.md`, `AGENTS.md`.
- Instructions for running TLC: requirements, installing `tla2tools.jar`, `tlc -config CascadeFS.cfg CascadeFS`.
- Minimal overview of the TLA+ spec (state, actions, invariants).
- What TLA+ checks and what it does not.

### TODO.md
Registry of active issues and verification improvement plans. Contains:
- Section 1 — active model bugs (currently: vacuity of WriteAndMaybeSplit).
- Sections 2-4 — plans grouped by effort: quick wins, medium, large.
- Section 5 — fundamental limitations of TLA+ (what is never modeled).
- Section 6 — recommended order of work.

Resolved items are removed from the file. The file is committed together with the other changes.

### AGENTS.md
This file. Description of the project structure and file maintenance rules.

## 2. Maintenance rules

### 2.1. Relation between spec.md and TLA.md / CascadeFS.tla
Any change to `spec.md` (adding, deleting, renaming, renumbering steps) requires a **mandatory** revision of `TLA.md` and `CascadeFS.tla`:

1. **A new step is added to spec.md** — check whether a new action/operator is needed; add it if necessary and review the invariants.
2. **A step is deleted/renumbered in spec.md** — find all mentions of this step in `TLA.md` (by lines of the form `X.Y.Z`) and in the comments of `CascadeFS.tla`; update them.
3. **A step's behavior is changed** (contract, branching, new sub-conditions) — review the corresponding action/operator and its guard conditions.
4. **Numbering is changed en masse** (e.g., after refactoring) — perform a global rename in `TLA.md` and `CascadeFS.tla`.

The revision of `TLA.md` and `CascadeFS.tla` must be done **in the same commit** as the `spec.md` change, or in a separate commit with an explicit indication of the relation. After a change to `CascadeFS.tla`, verification via TLC is mandatory.

### 2.2. Maintaining AGENTS.md
This file must reflect the current state of the project structure:

1. **A new file or directory is added to the project** — add a description to the "File index" section with a brief characterization of its content.
2. **A file or directory is deleted** — remove the corresponding section.
3. **A file's content changes significantly** — update the description in the index.
4. **New maintenance rules appear** — add them to section 2.

The rules of this section apply recursively: when `AGENTS.md` changes, updating it is not required, but the changes made must not contradict the existing rules.

### 2.3. Verification of CascadeFS.tla
Any change to `CascadeFS.tla` (a new action, a guard change, an invariant change) requires a **mandatory** check:

```sh
./verify.sh        # full run: default + 4/5/6 hashes + simulate + py-sim
# or in fast mode during development:
VERIFY_QUICK=1 ./verify.sh
# or targeted (quick check of a single configuration):
tlc -coverage 1 -config CascadeFS.cfg CascadeFS
```

Expected result: `VERIFY: PASS` / `Model checking completed. No error has been found.`

**Coverage requirement (vacuity protection):** after every change
the `-coverage 1` histogram must show `> 0` new states for every
action in `Next` (exception — `CompleteRead`, the closing action of
the TOCTOU window: it fires but returns to an already visited
state). A zero counter = a dead action (an unsatisfiable
conjunction of guards — the class of UpdateStep /
WriteAndMaybeSplit bugs, see the Vacuity note in README) —
investigate before merge. `verify.sh` wraps this check into a hard FAIL.

**Symmetry vs liveness:** `SYMMETRY` is sound ONLY for safety
(INVARIANT). For PROPERTY (liveness) symmetry is incorrect — fair
cycles in the quotient graph do not correspond to fair cycles of
the full graph (a false counterexample was observed). Therefore
`CascadeFS.cfg` is safety-only + SYMMETRY; liveness is checked by
a separate run WITHOUT symmetry (step 2 of `verify.sh`). Do not
add a PROPERTY block to `CascadeFS.cfg`.

If the state space has grown and a full check takes >10 s —
document the increased parameters in `TLA.md` (section 4).

### 2.4. Format of linear sequences in TLA.md
When describing interleavings (when a race needs to be illustrated in TLA+), follow the format:
- One line — a continuous slice of one participant's actions.
- Several consecutive steps of one participant — separated by commas.
- A change of participant — a new line.
- Step numbering must exactly match `spec.md`.

Step numbering must exactly match `spec.md`. Any discrepancy is a reason for a revision under rule 2.1.

### 2.5. What does not need tests (platform primitives)
The system calls and hardware primitives listed below **are not a subject of testing** in this project:

| Primitive | Source | Where it is covered |
|---|---|---|
| `read(2)` / `write(2)` | POSIX | OS kernel and glibc; behavior is deterministic per POSIX |
| `stat(2)` | POSIX | Same |
| `readdir(2)` / `opendir(2)` | POSIX | Same |
| `mmap(2)` / `msync(2)` | POSIX | Same; per-platform semantics described in `man mmap` |
| `rename(2)` / `unlink(2)` | POSIX | Same; atomicity guarantee — `rename(2)` spec |
| `flock(2)` / `fcntl(2)` | Linux/macOS | Kernel; in this project used via `flock` |
| CAS (compare-and-swap) | CPU | Architecture (x86 `CMPXCHG`, ARM `LDXR/STXR`); well-defined ISA guarantee |
| `LockFileEx` / `.lock.<dirname>` | Windows | Win32 API; documented by Microsoft |

**Rationale:** These are primitives, not logic. They are covered by their maintainers (kernel, libc, CPU vendor). Unit tests in this project are written for the **CascadeFS algorithm**, not to check the correctness of the OS or the CPU. Testing `read(2)` is the same as testing `assert(2+2==4)`: what is being checked is not the application code but the execution environment.

**What is tested:** The algorithmic logic (`spec.md` sections 4–6) — that is, the decisions CascadeFS makes on top of these primitives. This is done via:
- the TLA+ model `CascadeFS.tla` (formal verification of the state machine),
- the Python simulator `cascadefs_sim.py` (BFS over reachable states).

**What is NOT covered (known limitation):** The interaction of primitives under real race conditions on a specific OS — for example, the `rename(2)` + `readdir(2)` TOCTOU window. This is out of scope for the project and must be checked either by integration tests on the target OS or by a formal model of the OS (e.g., seL4), but not by application unit tests.

**Exception:** If a portable abstraction layer appears in the project in the future (e.g., `portable_flock` with implementations for Linux/macOS/Windows), its unit tests are acceptable — but these are tests of the adapter, not of the system call.
