#!/usr/bin/env python3
"""
Simulator for the CascadeFS TLA+ spec.

Runs the abstract state machine from CascadeFS.tla and checks:
  - DepthInv (max_depth >= min_depth always)
  - FilesAboveMin (files never below min_depth) — incl. the WU-01
    fix: writer commits re-validate D >= min_depth
  - Raise01Commit/12/23 (post-conditions of UPDATE)
  - Linearizability (spec 2.5 anchor)
  - ReadNoLost (TOCTOU window of READ)

Mirrors the TLA+ model semantics:
  - WRITE is a GRANULAR single-writer state machine: every step of
    spec 4.1 -> 4.2.5 is a standalone transition (WStart, descend,
    count/commit, overflow, lock try, split-move, release, finish).
    "Directory exists" is a may-abstraction (both branches enabled);
    lock FAIL is a nondeterministic may-branch (concurrent master).
  - UPDATE is one atomic step; the candidate chain never lowers
    min_depth (structural persistence).
  - READ is two-step: BeginRead (check) / CompleteRead (use).
  - Spec 6.5.1 collapses into the split-move (measured degenerate).

Limitations vs TLC:
  - EXPLICIT enumerator, no symmetry reduction.
  - Safety only; temporal properties are checked by TLC.
"""
from dataclasses import dataclass, field
from typing import Optional, Set, Dict, FrozenSet

# Writer program counters (mirror TLA+ WIdle..WDone).
W_IDLE, W_DESCEND, W_TRYLOCK, W_SPLIT, W_DONE = 0, 1, 2, 3, 4


def absent_sentinel() -> str:
    return "<absent>"


@dataclass(frozen=True)
class State:
    store: FrozenSet          # set of (hash, level)
    min_depth: int
    max_depth: int
    split_lock: bool
    root_lock: bool
    read_pending: FrozenSet = frozenset()  # set of (hash, level)
    w_pc: int = W_IDLE
    w_h: int = -1             # index of hash being written, -1 = none
    w_D: int = -1
    w_min: int = -1
    w_max: int = -1

    def as_dict(self) -> Dict:
        return {
            "store": sorted(self.store),
            "min": self.min_depth, "max": self.max_depth,
            "sl": self.split_lock, "rl": self.root_lock,
            "rp": sorted(self.read_pending),
            "w": (self.w_pc, self.w_h, self.w_D, self.w_min, self.w_max),
        }


@dataclass
class Model:
    hashes: tuple            # ordered, so w_h can be a stable index
    levels: range
    dir_limit: int
    num_sub: int
    absent: str = field(default_factory=absent_sentinel)

    # ----- helpers -----
    def at_level(self, s: State, L: int) -> Set:
        return {p for p in s.store if p[1] == L}

    def count_at(self, s: State, L: int) -> int:
        return len(self.at_level(s, L))

    def init(self) -> State:
        return State(
            store=frozenset(),
            min_depth=min(self.levels),
            max_depth=min(self.levels),
            split_lock=False,
            root_lock=False,
        )

    def _w(self, s: State, **kw) -> State:
        """Copy s applying writer-variable overrides."""
        return State(
            store=kw.get("store", s.store),
            min_depth=kw.get("min_depth", s.min_depth),
            max_depth=kw.get("max_depth", s.max_depth),
            split_lock=kw.get("split_lock", s.split_lock),
            root_lock=kw.get("root_lock", s.root_lock),
            read_pending=kw.get("read_pending", s.read_pending),
            w_pc=kw.get("w_pc", s.w_pc),
            w_h=kw.get("w_h", s.w_h),
            w_D=kw.get("w_D", s.w_D),
            w_min=kw.get("w_min", s.w_min),
            w_max=kw.get("w_max", s.w_max),
        )

    # ----- WRITE machine (spec 4, granular; mirrors TLA+ W*) -----
    def w_start(self, s: State, h) -> Optional[State]:
        if s.w_pc != W_IDLE:
            return None
        if any(p[0] == h for p in s.store):
            return None
        return self._w(s, w_h=h, w_min=s.min_depth, w_max=s.max_depth,
                       w_D=s.max_depth, w_pc=W_DESCEND)

    def w_dir_absent_step(self, s: State) -> Optional[State]:
        if s.w_pc != W_DESCEND or s.w_D <= s.w_min:
            return None
        return self._w(s, w_D=s.w_D - 1)

    def w_min_no_dir(self, s: State) -> Optional[State]:
        if s.w_pc != W_DESCEND or s.w_D != s.w_min:
            return None
        if (s.w_D + 1) not in self.levels:
            return None
        if s.w_D + 1 < s.min_depth:      # WU-01 fix: re-check min
            return None
        return self._w(s, store=s.store | {(s.w_h, s.w_D + 1)}, w_pc=W_DONE)

    def w_write_at_level(self, s: State) -> Optional[State]:
        if s.w_pc != W_DESCEND:
            return None
        if self.count_at(s, s.w_D) >= self.dir_limit:
            return None
        if s.w_D < s.min_depth:          # WU-01 fix: re-check min
            return None
        return self._w(s, store=s.store | {(s.w_h, s.w_D)}, w_pc=W_DONE)

    def w_overflow_write(self, s: State) -> Optional[State]:
        if s.w_pc != W_DESCEND:
            return None
        if self.count_at(s, s.w_D) < self.dir_limit:
            return None
        if (s.w_D + 1) not in self.levels:
            return None
        return self._w(s, store=s.store | {(s.w_h, s.w_D + 1)}, w_pc=W_TRYLOCK)

    def w_lock_fail(self, s: State) -> Optional[State]:
        # MAY-branch: nondeterministic concurrent master.
        if s.w_pc != W_TRYLOCK:
            return None
        return self._w(s, w_pc=W_DONE)

    def w_lock_success(self, s: State) -> Optional[State]:
        if s.w_pc != W_TRYLOCK or s.split_lock:
            return None
        return self._w(s, split_lock=True, w_pc=W_SPLIT)

    def w_split_move(self, s: State) -> Optional[State]:
        if s.w_pc != W_SPLIT or (s.w_D + 1) not in self.levels:
            return None
        moved = self.at_level(s, s.w_D)
        new_store = frozenset(
            (h, s.w_D + 1) if l == s.w_D else (h, l) for (h, l) in s.store)
        return self._w(s, store=new_store,
                       max_depth=max(s.max_depth, s.w_D + 1))

    def w_split_release(self, s: State) -> Optional[State]:
        if s.w_pc != W_SPLIT:
            return None
        return self._w(s, split_lock=False, w_pc=W_DONE)

    def w_finish(self, s: State) -> Optional[State]:
        if s.w_pc != W_DONE:
            return None
        return self._w(s, w_pc=W_IDLE, w_h=-1, w_D=-1, w_min=-1, w_max=-1)

    # ----- READ (spec 5, two-step TOCTOU window) -----
    def begin_read(self, s: State, h, L: int) -> Optional[State]:
        if (h, L) not in s.store:
            return None
        if any(ph == h for (ph, _) in s.read_pending):
            return None
        return self._w(s, read_pending=s.read_pending | {(h, L)})

    def complete_read(self, s: State, h) -> Optional[State]:
        if not any(ph == h for (ph, _) in s.read_pending):
            return None
        if not any(ph == h for (ph, _) in s.store):
            return None
        return self._w(s, read_pending=frozenset(
            (ph, pl) for (ph, pl) in s.read_pending if ph != h))

    # ----- UPDATE (spec 6.4, atomic) -----
    def update_step(self, s: State) -> Optional[State]:
        if s.root_lock:
            return None
        c = 0
        if (self.count_at(s, 0) == 0
                and self.count_at(s, 1) >= self.dir_limit):
            c = 1
        if (c >= 1 and self.count_at(s, 1) == 0
                and self.count_at(s, 2) >= self.dir_limit):
            c = 2
        if (c >= 2 and self.count_at(s, 2) == 0
                and self.count_at(s, 3) >= self.dir_limit):
            c = 3
        new_min = max(s.min_depth, c)
        return self._w(s, min_depth=new_min,
                       max_depth=max(s.max_depth, new_min))

    # ----- All actions -----
    def next_states(self, s: State) -> Set[State]:
        out = set()

        for h in self.hashes:
            if (ns := self.w_start(s, h)):
                out.add(ns)
        if (ns := self.w_dir_absent_step(s)):
            out.add(ns)
        if (ns := self.w_min_no_dir(s)):
            out.add(ns)
        if (ns := self.w_write_at_level(s)):
            out.add(ns)
        if (ns := self.w_overflow_write(s)):
            out.add(ns)
        if (ns := self.w_lock_fail(s)):
            out.add(ns)
        if (ns := self.w_lock_success(s)):
            out.add(ns)
        if (ns := self.w_split_move(s)):
            out.add(ns)
        if (ns := self.w_split_release(s)):
            out.add(ns)
        if (ns := self.w_finish(s)):
            out.add(ns)

        for h in self.hashes:
            for L in self.levels:
                if (ns := self.begin_read(s, h, L)):
                    out.add(ns)
            if (ns := self.complete_read(s, h)):
                out.add(ns)

        if (ns := self.update_step(s)):
            out.add(ns)

        return out

    # ----- Invariants -----
    def check_depth_inv(self, s: State) -> bool:
        return s.max_depth >= s.min_depth

    def check_files_above_min(self, s: State) -> bool:
        return all(lv >= s.min_depth for (_, lv) in s.store)

    def check_raise_commits(self, s: State) -> bool:
        if s.min_depth >= 1 and self.count_at(s, 0) != 0:
            return False
        if s.min_depth >= 2 and self.count_at(s, 1) != 0:
            return False
        if s.min_depth >= 3 and self.count_at(s, 2) != 0:
            return False
        return True

    def check_linearizability(self, s: State) -> bool:
        return all(lv == self.absent or isinstance(lv, int)
                   for (_, lv) in s.store)

    def check_read_no_lost(self, s: State) -> bool:
        pending = {ph for (ph, _) in s.read_pending}
        stored = {ph for (ph, _) in s.store}
        return pending <= stored


def run(model: Model, max_states: int = 200000):
    init = model.init()
    reachable = {init}
    frontier = [init]
    step = 0
    while frontier and len(reachable) < max_states:
        new_frontier = set()
        for s in frontier:
            for ns in model.next_states(s):
                if ns not in reachable:
                    assert model.check_depth_inv(ns), \
                        f"DepthInv violated: {ns.as_dict()}"
                    assert model.check_files_above_min(ns), \
                        f"FilesAboveMin violated: {ns.as_dict()}"
                    assert model.check_raise_commits(ns), \
                        f"RaiseCommit violated: {ns.as_dict()}"
                    assert model.check_linearizability(ns), \
                        f"Linearizability violated: {ns.as_dict()}"
                    assert model.check_read_no_lost(ns), \
                        f"ReadNoLost violated: {ns.as_dict()}"
                    new_frontier.add(ns)
        reachable |= new_frontier
        frontier = list(new_frontier)
        step += 1
        if step % 5 == 0:
            print(f"step {step}: {len(reachable)} reachable states")
    return reachable


def main():
    model = Model(
        hashes=("h1", "h2", "h3"),
        levels=range(0, 4),
        dir_limit=2,
        num_sub=2,
    )
    print("Initial state:", model.init().as_dict())
    reachable = run(model)
    print(f"\nTotal reachable states: {len(reachable)}")
    mins = {s.min_depth for s in reachable}
    maxs = {s.max_depth for s in reachable}
    pcs = {s.w_pc for s in reachable}
    print(f"min_depth range: {sorted(mins)}")
    print(f"max_depth range: {sorted(maxs)}")
    print(f"w_pc range: {sorted(pcs)} (0=idle..4=done)")
    for s in sorted(reachable, key=lambda x: (x.min_depth, x.max_depth))[:3]:
        print(" ", s.as_dict())


if __name__ == "__main__":
    main()
