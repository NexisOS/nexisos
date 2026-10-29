# ADR 0001 — Generation image format

Status: accepted
Supersedes: the "Immutable EROFS generation" language in the README

## Context

A NexisOS generation is the complete immutable `/usr` (plus supporting
structure) for one system state. The README specifies this as a monolithic
EROFS image, `system.erofs`, built by the generation builder and mounted at
boot.

The requirement set the format has to satisfy:

1. Several generations retained simultaneously for rollback.
2. Runtime paths are conventional FHS (`/usr/bin/foo`), never store paths.
3. SELinux labels are part of the generation, so a rollback restores the
   filesystem and its labels as one coherent unit.
4. The generation is verifiable before it is trusted.
5. Generation construction must be fast enough that a config change followed by
   a rebuild is a routine operation, not a coffee break.

## The problem with monolithic EROFS

A monolithic image satisfies (2) and (3) cleanly but fails badly on (1) and (5),
and only partly satisfies (4).

**Disk.** Every generation contains a full copy of every file. Ten retained
generations of a desktop `/usr` is ten full copies. The overwhelming majority of
those bytes are byte-identical across generations — a generation that changes
one package still duplicates the other several thousand.

**Page cache.** This is the more serious cost and the less obvious one. Generation
42 and generation 43 both contain `libc.so.6`. Under two separate EROFS images
these are two distinct inodes on two distinct block devices, so the kernel caches
the pages twice. Anything that runs across a generation boundary — a live
comparison, a container pinned to an older generation, an A/B test of a rollback
— pays double resident memory for shared code.

**Build time.** Producing the image means writing out the entire `/usr` and
compressing it, every time, even when one package changed. That is minutes of
I/O on every `nexis rebuild`.

**Verification granularity.** A whole-image hash tells you the image is intact.
It cannot tell you *which* file diverged, and it must be recomputed over the
whole image to check anything.

## Decision

**Generations are composefs images: an EROFS metadata image over the
content-addressed store, composed with overlayfs.**

Concretely, a generation is:

```
/system/generations/N/
    system.cfs          # EROFS image: directory structure, names, modes,
                        # uid/gid, xattrs (including security.selinux),
                        # and per-file overlayfs redirect + metacopy xattrs
    manifest
    signature
```

<cite index="15-3,15-5">The EROFS image carries `trusted.overlay.redirect` and `trusted.overlay.metacopy` xattrs (the latter holding an fs-verity digest) on every regular file inode; file *content* lives once in the content-addressed store, which is mounted as an overlayfs data-only lower layer.</cite> <cite index="15-4">Data-only layers never appear in directory listings and supply content only when a redirect xattr from the metadata layer above points at them</cite> — so the store stays invisible to applications, and requirement (2) holds exactly as before. `/usr/bin/foo` is still `/usr/bin/foo`.

### Why this resolves the objections

**Disk and page cache.** File content is stored once, keyed by content address,
and shared by every generation that references it. Two generations differing by
one package share the inodes of everything else, so the kernel caches those pages
once. The per-generation cost drops from "all of `/usr`" to "a metadata image of
a few megabytes."

**Build time.** Building a generation becomes: assemble a metadata tree,
serialise it to EROFS, write it out. No file content is copied — it is already
in the store, which is where the build put it. Generation construction goes from
minutes to seconds, which is what makes requirement (5) reachable.

**Verification.** This is where composefs is not merely cheaper but strictly
better than the monolithic design. <cite index="15-1">A single cryptographic digest authenticates the entire filesystem, covering both file contents and metadata — directory structure, permissions, ownership, symlinks, and xattrs — which goes further than fs-verity alone (contents only) and avoids dm-verity's fixed-partition requirement.</cite> <cite index="15-6,15-7">The EROFS metadata image is itself stored as a store object with fs-verity enabled, and the fs-verity digest of that image is the seal digest: the single value that authenticates the whole filesystem.</cite> Mounting with `verity=require` makes the kernel enforce the check on every file access, so integrity is continuous rather than a boot-time snapshot.

That seal digest is precisely the "System image hash" field the README's
generation manifest already calls for — it just now means something much
stronger than a hash of an opaque blob.

### SELinux

Requirement (3) was the reason to be cautious here, since overlayfs and SELinux
have a long history. It holds up:

- Labels are stored as `security.selinux` xattrs inside the EROFS metadata image
  and are therefore part of the generation, produced by the generation builder
  from the generation's own policy. Rollback restores filesystem and labels
  together, as required.
- The historic overlayfs/SELinux difficulty is concentrated in **copy-up** —
  deciding what label a file gets when it is promoted from a read-only lower
  layer to a writable upper layer. <cite index="10-1">The kernel grew dedicated hooks for exactly this (`security_inode_copy_up`, `security_inode_copy_up_xattr`, `dentry_create_files_as`) and SELinux deliberately does not copy the lower file's label up, because the new file was already labelled correctly at creation.</cite>
- More to the point, **`/usr` in a NexisOS generation has no writable upper
  layer**. It is read-only by design. Copy-up never happens, so the entire
  problem class is out of scope. Labels come from the lower inode and stay there.

### Kernel floor

<cite index="15-2">Data-only lower layers (the `::` separator in `lowerdir`, or `datadir` via `fsconfig_set_fd`) require kernel 6.5 or later.</cite> <cite index="3-1">On the EROFS side everything needed has been present since 5.15.</cite> <cite index="7-1">The overlayfs xattr changes composefs depends on are upstream, including escaping of overlayfs xattrs and whiteouts for nested mounts.</cite>

NexisOS ships its own kernel, so a 6.12+ floor is a decision we simply make.
This is not a constraint on users. Note also that <cite index="15-2">the integrity features are what require the newer kernel</cite> — the composition itself works on older kernels, so a degraded unsealed mode is available if ever needed.

## Consequences

- **The store becomes runtime-critical.** Previously it was "build output
  storage"; now the running system faults pages out of it. This does *not*
  violate "the store is not part of the runtime ABI" — ABI means the paths
  applications resolve, and those are unchanged — but it does mean the store
  must be mounted before pivot and cannot be garbage-collected without
  consulting every retained generation's reference set. The GC design must
  treat generations as roots.
- **Garbage collection gets easier, not harder.** Reference counting is now
  exact: an object is live if any retained generation's metadata image redirects
  to it.
- **`nexis-init` must mount the overlay before pivot_root.** This belongs in
  early boot, in the initramfs, alongside the store mount.
- **The generation builder needs a metadata-tree serialiser**, either by linking
  `libcomposefs` or by writing EROFS-with-overlay-xattrs directly. Linking the C
  library first is the right call; the format is stable but reimplementing it
  buys nothing early on.
- **Per-file fs-verity must be enabled on store objects at insert time**, which
  requires the store to live on a filesystem with fs-verity support (ext4,
  f2fs, btrfs). This is a documented installation requirement.
- **README updates required**: "Immutable EROFS generation" → composefs
  generation; `system.erofs` → `system.cfs`; the filesystem-model table's
  description of `/store` must note runtime participation.

## Alternatives considered

**Monolithic EROFS.** Rejected on disk, page cache, and build time as above.

**Per-package symlink farm into store paths (the Nix approach).** Rejected: it
makes store paths part of the runtime namespace, which is the specific thing
NexisOS exists to avoid, and it reintroduces the SELinux labelling problem the
project's architecture was designed to sidestep.

**Hardlink farm into a real directory tree (the ostree approach).** Closer, and
it does share disk and page cache. Rejected because the tree is mutable in
principle — a stray `chmod` corrupts a generation silently — and because it
offers no equivalent of the seal digest. composefs is the successor design to
exactly this, for exactly these reasons.


---

## Addendum — what rollback does and does not roll back

Added because "immutable image" and "snapshot" get conflated, and they are
opposite designs.

**A NexisOS rollback is not a filesystem snapshot.** It does not resemble
Timeshift, or `btrfs subvolume` rollback, or restoring a system image. Those
revert *everything on the volume*, including files the user created between the
snapshot and now — which is why they are frightening to use and why people put
off using them until the machine is already broken.

A generation is a composed `/usr` and the metadata that goes with it. Rolling
back mounts a different metadata image over the same object store. Concretely:

| Path | Rolled back? | Why |
| --- | --- | --- |
| `/usr`, `/bin`, `/lib` | **yes** | it *is* the generation |
| `/etc` | the declarative part | generated from the declaration; local edits under `/etc/nexis` are yours |
| `/var` | **no** | machine and application state, not system composition |
| `/home` | **no** | user data |
| `/store` | **no** | content-addressed; both generations reference it |

So rolling back a bad kernel upgrade does not lose this morning's work, and a
database in `/var/lib` does not travel back in time with the packages that
serve it. This is the NixOS model, and it is the one worth having: rollback
becomes cheap enough to use casually, which is the only way rollback is ever
actually used.

The cost of that choice is honest and should be stated: **a rollback cannot
undo a data migration.** If a service upgrade rewrote its on-disk format in
`/var`, reverting the package does not revert the data, and the older binary
may refuse to read it. Snapshot-based systems do handle that case. NexisOS does
not, and pretending otherwise would be worse than saying so — the answer is a
service-level backup, not a filesystem-level one.

**This requires no particular root filesystem.** composefs composes over
whatever holds `/store`, so ext4 is fully supported and is the intended
default. btrfs and xfs work but buy nothing here: their snapshot features are
not part of the generation model and are not used by it. If subvolume-based
whole-system snapshots are ever wanted, they would be a separate feature layered
on top, not a second rollback mechanism — two mechanisms answering "go back"
differently is how a user ends up not knowing what a command will do.

### ext4 and fs-verity

fs-verity is an on-disk feature flag, set at `mkfs` time and not addable later
without rewriting the filesystem. A root formatted without it can hold a
perfectly working NexisOS install whose generation images are never verified at
runtime, with nothing on screen to say so.

The installer therefore formats ext4 with `-O verity` unconditionally. It costs
nothing on a filesystem that never uses the feature, and it removes a class of
"integrity was silently off the whole time" that would otherwise only be found
by someone going looking.

### Kernel requirement

composefs needs overlayfs data-only lower layers (`datadir+`), which is a
recent kernel feature. This is a real constraint on how old a machine NexisOS
can target, and it is listed among the bootstrap debts in
[roadmap.md](roadmap.md) rather than discovered at boot.
