# Roadmap

Phases are ordered by what blocks what, not by importance. Each phase states
what it unblocks, so a decision to reorder is a decision with a stated cost.

For the working task list see [TODO.md](../TODO.md). For the current state of
each subsystem see the table in the [README](../README.md).

**Where the project actually is:** phases 0, 1, 2 and 3 are substantially
done. What remains everywhere is the same shape: the logic is implemented and
tested, and the calls that touch a live kernel or a live disk are not yet
made. Phase 4 — package coverage — is the critical path now, because without
definitions there is nothing to build, compose, or boot.

---

## Phase 0 — Skeleton *(complete)*

Everything needed for the tree to build, be tested, and produce an ISO image.

* [x] Package definition format v1 specified
* [x] Lexical scan, TOML parse, schema validation
* [x] SRI hashing and digest primitives
* [x] Content-addressed store: atomic insert, manifests, dedup on write
* [x] Refcounted index: append-only CRC-checked log, roots, compaction
* [x] Dependency resolution: ordered pinned sources, selection not solving
* [x] Build phases, output splitting, sandbox specification
* [x] `lib/process` — argv-only execution, constructed environment, timeouts
* [x] `lib/filesystem` — atomic writes (fsync, rename, fsync dir), sorted walk
* [x] `nexis` CLI — parsing, dispatch, refusals, `check --config`
* [x] TUI installer — all seven steps, animations, dry run, 80×24 VT fallback
* [x] ISO build scripts — rootfs, initramfs, hybrid BIOS+UEFI image, QEMU
* [x] CI — lint, build, unit, installer, integration, smoke; manual dispatch

## Phase 1 — Realisation *(complete)*

Turning a resolved graph into artifacts in the store. Nothing downstream of
this can be built or tested for real, which makes it the highest-value work
remaining regardless of what else looks more interesting.

* [x] `src/nexis/build/scheduler.nim` — drains the graph, deterministic
      dispatch order, cancellation on dependency failure
* [x] Sandbox enforcement — `violations()` asserted in `preflight`, and again
      before `enter()` unshares anything
* [x] Namespace setup per build — `isolate.nim` applies the spec: unshare,
      uid/gid maps, mount plan, pivot_root, rlimits, drop to the build uid
* [x] Mount plan built as data and audited, so a read-only bind that would
      have been writable fails in CI rather than in production
* [x] `src/nexis/build/realise.nim` — joins resolver, scheduler, sandbox and
      store; store lookup happens at plan time so dry-run predicts the real run
* [x] Transactional commit: a failed build discards its staging tree, takes no
      reference, and leaves the index unaware the buildId existed
* [ ] Build log capture, attached to the artifact rather than to a file
* [x] `nexis rebuild --dry-run` — runs the real planner; reports isolation
      availability and store state
* [x] `src/nexis/build/declare.nim` — walks a declaration into a complete
      closure: locate, parse, resolve, compute build identities bottom-up
* [x] `nexis rebuild --dry-run` runs the whole chain against real definitions
* [ ] Bootstrap package set sufficient to build itself

The chain runs end to end: a declaration naming `app`, which depends on
`libfoo`, produces a two-package closure with stable build identities and a
correct build order. What remains is not plumbing but content — there is no
bootstrap package set, so nothing real can be built yet. That is Phase 7.

One bootstrap shortcut is live and should not be forgotten: a dependency's
`buildId` currently stands in for its interface id, so an ABI-preserving
library rebuild rebuilds its dependants. Correct, just wasteful.

**Unblocks:** every remaining phase. Until a build can run, the store holds
nothing a generation could be composed from.

## Phase 2 — Composition and generations *(substantially complete)*

The single mechanism behind generations, dev shells, containers and per-user
home layers — see [architecture.md](architecture.md#compositions-one-mechanism-four-uses).

* [x] `src/nexis/compose/merge.nim` — merge trees, detect path collisions,
      record provenance per path so `nexis owns` has an answer
* [x] Path collision as a hard failure naming both packages and the path
* [ ] composefs image writing: EROFS metadata over a data-only lower layer
* [x] Generation manifests and seal digests, covering image, policy, boot and
      package set together
* [x] `nexis diff` semantics — added/removed/changed, with a rebuild at the
      same version reported rather than hidden
* [x] Atomic activation — gates run before anything changes; boot entry is
      written before the mount and made default after it, the two orders that
      fail safely
* [x] Rollback target selection, generation listing, never-reused ids
* [ ] The two steps that touch the kernel: mounting the image, and reading
      manifests back from disk. Everything around them is implemented.
* [x] Boot entries — BLS type 1, one file per generation, so the bootloader
      menu *is* the generation list and a broken machine is recoverable from it
* [x] `nexis generations` / `rollback` / `diff` wired to the CLI
* [ ] `nexis generations`, `nexis rollback`, `nexis diff`
* [ ] Compositions as GC roots; `nexis gc` walking them uniformly

**Unblocks:** a bootable installed system. The installer's plan already calls
`nexis rebuild boot`, which does not exist yet.

## Phase 3 — `nexis-init` *(substantially complete)*

* [x] PID 1: signalfd, reaping, early mounts, single-threaded event loop
* [x] pidfd supervision — a handle that cannot be recycled onto another process
* [x] Service model: two dependency axes, `requires` implying `after`
* [x] Deterministic topological ordering, ties broken by name
* [x] Restart policy, sliding-window flap detection, capped backoff
* [x] Readiness gating, and `blockedBy` so a stall is explicable
* [x] cgroups v2: creation, limits, `cgroup.kill`, PSI pressure reading
* [x] Per-service confinement — namespaces, capabilities, `NO_NEW_PRIVS`
* [x] Bounded shutdown: every phase escalates rather than waits
* [x] Sleep inhibitors, suspend idempotence, thrash detection, wakeup policy
* [x] Service set loading from TOML, with whole-set validation
* [x] `sd_notify` — `READY=1`, sender identified by `SO_PASSCRED`
* [x] Socket activation — pre-bind, pass as fd 3 with `LISTEN_FDS`/`LISTEN_PID`
* [x] Watchdog — opt-in per service, aborts rather than terminating
* [ ] `timerfd` deadlines, replacing the current 100ms tick
* [ ] Native uevent manager — netlink coldplug and hotplug, device nodes
* [ ] tmpfiles / sysusers / sysctl / modules-load appliers
* [ ] PSI-based OOM policy, replacing `systemd-oomd`
* [ ] `nexis-log` and a `/dev/log` syslog socket

**Unblocks:** a machine that boots to a usable system rather than to an
installer. The appliers in particular are what make a generation's declared
users, directories and sysctls real.

## Phase 4 — Package coverage *(not started)*

Ranked by coverage per unit of effort. This is the phase that decides whether
anyone can use the distribution — see
[packaging-strategy.md](packaging-strategy.md).

* [ ] `nexis new` — generate a definition from a URL, detect the build system
* [ ] `nexis new --binary` — vendor tarballs, AppImage, Flatpak passthrough
* [ ] `nexis import cargo|npm|pypi|go` — generate from lockfiles
* [ ] `nexis import pkgbuild` — Arch packaging, emitted as tier `generated`
* [ ] Definition tiers and `minimum-definition-tier` enforcement
* [ ] `build-script` source role for shell recipes
* [ ] `nexis check <definition>` — build in the sandbox, report the actual tier

## Phase 5 — Security *(not started)*

* [ ] refpolicy base, compiled into generation images
* [ ] `nexis_init_t` policy module and per-service domain transitions
* [ ] Generation-level file contexts — no boot-time relabel
* [ ] `nexis selinux explain` — legible denials from the audit log
* [ ] nftables ruleset generated from service declarations
* [ ] Firewall zones and hardening sysctls
* [ ] seccomp profile application (the field parses; nothing applies it)
* [ ] Security profile system — `baseline`, `workstation`, `hardened-server`
* [ ] `logind` D-Bus subset, so PowerDevil reaches `sleep.nim` without elogind

## Phase 6 — Usability *(not started)*

* [ ] `nexis rebuild` switch / boot / test / build
* [ ] `nexis add` / `remove` — TOML round-tripping that preserves comments
* [ ] `nexis why` / `explain` / `owns` — provenance introspection
* [ ] `nexis check` — drift detection against the declaration
* [ ] `nexis shell` — composefs-layer environments from `dev.toml`
* [ ] Lockfile ingestion for python/node/rust/go project dependencies
* [ ] `nexis shell --scratch`, `nexis env list`, `nexis env freeze`
* [ ] Language-tool containment: read-only graveyard paths, PATH policy
* [ ] Per-user composefs layers and session mount namespaces
* [ ] Home ownership modes: managed, seeded, merged
* [ ] Binary cache client

## Phase 7 — Distribution *(not started)*

* [ ] A NexisOS kernel package. Until then the ISO borrows the build host's,
      and is therefore not reproducible
* [ ] A NexisOS base package set, replacing the host binaries `rootfs.sh`
      currently copies
* [ ] Signed artifacts and signed generations
* [ ] Secure Boot and measured boot; the EFI binary is unsigned today
* [ ] Reproducible-build verification — build twice, diff
* [ ] Benchmarks run against the targets in [benchmarks.md](benchmarks.md)
* [ ] Release infrastructure, and ISOs published to SourceForge

## Post-1.0 — systemd independence

* [ ] `libudev`-compatible library over the native uevent manager
* [ ] hwdb ingestion — required for libinput device quirks

Until these land, the desktop profile ships standalone `udev`. See
[systemd-replacement.md](systemd-replacement.md) for why this is the one
component with no maintained alternative.

---

## Known bootstrap debts

Things that work today only because something borrowed from the build host is
standing in for a piece that does not exist yet. Each is listed so it stays a
decision rather than becoming the design.

| Debt | Stands in for | Cleared by |
| --- | --- | --- |
| ISO kernel from `/boot/vmlinuz-*` | a kernel package | Phase 7 |
| Root assembled from host binaries | a base package set | Phase 7 |
| `sgdisk`, `mkfs.*` copied from the host | packaged partitioning tools | Phase 4 |
| `cage`, `foot`, `seatd` copied from the host | packaged graphical stack | Phase 4 |
| Standalone `udev` on the desktop profile | native uevent manager | Post-1.0 |
| 100ms tick instead of `timerfd` | event-driven deadlines | Phase 3 |
| Unsigned EFI binary | Secure Boot chain | Phase 7 |
| `mkcomposefs` writes the generation image | a Nim EROFS writer | [ADR 0007](adr-0007-image-writer.md) |
| composefs needs a recent kernel for overlayfs data-only layers | nothing — it is a hard floor | n/a, document it |

## Unstable surfaces

No stability guarantees. These are expected to change without notice:

package definition format · build sandbox · artifact format · generation format ·
TOML schemas · service schema · SELinux integration · init and service APIs ·
boot process · configuration module system · binary cache protocol · security
profiles · CLI
