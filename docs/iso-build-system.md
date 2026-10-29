# ADR 0008 — Buildroot for the installation medium

**Status:** accepted — adopt Buildroot for the ISO, as an out-of-tree build
**Supersedes:** the first draft of this ADR, which rejected Buildroot on a
mistaken premise. That premise is recorded below, because the mistake is
instructive.

## The mistake worth recording

The first version of this decision argued that adopting Buildroot would mean
running two package managers, with every package described twice and the two
descriptions diverging forever.

**That is wrong, and it is wrong because of a boundary that had not been
written down anywhere.** Buildroot would build the *installation medium*. The
medium is scaffolding: it boots, runs the installer, writes generation 1, and
is then thrown away. Nothing Buildroot produces is ever part of the installed
system. There is no second package manager on the running machine because
there is no Buildroot output on the running machine.

Once that boundary is stated, most of the original argument evaporates.

## The boundary

```
  Buildroot            →  the ISO             →  discarded after install
  nexis + nexis-init   →  the installed system →  everything after that
```

Three rules follow, and they are the reason this ADR exists as much as the
tooling choice is:

1. **Buildroot builds the medium and nothing else.** Its output never reaches
   a target disk.
2. **`nexis` never builds the ISO.** It installs and manages a NexisOS system.
   Building the medium is `nimble distro` and the scripts under `tools/`, which
   are development tooling and not part of the distribution.
3. **The installer lays down two packages: `nexis` and `nexis-init`.** That is
   generation 1. Everything else on the installed machine arrives afterwards,
   declared by the user and built by `nexis`.

Rule 3 is why no cleanup pass is needed. A cleanup script removing
"Buildroot leftovers not tracked by nexis" would only make sense if Buildroot
output landed on the target, and it does not — the installer writes generation 1
from the store, it does not copy the medium's root onto the disk.

## Decision

Adopt Buildroot for the ISO, kept **outside** `src/`, alongside the existing
scripts' role rather than inside the Nim tree.

### Why it fits, now that the boundary is clear

**The medium is exactly what Buildroot is for.** A kernel, busybox, a
compositor, a terminal, a font, partitioning tools, wireless — a fixed,
purpose-built root filesystem assembled from source. That is Buildroot's entire
job description.

**It fixes the thing the scripts cannot.** `tools/rootfs.sh` copies binaries
off the build host. That is not reproducible: the ISO carries whatever glibc,
whatever Mesa, whatever `sgdisk` the maintainer's laptop had. Two people
building the same commit get different media. Buildroot builds from pinned
source and the result is the same everywhere.

**Every piece we need is already packaged.** `cage`, `foot`, `wlroots`,
`seatd`, `iwd`, `dbus`, `busybox`, `xorriso`, plus `fs/iso9660` with GRUB2 —
measured against the current tree, not recalled. The three gaps the scripts
currently have (coreutils, dbus, udev) are config lines rather than work.

**The Nim problem is smaller than it looked.** Buildroot has no Nim package,
but the ISO does not need a Nim *toolchain* — it needs three already-compiled
binaries. `nimble build` produces them and a rootfs overlay
(`BR2_ROOTFS_OVERLAY`) drops them in. Buildroot never has to know what Nim is.

**`composefs` is the one package we would write.** It has no Buildroot package,
and the installer needs `mkcomposefs` on the medium to write generation 1. That
is one `.mk` file — a real cost, but a small and bounded one.

### How it is wired

Not a git submodule. A submodule pins a 99 MB tree into every clone, including
clones by people who will never build an ISO. Instead: a pinned version in
`iso/buildroot.toml`, and a script that shallow-clones it on demand into
`build/`. Contributors who only touch Nim never pay for it.

The NexisOS-specific configuration lives in a `BR2_EXTERNAL` tree under
`iso/`, which is Buildroot's supported mechanism for exactly this. Our
defconfig, our overlay, our one package definition — all in our repository, with
Buildroot itself unmodified and replaceable.

## What this costs

Stated plainly, because these are real.

- **First build is tens of minutes.** Buildroot compiles a cross-toolchain and
  every package from source. Subsequent builds are incremental; the first is
  not, and CI must cache `dl/` and `output/` or every run pays it again.
- **Contributors need Buildroot knowledge to change the medium.** Changing
  what is on the ISO stops being "edit a shell script" and becomes "learn
  Kconfig". For a contributor who already knows Buildroot this is a gain; for
  one who does not, it is a wall the shell scripts did not have.
- **99 MB of external tree**, fetched on demand rather than vendored.

## What happens to the scripts

They stay, and they keep working. Two reasons.

`tools/rootfs.sh` is currently the only thing that produces a bootable image,
and deleting a working path before its replacement is proven is how a project
ends up with neither. It also remains the fast path: a developer changing the
installer wants a new ISO in thirty seconds, not thirty minutes, and copying
host binaries is exactly the right trade for that.

So: **the scripts become the development build, Buildroot becomes the release
build.** `nimble distro` for iteration, `nimble distro-release` for anything
published. The manifest in `iso/manifest.toml` describes what both must
produce, which keeps them honest about each other.

## Sequencing: not yet

Buildroot is the right answer and it is the wrong *next* thing.

Nothing in this project has booted. Not on hardware, not in a VM. The first
boot will find problems in `nexis-init`, in the initramfs handover, in the
installer's terminal handling — and every one of those is easier to find
against a medium that builds in thirty seconds than one that builds in thirty
minutes.

Worse, adopting Buildroot first means the first failure is ambiguous. A machine
that does not boot could be a bug in PID 1 or a missing kernel option in a
defconfig nobody has exercised, and telling those apart costs far more than
either costs alone.

So:

1. **Boot the script-built ISO.** Fix whatever it finds. That proves the init
   system, the boot chain, and the installer against a medium whose contents
   are known.
2. **Then swap the medium builder underneath**, with a working image as the
   reference to diff against. "Buildroot's ISO differs from the script's ISO
   in these three ways" is a tractable problem. "Buildroot's ISO does not boot"
   is not.

The pin in `iso/buildroot.toml` and the boundary in this document exist now so
that step 2 is a decision already made rather than one to relitigate later.

## Revisit when

The scripts and the Buildroot config drift far enough apart that they are
producing meaningfully different media. At that point one of them is wrong, and
the answer is to delete the scripts rather than to reconcile them.
