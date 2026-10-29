# System architecture

How NexisOS goes from a TOML declaration to a running system. This is the map;
the arguments live in the ADRs.

- [package-format.md](package-format.md) — the definition schema
- [adr-0001-generation-image-format.md](adr-0001-generation-image-format.md) — why composefs
- [adr-0003-store-index-and-gc.md](adr-0003-store-index-and-gc.md) — store layout and collection
- [adr-0005-spec-sources-and-resolution.md](adr-0005-spec-sources-and-resolution.md) — where packages come from

---

## The five layers

Configuration, package construction, artifact storage, generation construction,
and runtime execution are separate stages with narrow interfaces between them.

```text
TOML configuration  →  system specification  →  realization graph
                                                      ↓
                                        parallel reproducible builds
                                                      ↓
                                        content-addressed artifacts   /store
                                                      ↓
                                              generation builder
                                                      ↓
                            sealed composefs image + SELinux labels + manifest
                                                      ↓
                                              atomic activation
                                                      ↓
                                    /usr immutable · /etc declarative · /var mutable
```

The single load-bearing decision: **`/store` is not part of the runtime ABI.**
The generation builder resolves the full runtime closure while composing the
image, so applications see `/usr/bin/foo`, never `/store/<hash>/bin/foo`.

## Four identities, not one hash

A single package hash answers several different questions badly. NexisOS keeps
them apart:

| Identity | Answers | Changes when |
| --- | --- | --- |
| `specId` | which definition text | the definition file changes |
| `packageId` | which package, with which features and dependencies | the declaration changes; frozen at resolution |
| `buildId` | which build, under which policy, from which realized inputs | inputs are realized; refines `packageId` |
| `artifactId` | which bytes came out | the build output changes |
| interface id | what dependents can link against | the ABI changes |

Build dependencies enter a build hash by **artifact** id; runtime dependencies
enter by **interface** id. That is what lets an ABI-preserving security patch to
a library ship without rebuilding everything that links it.

`packageId` freezes before any build runs, so the graph is complete before work
starts. `buildId` cannot be known that early, because runtime dependencies enter
by interface id and an interface id is computed from a built output. Two
identities, deliberately — see
[adr-0004](adr-0004-scheduling-and-constraints.md).

## Compositions: one mechanism, four uses

A **generation**, a **per-user home layer**, a **dev environment** and a
**container image** are not four subsystems. Each one:

- merges a set of artifacts into a tree,
- detects path collisions between them,
- writes a composefs metadata image over the shared object store,
- carries its own SELinux labels in that image,
- is sealed by a digest,
- and is registered as a GC root.

```text
                    artifacts in /store
                            │
                    ┌───────┴────────┐
                    │ compose(kind)  │
                    └───────┬────────┘
        ┌───────────┬───────┴───────┬───────────┐
        ▼           ▼               ▼           ▼
   generation   userLayer     environment   container
      /usr       session         nexis        sandbox
                namespace        shell       namespace
```

Three properties fall out of the unification that would otherwise each have to
be built:

- **Containers and dev shells get sealing, rollback and integrity verification
  for free**, because they are compositions and compositions are sealed.
- **One collector handles all four.** `nexis gc` walks roots without caring
  which kind they are.
- **Shared page cache becomes structural.** A file used by the host, a
  container and a dev shell is one inode because all three compose over the
  same objects — not because three subsystems each remembered to reuse the
  store.

The four differ only in what artifacts go in, where it mounts, whether an upper
layer is writable, and whether it survives a reboot.

### composefs

A generation is an EROFS metadata image describing the tree, permissions and
xattrs, composed by overlayfs over the content store as a data-only lower layer.

File content is stored once and shared by every generation referencing it, on
disk and in the page cache. The metadata image is a few megabytes rather than a
copy of `/usr`, and one seal digest authenticates the whole tree — structure,
permissions, ownership, xattrs and content together.

Data-only layers never appear in directory listings, so the store is invisible
to applications. `/usr/bin/foo` is still `/usr/bin/foo`.

## Filesystem model

| Path | Purpose | Mutability |
| --- | --- | --- |
| `/store` | Content-addressed artifacts | Immutable |
| `/system` | Generations and their metadata | Managed by NexisOS |
| `/usr` | System runtime | Immutable |
| `/bin` `/sbin` `/lib` `/lib64` | Compatibility paths | Immutable |
| `/etc` | System configuration | Declarative + controlled mutable state |
| `/var` | Application and machine state | Mutable |
| `/run` | Runtime state | Ephemeral |
| `/home` | User data | Mutable, with declared layers |
| `/boot` | Kernel, initramfs, boot entries | Managed |

> `/store` holds software artifacts. `/usr` holds the software that *is* the
> operating system. Nothing executes from `/store`.

Because paths are stable and conventional, the dynamic linker works without
`RPATH` rewriting or wrapper scripts, prebuilt vendor binaries find
`/lib64/ld-linux-x86-64.so.2` where they expect it, and upstream SELinux
`file_contexts` apply nearly unchanged.

## Activation

A change is a generation transition, never an in-place mutation.

```text
resolve config → resolve dependencies → build/fetch artifacts → build generation
                                                                       │
                          ┌────────────────────────────────────────────┤
                          ▼                                            ▼
                     validate                              system.cfs, SELinux policy,
                          │                                file contexts, service metadata,
                          ▼                                generation manifest
                     activate
```

Validation runs before the active system changes: dependency completeness,
artifact integrity, SELinux policy compilation, service dependency graph,
signature verification, bootability. A generation that fails validation is never
activated, and exits `5`.

A generation carries its filesystem, service configuration, security policy,
metadata and boot entry **together**, so a rollback cannot restore the
filesystem while leaving an incompatible policy behind.

```text
Generation 40 → 41 → 42 (active)
                       ╰─ 43 (prepared) ──validation fails──▶ stays on 42
```

## Generation manifest

Each generation records enough to verify it against its intent:

```text
generation id · configuration digest · artifact digests · image digest
SELinux policy digest · boot artifact digests · build metadata · signatures
```

Verifying a generation is therefore a digest comparison, not a filesystem walk.
See [reproducibility notes in adr-0003](adr-0003-store-index-and-gc.md) for how
this interacts with collection.
