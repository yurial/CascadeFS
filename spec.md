# CascadeFS Storage Specification (v1.0)

## 1. Basic Principles

**1.1.** **Key and file name:** The key is a cryptographic hash (SHA-256). The file name is the full HEX string of the hash.

**1.2.** **Directory limit:** The limit is **4096** entries. Both files and nested directories are counted. Service files (`.depth_map` and lock files `.lock.*`) are ignored. To obtain the entry count, the directory contents are read (e.g., `opendir`/`readdir`), because standard `stat()` does not return the number of items. When the limit is exceeded, resharding is initiated.

**1.3.** **DB root:** Contains the `.depth_map` file, service lock files, and level directories.

## 2. Global Metadata (`.depth_map`)

**2.1.** Contains the values: `min_depth` and `max_depth` (default `0`). The file is mapped into memory shared between processes (mmap on all supported OSes — Linux, macOS, Windows), so all processes immediately see the updated values of the variables. Atomicity of updates is ensured by CAS (see 6.1.2.2). After each write of the values, `msync(MS_SYNC)` or an equivalent (`FlushViewOfFile` on Windows) is called to guarantee durability against a process/OS crash.

**2.2.** **Semantics:** `min_depth` is an optimization parameter. There are no file paths shallower than `min_depth` in the system. All algorithms operate correctly even when `min_depth` is too low. IMPORTANT: `min_depth` is never raised above 3, because it is very hard to verify the conditions for raising `min_depth` above 3.

**2.3.** Updated by the resharding Master after the split completes.

**2.4.** **Invariant:** `max_depth >= min_depth` always holds. A violation is possible on failures and is repaired by the recovery procedure (see 6.4).

**2.5.** **WRITE/READ linearizability (invariant):** A file write is considered complete at the moment the write function returns control. A Read performed before this moment may not find the file (partial visibility during the write is acceptable). A Read performed after the write function returns control MUST find the file — a successful write is atomic with respect to subsequent reads. The guarantee is provided by the atomicity of `rename(2)` on POSIX systems (atomic inode replacement in the directory) and equivalent means of the target OS on other platforms.

## 3. Path Generation

**3.1.** A level is formed by a cascade of prefixes: 1 character → 2 characters → 3 characters → new level (1 character), and so on.

**3.2.** *Example for the hash `abcdef...`:*

* Level 0: `/abcdefg...`
* Level 1: `/a/abcdefg...`
* Level 2: `/ab/abcdefg...`
* Level 3: `/abc/abcdefg...`
* Level 4: `/abc/d/abcdefg...`
* Level 5: `/abc/de/abcdefg...`
* Level 6: `/abc/def/abcdefg...`

## 4. Write Algorithm (WRITE)

**4.1.** Reads `min_depth`, `max_depth`.

**4.2.** Iterates level `D` from `max_depth` down to `min_depth` inclusive in descending order (`D = max_depth, max_depth-1, ..., min_depth`):

**4.2.1.** Builds the path of level `D`. Opens the directory (or calls the equivalent of `opendir` / `scandir`).

**4.2.2.** If the directory does not exist:

* **4.2.2.1.** If `D > min_depth`: proceeds to the next level (`D-1`).
* **4.2.2.2.** If `D == min_depth`: the directory for this prefix at level `min_depth` is absent (no file with the given prefix has been written at this level). In this case the writer **does not descend lower**, but moves to level `D+1`, automatically creates the directory if necessary, and writes the file there. Before writing, the writer **re-reads the current `min_depth`** from `.depth_map` (mmap, a cheap operation); if `D+1 < min_depth_current`, the write at `D+1` is not performed — the writer restarts the algorithm from step 4.1. (End)

**4.2.3.** If the directory exists (for the root `D=0` the directory always exists), computes the `entry` count (reads the directory contents, counts files and directories, ignoring service ones).

**4.2.4.** If `entry` >= 4096:

  The writer generates the path of the next level (`D+1`) and writes to it, automatically creating the directory if necessary.

  Initiates the **SPLIT lock acquisition procedure (Section 6)**:

  * **4.2.4.1.** **If the lock is NOT acquired (FAIL):** The directory is currently being resharded. (End)
  * **4.2.4.2.** **If the lock is acquired (SUCCESS):** The writer becomes the Master and performs **SPLIT (Section 6)**. (End)

**4.2.5.** If `entry` < 4096 — writes the file. Before writing, the writer **re-reads the current `min_depth`** from `.depth_map` (mmap, a cheap operation); if `D < min_depth_current`, the write at `D` is not performed — the writer restarts the algorithm from step 4.1 (UPDATE could have raised `min_depth` above `D` during the descent, while the writer was working with the snapshot from 4.1; a write below `min_depth` would make the file invisible to READ, which iterates from `min_depth` upward). (End)

## 5. Read Algorithm (READ)

**5.1.** Reads `min_depth`, `max_depth`.

**5.2.** Iterates level `D` from `min_depth` to `max_depth`.

**5.2.1.** Builds the path of level `D`. If the file does not exist, continues the loop. If the file exists: opens it and returns the data. (End)

## 6. Resharding Algorithm (SPLIT)

The resharding lock is implemented in two ways depending on OS capabilities. The SPLIT algorithm is uniform; only the method of lock acquisition and release differs.

### 6.1. Lock Acquisition (Non-blocking Test + Wait)

The process that detected the overflow attempts to become the "Master" using a **non-blocking** request:

**6.1.1.** The process attempts to become the "Master":

* **6.1.1.1.** **Systems with `flock` support (Linux, macOS):**
  Opens the directory (`open(path, O_RDONLY)`) and calls `flock(fd, LOCK_EX | LOCK_NB)`.
* **6.1.1.2.** **Systems without `flock` (Windows, etc.):**
  Attempts to atomically create the file `.lock.<dirname>` one level above the overflowing directory (`open(".lock.<dirname>", O_CREAT | O_EXCL)`). For the root directory, the `.lock` file is created inside the root directory itself.

**6.1.2.** Result handling:

* **6.1.2.1.** **If the attempt result is FAIL:** another process is already the Master and is performing SPLIT. The file write at `D+1` has already been done in the previous step (see 4.2.4); no additional actions are required.
* **6.1.2.2.** **If the attempt result is SUCCESS:** The process becomes the Master. The Master **atomically via CAS** updates `max_depth` in `.depth_map` to `max(max_depth, D+1)`: the loop `do { old = atomic_load(max_depth); if (old >= D+1) break; } while (!atomic_compare_exchange_weak(max_depth, &old, D+1));`. This records the appearance of paths of the new depth.

### 6.2. Data Movement

**6.2.1.** Before the movement begins, the Master pre-creates all 16 directories of the next level (from `0` to `f`). The placement of the new directories depends on the cascade transition and is determined by the cascade structure (see Section 3):

* **6.2.1.1.** **Transition with cascade reset (`3→4`, `6→7`, ...):** the new directories are created **inside** the overflowing directory as its subdirectories. Example: on a split of `/abc`, `/abc/0/, /abc/1/, ..., /abc/f/` are created.
* **6.2.1.2.** **Transition within a cascade group (`2→3`, `5→6`, ...):** the new directories are created **at the same level** as the overflowing one — in the same parent directory, as its siblings. Example: on a split of `/ab`, `/abc, /abd, ..., /abf/` are created next to `/ab` in `/a`.

**6.2.2.** Then the Master reads the list of files and moves (`rename`) them into the corresponding created subdirectories. Upon completion, it checks that no new files were added and repeats the movement if necessary.

**6.2.3.** If the source directory is **empty** after the files have been moved (contains neither files nor non-service subdirectories), the Master deletes it. It schedules an overflow check for the parent directory.

### 6.3. Lock Release

**6.3.1.** **With `flock`:** The Master closes the directory file descriptor. The lock is released automatically.

**6.3.2.** **With `.lock`:** The Master deletes the `.lock.<dirname>` file.

### 6.4. Metadata Update (`min_depth`)

The procedure is performed by the Master after a successful SPLIT, and also to restore the invariant `max_depth >= min_depth` (see 2.4) when its violation is detected:

**6.4.1.** An exclusive lock is acquired on the root directory (`flock(LOCK_EX)` on `/` on Linux/macOS; on Windows — an equivalent lock on the directory). The lock serializes steps 6.4.2–6.4.4 (checking files/directories and deleting emptied directories) so that two Masters do not raise `min_depth` in parallel and lose state. This lock has nothing to do with the modification of `.depth_map` — writing the values is performed atomically via CAS (see 6.4.5).

**6.4.2.** `min_depth := 0` (a reset for re-validation from the root; the correctness of the algorithms when `min_depth` is too low is guaranteed by 2.2).

**6.4.3.** Sequential raise attempt:

* **6.4.3.1.** **0→1:** there are no L0-files in the root (no files with a hash name, excluding `.depth_map` and `.lock.*`) and all 16 L1-directories `/0/, /1/, ..., /f/` exist. If satisfied — `min_depth := 1` and continue.
* **6.4.3.2.** **1→2:** there are no L1-directories `/X/` in the root and all 256 L2-directories `/XY/` exist. If satisfied — `min_depth := 2` and continue.
* **6.4.3.3.** **2→3:** there are no L2-directories `/XY/` in the root and all 4096 L3-directories `/XYZ/` exist. If satisfied — `min_depth := 3` and continue.
* **6.4.3.4.** Raising above 3 is not performed (see 2.2).
* **6.4.3.5.** If the next condition is not satisfied — stop.

**6.4.4.** If the resulting `max_depth < min_depth`, then `max_depth := min_depth` (ensuring the invariant 2.4).

**6.4.5.** Writing `min_depth` (and `max_depth`, if changed) to `.depth_map` is performed atomically via CAS (see 6.1.2.2), independently per field, after which `msync(MS_SYNC)` is called (see 2.1).

**6.4.6.** The lock on the root is released.

While the lock is held, writers MUST NOT create new files/directories at levels `< min_depth` (which is already guaranteed by WRITE: 4.2 does not consider `D < min_depth`).

### 6.5. Parent Directory Check

**6.5.1.** Checks whether the parent directory needs resharding. If necessary, starts from item 6.1.
