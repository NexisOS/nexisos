# How this compares

Where NexisOS sits against the systems it borrows from, and where it is
deliberately worse. A design document that only lists advantages is marketing.

## At a glance

| | Nix / NixOS | Guix | ostree / rpm-ostree | Portage | dpkg / apt | OCI / Docker | Spack | **NexisOS** |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Runtime layout | store paths + symlink farm | same | real FHS | real FHS | real FHS | layered FHS | store paths + RPATH | **real FHS** |
| Composition | symlinks | symlinks | hardlink farm | in-place | overlay layers | symlinks | mount |
| Dedup | retroactive hardlink | retroactive | hardlink at commit | none | none | per-layer only | none | **CAS at insert** |
| Multiple versions | silently allowed | allowed | no | slots | no | per-image | first-class | **slots only** |
| Rollback | generations | generations | deployments | none | none | image tag | none | **generations** |
| Atomic update | yes | yes | yes | no | no | yes | no | **yes** |
| Per-package builds | yes | yes | **no** | yes | yes | no | yes | **yes** |
| Config language | Nix | Scheme | none | bash | none | Dockerfile | Python | **TOML** |
| Prebuilt binaries run | needs patchelf | needs patchelf | yes | yes | yes | yes | needs RPATH | **yes** |
| SELinux | effectively no | no | **yes** | yes | yes | partial | no | **yes** |

## Nix and Guix

The direct ancestors, and the source of the good ideas: content-addressed
builds, generations, atomic activation, rollback, declarative system
configuration. Guix is Nix with Scheme instead of the Nix language; everything
below applies to both.

**What NexisOS takes.** The generation model wholesale. The insight that a
system should be a pure function of a declaration. Binary substitution from
reproducible builds.

**Where it diverges, and why.**

*Store paths in the runtime namespace.* This one choice cascades. Because
`/nix/store/<hash>-nginx/bin/nginx` is where nginx lives, prebuilt binaries
cannot run without `patchelf`, SELinux `file_contexts` cannot address anything
meaningfully, and store paths leak into `RPATH`, wrappers and
`LD_LIBRARY_PATH` throughout the system. A large share of nixpkgs' size is the
work of reconstructing an FHS that the software already expected. NexisOS
merges into a real `/usr` and pays a different price: no two versions of a
library can coexist by accident.

*Retroactive deduplication.* Files are written per-derivation, so identical
content becomes separate inodes and dedup is a batch job that reclaims 25–35%
of the store. NexisOS content-addresses at insert, so the duplication never
exists and there is no `optimise` command.

*Garbage collection that scales with the store.* Root discovery scans `/proc`,
closure computation goes through SQLite, deletion is `rm -rf` of deep trees.
NexisOS refcounts through an index; retiring a generation costs what that
generation uniquely held.

*A programming language for configuration.* Nix expressions are lazily
evaluated over ~120,000 definitions, which is why `nixos-rebuild` evaluation
takes seconds to tens of seconds and gigabytes of RAM. TOML parses in
milliseconds.

**Where Nix is better, plainly.** Abstraction. A Nix definition can be a
function, can be overridden with arbitrary logic, and can compute a package
set. TOML cannot. Where a Nix user writes a function, a NexisOS user writes a
generator that emits definitions — worse for the small number of people
maintaining highly parameterised package sets, better for everyone reading,
diffing, verifying or machine-generating them. Nix also has a decade of
packaging and a real community; NexisOS has neither.

## ostree and rpm-ostree

The closest relative on the image side, and the design NexisOS's generation
model is genuinely descended from. ostree commits whole filesystem trees,
content-addressed, deduplicated by hardlink, deployed atomically with rollback
— all on a real FHS.

**What NexisOS takes.** Whole-tree commits, atomic deployment, real FHS,
SELinux labels that work.

**Where it diverges.** ostree has **no package manager**. A commit is a tree
someone else built; rpm-ostree bolts RPM on top and composes trees server-side,
which is why client-side package changes are awkward and layered packages are a
second-class mechanism. NexisOS builds packages itself and composes generations
locally from a declaration.

The hardlink farm is also mutable in principle — a stray `chmod` corrupts a
deployment silently — and offers no equivalent of a seal digest. composefs is
the successor design to exactly this, for exactly these reasons, which is why
[adr-0001](adr-0001-generation-image-format.md) chose it.

## Portage

Source-based, `USE` flags, slots for parallel versions. The feature and slot
model in the package format is closer to Portage than to Nix, and deliberately.

**What NexisOS takes.** `USE`-style features that select dependencies rather
than merely flipping build flags. Slots as the explicit mechanism for
deliberate parallel versions.

**Where it diverges.** Portage installs in place: no atomic activation, no
rollback, and a failed emerge leaves a half-updated system. Ebuilds are bash
with global mutable state. There is no artifact identity, so nothing can be
cached or verified across machines.

## dpkg / apt and rpm / dnf

**What they get right, and the reason NexisOS runs an FHS at all.** Every
prebuilt binary on Earth targets this layout. File conflicts are a hard error
rather than last-write-wins — the same choice NexisOS makes in
[package-format.md](package-format.md) §3.

**Where they fall down.** Imperative and stateful: the installed set is a
database that drifts from any declaration, upgrades are not atomic, and
rollback does not exist. `/etc` is edited in place by maintainer scripts, so
two machines given the same commands can end up different.

## OCI / Docker

**What NexisOS takes.** Nothing directly, but the layer model is the obvious
alternative for composition and it is worth saying why it was not chosen.

**Where it diverges.** Layers deduplicate only whole layers, and only when they
are bit-identical and share a parent. Two images containing the same libc from
different bases share nothing. There is no partial update: changing one file in
a lower layer rebuilds every layer above. And a container's filesystem is not
introspectable as a set of packages — `nexis why` has no OCI equivalent.

The NexisOS container story is the inverse: a container image *is* a
generation, composed over the same object store, so a file used by the host and
by three containers is one inode and one page cache entry.

## Spack

HPC-oriented, and the closest thing to NexisOS's feature/variant model in a
build-from-source tool. Multiple versions and compilers coexist by design.

**Where it diverges.** Spack resolves at install time with a concretiser that
can produce different results on different runs, and composition is
`RPATH`-based rather than filesystem-level, so there is no system image, no
atomic activation and no rollback. It is a toolchain manager, not an OS.

## What NexisOS is worse at

Stated plainly, because these are the reasons to choose something else. Where
a weakness has since been addressed, the mitigation is named; where it has not,
that is said instead of dressed up.

**Abstraction in definitions — partly addressed.** TOML cannot express a
function. In practice Nix's abstraction covers three uses, and
[package-format.md](package-format.md) §1.6 now handles two of them as data:
`extends` for shared build boilerplate, one level deep with the template's hash
entering the build identity; and `matrix` for version families. What remains
unavailable is genuine computation — deriving a value from another definition,
or branching on anything but a feature. Generators cover those, and a generator
is more work than a function. This is the intended limit rather than an
oversight, but it is still a limit.

**Ecosystem — the real risk, partly mitigated.** nixpkgs has ~120,000
definitions and thousands of contributors. Three things reduce the exposure:
FHS means far fewer definitions are needed at all, because prebuilt binaries
run unmodified; lockfile importers generate the bulk mechanically; and
`nexis import deb|rpm` can consume Debian's and Fedora's archives directly,
since their payloads are already laid out for the FHS this system runs. That
last one is the largest single lever and it exists only because of the runtime
layout choice. None of it produces a community, and this remains the risk that
decides whether the project matters.

**One library version per view — overstated in an earlier draft.** Sonames
already separate `libfoo.so.2` from `libfoo.so.3`, so both install with no slot
declaration and the dynamic linker does the right thing. The constraint bites
only for same-path executables, same-soname incompatible ABIs (an upstream
bug), and the unversioned `dev` symlink — all handled by slots. Per-user
package layers compose separately, so two users can hold different versions of
anything without either declaring a slot. The remaining hard case is one
process needing two incompatible versions of one soname, which Nix also cannot
make work correctly, only silently.

**Unproven — now falsifiable.** Every performance claim in this document is a
design argument, not a measurement. [benchmarks.md](benchmarks.md) specifies
the operations, the comparison points and the pass conditions, so the claims
can be shown wrong. They are currently unmeasured, and a design argument that
survives only because nobody ran it is worth very little.

**Kernel floor — scoped, not removed.** composefs needs 6.5+ for data-only
lower layers and newer still for the integrity features. NexisOS ships its own
kernel, so this constrains nobody running NexisOS. It does constrain using the
system manager standalone on another distribution, where the fallback is an
unsealed composition at reduced integrity rather than a failure.

**Still genuinely open.** Secrets in declared dotfiles, per-user services,
cross-compilation beyond the `native`/`dependencies` split, and the binary
cache transport and trust model. See [../TODO.md](../TODO.md).
