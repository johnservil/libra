# Faster `add` and `fsck`: what this branch changes, and what it measures

This branch makes `libra add` about a quarter faster and `libra fsck` about
7% faster on an Apple M4 Max, in Libra's own benchmark (`benchmark/run.sh`).
Most of the gain comes from two changes that work for every object format:
hashing objects where they lie, and updating the object index in batches.

## Results

Libra's benchmark, Apple M4 Max (macOS 26), BLAKE3 fixtures, medians of 5
runs, each build run twice in the order L0 L2 L3 L3 L2 L0 so drift falls on
all alike (seconds; the two passes' mean):

| Build | `add_all` | `fsck_history` | `status_dirty` |
|---|---|---|---|
| L0: Libra 85dcbb7 as it is | 9.75 | 5.57 | 0.43 |
| L2: + objects hashed in place (commit 2 and git-internal `in-place-ids`) | 8.31 | 5.19 | 0.42 |
| L3: + object-index updates in batches (commit 3), **this branch** | **7.37** | **5.20** | 0.42 |

`add_all` is new (commit 1): `libra add .` on 5,000 untracked files whose
sizes cycle from 512 B to 64 KiB, about 10 KB on average, as git's own tree
has. In a Linux VM on the same Mac, the batched index updates alone took the
same `add` from 9.22 s to 4.37 s and its CPU time from 11.2 s to 3.7 s; the VM's
storage syncs almost for free, so there the per-object work shows as CPU.

## The changes

1. **Benchmark** (`benchmark/run.sh`): `--object-format` passes through to
   `libra init` for every fixture, and the `add_all` scenario runs each sample
   on a fresh, untimed copy of its fixture.
2. **Objects hashed in place.** Five places copied an object's content behind
   its `"<type> <size>\0"` header into a new buffer before hashing it, and two
   streamed the header by hand. Each now starts its hasher with git-internal's
   `HashAlgorithm::for_object(kind, type, size)` and hashes the content where
   it lies. For SHA-1 and SHA-256 the IDs stay the same; for BLAKE3, git-internal
   `in-place-ids` drops the header and uses a key-derivation context per object
   type (libra-tools/git-internal#183).
3. **Object-index updates in batches.** `add` publishes every repair marker
   exactly as before (ADR-OI-04), and at the batch's end replays them through
   `repair_pending_object_index_updates`, the batched path preflight already
   uses: one connection, multi-row upserts, then marker retirement. Before, each
   object's queued update opened a fresh SQLite connection and committed its own
   transaction, two database opens and four `fsync`s per file. A replay failure
   leaves the markers for the next command's preflight, as a failed queued
   update did.
4. **Dependencies:** git-internal from johnservil/git-internal `in-place-ids`,
   which adds `for_object` and builds on the servil fork of BLAKE3
   (johnservil/BLAKE3), with SME2 and integer + NEON kernels on AArch64.

After `add`, every object has its index row, no repair marker remains, and
`fsck` passes, the same as with Libra as it is.

## Without BLAKE3

Estimated, from these runs: nearly all of the gain. On SHA-1 fixtures, Libra as
it is takes the same time as on BLAKE3 ones (`add_all` 9.66 s against 9.73,
`fsck_history` 5.45 against 5.54), and faster BLAKE3 kernels alone change
nothing measurable: hashing is a small part of each command. Commit 2 keeps
SHA-1 and SHA-256 IDs as they are and removes the same copies; commit 3 is
independent of the hash. So a SHA-1 repository should see about the same
`add_all` 7.4 s and `fsck_history` 5.2 s. BLAKE3's own share grows as the
remaining per-file costs shrink: hashing the fixture's 50 MB takes BLAKE3 about
10 ms on one core, a hardware-accelerated SHA-1 about two to three times as long.

## Where `add` spends the rest

`strace -f` on `libra add .` of the 5,000 files in the VM, per file: two opens
each of `.gitignore` and `.libraignore`, two opens of the file itself, one of
`objects/pack`, two repair-marker temporaries written and renamed, 354
`readlinkat` calls (nearly all failing with EINVAL, as path resolution probes
each component), about 190 `stat` calls, and two new threads. The Mac's 7.37 s
is about 1.5 ms per file. Reading the ignore rules once per command, resolving
paths once, keeping the blocking pool's threads between files, and publishing
markers per batch rather than per file each look likely to take a share of it.

## Reproducing

[johnservil/bench-hashes `apps/libra-bench`](https://github.com/johnservil/bench-hashes/tree/candidate/no-linger/apps/libra-bench)
holds the patches, a script that clones Libra and git-internal at these
commits, builds each variant, and runs `benchmark/run.sh` over them, and the
result files of the runs above.
