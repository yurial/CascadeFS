# CascadeFS performance: analytical estimate

Numerical performance model. All formulas and probabilities come from
`math.md` (§9, "summary of quantities"); operation costs were measured on
the reference machine (calibration below). The model is analytical: the
repository has no benchmarks; to get numbers for another machine,
substitute your costs into the calibration table and recalculate (all
final formulas are linear in the costs).

---

## 1. Calibration of operation costs (reference machine)

Method: median over 7 runs, tmp directory on ext4 (/tmp), warm cache,
Linux 6.8, 64-bit. Python 3.12 (os.* is a thin wrapper over syscalls).

| Key | Operation | Cost, µs | Note |
|---|---|---|---|
| `c_stat_hit` | stat on an existing path | 6.1 | 1 path component |
| `c_stat_miss` | stat on a missing path | 4.3 | ENOENT — cheaper than a hit |
| `c_re` | readdir: one directory entry | 0.95 | scandir, 600-entry dir |
| `c_opendir` | opening a directory stream | ≈ 4 | ≈ c_stat_hit; included in c_re for small dirs |
| `c_rename` | rename within the same directory | 21.5 | metadata, single filesystem |
| `c_write` | open+write+close, 4 KiB file | 236 | new inode creation |
| `c_flock` | flock EX\|NB + unlock (pair) | 1.9 | uncontended lock |

Calibration assumptions: single-component path; dentry cache effects
of large directories are not modeled (real readdir of large directories
is cheaper on a hot cache), no fsync (the spec does not require it).

## 2. READ cost (by modes of math.md §4)

Formula from math.md: probes = ℓ − min_depth + 1 stat; epoch = 1 probe.

    T_read(epoch)   = c_stat_hit                          =   6.1 µs
    T_read(wave,f)  = c_stat_miss + c_stat_hit = 1+f → ≤  ≈  10.4 µs

The whole range of modes is **≤ 10.4 µs per read**, i.e. ~100K
reads/s per core. READ does not depend on N, depth, or phase.

## 3. WRITE cost

From math.md §5: descent (1–2 stats) + directory count (readdir of
average load μ̄ = 2176 entries in an epoch, 2048 at ℓ=0, 256 — young,
right after a split) + file write. Additionally: the final-name rename
is not needed (write = creation), i.e. c_write is already final.

    T_write(epoch) = c_stat·1 + c_re·2176 + c_write
                   = 6.1 + 2070 + 236              ≈ 2.3 ms
    T_write(ℓ=0)   = 6.1 + 0.95·2048 + 236         ≈ 2.2 ms
    T_write(wave, young bin) = 6.1 + 243 + 236     ≈ 0.5 ms

The upper-bound estimate does not depend on N (O(1), math.md §5). The
dominant component is **readdir counting 4.2.3: ~90% of write time**.

## 4. Split wave: peak and average effects

From math.md §3.3 (quantities 3–8): peak hazard 0.64%/write, 155
writes/split, 4096 renames per split, the wave moves ≈1.05×N_ℓ.

Cost of a single split (master):

    T_split = c_flock + 16·(c_opendir + c_write) + B·(c_re + c_rename) + UPDATE_own
            ≈ 1.9 + 16·(4 + 236) + 4096·22.45        ≈ 96 ms

(16 mkdir ≈ 3.8 ms included; UPDATE part — see §5, ≤16 ms.)

Peak write during a wave (pessimistic, "a split is running nearby"):

    T_write(wave) = T_write(epoch) + p_max·T_split_per_queued_write
    — the master works in parallel (try-lock does not block, math.md §6),
    so for a single writer the wave adds only +1 stat
    miss (young level): see §3, the "wave" row.

End-to-end amortization of renames (math.md No. 8):

    rename/write ≤ 1.1 ⇒ per-write addition ≈ 1.1·c_rename ≈ 24 µs
    — amortized write ≈ T_write(epoch) + 24 µs ≈ 2.33 ms.

Conclusion: **the wave does not change the order of magnitude**, but it
creates burst load: at the peak (peak width of ~155·k_ℓ writes) every
155th writer becomes the master and spends ~92 ms locally (the rest —
0.5 ms per write).

## 5. UPDATE: cost of min_depth promotion

A successful promotion m→m+1 (math.md No. 12): 16^(m+1) opendirs.

    T_raise(m→m+1) = 16^(m+1)·c_opendir
    m=0→1: 16·4   = 64 µs
    m=1→2: 256·4  ≈ 1.0 ms
    m=2→3: 4096·4 ≈ 16 ms

Intermediate (unsuccessful) runs: with an early exit at the first
missing directory — O(1/(1−f)) opendirs, where f is the fraction of
completed splits of the wave (~k_ℓ/2 uniformly on average): the worst
case without early exit is 16^ℓ·16^ℓ opendirs (math.md No. 13).
The "early exit" setting is mandatory for ℓ≥3 (see math.md §3.4):
without it, an ℓ=3 wave would cost 4096·4096·4 µs ≈ 67 s of total CPU.

UPDATE frequency = split frequency = 1/155 writes in a wave; outside
a wave, UPDATE is not started (the promotion condition does not hold,
early exit — microseconds). The impact on writer throughput is zero
(the root lock does not intersect the write path).

## 6. Summary throughput table

One core, a sequential stream (no contention; for concurrency —
math.md §6, collisions are negligible at ℓ≥2).

| Phase / operation | Latency | Throughput (1 core) | Comment |
|---|---|---|---|
| READ, any phase | 6–10 µs | ~100–160K/s | O(1); +f·4.3 µs in a wave |
| WRITE, epoch ℓ≥1 | ~2.3 ms | ~430/s | 90% — readdir count |
| WRITE, ℓ=0 | ~2.2 ms | ~450/s | DB start |
| WRITE, young bin (wave) | ~0.5 ms | ~2000/s | readdir 256 |
| WRITE amortized | ~2.33 ms | ~430/s | +1.1 rename/write |
| SPLIT (master, local) | ~96 ms | — | burst; parallel to readers/writers |
| UPDATE raise 2→3 | ~16 ms | — | once per ℓ=3 wave |
| ℓ=2 wave in full | ~23 s CPU (256×96 ms ≈ 25 s) | — | spread over ~4.0e4 writes ≈ 1.5 min wall at 430 writes/s |
| ℓ=3 wave in full | ~6.0 min CPU (4096×96 ms ≈ 6.6 min) | — | over ~6.4e6 writes ≈ 4.1 h wall |

Consistency check: the ℓ=2 wave — 256 splits × 92 ms ≈ 24 s of CPU ✓
(matches the rename count); the wave's wall-time = number of writes
to the threshold / write speed.

## 7. Scale ladder (summary)

| N | Level ℓ | WRITE latency | Waves survived | Total split CPU |
|---|---|---|---|---|
| 4e3 | 0→1 | 2.2 ms | 1 (0.02 s CPU) | 92 ms |
| 6e4 | 1 | 2.3 ms | 2 (~0.6 s) | <1 s |
| 1e6 | 2 | 2.3 ms | 3 (~24 s) | ~25 s |
| 1.6e7 | 3 | 2.3 ms | 4 (~6 min) | ~6.6 min |
| 2.5e8 | 4 | 2.3 ms | 5 (~96 min) | ~1.6 h |

WRITE throughput **does not degrade as N grows** (O(1));
the price of growth is periodic burst waves whose duration grows
linearly with N_ℓ (6 min of CPU at N=1.6e7, spread over hours).

## 8. Applicability boundaries

- Syscall costs — reference machine (ext4, warm, no fsync); recalculate
  the §1 calibration for the target filesystem.
- Not accounted for: page/dentry cache of large directories (real
  readdir is cheaper when hot), core parallelism (split masters run
  in parallel, math.md §3.3), network filesystems.
- WU-01 write restarts (<1% of writes, math.md §5) — within the
  margin of error.
- A write counter cache (eliminating the readdir count) would cut
  T_write by ~9.5× (to ~250 µs) — the No. 1 optimization candidate
  (noted in math.md §5), requires a spec change.
