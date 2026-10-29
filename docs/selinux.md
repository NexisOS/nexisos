# SELinux

SELinux enforcing by default, with a real policy, is a design goal rather than
an aspiration — and it is achievable specifically because of the FHS decision.

## Why NixOS cannot do this, precisely

The reason is worth stating exactly, because it is the clearest case of a design
choice foreclosing a security property.

SELinux assigns types to files through `file_contexts`: a list of path regexes
mapped to types. `/usr/sbin/nginx` gets `httpd_exec_t`. Every rule in the policy
that constrains what nginx may do keys off that type.

Under Nix, nginx lives at `/nix/store/<hash>-nginx-1.27.3/bin/nginx`. That path:

- contains a hash that changes whenever any input changes, so no regex written
  in advance matches it;
- is not stable across rebuilds, so labels must be reapplied constantly;
- carries no semantic information — `/nix/store/<hash>-*/bin/*` is every binary
  on the system, so a regex broad enough to match is too broad to be useful.

The practical outcomes are the ones people actually hit: relabeling the store is
expensive and unbounded, upstream `refpolicy` is unusable without rewriting its
entire `file_contexts`, and the pragmatic fallback is labelling the store
permissively — which is close to not running SELinux at all.

This is not a bug anyone can fix. It is what content-addressed runtime paths
cost.

## Why NexisOS can

Applications live at `/usr/sbin/nginx`. Libraries at `/usr/lib`. Configuration
at `/etc/nginx`. State at `/var/lib/nginx`.

These are the paths that upstream `file_contexts` were written against, over
twenty years, by people who understood the software being confined. **NexisOS can
use them nearly unchanged.** That reuse is the single largest piece of leverage
available, and it is a direct dividend of not exposing store paths.

## Labels are built, not applied

The second structural advantage: labels never need to be applied to a running
system.

Generation images are composefs — an EROFS metadata image carrying the directory
structure, permissions, and xattrs, including `security.selinux`. The generation
builder writes the labels **into the image** from the generation's own policy.

So:

- There is no `setfiles` pass, at install or at boot or after an update. The
  labels arrive correct.
- There is no relabel-on-first-boot, which on other distributions is a
  multi-minute step that users learn to dread.
- Labels are covered by the generation's seal digest, so a mislabelled file is
  an integrity failure, not a silent policy hole.
- Rollback restores filesystem and labels as one object. It is not possible to
  end up on generation 41's `/usr` with generation 42's contexts.

`/usr` is read-only and has no overlayfs upper layer, so the copy-up labelling
problems that make overlayfs and SELinux historically awkward do not arise.

## Why file-level dedup does not fight labelling here

Worth stating because it is an argument against the obvious alternative.

Extended attributes live on the inode. A store that deduplicates by
**hardlinking** — which is what `nix-store --optimise` does — cannot share two
byte-identical files that need different SELinux labels, because sharing them
means sharing one `security.selinux` value. Dedup and labelling conflict, and
they conflict silently.

Under composefs the label lives in the generation's metadata image, not on the
store object. Several generations redirect to the same object and each supplies
its own label. So NexisOS gets full file-level deduplication *and* per-
generation labelling, and a rollback restores the filesystem and its contexts
as one sealed unit. See
[adr-0003-store-index-and-gc.md](adr-0003-store-index-and-gc.md).

## Policy source

Write nothing from scratch. `refpolicy` is the base, with Fedora's derived
policy as the reference for how a modern desktop and server are actually
confined.

**The one real incompatibility:** upstream policy assumes systemd. Service
domain transitions are written as `init_t` → service domain via systemd's unit
handling, and a good deal of policy encodes systemd's specific behaviour around
sockets, cgroups and D-Bus activation.

`nexis-init` therefore needs its own policy module: a `nexis_init_t` domain for
PID 1, transition rules from it into each service domain, and rules covering the
supervisor's use of `pidfd`, cgroup v2 and socket activation. This is real work,
but it is *bounded* work against a stable interface — it is one module, not a
policy.

Everything else — the thousands of rules describing what nginx, sshd, postgres
and a desktop session may do — carries over.

## Per-package contracts generate policy

A package declares its security contract:

```toml
[security.selinux]
domain          = "httpd_t"
executable-type = "httpd_exec_t"

[security]
needs-network = true

[security.capabilities]
allow = ["CAP_NET_BIND_SERVICE"]
```

The generation builder turns these into the file context entries and domain
transitions for that package and composes them into the generation's policy.
A package's confinement travels with the package rather than living in a
separate policy repository that drifts out of sync with it.

## Defaults

- **Enforcing, not permissive.** Shipping permissive means shipping untested
  policy, and a policy nobody tests is a policy that will never be enforced.
- **Targeted policy**, confining services rather than attempting MLS.
- **Booleans are declarative.** `[selinux.booleans]` in configuration; no
  `setsebool -P` mutating state outside the generation.
- **`unconfined_t` is available but never the default for a service.** A service
  that will not confine is a bug to be fixed, and marking it unconfined should
  require saying so in the configuration where a reviewer will see it.

## The hard parts, stated up front

- **Denials must be legible.** The single largest reason people disable SELinux
  is that a denial presents as a program mysteriously not working. `nexis
  selinux explain` reading the audit log and reporting which rule denied what,
  with the specific configuration change that would allow it, is not a nice-to-
  have. It is the difference between a policy that stays enforcing and one that
  gets turned off.
- **Third-party and imported definitions arrive unconfined.** A definition
  imported from a `PKGBUILD` has no security contract. It should default to a
  restrictive generic domain rather than `unconfined_t`, and `nexis show` should
  report confinement status alongside definition tier.
- **Desktop confinement is genuinely unsolved everywhere.** Fedora confines
  services well and desktop applications barely. NexisOS will not solve this
  either; the honest target is service confinement equal to Fedora's, plus
  seccomp and namespace isolation for desktop applications through the service
  sandbox rather than through SELinux.
