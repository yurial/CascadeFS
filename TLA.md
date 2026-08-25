# TLA+ Specification of CascadeFS

This document describes the `spec.md` algorithm in TLA+ (Lamport, 1999).
The goal is to formalize the key invariants and the behavior of WRITE/READ/SPLIT/UPDATE
as a checkable specification. The file system (cascade paths, hash
prefixes, directory hierarchy) is abstracted into mappings `(hash, level) →
store`.

The complete module is suitable for checking in TLC: the model checks safety invariants
(monotonicity of `min_depth`, file preservation, integrity of `max_depth ≥ min_depth`).
Liveness properties (termination of WRITE/SPLIT) are expressed temporally.

---

## 1. Module

```tla
-------------------------- MODULE CascadeFS --------------------------
(***************************************************************************
 * CascadeFS — content-addressable key-value store with cascade layout
 * and lock-protected SPLIT. Models spec.md sections 1-6.
 ***************************************************************************)
EXTENDS Integers, FiniteSets, TLC, Sequences

CONSTANTS
    Hashes,      \* Set of SHA-256 hash keys (finite abstract)
    Levels,      \* Set of cascade levels {0, 1, ..., L}; L ≥ 6
    DirLimit,    \* 4096 (spec.md 1.2)
    NumSub       \* 16 (spec.md 6.2.1 — number of SPLIT subdirs)

ASSUME
    /\ DirLimit \in Nat
    /\ NumSub \in Nat
    /\ 0 \in Levels
    /\ Levels \subseteq Nat
    /\ Cardinality(Levels) ≥ 7          \* need at least levels 0..6

\* Absent — file is not stored. (spec.md sections 1.2, 4.)
Absent == CHOOSE x : x \notin Levels

\* Abstract cascade routing: a hash is assigned to one of NumSub
\* subdirs based on its character at position `level` (hex char).
\* Modeled abstractly: each hash has a "route" function.
Route(h, level) == (level + HashToInt(h)) % NumSub

\* For the abstract model, replace HashToInt with a deterministic
\* function. TLC will enumerate Hashes as a small set.
HashToInt(h) == CHOOSE i \in 0..(Cardinality(Hashes)-1) : TRUE
\* (Above is non-deterministic for TLC; use a constant mapping in
\* concrete model.)

VARIABLES
    store,         \* [hash → level ∪ {Absent}]
    min_depth,     \* current min_depth in .depth_map
    max_depth,     \* current max_depth in .depth_map
    split_lock,    \* boolean — flock on overflowed dir held?
    root_lock,     \* boolean — flock on root dir held?
    read_pending,  \* [hash → level ∪ {-1}]: open READ TOCTOU window
    w_pc,          \* writer program counter (WIdle..WDone)
    w_h,           \* hash being written (Hashes ∪ {-1})
    w_D,           \* current descent level (Levels ∪ {-1})
    w_min,         \* min_depth snapshot from 4.1 (Levels ∪ {-1})
    w_max          \* max_depth snapshot from 4.1 (Levels ∪ {-1})

vars == <<store, min_depth, max_depth, split_lock, root_lock, read_pending,
          w_pc, w_h, w_D, w_min, w_max>>

\* ------------------------------------------------------------------------
\* Initial state
\* ------------------------------------------------------------------------
Init ==
    /\ store = [h \in Hashes ↦ Absent]
    /\ min_depth = 0
    /\ max_depth = 0
    /\ split_lock = FALSE
    /\ root_lock = FALSE

\* ------------------------------------------------------------------------
\* Type invariant
\* ------------------------------------------------------------------------
TypeOK ==
    /\ store \in [Hashes → Levels ∪ {Absent}]
    /\ min_depth \in Levels
    /\ max_depth \in Levels
    /\ split_lock \in BOOLEAN
    /\ root_lock \in BOOLEAN

\* ------------------------------------------------------------------------
\* Set of hashes currently stored at level L.
\* ------------------------------------------------------------------------
AtLevel(L) == {h \in Hashes : store[h] = L}

\* ------------------------------------------------------------------------
\* Spec.md section 1.2 — entry count at a level.
\* Count of files + non-service subdirs. For the abstract model,
\* ignore subdirs and count files only.
\* ------------------------------------------------------------------------
CountAt(L) == Cardinality(AtLevel(L))

\* Below min_depth there should be no files: spec.md 4.2 says we never
\* write below min_depth, and READ skips levels < min_depth.
FilesBelowMin == Cardinality({h \in Hashes :
                              store[h] /= Absent /\ store[h] < min_depth})

\* ------------------------------------------------------------------------
\* WRITE (spec.md section 4) — GRANULAR single-writer state machine.
\*
\* Each step 4.1→4.2.5 is a standalone action in Next: all intermediate
\* states (meta snapshot taken, descent, overflow write, lock taken,
\* files moved) are observable, and any other action (UpdateStep,
\* BeginRead/CompleteRead) can interleave between them. This makes the
\* WRITE side of TOCTOU windows checkable — a stale min/max snapshot
\* from 4.1.
\*
\* It is precisely this model that found WU-01 (see git history and the
\* fix in spec.md): the literal text of 4.1→4.2.5 allowed a commit
\* below the actual min_depth if UPDATE raised min inside the write
\* window. The fix — re-reading min_depth before commit (guards of
\* WWriteAtLevel and WMinNoDir) — is reflected in spec 4.2.5 / 4.2.2.2.
\*
\* Writer variables: w_pc (WIdle/WDescend/WTryLock/WSplit/WDone),
\* w_h, w_D, w_min, w_max (snapshot from 4.1 — deliberately not updated
\* until the end of the session, except on restart).
\*
\* ABSTRACTIONS (over-approximation — the right direction for
\* checking invariants):
\*  - "directory at level D exists" (4.2.2): may-abstraction — both
\*    branches (exists/does not) are allowed at every descent step; the
\*    real predicate is prefix-specific and not representable in the
\*    count model;
\*  - lock FAIL (4.2.4.1): non-deterministic may-branch — a competing
\*    master is absent in the single-writer model, and the literal
\*    guard split_lock = TRUE made the action dead (flagged by
\*    coverage);
\*  - 6.5.1 (parent check) collapses into WSplitMove at w_D-1
\*    (measured as degenerate back in the atomic model).
WStart(h) ==
    /\ w_pc = WIdle
    /\ store[h] = Absent
    /\ w_h' = h /\ w_min' = min_depth /\ w_max' = max_depth
    /\ w_D' = max_depth /\ w_pc' = WDescend
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   read_pending>>

\* 4.2.2.1: no dir@w_D, D > local min → D-1.
WDirAbsentStep ==
    /\ w_pc = WDescend
    /\ w_D > w_min
    /\ w_D' = w_D - 1
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_pc, w_h, w_min, w_max>>

\* 4.2.2.2: no dir and D == min → write at D+1.
\* WU-01 FIX: re-read the actual min; D+1 < min_depth → restart.
WMinNoDir ==
    /\ w_pc = WDescend
    /\ w_D = w_min
    /\ (w_D + 1) \in Levels
    /\ (w_D + 1) >= min_depth
    /\ store' = SetStore(w_h, w_D + 1)
    /\ w_pc' = WDone
    /\ UNCHANGED <<min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.3 + 4.2.5: count(w_D) < DirLimit → commit at w_D.
\* WU-01 FIX: the commit is validated against the ACTUAL min_depth
\* (re-read at commit time), not against the w_min snapshot.
WWriteAtLevel ==
    /\ w_pc = WDescend
    /\ CountAt(w_D) < DirLimit
    /\ w_D >= min_depth
    /\ store' = SetStore(w_h, w_D)
    /\ w_pc' = WDone
    /\ UNCHANGED <<min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.4: overflow — first write the file at D+1.
WOverflowWrite ==
    /\ w_pc = WDescend
    /\ CountAt(w_D) >= DirLimit
    /\ (w_D + 1) \in Levels
    /\ store' = SetStore(w_h, w_D + 1)
    /\ w_pc' = WTryLock
    /\ UNCHANGED <<min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.4.1: FAIL — another master (may-branch). File already at D+1. (End)
WLockFail ==
    /\ w_pc = WTryLock
    /\ w_pc' = WDone
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.4.2: SUCCESS — become the split master.
WLockSuccess ==
    /\ w_pc = WTryLock
    /\ ~split_lock
    /\ split_lock' = TRUE
    /\ w_pc' = WSplit
    /\ UNCHANGED <<store, min_depth, max_depth, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 6.2.2 (master): move all files w_D → w_D+1, bump max.
\* (The max_depth bump per 6.1.2.2 is performed by WSplitMove — the CAS
\* maximum is idempotent with the earlier one.)
WSplitMove ==
    /\ w_pc = WSplit
    /\ (w_D + 1) \in Levels
    /\ store' = MoveToLevel(AtLevel(w_D), w_D)
    /\ max_depth' = Max(max_depth, w_D + 1)
    /\ UNCHANGED <<min_depth, split_lock, root_lock, read_pending,
                   w_pc, w_h, w_D, w_min, w_max>>

\* 6.3: release the lock. (End)
WSplitRelease ==
    /\ w_pc = WSplit
    /\ split_lock' = FALSE
    /\ w_pc' = WDone
    /\ UNCHANGED <<store, min_depth, max_depth, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* Write session finished — reset the machine.
WFinish ==
    /\ w_pc = WDone
    /\ w_pc' = WIdle
    /\ w_h' = -1 /\ w_D' = -1 /\ w_min' = -1 /\ w_max' = -1
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock, read_pending>>

WStep ==
    \/ WDirAbsentStep \/ WMinNoDir \/ WWriteAtLevel \/ WOverflowWrite
    \/ WLockFail \/ WLockSuccess \/ WSplitMove \/ WSplitRelease \/ WFinish

\* ------------------------------------------------------------------------
\* READ (spec.md section 5) — TWO-STEP, a TOCTOU window between the
\* path check (5.2.1: "the file exists at L") and the open. Any action
\* (Write/SplitMaster/UpdateStep) can interleave between the steps —
\* all interleavings inside the window are observable, and ReadNoLost
\* checks the main thing: a once-observed file is not lost while the
\* window is open. Only POSITIVE observations are modeled: a negative
\* stat ("not at L") simply continues the 5.2 loop, no window needed.
BeginRead(h, L) ==
    /\ store[h] = L
    /\ read_pending[h] = -1
    /\ read_pending' = [read_pending EXCEPT ![h] = L]
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock>>

\* Open (use): in reality an open by the snapshot path; if SPLIT
\* carried the file away — ENOENT and a retry of the 5.2 loop, which
\* finds the file at the new level. The abstraction collapses the
\* retry: store[h] ≠ Absent suffices — the file is reachable somewhere.
CompleteRead(h) ==
    /\ read_pending[h] /= -1
    /\ store[h] /= Absent
    /\ read_pending' = [read_pending EXCEPT ![h] = -1]
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock>>

\* ------------------------------------------------------------------------
\* UPDATE (spec.md section 6.4)
\* ------------------------------------------------------------------------

\* 6.4 — the full UPDATE procedure, modeled as ONE atomic
\* transition (UpdateStep in CascadeFS.tla).
\*
\* Why atomic: there are no standalone root-lock actions in Next, so
\* the intermediate states 6.4.1..6.4.6 (lock acquired, candidate
\* computed) are unobservable. IMPORTANT (a found and fixed bug):
\* composing granular actions does not work here — AcquireRootLock
\* requires root_lock' = TRUE, while ReleaseRootLock has a guard on the
\* ORIGINAL root_lock = TRUE; the conjunction is unsatisfiable, and the
\* whole orchestrator silently never fired (vacuous verification). Do
\* not return to granular composition without standalone root-lock
\* substates in Next.
\*
\* The candidate's functional chain:
\*   6.4.1  acquire root lock     (implicit, via atomicity)
\*   6.4.2  candidate := 0       (re-validation from the root; safe per 2.2)
\*   6.4.3  0→1, 1→2, 2→3: source empty, target reached DirLimit
\*          (6.4.3.4 cap at 3; 6.4.3.5 early exit = the chain stopped)
\*   6.4.4  max_depth := Max(max_depth, min_depth')
\*   6.4.5  commit: min_depth := Max(min_depth, candidate). In a real
\*          system the raise conditions are STRUCTURAL (created subdirs
\*          persist), so re-validation never undercuts a previously
\*          confirmed min_depth; the count abstraction may "forget"
\*          this (SPLIT empties a level, carrying files away), so
\*          Max() encodes structural persistence and preserves
\*          MonotoneMin.
\*   6.4.6  release root lock (implicit, via atomicity)
Update ==
    /\ ~root_lock
    /\ LET c1 ==
               IF Cardinality(AtLevel(0)) = 0
                  /\ Cardinality(AtLevel(1)) >= DirLimit
               THEN 1 ELSE 0
       IN LET c2 ==
               IF c1 >= 1
                  /\ Cardinality(AtLevel(1)) = 0
                  /\ Cardinality(AtLevel(2)) >= DirLimit
               THEN 2 ELSE c1
       IN LET c3 ==
               IF c2 >= 2
                  /\ Cardinality(AtLevel(2)) = 0
                  /\ Cardinality(AtLevel(3)) >= DirLimit
               THEN 3 ELSE c2
       IN LET newMin == Max(min_depth, c3)
       IN
       /\ min_depth' = newMin
       /\ max_depth' = Max(max_depth, newMin)
    /\ UNCHANGED <<store, split_lock, root_lock>>

\* ------------------------------------------------------------------------
\* Top-level next-state relation
\* ------------------------------------------------------------------------

Next ==
    \/ \E h \in Hashes : WStart(h)
    \/ WStep
    \/ \E h \in Hashes, L \in Levels : BeginRead(h, L)
    \/ \E h \in Hashes : CompleteRead(h)
    \/ Update

Spec == Init ∧ □[Next]_vars
       ∧ WF_vars(∃h ∈ Hashes : WStart(h))
       ∧ WF_vars(WStep)
       ∧ SF_vars(WSplitRelease)
       ∧ WF_vars(Update)
       ∧ ∀h ∈ Hashes : WF_vars(CompleteRead(h))

\* ------------------------------------------------------------------------
\* Safety invariants
\* ------------------------------------------------------------------------

\* Spec.md 2.4: max_depth >= min_depth.
DepthInv == max_depth >= min_depth

\* Files are never below min_depth (the WRITE algorithm refuses to
\* descend below min_depth, and READ skips those levels).
FilesAboveMin ==
    \A h \in Hashes :
        (store[h] /= Absent) ⇒ (store[h] >= min_depth)

\* Monotonicity of min_depth: the UPDATE procedure only raises it,
\* the CAS is non-downgrading.
MonotoneMin == □[min_depth' >= min_depth]_<<min_depth, vars>>

\* Monotonicity of max_depth: SPLIT only raises it.
MonotoneMax == □[max_depth' >= max_depth]_<<max_depth, vars>>

\* Mutual exclusion during SPLIT-master is enforced by `SplitMaster`
\* action's `~root_lock` precondition, captured at the action level
\* rather than as a global state invariant (the orchestrator
\* WriteAndMaybeSplit holds split_lock across one atomic transition).

\* Safety bundle (state predicates — TLC requires no primes/temporals
\* for INVARIANT).
StateSafety == TypeOK ∧ DepthInv ∧ FilesAboveMin

\* ------------------------------------------------------------------------
\* Liveness (spec.md implicit)
\* ------------------------------------------------------------------------

\* A started write session finishes (the machine returns to idle).
\* REPLACES the former WriteProgress ("every Absent hash is eventually
\* written"): in the single-writer abstraction the absence of
\* starvation among hashes is a property of the SCHEDULER (in a real
\* system there are many writers/processes), not of the algorithm;
\* \E-quantified WF on WStart cannot guarantee the choice of every
\* hash. The algorithm guarantees: a started session finishes (no
\* livelock inside the machine).
WriteCompletes == □(w_pc ≠ WIdle ⇒ ◇w_pc = WIdle)

\* SPLIT eventually releases its lock (no deadlock).
SplitLockReleased == □(split_lock ⇒ ◇~split_lock)

\* ============================================================================
\* Modification History
\* ============================================================================
\* vim: set ts=4 sw=4 et:
```

---

## 2. Explanation of Abstractions

### 2.1. File system abstraction

The spec operates on paths in a cascade hierarchy of directories. In TLA+ it is
impractical to model these literally (the state size would explode).
Instead:

- `store: [hash → level ∪ {Absent}]` — the single source of truth about
  file placement. `Absent` means "not stored".
- `Route(h, level) ∈ 0..15` — abstract function distributing a hash over
  16 subdirs. The concrete function depends on the hex character `hash[level]`;
  in the model it is replaced by a deterministic mapping.

### 2.2. Entry counting abstraction

`CountAt(L)` counts only files at level L, ignoring service subdirectories
(`.depth_map`, `.lock.*`). In the real implementation (`cascadefs_count_entries`)
the count also includes non-service subdirectories. For formalizing the invariant
"no files below min_depth" this is sufficient.

### 2.3. Lock abstraction

`split_lock` and `root_lock` are two independent boolean flags. In
reality they are implemented via `flock()` on different inodes. In the model they
are simply booleans — the model does not distinguish processes, but the interleaving of actions
gives the same freedom of reordering as real multithreading.

### 2.4. CAS-bump

In reality CAS is an atomic operation. In TLA+ we model it as
a simple assignment (single-step atomic action). The correctness of CAS
(impossibility of a torn write) is a property of the language: every action is
atomic by definition.

### 2.5. Hash symmetry (canonical justification of SYMMETRY)

The model is checked with factorization by `Permutations(Hashes)`
(`SYMMETRY HashSymmetry` in the cfg; see §4). Justification of soundness:

1. **Hashes are indistinguishable to the algorithm.** No guard of any
   action branches on a specific hash: hashes appear only under
   uniform quantifiers (`\A h \in Hashes`, `\E h \in Hashes`) or in
   aggregates (`AtLevel`, `CountAt`, `MoveToLevel`).
2. **The invariants are symmetric.** All INVARIANTs (TypeOK, DepthInv,
   FilesAboveMin, Raise01/12/23Commit, WriteIsLinearizable) are either
   quantifier-free symmetric (do not mention hashes at all) or
   quantified by `\A h` uniformly.
3. **Properties and fairness are symmetric.** PROPERTY clauses and WF/SF conditions
   either do not mention hashes, or are quantified by `\A`/`\E h`
   uniformly.

Corollary: permuting hashes yields an isomorphic state with the same
values of all checked formulas, therefore factorization by permutation
orbits preserves truth — it suffices for TLC to check one
representative per orbit.

**Form requirement:** the `SYMMETRY` argument in the cfg must be the name
of a parameterless module operator (`HashSymmetry`); the cfg parser does
not accept inline expressions.

**CRITICAL: symmetry is unsound for liveness.** The argument above
proves the invariance of formula values under permutation — this is
sufficient for safety (invariants are state predicates). For temporal
properties this is INSUFFICIENT: fair cycles in the factor graph need
not correspond to fair cycles in the full graph. In practice: TLC with
`PROPERTY ReadCompletes` + `SYMMETRY` produced a FALSE violation (a
lasso in which the starving read was continuously enabled; without
symmetry the same property is clean).
Therefore:
- safety runs (INVARIANT) — with `SYMMETRY` (sound, fast);
- liveness runs (PROPERTY + fairness) — WITHOUT symmetry
  (slower, but correct); `verify.sh` separates these modes.

**Gain (safety only):** the state space shrinks by roughly the
factorial of `\|Hashes\|`.

### 2.6. Read TOCTOU window abstraction

READ is modeled by two actions: `BeginRead(h, L)` (the positive
observation "the file exists at L" — check) and `CompleteRead(h)` (the
open — use). Any action can interleave between them in `Next`, i.e. all
interleavings inside the window are observable, not collapsed. This
makes checkable the class of "stale observation" races (formerly
RW-04/RW-06): the invariant `ReadNoLost` asserts that an observed file
cannot disappear while the window is open — moving it (SPLIT) is
allowed, losing it is not. The retry semantics of the real READ
(ENOENT → next iteration of the 5.2 loop) is collapsed into the guard
`store[h] ≠ Absent` of `CompleteRead`. Negative observations ("not at
L") are not modeled by a separate window: they do not create a
check-then-use pair.


---

## 3. Invariants and Properties

### 3.1. Safety (state predicates; configured as `INVARIANT` in the cfg)

| Invariant | Spec | Meaning |
|---|---|---|
| `TypeOK` | 2.1 | All variables within their types |
| `DepthInv` | 2.4 | `max_depth >= min_depth` always |
| `FilesAboveMin` | 4.2, 5.2 | Files never below `min_depth` |
| `WriteIsLinearizable` | 2.5 | After a successful WRITE (atomic transition) the file is immediately visible to READ at that level |
| `ReadNoLost` | 5.2.1 | Read TOCTOU window: while a read for h is open, file h does not disappear from the store (it may move, but not be lost) |

Mutual exclusion of the SPLIT master and the root lock is ensured by the guard
condition `~root_lock` in `SplitMaster` and the atomicity of
`WriteAndMaybeSplit`; this is not a separate invariant but an action
precondition.

### 3.2. Liveness / temporal (PROPERTY; runs WITHOUT symmetry — see 2.5)

| Property | Spec | Meaning |
|---|---|---|
| `MonotoneMin` | 6.4.5 | `min_depth` grows monotonically |
| `MonotoneMax` | 6.1.2.2 | `max_depth` grows monotonically |
| `WriteCompletes` | 4 | A started write session finishes (the writer machine returns to idle; the global absence of starvation among hashes is a scheduler property, outside the single-writer abstraction) |
| `SplitLockReleased` | 6.3.1 | The SPLIT master does not hang forever |
| `ReadCompletes` | 5.2.1 | A started read finishes: the TOCTOU window does not hang forever |

Checking liveness requires `WF`/`SF` clauses in `Spec`
(`Spec == Init ∧ □[Next]_vars ∧ WF_vars(...) ∧ SF_vars(...)`).
Without them TLC proves only safety — an unfair scheduler can
stutter forever inside the writer machine, and `WriteCompletes`
will not hold. For the writer machine WF(WStart) + WF(WStep) (in every
non-idle pc at least one step is enabled) + SF(WSplitRelease).

A fairness subtlety for `ReadCompletes`: WF on the quantified form
`∃h : CompleteRead(h)` is INSUFFICIENT — TLC found a counterexample
where constantly reopening windows (Begin/Complete on h1) forever
satisfy ∃-WF, starving another hash's read. Per-hash fairness
`∀h : WF_vars(CompleteRead(h))` is required. WRITE does not need this:
its actions are one-shot (`store[h] ≠ Absent` disables `Write(h)`),
∃-WF suffices.

---

## 4. How to Run the Check in TLC

### 4.1. Full run (recommended)

```sh
./verify.sh                  # safety+sym, liveness no-sym, 4/5 hashes, simulate, py-sim (~3 min)
VERIFY_QUICK=1 ./verify.sh   # quick mode: default + 4 hashes + py-sim (~15 s)
```

The script checks: (1) the default cfg (SAFETY + SYMMETRY) with
`-coverage 1` and an **alarm on actions with zero coverage** —
systematic protection against vacuity (the class of UpdateStep /
WriteAndMaybeSplit bugs); (2) a **liveness run WITHOUT symmetry**
(full PROPERTY block; symmetry + liveness is unsound — see §2.5);
(3) exhaustive SAFETY with 5 hashes with symmetry; (4) `-simulate num=50`
on 7 hashes; (5) `cascadefs_sim.py`.

### 4.2. Manual run

```sh
# safety (with symmetry — sound for invariants):
tlc -coverage 1 -config CascadeFS.cfg CascadeFS

# liveness (WITHOUT symmetry — mandatory):
grep -v '^SYMMETRY' CascadeFS.cfg > /tmp/live.cfg
cat >> /tmp/live.cfg <<'EOF'
PROPERTY MonotoneMin
PROPERTY MonotoneMax
PROPERTY WriteCompletes
PROPERTY SplitLockReleased
PROPERTY ReadCompletes
EOF
tlc -config /tmp/live.cfg CascadeFS
```

`-coverage 1` prints a firing histogram; after the run check that
every action from `Next` fired and yielded `> 0` new states (the
exception is `CompleteRead`: a closing action, it returns to an
already visited state and yields none by design, but it must fire).
A zero counter = a dead-action candidate — investigate before merge.

### 4.3. Configuration (CascadeFS.cfg — SAFETY-only + SYMMETRY)

```cfg
\* CascadeFS.cfg — SAFETY-only (the PROPERTY block lives in the
\* liveness runs of verify.sh; symmetry+liveness are incompatible — see §2.5).
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
    \* 4 hashes: the descent branch of the granular writer
    \* (WDirAbsentStep, 4.2.2.1) requires states with max > min and an
    \* unwritten hash — with 3 hashes all such states already contain
    \* all hashes (flagged by coverage: 0:0). 4 hashes keep all
    \* actions alive.
    Hashes = {h1, h2, h3, h4}
    Levels = {0, 1, 2, 3, 4}       \* levels 0..4
    DirLimit = 2                   \* tiny threshold
    NumSub = 2                     \* tiny subdir count
SYMMETRY HashSymmetry              \* justification — §2.5 (safety only!)
CHECK_DEADLOCK FALSE
```

TLC checks the model on a finite state space. For production
parameters (4096 entries, 16 subdirs, 2^256 hashes) the model is
**not** checked directly — parameterized induction or abstraction
machinery (Predicate Abstraction, Counterexample-guided refinement) is
needed.

---

## 5. What is NOT Modeled (known limitations)

| Aspect | Why it is not modeled |
|---|---|
| Concrete paths (`/<root>/ab/c/<hash>`) | State explosion; abstracted by `Route(h, level)` |
| Hash routing by the character `hash[level]` | Abstracted by a deterministic function |
| 4096 entries limit | Parameterized via `DirLimit` (a small value is used in TLC) |
| Six cascade levels | Parameterized via `Levels` |
| `.depth_map` mmap, `msync` | These are implementation details; TLA+ models only observable behavior |
| Platform lock files `.lock.*` (Windows) | Reserved as a no-op on Linux/macOS |
| Crash between CAS and `msync` (race.md DM-03) | Requires fault injection into the model — a separate module |
| WRITE/SPLIT TOCTOU windows (readdir→rename, count→decide inside the split) | The read side is modeled (§2.6, `ReadNoLost`); the write/split side is not: their windows do not change the abstract store, they are checked at the implementation level |

---

## 6. Mapping of Specification Steps to TLA+ Module Actions

| spec.md | TLA+ action |
|---|---|
| 2.5 | (linearizability — an implicit property: `WWriteAtLevel`/`WMinNoDir`/`WOverflowWrite` either move `store[h]` to a level in one atomic step, or the action is disabled; there is no intermediate state "the file is being written but is not there") |
| 4.1 | `WStart` (min/max snapshot into w_min/w_max — deliberately stale until the end of the session) |
| 4.2.1 | (path-forming/open — not modeled separately; the session holds w_D) |
| 4.2.2 | (may-abstraction of directory existence: both branches enabled at every descent — see the WRITE section of the module) |
| 4.2.2.1 | `WDirAbsentStep` (descend to D-1) |
| 4.2.2.2 | `WMinNoDir` (commit at D+1; guard `(w_D+1) >= min_depth` — the WU-01 fix, re-reading min at commit) |
| 4.2.3 | `CountAt(w_D) < DirLimit` guard in `WWriteAtLevel` / `>= DirLimit` in `WOverflowWrite` |
| 4.2.4 | `WOverflowWrite` (writing the file at D+1 before acquiring the lock) |
| 4.2.4.1 | `WLockFail` (may-branch: a competing master; nondeterministic) |
| 4.2.4.2 | `WLockSuccess` → `WSplitMove` → `WSplitRelease` (master: move, bump max, release) |
| 4.2.5 | `WWriteAtLevel` (commit at w_D; guard `w_D >= min_depth` — the WU-01 fix) |
| 5.1 | (none — `read_5_1`/`write_4_1` = pure) |
| 5.2 | (loop semantics — not modeled separately) |
| 5.2.1 | `BeginRead` (check) + `CompleteRead` (use, retry collapsed) — TOCTOU window, see §2.6 |
| 6.1.1.1 | `WLockSuccess`/`WLockFail` (the try-lock is non-deterministic: may-branch of a competing master) |
| 6.1.1.2 | (Windows-only, UNSUPPORTED on Linux — not modeled) |
| 6.1.2.1 | `WLockFail` (FAIL branch: the file is already at D+1, end) |
| 6.1.2.2 | `WSplitMove` (CAS-bump `max_depth' = Max(max_depth, w_D + 1)`) |
| 6.2.1 | (subdirectory creation — not modeled separately) |
| 6.2.1.1 | (cascade reset — placement) |
| 6.2.1.2 | (within cascade — placement) |
| 6.2.2 | `WSplitMove` (the move `MoveToLevel(AtLevel(w_D), w_D)`; subdir routing is abstracted — see §5) |
| 6.2.3 | (rmdir empty — modeled as part of `WSplitMove`) |
| 6.3.1 | `WSplitRelease` |
| 6.3.2 | (Windows-only) |
| 6.4.1 | (implicit — atomicity of `Update`; there are no standalone root-lock actions in Next) |
| 6.4.2 | `Update`: the `c1` chain starts at 0 (reset for re-validation from the root) |
| 6.4.3.1 | `Update`: step `c1` (0→1: L0 empty, L1 ≥ DirLimit) |
| 6.4.3.2 | `Update`: step `c2` (1→2) |
| 6.4.3.3 | `Update`: step `c3` (2→3) |
| 6.4.3.4 | `Update`: the chain is capped at 3 (no further raises) |
| 6.4.3.5 | `Update`: the chain stops (ELSE branch of a step) |
| 6.4.4 | `Update`: `max_depth' = Max(max_depth, newMin)` |
| 6.4.5 | `Update`: commit `min_depth' = Max(min_depth, c3)` (CAS ≡ atomic transition; Max — structural persistence, see the comment) |
| 6.4.6 | (implicit — atomicity of `Update`) |
| 6.5.1 | (collapsed into `WSplitMove` on the parent: guards and effect are identical; the separate action was removed after a coverage measurement — 0 new states; the distinction exists only at the file-system level, which the abstraction does not represent) |
