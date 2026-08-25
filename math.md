# CascadeFS Mathematical Model

Analytical model of the CascadeFS algorithms for performance evaluation.
Consumer — `perf.md` (the formulas and numerical values are built from here).
Contract sources: `spec.md` (algorithms), `CascadeFS.tla` (verified
guarantees). Notation is fixed here and reused in `perf.md`.

---

## 1. Model and assumptions

**M1 (hash uniformity).** SHA-256 of pairwise distinct content is
modeled as a sequence of i.i.d. random variables; each hexadecimal
character of the hash ~ Uniform({0..f}). Corollary: path prefixes are
equiprobable and independent.

**M2 (entry flow).** Poisson flow of intensity λ (for concurrency);
for capacity calculations deterministic growth N(t) suffices.

**M3 (cascade structure).** Level ℓ consumes ℓ hex characters of the
prefix ⇒ the number of distinguishable directories at level ℓ:
k_ℓ = 16^ℓ. The cascade grouping 1→2→3→reset (spec §3) affects only
the nesting depth of paths, not k_ℓ.

**Notation.**

| Symbol | Meaning | Value |
|---|---|---|
| B | directory limit (DirLimit) | 4096 |
| h | branching factor (hex) | 16 |
| N | number of files in the DB | — |
| k_ℓ | directories at level ℓ | 16^ℓ |
| μ, σ | mean/stddev of a single directory's load | μ = N/k_ℓ, σ ≈ √μ |
| φ, Φ | density/CDF of the standard normal | — |
| L*(N) | working level (depth) for N files | §2 |

---

## 2. Level capacity and the working level L*(N)

### 2.1. Load distribution

N files across k = 16^ℓ directories: the load of a single directory
X ~ Binomial(N, 1/k); for large k — the normal approximation:

    X ≈ Normal(μ = N/k,  σ² = N/k·(1−1/k) ≈ μ).

The maximum over k bins (Gumbel/extremes):

    E[max X] ≈ μ + σ·√(2·ln k).

Level ℓ is exhausted when the fullest directory reaches B.
The threshold N_ℓ is the solution of

    μ + √(2·ℓ·ln 16 · μ) = B.        (*)

### 2.2. Threshold table

| ℓ | k_ℓ | μ*_ℓ (bin fill at threshold) | N_ℓ = k_ℓ·μ*_ℓ | σ* = √μ*_ℓ |
|---|---|---|---|---|
| 0 | 1 | 4096 (exact) | 4.10e3 | 0 |
| 1 | 16 | 3948 | 6.32e4 | 62.8 |
| 2 | 256 | 3888 | 9.95e5 | 62.4 |
| 3 | 4096 | 3843 | 1.57e7 | 62.0 |
| 4 | 6.55e4 | 3806 | 2.49e8 | 61.7 |
| 5 | 1.05e6 | 3773 | 3.96e9 | 61.4 |
| 6 | 1.68e7 | 3743 | 6.28e10 | 61.2 |

The maximum correction subtracts ~6–9% of capacity relative to the naive
16^ℓ·4096 (an allowance for variance: a full bin appears earlier than the
mean fill μ = B).

**Working level:** L*(N) = min{ ℓ : N < N_ℓ }.
Practical scale: up to 63 thousand files — depth 1; up to ~1 million — 2;
up to ~16 million — 3; up to ~250 million — 4.

---

## 3. Dynamics: split waves

### 3.1. Epoch of level ℓ

After the wave ℓ−1 → ℓ, each directory of level ℓ was created by a split
of its parent and receives a starting load of (B+1)/16 ≈ 256. The epoch
is the growth of bin load from 256 → 4096 (the number of files grows
~16-fold: from N_{ℓ−1} to N_ℓ). During the epoch min_depth = max_depth = ℓ:
writes and reads operate at a single level.

### 3.2. Split trigger (hazard)

A write to a bin with load exactly B triggers a split. Probability per
arriving write:

    p_split(N) = P(X = B) ≈ φ(z)/σ,   z = (B − μ)/σ,  μ = N/k_ℓ.

Peak at z = 0 (μ = B):

    p_max = 1/(σ·√(2π)) ≈ 1/(62·2.507) ≈ **0.64% per write**.

Off the peak — the Gaussian tail: for example at z = 3 (μ is 3σ below B)
p_split ≈ 0.0044/62 ≈ 0.007% — two orders of magnitude lower.

### 3.3. Wave parameters

Wave = the sequence of splits of all k_ℓ bins of level ℓ.
Number of bins at the B boundary simultaneously: E = k_ℓ·φ(z)/σ; at the
peak k_ℓ/155 (ℓ=2: ~1.7; ℓ=3: ~26; ℓ=4: ~422).

| Quantity | Formula | Value |
|---|---|---|
| Number of splits per wave | k_ℓ | 16^ℓ |
| Effective wave width (writes) | k_ℓ·σ·√(2π) | ≈ 155·16^ℓ |
| Writes per single split (averaged over the wave) | σ·√(2π) | ≈ 155 |
| Renames per split | ≈ B | ≈ 4096 (+ re-check 6.2.2) |
| Peak write amplification | B·p_max | **≈ 26 rename/write** |
| Total renames per wave | k_ℓ·B | (B/μ*_ℓ)·N_ℓ ≈ **1.04–1.09 × N_ℓ** |

Key corollaries:

- **Each wave moves the entire dataset once** (+4–9% for threshold
  rounding). In total over the lifetime (0 → N): total renames
  ≈ 1.1·N_ℓ(of the last wave) ⇒ **amortized ≤ ~1.1 rename per
  write**, concentrated in waves.
- Splits of different bins are independent (different flock) ⇒ the
  "storm" of ~26 parallel masters (ℓ=3) is not serialized among
  themselves.
- A fresh prefix after a split of its own bin always writes at ℓ+1
  (the subdirectories were created by the split, 4.2.2.1 descends
  past it) ⇒ **each bin undergoes ≈ one split per wave** (without
  repeated fills of level ℓ).

### 3.4. Cost of UPDATE (min_depth)

A successful raise m → m+1 requires checking "level m is empty + all
16^(m+1) directories of level m+1 exist" (6.4.3): Θ(16^(m+1))
opendirs. Numerical justification of the cap m ≤ 3 (spec 2.2): the
check 0→1..2→3 costs ≤ 4096 opendir, while 3→4 would require 65 536.

UPDATE is launched after each split (spec 2.3). Intermediate launches
during a wave are bound to fail (not all directories exist yet); with
an early exit at the first missing one their cost is
O(1/(1−f)), where f is the fraction of completed splits. Without an
early exit (the implementation scans everything) — pessimistically
Θ(16^ℓ · 16^ℓ) syscalls per wave. **Uncertainty point for perf.md**:
O(16^ℓ·log) vs O(16^(2ℓ)) — depends on the implementation of the check.

---

## 4. Cost of READ

The number of stat probes = ℓ(file) − min_depth + 1 (iteration 5.2
bottom-up).

| Mode | Probes | Probability/fraction |
|---|---|---|
| Epoch (steady state) | **exactly 1** | all files at ℓ = m |
| Wave (m = ℓ, file at ℓ+1) | 2 (miss at ℓ) | fraction f ∈ [0..1] |
| Wave (file still at ℓ) | 1 | fraction 1−f |

    E[probes] = 1 + f  ≤ 2.

The lag of min_depth after a wave is one UPDATE cycle (the raise is
performed by the master of the last split). There are no other sources
of >2 probes (files below m are impossible — the FilesAboveMin
invariant, verified by TLC).

Path length: ℓ hex characters of the prefix, path components
nest(ℓ) = ℓ for ℓ ≤ 3, otherwise 3 + ⌈(ℓ−3)/3⌉ (groups of 3, §3 spec).
The file name (64 hex characters of the hash) dominates over the path
at any ℓ ≤ 6: the path is ≤ 12 characters versus 64.

---

## 5. Cost of WRITE

Descent of 4.2 from the top (max_depth → target level):

| Component | Epoch | Wave |
|---|---|---|
| stat/opendir of levels | 1 | ≤ 2 |
| readdir for counting entries (4.2.3) | 1 directory | 1 directory |
| Size of the counted directory | grows 256 → 4096 | 256 (young) or 256→4096 (old) |
| File write | O(1) | O(1) |
| Fresh-prefix branch (4.2.2.2) | 0 readdir, write at ℓ+1 | — |

Average size of the scanned directory over the epoch (linear growth
of load 256 → 4096): **(256+4096)/2 = 2176 entries** (epoch ℓ=0:
(0+4096)/2 = 2048). Hence the main structural constant of a write:

    cost_write ≈ c_stat·1 + c_readdir·2176 + c_write,

i.e. a write is **O(1) in N** (a constant of ~2·10³ dirents per
write), not O(log N): depth has almost no effect; the price is set by
the mandatory count of 4.2.3. A candidate for future optimization
(a counter cache) — outside the spec.

Wave amplification adds, at peak, ≈ 26 rename/write (§3.3) and +1
stat. Probability of a restart due to the WU-01 fix (re-reading min at
commit, 4.2.5): P(UPDATE raised min inside the write window) — the
fraction of wave time × the conditional probability; expected for
< 1% of writes, the cost of a restart = a repeated descent
(≤ 2 stat + readdir).

---

## 6. Concurrency

- **SPLIT-lock is non-blocking** (6.1.1): the FAIL branch of 4.2.4.1
  terminates (the file is already at D+1) — writers **never wait**
  for the split master; the price of a miss = 1 unsuccessful flock.
- Writer contention for a single directory: M parallel writers,
  targets ~ Uniform(k_ℓ): P(pair collision) ≈ (M−1)/k_ℓ (epoch ℓ=2,
  M=32: ~1.2·10⁻¹ per writer — the level of KERNEL readdir
  serialization on a single inode, not of the algorithm).
- UPDATE holds the root-flock; UPDATE frequency = split frequency
  (155 writes per split during a wave, 0 outside) ⇒ the impact on
  writers is negligible (writers do not take the root-lock).
- Starvation of write sessions is ruled out at the algorithm level
  (WriteCompletes, TLC); inter-hash scheduling is a property of the OS.

## 7. SHA-256 collisions

P(at least one pair among N files coincides) ≤ N²/2^257 (birthday).
N = 10⁹: ~10⁻⁵⁹. For any practical N collisions are absent;
content addressing is safe without checks.

## 8. Model boundaries

- M1 is violated under adversary-controlled content (adversarial
  prefixes): all tables degrade to the "worst case: all files in one
  bin" — the cascade degenerates into linear depth along a single
  prefix.
- Not modeled: the FS page cache / dentry cache (real readdir is
  cheaper on hot directories), the cost of rename depending on the
  FS, network file systems.
- σ ≈ 62 = √B — the common scale of all "wave" constants; for a
  different B all numbers are recalculated by substitution into the
  formulas of §2–3.

---

## 9. Summary of quantities for perf.md

| # | Quantity | Formula | Baseline value (B=4096) |
|---|---|---|---|
| 1 | Threshold of level ℓ | μ + √(2ℓ·ln16·μ) = B | N_ℓ: 4.1e3 / 6.3e4 / 1.0e6 / 1.6e7 / 2.5e8 / 4.0e9 |
| 2 | σ of a bin at the threshold | √μ* | ≈ 62 (=√B) |
| 3 | Peak split probability per write | 1/(σ√(2π)) | 0.64% |
| 4 | Writes per split in a wave | σ√(2π) | ≈ 155 |
| 5 | Renames per split | ≈ B | 4096 |
| 6 | Peak write amplification | B/(σ√(2π)) | ≈ 26 rename/write |
| 7 | Renames per wave | k_ℓ·B | ≈ 1.04–1.09 × N_ℓ |
| 8 | Rename amortization | Σwaves/N | ≤ ~1.1 per write |
| 9 | READ probes | 1 + f | 1 (epoch), ≤2 (wave) |
| 10 | WRITE: dirents per count | average bin load | 2176 (epoch), 2048 (ℓ=0) |
| 11 | WRITE: stat probes | 1–2 | O(1) in N |
| 12 | UPDATE: opendirs of a successful raise | 16^(m+1) | ≤ 4096 (cap m=3) |
| 13 | UPDATE cost per wave | 16^ℓ·log .. 16^(2ℓ) | implementation uncertainty |
| 14 | Path components of level ℓ | nest(ℓ) | ℓ≤3: ℓ; beyond that 3+⌈(ℓ−3)/3⌉ |
| 15 | Collision of M writers | ≈ (M−1)/16^ℓ | negligible for ℓ≥2 |
| 16 | P(hash collision) | N²/2^257 | < 10⁻⁵⁹ at N=10⁹ |
