# ADR 0004 — Scheduling, constraints, and build policy identity

Status: accepted
Amends: the sequence diagram in `docs/diagrams/`, and `buildIdentity` in
`package/resolve.nim`

## Context

An external review of the architecture raised five points. Three are adopted
here, one is adopted in a modified form, and one is rejected. Recording the
rejected one matters as much as the rest, because it is the point where this
design deliberately diverges from the mainstream package-manager shape and the
reasoning should be findable later.

---

## 1. The dependency graph is the scheduler — adopted

This was a real gap.

Every diagram and every prose description so far said "for each package, in
dependency order", which is not merely a simplification — it encodes a
sequential mental model into the design. If `zlib`, `openssl` and `libpcre`
depend on nothing in common, there is no reason for them to build one after
another, and on a machine with 16 cores the sequential model wastes most of
the machine on every rebuild.

**Decision.** Realisation is driven by a scheduler over the resolved graph. A
node is *ready* when every one of its inputs is realised; all ready nodes may
execute concurrently up to a job limit. The graph is not walked in an order —
it is drained.

```
RealizationGraph
  ready()     -> nodes whose inputs are all realised
  realize(id) -> mark done, release dependents
```

Consequences that are not obvious:

- **Cache lookup happens per node, before scheduling**, not as a separate
  pass. A node whose `buildId` is already in the index is realised instantly
  and releases its dependents immediately, so a mostly-cached rebuild collapses
  to a graph walk with almost no building.
- **Build failure must not leave the graph half-drained silently.** The
  scheduler stops admitting new work on first failure, lets in-flight builds
  finish or be cancelled, and reports the failed node plus every node that was
  waiting on it. Reporting only the failure leaves the user guessing at scope.
- **Job limits are per-machine, not per-package.** `@jobs@` inside one build
  and the number of concurrent builds are separate budgets, and multiplying
  them is how a rebuild ends up with 256 compiler processes. The scheduler owns
  the total.
- **Parallelism must not reach identity.** Two machines with different core
  counts must produce the same `buildId`, so neither the job limit nor the
  scheduling order may enter the hash. This is already true and there is a test
  for it; it becomes load-bearing once scheduling is concurrent.

## 2. Build policy belongs in the identity — adopted

`buildIdentity` currently hashes the source identity, revision, target,
builder, phases, features, environment and dependency identities. It does not
hash the **sandbox policy**.

That is a hole. If the sandbox changes — a mount is added, an environment
variable is introduced, the uid changes, network is permitted for a class of
build — then artifacts built before and after are not built under the same
conditions, and yet they share a cache entry. The reproducibility argument
in [adr-0002](adr-0002-build-recipes-and-tiers.md) depends on the sandbox, so
the sandbox has to be part of what identifies a build.

**Decision.** Introduce `BuildPolicy`, bundling the sandbox spec, the toolchain
identity and `SOURCE_DATE_EPOCH`, and hash its canonical rendering into
`buildId`. `SandboxSpec.render()` already produces that canonical form — it was
written for the build log, and it turns out to be exactly what identity needs.

## 3. `RealizationGraph` as an explicit type — adopted

Resolution currently returns a `Resolved` per package and the caller is left to
infer the graph. Making the graph a value gives the scheduler something to
drain, gives `nexis why` a structure to walk, and gives the CLI something to
render for `dry-run`. Cheap, and it removes an implicit structure that three
different callers would otherwise each reconstruct.

## 4. Version constraints — adopted as *assertions*, not as a solver

The review proposed dependencies as constraints (`pcre2 >= 10`) resolved by a
solver, on the grounds that a dependency should mean "something satisfying this
requirement" rather than "the package with this name from the repository".

**The goal is right and is already met by other means.** There is no privileged
repository: definitions resolve from whatever sources the configuration
declares, and `provides` already supplies the "anything satisfying this
interface" indirection. Decentralisation does not require a constraint solver.

**The mechanism is rejected, and the reason is reproducibility.** A solver's
output depends on the universe of specs available at resolve time. Two machines
with different definition sources — or the same machine a week later — resolve
the same declaration to different closures. That breaks the property the entire
system is built on: *system state is a pure function of the declaration*. It
also breaks caching, because a differently-resolved closure produces a
different `buildId` for everything downstream.

This is the same reason Nix does not do constraint solving, and it is one of
the few places where Nix's design is unambiguously right.

**What is adopted is the narrow, useful part.** Constraints are recorded and
**checked**, never solved:

```toml
[[dependencies]]
name = "pcre2"
requires = ">=10.40"
```

The resolver resolves `pcre2` by name as it does today, then asserts that the
resolved version satisfies `>=10.40` and fails with both versions named if it
does not. That catches the real bug — a definition source silently providing a
version too old for the package — without making resolution depend on anything
but the declaration.

If constraint solving is ever added, it must emit a **committed lockfile**, so
that resolution happens once and the declaration plus lock remains a pure
function. A solver whose result is not written down is not compatible with this
architecture.

## 5. Renaming `Definition` to `PackageSpec` — rejected

The argument: "definition" connotes something maintained centrally, while
"spec" makes clear that a user may author one.

The connotation is weak — Arch has `PKGBUILD`, Gentoo `ebuild`, Homebrew
`formula`, Spack `package`, none of which reads as more or less
user-authorable than the others — and the decentralisation is already stated
architecturally rather than left to inference.

Against it, there is a concrete collision: this project already has a
*specification* (`docs/package-format.md`) describing the format. Calling the
files "specs" means "the spec spec", and every sentence about one has to
disambiguate. That cost is paid on every future document.

**Rejected**, but the underlying concern is real and is addressed directly: the
format documentation now leads with the fact that anyone may author a
definition and point at it, rather than leaving it to be inferred from a
section on decentralised sources.

---

## Also considered and not adopted

The review's example model dropped several things. Recording why each stays:

- **Phase modes.** The proposal has every phase spelled out as explicit argv.
  That is exactly the `script` builder, which already exists. Dropping
  `default`/`args`/`prepend`/`append`/`replace` would mean every autotools
  package restates `./configure && make && make install`, which works against
  the goal of making a definition trivial to write.
- **`/out` as an install prefix.** A Nix-ism. Packages must install to FHS
  paths because the generation merges them into a real `/usr`; `@dest@` plus
  `@prefix@` is a staging root plus a real prefix, and relocating from `/out`
  afterwards would reintroduce exactly the path-rewriting this design avoids.
- **`tier`, `slot`, `provides`, `conflicts`, `replaces`, `revision`, and the
  security contract.** The simplified model omits all of these. They are what
  make the FHS merge and SELinux integration work, and their absence is why the
  simplified model looks cleaner.
- **`role` on sources.** Dropping it removes patches and hashed build scripts,
  both of which are load-bearing.

## Consequences

- `resolve.nim` gains `RealizationGraph` with `ready()` / `realize()`.
- `buildIdentity` gains the `BuildPolicy` digest. This invalidates every
  artifact built before the change, which is correct and should happen before
  any cache is published.
- `build/scheduler.nim` is a new module: drain the graph, honour a job limit,
  stop admitting on failure, report the blocked set.
- The package format gains an optional `requires` on dependencies, checked
  after resolution.
- The sequence diagram is redrawn with a `par` block; the sequential loop was
  misleading.
