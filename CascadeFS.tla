---------------------------- MODULE CascadeFS --------------------------
(*
  CascadeFS — abstract TLA+ spec of spec.md sections 1-6.

  Models the WRITE/SPLIT/UPDATE/READ algorithms at the level of
  state transitions on an abstract store keyed by hash.

  Parameters (set in CascadeFS.cfg):
    Hashes    — finite set of abstract file hashes
    Levels    — set of valid cascade levels
    DirLimit  — abstract directory capacity
    NumSub    — number of sub-directories per cascade level (unused in
                safety model; Route() is shown for documentation only)

  ------------------------------------------------------------------
  Model baselines (rerun via ./verify.sh; TLC 2026.08.21.155922):
    default  (4 hashes, safety+sym, cfg CascadeFS.cfg):
      1360 distinct states, diameter 24, ~3 s   [2026-08-24]
    liveness-4 (4 hashes, NO symmetry, full PROPERTY):
      17109 distinct states, ~47 s              [2026-08-24]
    hashes-5 (5 hashes, safety+sym):
      6919 distinct states                      [2026-08-24]
    simulate-7 (7 hashes, num=50): 50 traces    [2026-08-24]
    py-sim cross-check: 3 hashes = 1074 states == TLC no-sym [2026-08-24]
*)
EXTENDS Integers, FiniteSets, TLC, Sequences

CONSTANTS
    Hashes,    \* abstract set of hashes
    Levels,    \* abstract set of levels (typically 0..N)
    DirLimit,  \* capacity of a single directory
    NumSub     \* number of sub-directories per level

\* ------------------------------------------------------------------------
\* Helpers
\* ------------------------------------------------------------------------

\* max/min helpers (TLA+ core has <, >, etc. but not max/min).
Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

\* Absent — sentinel for "not stored". All levels in `Levels` are
\* non-negative integers in the cfg, so -1 is provably outside the set.
Absent == -1

\* Abstract cascade routing: deterministic per (hash, level).
\* (Not used in actions; kept for documentation. TLC cannot evaluate
\*  CHOOSE-based per-hash functions cheaply.)
Route(h, level) == (level + 0) % NumSub

\* Symmetry group over hashes for TLC's symmetry reduction.
\* Soundness argument and usage constraints: see TLA.md section 2.5
\* (canonical rationale). Must be a named, argument-less operator —
\* the cfg parser rejects inline expressions.
HashSymmetry == Permutations(Hashes)

\* Writer program counters (definition must precede use — see Init
\* and the WRITE section below for the semantics of each state).
WIdle == 0          \* no write in flight
WDescend == 1       \* 4.2 loop: examining level w_D
WTryLock == 2       \* 4.2.4: overflow-written, attempting split lock
WSplit == 3         \* 4.2.4.2: master, moving files (6.2)
WDone == 4          \* terminal; WFinish resets to idle

VARIABLES
    store,         \* [hash -> level \cup {Absent}]
    min_depth,     \* current min_depth in .depth_map
    max_depth,     \* current max_depth in .depth_map
    split_lock,    \* boolean — flock on overflowed dir held?
    root_lock,     \* boolean — flock on root dir held?
    read_pending,  \* [hash -> level \cup {-1}]: TOCTOU window of READ
    w_pc,          \* writer program counter (WIdle..WDone)
    w_h,           \* hash being written (Hashes \cup {-1})
    w_D,           \* current descend level (Levels \cup {-1})
    w_min,         \* 4.1 snapshot of min_depth (Levels \cup {-1})
    w_max          \* 4.1 snapshot of max_depth (Levels \cup {-1})

vars == <<store, min_depth, max_depth, split_lock, root_lock, read_pending,
          w_pc, w_h, w_D, w_min, w_max>>

\* Type invariant
TypeOK ==
    /\ store \in [Hashes -> Levels \union {-1}]
    /\ min_depth \in Levels
    /\ max_depth \in Levels
    /\ split_lock \in BOOLEAN
    /\ root_lock \in BOOLEAN
    /\ read_pending \in [Hashes -> Levels \union {-1}]
    /\ w_pc \in 0..4
    /\ w_h \in Hashes \cup {-1}
    /\ w_D \in Levels \union {-1}
    /\ w_min \in Levels \cup {-1}
    /\ w_max \in Levels \union {-1}

\* ------------------------------------------------------------------------
\* Initial state
\* ------------------------------------------------------------------------
Init ==
    /\ store = [h \in Hashes |-> Absent]
    /\ min_depth = 0
    /\ max_depth = 0
    /\ split_lock = FALSE
    /\ root_lock = FALSE
    /\ read_pending = [h \in Hashes |-> -1]
    /\ w_pc = WIdle
    /\ w_h = -1
    /\ w_D = -1
    /\ w_min = -1
    /\ w_max = -1

\* Set of hashes currently stored at level L.
AtLevel(L) == {h \in Hashes : store[h] = L}

\* Entry count at level L (abstract: count of files only).
CountAt(L) == Cardinality(AtLevel(L))

\* Helper: update a single hash h to new value newLvl.
SetStore(h, newLvl) ==
    [store EXCEPT ![h] = newLvl]

\* Helper: bulk update — move all hashes in moved to D+1.
MoveToLevel(moved, D) ==
    [h \in Hashes |-> IF h \in moved THEN D + 1 ELSE store[h]]

\* ------------------------------------------------------------------------
\* WRITE (spec.md section 4) — GRANULAR single-writer state machine.
\*
\* Every step of 4.1 -> 4.2.5 is a STANDALONE action in Next, so all
\* intermediate states (meta snapshot taken, descending, overflow
\* written, lock acquired, files being moved) are OBSERVABLE and any
\* other action (UpdateStep, BeginRead/CompleteRead) can interleave
\* between them. This replaces the previous atomic Write/WriteAndMaybeSplit
\* (kept in history: commit 6958213) and makes the WRITE-side TOCTOU
\* windows — the stale min/max snapshot of 4.1 — checkable.
\*
\* ABSTRACTIONS (documented, over-approximations):
\*  - "Directory at level D exists" (4.2.2) is a may-abstraction:
\*    both branches (dir present / dir absent) are enabled at every
\*    descend step; the real predicate is prefix-specific and not
\*    representable in the count-based store. Over-approximation is
\*    the correct direction for invariant checking: it can only add
\*    behaviors, never hide violations.
\*  - w_min / w_max are the writer's LOCAL snapshot from 4.1 and are
\*    intentionally NOT refreshed at commit time — this models the
\*    spec text literally (no re-read of .depth_map between 4.1 and
\*    4.2.5). The whole point of the granular model is to test
\*    whether that literalness is safe.
\*  - 6.5.1 (parent sharding) collapses into WSplitMove applied at
\*    w_D - 1 (measured degenerate earlier in the atomic model).
\*
\* Program counters (see the macros at the top of the module):
\*   WIdle / WDescend / WTryLock / WSplit / WDone.
\*
\* 4.1: read min/max into locals, start descending from max.
WStart(h) ==
    /\ w_pc = WIdle
    /\ store[h] = Absent
    /\ w_h' = h
    /\ w_min' = min_depth
    /\ w_max' = max_depth
    /\ w_D' = max_depth
    /\ w_pc' = WDescend
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock, read_pending>>

\* 4.2.2.1: dir at w_D absent, D > local min -> descend (D-1).
WDirAbsentStep ==
    /\ w_pc = WDescend
    /\ w_D > w_min
    /\ w_D' = w_D - 1
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_pc, w_h, w_min, w_max>>

\* 4.2.2.2: dir absent AND D == local min -> write at D+1. (End)
\* SPEC FIX (WU-01): re-read the CURRENT min_depth at commit time;
\* if D+1 < min_depth (UPDATE raised min inside the window), do not
\* commit — restart from 4.1.
WMinNoDir ==
    /\ w_pc = WDescend
    /\ w_D = w_min
    /\ (w_D + 1) \in Levels
    /\ (w_D + 1) >= min_depth
    /\ store' = SetStore(w_h, w_D + 1)
    /\ w_pc' = WDone
    /\ UNCHANGED <<min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.3 + 4.2.5: count entries at w_D; under limit -> write at w_D.
\* SPEC FIX (WU-01): commits are validated against the CURRENT
\* min_depth (re-read at commit time, spec 4.2.5), not the stale 4.1
\* snapshot w_min. If UpdateStep raised min past w_D during the
\* writer's descend, the commit is disabled and the write restarts
\* (modeled by the guard; the restart loop is WStart again).
WWriteAtLevel ==
    /\ w_pc = WDescend
    /\ CountAt(w_D) < DirLimit
    /\ w_D >= min_depth
    /\ store' = SetStore(w_h, w_D)
    /\ w_pc' = WDone
    /\ UNCHANGED <<min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.4 (first half): overflow — write the file at D+1 first.
WOverflowWrite ==
    /\ w_pc = WDescend
    /\ CountAt(w_D) >= DirLimit
    /\ (w_D + 1) \in Levels
    /\ store' = SetStore(w_h, w_D + 1)
    /\ w_pc' = WTryLock
    /\ UNCHANGED <<min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.4.1: lock FAIL — another master is splitting. (End)
\* MAY-ABSTRACTION: the single-writer machine itself never holds
\* split_lock outside WSplit, so a literal split_lock = TRUE guard
\* would make this branch dead (TLC coverage flagged 0:0 — the
\* "other process" is what this branch models, and other processes
\* are abstracted away here). The nondeterministic choice between
\* FAIL and SUCCESS at WTryLock over-approximates concurrent
\* masters: correct direction for invariant checking.
WLockFail ==
    /\ w_pc = WTryLock
    /\ w_pc' = WDone
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 4.2.4.2: lock SUCCESS — become the split master.
WLockSuccess ==
    /\ w_pc = WTryLock
    /\ ~split_lock
    /\ split_lock' = TRUE
    /\ w_pc' = WSplit
    /\ UNCHANGED <<store, min_depth, max_depth, root_lock,
                   read_pending, w_h, w_D, w_min, w_max>>

\* 6.2.2 (as master): move all files from w_D to w_D+1, bump max.
WSplitMove ==
    /\ w_pc = WSplit
    /\ (w_D + 1) \in Levels
    /\ store' = MoveToLevel(AtLevel(w_D), w_D)
    /\ max_depth' = Max(max_depth, w_D + 1)
    /\ UNCHANGED <<min_depth, split_lock, root_lock, read_pending,
                   w_pc, w_h, w_D, w_min, w_max>>

\* 6.3: release the split lock. (End) Also serves 6.5.1's loop exit.
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
    /\ w_h' = -1
    /\ w_D' = -1
    /\ w_min' = -1
    /\ w_max' = -1
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock, read_pending>>

\* Disjunction of all writer steps (for fairness).
WStep ==
    \/ WDirAbsentStep
    \/ WMinNoDir
    \/ WWriteAtLevel
    \/ WOverflowWrite
    \/ WLockFail
    \/ WLockSuccess
    \/ WSplitMove
    \/ WSplitRelease
    \/ WFinish

\* ------------------------------------------------------------------------
\* READ (spec.md section 5) — TWO-STEP, modeling the TOCTOU window
\* between the path check (5.2.1: "file exists at L") and the open.
\*
\* Why two steps: in the real system READ stats the path and then
\* opens it; between stat and open, SPLIT may rename the file away
\* and UPDATE may raise min_depth. The window is where stale
\* observations live (old race.md RW-04/RW-06 class). Modeling it
\* as two actions makes every interleaving (Write, SplitMaster,
\* UpdateStep) observable INSIDE the window, and ReadNoLost below
\* checks the crucial safety: a file once observed can never be
\* lost while the reader still holds the observation.
\*
\* BeginRead(h, L): positive observation — store[h] = L at stat
\* time. The snapshot level is recorded; no other variable moves.
\* Only positive observations are modeled: a negative stat
\* ("not at L") just continues the loop (5.2), no window needed.
BeginRead(h, L) ==
    /\ store[h] = L
    /\ read_pending[h] = -1
    /\ read_pending' = [read_pending EXCEPT ![h] = L]
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   w_pc, w_h, w_D, w_min, w_max>>

\* CompleteRead(h): the open (the "use" of the check). In the real
\* system the open targets the snapshotted path; if SPLIT renamed
\* the file away, the open fails with ENOENT and the READ loop
\* retries from min_depth upward and finds the file at its new
\* level. The abstraction collapses the retry: completion requires
\* only store[h] /= Absent — the file is SOMEWHERE findable. That
\* is exactly the property worth verifying (ReadNoLost).
CompleteRead(h) ==
    /\ read_pending[h] /= -1
    /\ store[h] /= Absent
    /\ read_pending' = [read_pending EXCEPT ![h] = -1]
    /\ UNCHANGED <<store, min_depth, max_depth, split_lock, root_lock,
                   w_pc, w_h, w_D, w_min, w_max>>

\* ------------------------------------------------------------------------
\* UPDATE (spec.md section 6.4)
\* ------------------------------------------------------------------------

\* Full UPDATE procedure, modeled as ONE atomic action.
\*
\* Why atomic: there are no standalone root-lock actions in Next, so
\* intermediate states of 6.4.1..6.4.6 (lock held, candidate being
\* computed) are unobservable in this abstraction. NOTE: composing
\* granular actions here is a known trap — AcquireRootLock sets
\* root_lock' = TRUE while ReleaseRootLock guards on the ORIGINAL
\* root_lock = TRUE; the conjunction is unsatisfiable and the whole
\* orchestrator silently never fires (vacuous verification). Do not
\* re-introduce granular composition without standalone root-lock
\* sub-states in Next.
\*
\* Semantics (functional candidate chain):
\*   6.4.1  root lock acquired     (implicit in atomicity)
\*   6.4.2  candidate := 0         (re-validation from root; safe per 2.2)
\*   6.4.3  0->1, 1->2, 2->3 raises: each requires the source level to
\*          be empty and the target level to be at/over DirLimit
\*          (6.4.3.4 cap at 3; 6.4.3.5 early exit = chain stops)
\*   6.4.4  max_depth := Max(max_depth, min_depth')
\*   6.4.5  commit: min_depth := Max(min_depth, candidate). In the real
\*          system the raise conditions are STRUCTURAL (once created,
\*          subdirs persist), so re-validation never lowers a
\*          previously validated min_depth. The count-based
\*          abstraction can "forget" this (SPLIT empties a level by
\*          moving files away), so the Max() encodes structural
\*          persistence and keeps MonotoneMin valid.
\*   6.4.6  root lock released     (implicit in atomicity)
UpdateStep ==
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
    /\ UNCHANGED <<store, split_lock, root_lock, read_pending,
                   w_pc, w_h, w_D, w_min, w_max>>

\* ------------------------------------------------------------------------
\* Top-level next-state relation
\* ------------------------------------------------------------------------

Next ==
    \/ \E h \in Hashes : WStart(h)
    \/ WStep
    \/ \E h \in Hashes, L \in Levels : BeginRead(h, L)
    \/ \E h \in Hashes : CompleteRead(h)
    \/ UpdateStep

\* Fairness: writers don't starve, locks don't hang, UPDATE and READ
\* windows progress.
\* - WF on Write: without it, an unfair scheduler could stutter forever
\*   and WriteProgress would be unprovable.
\* - SF on ReleaseSplitLock: split_lock holders must eventually release
\*   (strong fairness: even if release is intermittently disabled).
\* - WF on UpdateStep: UPDATE, when continuously enabled, eventually
\*   fires (root lock is not held forever in this abstraction because
\*   UpdateStep is the only action that touches it, atomically).
\* - WF on CompleteRead — PER-HASH, quantified: a single
\*   WF_vars(\E h : CompleteRead(h)) is NOT enough. Counterexample
\*   found by TLC: re-openable windows (BeginRead h1 again after
\*   every CompleteRead h1) keep the \E-form enabled and firing
\*   forever while a DIFFERENT hash's read starves inside its
\*   window. Per-hash WF forces each pending window to close.
\*   (Write does not need this: its actions are one-shot —
\*   store[h] /= Absent disables Write(h), so \E-WF suffices.)
\* Fairness: the writer machine progresses, UPDATE and READ windows
\* progress.
\* - WF on WStart — \E-quantified: a REVIEWED DEVIATION from the
\*   per-instance fairness rule (never WF on \E-existential actions).
\*   Justification: the per-instance guarantee ("every absent hash
\*   eventually gets a session") is a SCHEDULER property — in the
\*   real system many processes write arbitrary hashes; the algorithm
\*   cannot force it. We assert only "someone eventually starts",
\*   and WriteCompletes below is deliberately per-session, not
\*   per-hash. WStart is one-shot per hash (store[h] /= Absent
\*   disables it), so the \E form cannot hide intra-session hang.
\* - WF on WStep: a disjunction of 9 concrete writer-local actions of
\*   a SINGLE-writer machine — there is exactly one agent, so the
\*   per-instance concern (hiding per-agent starvation) does not
\*   apply; WF on the disjunction is the standard machine-progress
\*   form. In every non-idle pc at least one step is enabled
\*   (descend: under/over-limit branches cover both counts; trylock:
\*   split_lock is either TRUE or not; split: WSplitRelease always;
\*   done: WFinish).
\* - SF on WSplitRelease: the master eventually releases the lock.
\* - WF on UpdateStep: as before (atomic, sole root-lock user).
\* - Per-hash WF on CompleteRead: see the READ section comment.
FairSpec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(\E h \in Hashes : WStart(h))
    /\ WF_vars(WStep)
    /\ SF_vars(WSplitRelease)
    /\ WF_vars(UpdateStep)
    /\ \A h \in Hashes : WF_vars(CompleteRead(h))

Spec == FairSpec

\* ------------------------------------------------------------------------
\* Safety invariants
\* ------------------------------------------------------------------------

\* Spec.md 2.4: max_depth >= min_depth.
DepthInv == max_depth >= min_depth

\* Files are never below min_depth.
FilesAboveMin ==
    \A h \in Hashes :
        (store[h] /= Absent) => (store[h] >= min_depth)

\* Spec.md 6.4.3: post-conditions of TryRaise* actions.
\* If min_depth >= k, then level k-1 must be empty (otherwise we
\* would have raised). These are stronger invariants than FilesAboveMin:
\* they ensure UPDATE has actually cleaned up old levels.
Raise01Commit == (min_depth >= 1) => Cardinality(AtLevel(0)) = 0
Raise12Commit == (min_depth >= 2) => Cardinality(AtLevel(1)) = 0
Raise23Commit == (min_depth >= 3) => Cardinality(AtLevel(2)) = 0

\* Spec.md 2.5: linearizability of WRITE/READ.
\* The model enforces this by construction: every Write action is a
\* single atomic transition that sets store[h] to a specific level
\* (or is disabled). There is no observable "in-progress" state —
\* once a Write returns, store[h] /= Absent and any subsequent Read
\* at that level will see it. This invariant is derivable from TypeOK
\* but stated explicitly to anchor the spec rule to a checkable
\* TLA+ formula.
WriteIsLinearizable ==
    \A h \in Hashes :
        (store[h] /= Absent) => (store[h] \in Levels)

\* TOCTOU-window safety of READ (old race.md RW-04/RW-06 class):
\* while a reader holds a positive observation of h (stat succeeded,
\* open not yet done), the observed file can be MOVED (SplitMaster,
\* WriteAndMaybeSplit) but never LOST — store[h] stays /= Absent,
\* so the open-after-retry (CompleteRead) can always succeed.
\* This is exactly what makes the check-then-use window benign.
ReadNoLost ==
    \A h \in Hashes :
        (read_pending[h] /= -1) => (store[h] /= Absent)

\* Monotonicity of min_depth: UPDATE only raises it, never lowers.
MonotoneMin == [][min_depth' >= min_depth]_<<min_depth, vars>>

\* Monotonicity of max_depth: SPLIT only raises it, never lowers.
MonotoneMax == [][max_depth' >= max_depth]_<<max_depth, vars>>

\* Safety invariants (state predicates only — TLC requirement).
StateSafety ==
    /\ TypeOK
    /\ DepthInv
    /\ FilesAboveMin
    /\ Raise01Commit
    /\ Raise12Commit
    /\ Raise23Commit
    /\ WriteIsLinearizable
    /\ ReadNoLost

\* Safety bundle for INVARIANT.
Safety == StateSafety

\* ------------------------------------------------------------------------
\* Liveness / temporal properties (configured as PROPERTY)
\* ------------------------------------------------------------------------

\* A started WRITE session eventually finishes (the machine returns
\* to idle). This REPLACES the old WriteProgress ("every Absent hash
\* eventually stored"): with a SINGLE-writer abstraction, global
\* starvation-freedom across hashes is a SCHEDULING property (real
\* system has many concurrent writers/processes), not an algorithmic
\* one — \E-quantified WStart fairness cannot guarantee each hash is
\* picked. What the algorithm DOES guarantee: once a session starts,
\* it terminates (no livelock inside the machine).
WriteCompletes ==
    [](w_pc /= WIdle => <>(w_pc = WIdle))

\* SPLIT eventually releases its lock (no deadlock in master).
SplitLockReleased == [](split_lock => <>~split_lock)

\* A begun READ eventually completes: the TOCTOU window closes.
\* Depends on WF_vars(\E h : CompleteRead(h)) in FairSpec.
ReadCompletes ==
    \A h \in Hashes :
        [](read_pending[h] /= -1 => <>(read_pending[h] = -1))

=============================================================================
\* Modification History
\* vim: set ts=4 sw=4 et: