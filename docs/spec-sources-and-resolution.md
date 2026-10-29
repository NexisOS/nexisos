# ADR 0005 — Where packages come from

Status: accepted
Amends: ADR 0004 §4 (constraints), package-format.md §2.2 (dependency groups),
and the identity model in ADR 0002

## The question

If NexisOS does not maintain a package repository, what does this mean?

```toml
[[dependencies]]
name     = "openssl"
requires = ">=3.2"
```

Previous documents said dependencies "resolve by name from the declared
sources" without ever saying how a name becomes a specific file. That is the
hole at the centre of the design, and everything else — reproducibility,
caching, the whole decentralisation claim — is downstream of it.

The goal this has to serve: **anyone can package anything, and the package
manager does the hard parts.** Writing a definition should be the easy half;
verifying it should be a command rather than a discipline.

---

## 1. Specs come from ordered, pinned sources

A NexisOS system declares where definitions may be found, in order:

```toml
[[sources]]
name = "core"
git  = "https://github.com/NexisOS/definitions"
rev  = "9f2c1ab4e8..."
keys = ["nexis-core-2026"]

[[sources]]
name = "kyle"
path = "~/src/my-definitions"

[[sources]]
name = "work"
git  = "git@internal:packaging/specs"
rev  = "3d7e91c..."
keys = ["acme-packaging"]
```

Resolution of `openssl >= 3.2`:

1. Walk sources **in declaration order**.
2. In each, look for a definition named `openssl`.
3. Take the **first** whose version satisfies the bound.
4. If none satisfies it, fail naming every candidate found and its version.

No search of a global namespace, no server, no registry. A source is a git rev
or a directory, and a git rev is a content hash — so "the set of available
definitions" is itself pinned.

## 2. Selection, not solving — and why that is enough here

ADR 0004 rejected constraint solving on reproducibility grounds and was
criticised for leaving the selection mechanism unspecified. The mechanism is
above. The rejection stands, and the reason is stronger than previously stated.

**Selection** is: first pinned source providing a satisfying version. Given the
same pinned sources it yields the same answer on every machine, forever, with
no backtracking.

**Solving** is: find an assignment of versions satisfying all constraints
simultaneously. It requires backtracking, and its result depends on the whole
universe of available versions — so the same declaration resolves differently
as sources gain versions.

The additional argument: **there is nothing for a solver to negotiate.** A
generation merges into one real `/usr`, so exactly one version of a package
exists in a view regardless. The value a SAT solver provides — finding a
consistent assignment among many possible version combinations — is moot when
the answer space has one element per name. Cargo and npm need solvers because
they permit many versions in one dependency tree. NexisOS does not, by
construction.

`requires` therefore stays a **bound that filters candidates and is asserted
after selection**, not a constraint fed to a solver. If solving is ever added
it must emit a committed lockfile, because resolution that is not written down
is not a pure function of the declaration.

## 3. A dependency may name its own source

This is the missing escape hatch, and it is what makes "package your own thing"
actually work. When no declared source provides a package, the dependency
supplies one inline:

```toml
[dependencies.mylib]
path     = "./mylib.toml"

[dependencies.otherlib]
git      = "https://github.com/someone/otherlib-spec"
rev      = "a1b2c3d"
requires = ">=2.1"
```

An inline source is used *for that dependency only* and does not enter the
system's source list, so vendoring a spec for one package cannot silently
change what another package resolves to.

The consequence worth stating: a user who wants to package a program nobody
else has packaged writes two files — the definition, and one line pointing at
it. There is no pull request, no review queue, and nothing to wait for. If it
turns out to be good, publishing it is moving the file to a git repository
someone else lists as a source.

## 4. Interfaces are first-class

`provides` was a path-level mechanism for alternatives (`/usr/bin/cc`). It is
promoted to a capability that a dependency can name:

```toml
[[provides]]
name    = "libc"
version = "2.40"

[[provides]]
name     = "cc"
version  = "14.2"
path     = "/usr/bin/cc"      # optional: also an alternatives target
priority = 50
```

```toml
[[dependencies]]
name     = "libc"
kind     = "interface"
requires = ">=2.38"
```

Selection over an interface uses the same ordered walk, filtered to definitions
that `provide` the name. This is what lets two people write competing
implementations of the same capability without either owning the name, and it
is the part of the design that is genuinely less repository-centric than Nix,
whose dependency graph is package-name-centric throughout.

Interface names are unqualified and therefore collide by construction. That is
deliberate — the whole point is that several packages may claim `libc` — and
the ordered source walk is what makes the collision resolvable rather than
ambiguous. A system that wants to pin the choice does so explicitly:

```toml
[interfaces]
libc = "glibc"
```

## 5. Dependency groups are removed

`dependency-groups` was authoring sugar for "every C++ package needs these
five things". `extends` (package-format §1.6) does the same job and more,
carries its template hash into the build identity the same way, and is one
mechanism instead of two.

Groups were also the weaker of the pair: a group is a bare list with no
identity of its own, whereas a template is an ordinary definition that can be
fetched, signed and pinned like anything else. Removing them costs nothing and
deletes a concept.

## 6. `packageId` and `artifactId` are different things

`buildId` was doing double duty. Split:

| Identity | Determined by | Identifies |
| --- | --- | --- |
| `specId` | canonical definition text | a definition file |
| `sourceId` | source and patch hashes | what gets fetched |
| `packageId` | specId, sourceId, resolved dependency `packageId`s, features, build policy | **a planned realisation** |
| `buildId` | packageId, plus realised inputs' artifact and interface ids | **a cache key** |
| `artifactId` | one output's manifest | **one output tree** |

One `packageId` yields several `artifactId`s — `out`, `dev`, `doc`. Conflating
them meant a dependency on `openssl:dev` had no distinct identity from a
dependency on `openssl`.

**Why there are two build-time identities and not one.** The review argued
resolution should freeze everything before scheduling begins. It cannot,
entirely, and the reason is a consequence of a deliberate earlier choice:
runtime dependencies enter by *interface* identity, which is computed from the
built output's exported symbols. That is what makes an ABI-preserving security
patch cheap, and it is not knowable at resolve time.

So `packageId` is fully determined by the declaration and is what the graph and
`nexis why` use; `buildId` is refined at dispatch, once inputs are realised.
The property that matters is preserved: `buildId` depends only on *which*
inputs were realised, never on when or in what order, so two machines with
different core counts agree.

## 7. Roots commit transactionally; a failed build leaves no live reference

Objects may land in the store during a build — they are immutable and
content-addressed, so a stray object costs disk and nothing else. **References
and roots may not.** Refcount increments are staged and committed only when a
realisation succeeds, and a generation becomes a root only after its image
validates.

A build that fails therefore leaves unreferenced objects, which the next
collection reclaims, and no half-registered generation.

## 8. Garbage collection: refcounts for speed, reachability for correctness

The review argued refcounts should not be load-bearing for correctness. Agreed,
and that is already the design — but the invariant deserves to be sharper than
"the index is a cache".

- **Normal path:** refcounts. Retiring a generation costs what it uniquely
  held.
- **Correctness path:** an object is deleted only if it is refcount-zero
  **and** unreachable from the live roots. The intersection means refcount
  drift can only ever cost disk, never delete a live file.
- **Repair path:** `nexis store verify --rebuild-index` recomputes from roots.

Making deletion require both conditions is the change here. It removes the
consistency problem the review identified, at the cost of a reachability walk
during collection that can be scoped to the retiring closure rather than the
whole store.

---

## Consequences

- `[[sources]]` replaces the sketch in packaging-strategy §3, with ordering as
  the resolution rule.
- Dependencies gain `kind = "interface"`, inline `path`/`git`/`rev`, and
  `requires`.
- `provides` gains `version`; `path` becomes optional.
- `dependency-groups` and `native-groups` are removed from the format;
  `modules/base/groups.toml` and `package/groups.nim` go with them.
- `Resolved` gains `specId` and `packageId`.
- Refcount commits become transactional, and `collect` intersects refcount-zero
  with root-unreachability.
- The resolver needs a spec loader and cache: fetch a git source once per rev,
  store it content-addressed, reuse it across resolutions.
