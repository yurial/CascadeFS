# Hint: hints for efficient implementations and optimizations

A catalog of techniques for the future implementation of CascadeFS. Each item
is a potential optimization with applicability conditions and a cost; anything
that changes the observable behavior of the algorithms requires a revision of
spec.md + TLA (rule AGENTS 2.1). Statuses: `idea` — not written up,
`proposed` — proposed in spec/perf, `adopted` — in the spec.

Selected based on the measurements in `perf.md` (bottlenecks) and the
`math.md` model (which constants dominate where). Savings priority:

1. WRITE ~2.3 ms, of which **~90% is counting entries (4.2.3)**;
2. SPLIT ~96 ms — 4096×(readdir+rename), waves are linear in N_ℓ;
3. READ 6–10 µs — already nearly the price of a stat, nothing to optimize.

---

## 1. Counting entries without readdir (goal #1, ~9.5× on write)

### H-1.1. Directory st_size as an approximate counter — `proposed`
**Idea.** On ext4/tmpfs/ZFS `stat(dir).st_size` grows linearly with
the number of entries: measured (ext4: 81.92 B/entry with 64-hex
names; tmpfs: exactly 20 B/entry + 40 B). One stat (~6 µs) instead of
a readdir of 2176 entries (~2 ms).
**Conditions.** Fixed-length names (our 64 hex — yes); filesystems
from the whitelist; the limit is soft (overshoot ~1.2% per ext4 block
quantum — indistinguishable from a legal race of two writers); there
is no DELETE in the spec, after unlink the ext4 size does not shrink
(conservative).
**FS where it does not work.** btrfs, APFS, NTFS, NFS (st_size does
not depend on entries) — there the fallback is readdir (current
behavior).
**Calibration.** The coefficient K_fs is captured once by comparing
stat vs one readdir (at startup and on every SPLIT master — it holds
the full list anyway; divergence > quantum → recalibration).
No state is stored — there is no repair protocol after a crash.
**Required changes.** spec 1.2, 4.2.3; perf §3/§8 (write ~250 µs).
**TLA.** No changes: `CountAt(w_D) < DirLimit` abstracts away the
source of the count.

### H-1.2. mmap array `.counts` (u32 per bin) with fetch_add — `idea`
**Idea.** An exact O(1) counter: `old = fetch_add(count[D],1)` in
4.2.3; the SPLIT master overwrites the children's counters with the
result of its readdir (the repair point); level growth — a new file +
rename.
**Downsides vs H-1.1.** A new service file, a crash-consistency
protocol (the "file → increment" order yields a safe undercount),
repair/versioning. Keep as a fallback for filesystems where H-1.1 is
inapplicable but readdir is expensive (NFS?).
**Required changes.** spec 1.2, 4.2.3, 6.2.2, a 2.1-like item.

### H-1.3. APFS ATTR_DIR_ENTRYCOUNT — `idea`
`getattrlist(ATTR_DIR_ENTRYCOUNT)` — an exact count in a single call;
macOS build only, guard `#ifdef`. The natural fast path instead of
H-1.1 on APFS.

### H-1.4. Asynchronous counting (write immediately, check the limit in the background) — `idea`
The write path is O(1) without any counters, but the overshoot is
unbounded under a stream into a single bin → a valve is needed (a
periodic stat per H-1.1 or a daemon). Not adopted on its own; combine
with H-1.1 as "check not every write, but every k-th one" when the
error is low.

## 2. READ / path descent

### H-2.1. Buffered getdents64 — `idea`
readdir with a 64–256 KiB buffer: ~2–3× fewer syscalls per entry —
speeds up both remaining bulk readdirs (SPLIT master, H-1.1 fallback)
and any service traversals. Portable (Linux).
**No spec changes** (an implementation detail).

### H-2.2. statx(mask) instead of stat — `idea`
Request only the needed attributes (existence/size): saves a few µs
per descent probe. Linux 4.11+ only; the effect is small, take it
together with H-2.3.

### H-2.3. openat2(RESOLVE_IN_DEPTH)/openat with dirfd — `idea`
Cascade descent without absolute paths: hold the parent's fd,
`openat(fd, next, ...)` — saves path-walk at ℓ≥2 (≤12 components).
Does not cure the path-count problem (that is ~readdir), but reduces
the READ/WRITE descent constant. Portable subset: `openat` is
POSIX everywhere.

## 3. SPLIT (goal #2: a 96 ms burst × k_ℓ times per wave)

### H-3.1. renameat2(RENAME_NOREPLACE/EXCHANGE) — `idea`
`RENAME_NOREPLACE` (Linux) provides an atomic "do not overwrite" if
the target bin already has a file with the same name (a hash
collision or a repeated split) — replaces the existence check with a
separate stat. `RENAME_EXCHANGE` — for atomic replacement during
repair. Where unavailable (macOS/Windows) — the fallback is
`rename()` per the spec.

### H-3.2. Batch move without re-scan — `proposed`
6.2.2 already requires a re-check of "has anything been added" and a
retry; keep the directory entry stream in memory (one readdir), do
renames from the list, and re-readdir only if new entries arrived.
This is the current letter of the spec — fix it as the mandatory
implementation so as not to scan k times.

### H-3.3. Deferred rmdir (6.2.3) — `idea`
Collect emptied directories and remove them in a batch after the lock
is released: less noise for concurrent READs (fewer ENOENT
re-lookups during waves). No contract changes (is rmdir outside the
lock window anyway? — check the spec: 6.2.3 is performed by the
master before 6.3).

### H-3.4. Master throttling — `idea`
Voluntary pauses between renames inside a split (nanosleep every N
renames), so that the 96 ms burst does not monopolize io from
concurrent READs of the epoch. Trade off against the wall-time of the
wave; enable based on the contention metric. An implementation
detail, the spec does not change.

## 4. UPDATE / .depth_map

### H-4.1. Early exit of the 6.4.3 check — `adopted` (perf.md §5: without it L3 = 67 s CPU/wave)
The first missing directory of level m+1 → stop. Already reflected in
perf; make sure the wording of spec 6.4.3 permits it (currently the
text says "checks" — the interpretation "up to the first missing one"
is fixed in perf; when editing spec — formalize explicitly).

### H-4.2. Deferred UPDATE: only the last master of the wave — `idea`
An UPDATE after EVERY split mostly fails (not all directories exist
yet). Consider the owner of the promotion to be the master that
completes the k_ℓ-th split (locally: "I am the last" cannot be
determined — but UPDATE can be triggered by the split counter in a
`.depth_map` extension). Removes O(k_ℓ) idle early-exit runs (cheap,
but clutters the log/statistics). `idea`, requires care with crashes
(loss of the last master → a stuck min_depth until the next split;
cured by a periodic UPDATE tick).

## 5. Storage/files

### H-5.1. O_TMPFILE + linkat for atomic publication — `idea`
Write to a temporary inode (it does not appear in the directory →
H-1.1 counters see no garbage), then `linkat` to the target name —
publication is atomic, a crash leaves no fragments. Linux; the
fallback is temp+rename per the spec (2.5 is preserved).

### H-5.2. copy_file_range/sendfile for dedup migration — `idea`
Not for the current spec (files are written once), but in case a
compaction/re-shard transfer between filesystems appears.

### H-5.3. msync order for .depth_map — `adopted` (spec 2.1)
CAS + msync(MS_SYNC) is already in the spec; hint: on Linux fsync(fd)
instead of msync is often cheaper for rare writes — measure on the
target FS.

## 6. Misc OS topics

### H-6.1. Windows: ReplaceFile/MoveFileEx(MOVEFILE_REPLACE_EXISTING) — `idea`
The equivalent of the rename atomicity of 2.5; `.lock.<dirname>` is
already in the spec (6.1.1.2). FindFirstFile traversals = the readdir
fallback of H-1.1.

### H-6.2. flock: LOCK_SH for READ traversals — `idea`
Service traversals (the UPDATE check 6.4.3) only need a shared lock
on the root — to avoid conflicting with writers on EX. Note: the
spec distinguishes only the exclusivity of the root lock (6.4.1).

### H-6.3. io_uring for split batch operations — `idea`
A split = thousands of homogeneous renames: io_uring (Linux 5.1+)
cuts syscall overhead from ~21.5 µs → ~1–2 µs per operation. Requires
rebuilding T_split in perf (on the order of 96 ms → ~15–20 ms). Linux
only; the fallback is plain rename. An implementation detail, the
spec does not change (the renames are the same).

---

## Priorities (per math/perf)

| Place | Hint | Gain | Cost |
|---|---|---|---|
| WRITE 90% | H-1.1 (st_size) | ~9.5× | spec 1.2/4.2.3 edit, FS fallback table |
| WRITE minor | H-2.3 (openat descent) | ~tens of µs | pure implementation |
| SPLIT burst | H-6.3 (io_uring) | ~5× of split | Linux-only, complexity |
| SPLIT completeness | H-3.2 (no re-scan) | wording fix | ~0 |
| UPDATE idle runs | H-4.2 | cleanliness/log | split counter protocol |
| portability | H-6.1 (Win), H-1.3 (APFS) | coverage | #ifdef branches |

## Rules for adding hints

- A new hint: the wording "Idea / Conditions / FS where it does not
  work / Required changes (spec/perf/TLA?) / Status". The status
  changes only together with the corresponding edit of the artifact.
- Anything that touches observable behavior → AGENTS 2.1 (a spec ↔
  TLA revision in one commit) + a verify.sh run.
- Measurements go in perf.md (calibration §1); only references here.
