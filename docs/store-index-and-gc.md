# ADR 0003 — Store layout, indexing, and garbage collection

Status: accepted
Amends: ADR 0001 (generation image format), and the GC sketch in store.nim

## Context

Two Nix operations are notoriously slow, and both are slow for structural
reasons rather than implementation ones. Since NexisOS is making the same
category of decision now, it is worth being precise about what goes wrong.

### Why `nix-store --optimise` is slow

Nix writes build outputs as ordinary files inside per-derivation directories.
Two derivations containing a byte-identical file produce two independent
inodes. Deduplication is therefore a **retroactive batch job**: walk the entire
store, hash every file, group by hash, replace duplicates with hardlinks.

The scale is not hypothetical. <cite index="4-1">The operation typically reduces store size by 25–35%</cite> — a third of a Nix store is duplicate content that exists only because dedup happens after the fact. One reported run <cite index="14-1">hardlinked 881,561 files to free 12 GB from a 38 GB store</cite>, and real stores reach <cite index="15-1">4 million files across 300 GB</cite>.

Neither of the two available modes is good. <cite index="1-1">The incremental setting slows builds significantly, particularly with lots of small files, while the periodic run pointlessly re-optimises store paths that were already optimised.</cite>

### Why `nix-collect-garbage -d` is slow

Four compounding costs:

1. **Root discovery scans `/proc`.** Live paths are found by reading every
   process's maps, environment and cwd.
2. **Closure computation goes through SQLite.** A general SQL engine doing a
   transitive closure over a reference table, for a workload that is a
   reachability walk over a hash map.
3. **Deletion is `rm -rf` over deep trees.** Recursive directory removal of
   hundreds of thousands of small files dominates everything else.
4. **The store is locked throughout.**

And the outcome is imprecise: <cite index="20-1">`--max-freed` selects which paths to delete essentially at random</cite>.

### Why the symlink farm costs at runtime

A NixOS system profile is a tree of symlinks into store paths.
`/run/current-system/sw/bin/foo` resolves through several links before reaching
a real inode. Every `exec`, every `dlopen`, every `stat` pays that resolution,
and the indirection is why store paths leak into `RPATH`, wrapper scripts and
`LD_LIBRARY_PATH` throughout the system.

## Decisions

### 1. Content-addressing at insert. There is no `optimise` command.

An object's name **is** its content hash, so a second insert of identical
content is a hash comparison and a no-op. Deduplication is not an operation; it
is a property of writing.

This removes the entire 25–35% duplication class, both the disk cost and the
batch job that reclaims it. The build slowdown from incremental optimisation
does not appear either, because there is no extra work: the build output has to
be hashed anyway to compute its artifact identity.

### 2. Two levels: objects and manifests

```
/store/
  objects/<ab>/<digest>      individual file contents, deduplicated
  manifests/<ab>/<digest>    canonical tree descriptions
  index/                     the refcount index (below)
  tmp/                       staging for atomic inserts
  build/                     build sandboxes
```

Composefs redirects **per file**, so objects must be individual files. Packages
produce **trees**, so a manifest names a tree by listing the objects it is made
of. Two packages sharing a file share one object; two generations sharing a
package share every object in it.

Objects are flat within their shard. This matters for deletion: reclaiming an
object is a single `unlink`, never a recursive directory walk, which removes
Nix's dominant GC cost by construction.

### 3. Refcounted index, not a filesystem mark-and-sweep

The GC in the first cut of `store.nim` walked `objects/` and compared against a
reachable set. That is O(store) — the same mistake, and it would get slower
every year the machine is in use.

Instead the store keeps an index:

```
digest -> (refcount, size, present)
```

- Inserting an artifact increments the refcount of each object it references.
- Retiring a generation decrements them.
- An object reaching zero is unlinked.

**Cost is proportional to what changed, not to what is stored.** Retiring one
generation touches only that generation's objects. A machine with a 200 GB
store and ten generations collects a retired generation in the time it takes to
unlink its unique files — typically a few thousand, not a few million.

Root discovery does not scan `/proc`. Roots are explicit: retained generations,
named environments, and pinned artifacts, all recorded in the index.

### 4. Index format: append-only log, compacted

Records are appended, each with a CRC so a torn tail from a crash is detected
and truncated rather than silently misread. The map is rebuilt in memory on
open; compaction rewrites the log when dead records exceed live ones.

Chosen over SQLite deliberately. The workload is a hash map keyed by a 32-byte
digest, and SQLite's cost on exactly this shape is one of the things that makes
Nix's GC slow. A log plus a hash map has no query planner, no B-tree
maintenance on the write path, and appends at memory bandwidth.

**The honest limit.** Load time and resident memory grow with live object
count: roughly 50 bytes per record, so a million objects is a ~50 MB log and a
~100 MB in-memory map, loading in a few hundred milliseconds. That is fine for
a CLI invoked occasionally and wrong for a long-running daemon. If the index
crosses a few million objects, the replacement is **LMDB** — memory-mapped
B+tree, zero-copy reads, single writer, ACID, no server — not SQLite. The
`Index` interface is deliberately narrow (`get`, `incr`, `decr`, `roots`) so
that swap is contained.

**The index is a cache, not the source of truth.** `nexis store verify`
rebuilds it by walking manifests, and `--rebuild-index` repairs it. Losing the
index costs one slow pass, never data.

### 5. Generations are mounted, never copied

Answering the question directly: **mount**.

Copying a generation's tree into `/usr` would reintroduce every problem this
design exists to avoid — the full size of `/usr` per generation on disk, a
multi-minute copy on every rebuild, a non-atomic window during which the system
is half-updated, and separate page cache for every copy of every shared file.

Mounting a composefs image is a single syscall. It is atomic, effectively
instant regardless of `/usr` size, and shares both disk and page cache with
every other mount over the same objects.

### 6. No symlink trees anywhere in the runtime

A generation presents a real directory hierarchy. `/usr/bin/foo` is a path that
resolves to an inode through ordinary dentry lookup, which the kernel caches.
There is no profile symlink chain, no wrapper script, and no store path in
`RPATH` — which is also why prebuilt binaries run unmodified
(see [packaging-strategy.md](packaging-strategy.md)).

Composefs does add an overlayfs indirection, but it resolves through cached
dentries rather than through a chain of `readlink` calls, and it is paid once
per lookup rather than once per path component.

### 7. Deduplication and SELinux are orthogonal — which hardlinking cannot achieve

This is the point where content-addressing and security stop being separate
concerns, and it is an argument against hardlink dedup specifically.

Extended attributes live on the **inode**. Under Nix's hardlink optimisation,
two byte-identical files that need *different* SELinux labels cannot be shared,
because sharing them means sharing one inode and therefore one
`security.selinux` value. Dedup and labelling are in direct conflict, and the
conflict is silent.

Under composefs the label lives in the **generation's metadata image**, not on
the store object. The same object is redirected to from several generations,
each supplying its own label. Store objects can carry one inert type; the
generation supplies the real ones.

So NexisOS gets full file-level dedup *and* per-generation labelling, and
rolling back restores the filesystem and its labels as one sealed unit. That
combination is not available to a hardlink-based store at all.

### 8. Containers and environments share the object store

A container image is a generation. A `nexis shell` environment is a composefs
layer. Both compose over the **same objects**.

The consequence the user actually feels is memory. Because a file used by the
host, by a container, and by a dev shell is literally the same inode, the
kernel caches its pages **once**. Under OCI layers there is no cross-image file
dedup at all; under a copy-based scheme each copy is cached separately. A
hundred Rust projects on one machine share one `rustc` inode and one page cache
entry for it.

This is also what makes the language-package containment in
[environments.md](environments.md) cheap: a scratch overlay holds only the
files that differ.

### 9. Sizes and roots come from the index, never from `du`

`nexis env list` reports per-environment size, and `nexis gc` reports what it
would free. Both read the index. Walking directories to compute sizes is the
same O(store) mistake in a different costume.

## Consequences

- `store.nim`'s `reachable`/`gc` are replaced by index-driven refcounting. The
  mark-and-sweep survives as `nexis store verify`, a repair tool.
- Object deletion must batch and sort unlinks by shard for locality, and should
  be deferrable so `nexis rebuild` never blocks on reclamation.
- The index must be crash-safe. A torn record truncates; a lost index rebuilds.
- Every root — generation, environment, pin — must be registered explicitly.
  An unregistered root is a live tree whose objects can be collected, which is
  the one failure mode here that produces a broken system rather than wasted
  disk.
- The manifest text format must be unambiguous for paths containing spaces,
  since manifests are parsed to compute refcounts on every GC.
