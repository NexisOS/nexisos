# ADR 0006 — Hash function and store layout

**Status:** accepted
**Supersedes:** nothing. Formalises what `lib/hashing` and `lib/paths` already do.

## Context

Two questions that look like one:

1. Which hash function addresses store content?
2. How are objects laid out on disk?

They interact, because the digest length sets the directory-name length and the
layout has to match what composefs expects if generations are to mount the
store directly.

## Decision 1 — SHA-256 for sources, BLAKE3 for the store

**Not one function for both jobs**, because they are different jobs.

**Sources are verified with SHA-256.** Not because it is faster — it is not —
but because it is what upstreams publish. npm, PyPI, crates.io, and nearly
every release page publish SHA-256, and Subresource Integrity (`sha256-…`) is
the format `[[source]] hash` already uses. Addressing sources with anything
else would mean every definition carrying a digest nobody upstream can confirm,
which turns a verifiable claim into a NexisOS-specific assertion.

**Store objects are addressed with BLAKE3**, once the migration is worth doing:

| | SHA-256 | BLAKE3 |
| --- | --- | --- |
| Throughput, no HW accel | ~0.4 GB/s | ~3 GB/s |
| Throughput, SHA-NI | ~2 GB/s | ~3 GB/s (SIMD) |
| Parallel over one file | no | yes |
| Tree structure | no | yes — verified streaming, cheap subtree checks |
| Published by upstreams | universally | rarely |

The tree structure is the part that matters here, more than the speed. A
generation is a large tree that gets sealed by one digest and verified on every
boot; BLAKE3's Merkle structure means a subtree can be verified without reading
the whole image, and a partially-fetched artifact can be verified as it
arrives. SHA-256 offers neither.

The speed argument is real but weaker than it first looks: SHA-NI on any recent
x86-64 closes most of the gap, and NexisOS targets machines that have it.

**Status: not yet done.** `lib/hashing` is SHA-256 throughout. The change is
mechanical but touches manifests and the index, so it is sequenced after the
store format stabilises rather than during it.

### What this rules out

A single function for both would mean either publishing BLAKE3 digests nobody
can independently confirm, or giving up tree hashing for generations. Neither
is worth the simplicity of one function.

## Decision 2 — Two hex characters of shard, remainder as filename

```
/store/objects/6c/0d7e4d722975dd…
/store/manifests/84/b9b2cc6eda270f…
```

**Two characters, not one or three.** 256 buckets keeps a million-object store
near four thousand entries per directory, which every modern filesystem indexes
without a linear scan. One level of 16 buckets is sixteen times worse; three
levels is 4096 mostly-empty directories, each costing an inode and a seek.

**The remainder as the filename, not the whole digest.** This is the layout
composefs expects for a `--digest-store`, so a generation image can use the
object store *directly* as its data-only lower layer. The alternative is
NexisOS maintaining a second parallel tree with the same bytes in it, which
would double disk use and create a class of bug where the two disagree.

### What this rules out

A flat `objects/<digest>` directory. It works until it does not: `readdir` on a
directory with a million entries is slow enough to be noticeable in `gc`, and
tab-completion in that directory locks a shell.

### Consequences

Reconstructing a digest from a path requires the directory name *and* the
filename. Code that reads only the filename sees every object as unindexed —
which is exactly the bug this decision introduced in `store.verify` and which
the store tests now cover.

## Not chosen: a hashmap or database index

Considered and rejected for the object store itself. The filesystem *is* the
hashmap: a content-addressed lookup is one `stat` on a path computed from the
digest, with no process, no lock, and no format to corrupt. A database would
add a component that has to be open, consistent, and recovered.

The refcount index in `store/index.nim` is a separate matter and does use a
log — see [ADR 0003](adr-0003-store-index-and-gc.md).
