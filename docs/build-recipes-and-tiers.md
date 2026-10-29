# ADR 0002 — Build recipes, definition tiers, and dependency resolution

Status: accepted
Supersedes: the tier table in package-format.md §1.5

## Context

The package format bans shell strings in build phases; phases are argv arrays.
The largest available source of package coverage — Arch `PKGBUILD`, Alpine
`APKBUILD`, Void templates, Gentoo ebuilds — is shell. An earlier draft resolved
this with a `tier` field where `imported` meant "shell allowed."

That framing was wrong, and reviewing it turned up a better answer.

## The argument that changed the decision

"Shell is dangerous, argv is safe" does not survive contact with what a build
actually does.

`make` runs arbitrary code. `configure` is a 40,000-line shell script that every
autotools package executes. `cmake` evaluates a Turing-complete language. GCC
runs arbitrary code through plugins and specs files. `cargo build` executes
`build.rs`. An argv-only phase list invoking `./configure && make` is *already*
running a large shell program — the phase list just doesn't contain the text.

So the security delta between an argv phase list and a shell script is close to
zero. Both run arbitrary code as the build user. What actually contains that
code is the sandbox — no network after fetch, no host `/usr`, declared inputs
only, fixed uid, fixed `SOURCE_DATE_EPOCH`, fixed hostname — and the sandbox is
identical either way. `curl | sh` inside a build fails on NexisOS because there
is no network, not because the recipe was argv-shaped.

The one thing argv-only genuinely buys is **reviewability**: a reader can see the
commands without reading a program. That is worth something, but it is a code-
review property, not a security boundary, and it was being sold as the latter.

## Decision

### 1. Shell is allowed, as a hashed source input

Not as a phase mode, and not gated behind a tier. A build script is a **source**:

```toml
[[source]]
role = "build-script"
path = "build.sh"
hash = "sha256-<base64>"
```

```toml
[build]
builder = "script"
```

Consequences of treating it as a source rather than as embedded text:

- It enters `source-id`, exactly like a patch does. The recipe is as pinned and
  as reproducible as the tarball.
- It is reviewable as a file, diffable across versions, and signed with the
  definition source.
- It cannot be edited without changing the build identity, so a modified recipe
  cannot silently reuse a cached artifact.
- The definition file stays declarative. There is no shell *in* the TOML — the
  TOML references a hashed artifact that happens to be a script.

This is strictly better than an embedded shell string and it required no new
concept: `[[source]]` already did this for patches.

### 2. Tiers stay, but measure the right axis

The tier field was measuring "contains shell." It should measure **has a human
looked at this**, which is the property a user actually wants to know:

| Tier | Meaning |
| --- | --- |
| `audited` | Reviewed by a person, and reproducibility verified by rebuilding |
| `standard` | Hashes pinned, builds reproducibly in CI, not individually reviewed |
| `generated` | Machine-produced from a lockfile or foreign packaging; unreviewed |
| `binary` | Prebuilt upstream artifact, no build performed |

`generated` is not a euphemism for "unsafe." It is a statement of provenance: a
definition emitted by `nexis import pkgbuild` or `nexis import cargo` is exactly
as sandboxed as any other, and its inputs are exactly as pinned. Nobody read it.
That is worth saying out loud, and it is worth being able to require:

```toml
[security]
minimum-definition-tier = "standard"
```

A tier is a claim the definition source makes and signs. `nexis check
<definition>` verifies it — rebuilding twice and comparing artifact ids — so
`audited` and `standard` are falsifiable rather than self-asserted.

### 3. `binary` definitions are first-class, not a fallback

Because NexisOS runs a real FHS, a vendor tarball is not a degraded case
requiring `patchelf` heroics; it is a fetch and a file placement. `binary` sits
in the tier list as a legitimate outcome, and a definition that repackages an
upstream release is a normal thing to write.

## Why this prevents dependency hell better than Nix does

This is the part that motivated getting the above right, and it is a genuine
design advantage rather than a matter of taste.

Nix permits multiple versions of the same library in one closure. Two paths
through the dependency graph can pull `openssl-3.0` and `openssl-3.2`, both land
in the store, and both get loaded into the same process by different
dependencies. This is *usually* fine and *occasionally* produces symbol
collisions and state corruption that are nearly impossible to diagnose. Closure
bloat is the visible symptom; silent ABI mixing is the dangerous one.

**NexisOS cannot do this, and that is the point.** A generation merges into one
real `/usr`, so `/usr/lib/libssl.so.3` names exactly one file. A dependency graph
requiring two incompatible versions is not resolvable, and the generation build
**fails with both requirers named** rather than quietly producing a system that
works until it doesn't.

That is a stricter constraint, and it is strictly better:

- **Conflicts surface at build time**, in a message naming the two packages and
  the path, instead of surfacing at runtime months later.
- **Closures stay small**, because there is no mechanism by which a duplicate
  version can hide in one.
- **Deliberate parallelism is explicit.** Slots (`python@3.12`, `llvm@18`) exist
  for cases where two versions genuinely must coexist, and they require
  slot-qualified paths, so the parallelism is visible in the filesystem rather
  than being an accident of the graph.
- **ABI changes are detected.** Interface identity is computed from the actual
  exported symbol set, so a rebuild that breaks ABI produces a different
  interface id and forces dependents to rebuild. Nix's input-addressed model
  cannot distinguish an ABI-preserving rebuild from an ABI-breaking one and must
  conservatively rebuild everything.

## Why this is faster than Nix

Also a real difference, and it comes from the format rather than from
implementation effort:

**Evaluation.** Nix evaluates a lazy functional language over a repository of
~120,000 expressions. A `nixos-rebuild` evaluation is seconds at best, often
tens of seconds, and can consume gigabytes of RAM. NexisOS parses TOML and looks
up content addresses. Evaluation is a parse and a graph walk — milliseconds,
bounded memory, and trivially cacheable because the input is data rather than a
program.

**Generation construction.** Nix builds a symlink farm and runs an activation
script. NexisOS serialises a metadata tree to EROFS; file content is already in
the store and is never copied. Seconds rather than minutes.

**Environment entry.** `nix-shell` re-evaluates. `nexis shell` hashes `dev.toml`
plus lockfiles, finds the composed layer if it exists, and mounts it. See
[environments.md](environments.md).

**Boot and runtime.** No store paths in `RPATH`, no wrapper scripts, no
`LD_LIBRARY_PATH` stuffing. The dynamic linker uses its normal cache. Page cache
is shared across generations because file content is shared.

### The honest cost

TOML cannot express abstraction. Nix definitions can be functions, can inherit,
can be overridden with arbitrary logic, and can compute a package set. A NexisOS
definition cannot.

The mitigations are real but they are mitigations: features cover conditional
builds, dependency groups cover repetition, the module system covers
configuration composition, and generators cover the cases that genuinely need
computation. Where a Nix user would write a function, a NexisOS user writes a
generator that emits definitions.

That is a worse experience for the small number of people writing highly
parameterised package sets, and a better one for everyone reading, diffing,
verifying or machine-generating definitions. Given that machine generation is
the coverage strategy, the trade is the right way round — but it is a trade, and
anyone evaluating NexisOS against Nix should be told so plainly.

## Consequences

- `package-format.md` §1.5 tier table is replaced by the one above.
- `[[source]]` gains `role = "build-script"` and a `path` field for sources that
  live in the definition directory rather than at a URL.
- `nexis check <definition>` must rebuild twice and compare artifact ids, since
  tier claims are otherwise unverifiable.
- The generation builder must report dependency conflicts naming both requirers
  and the contested path. A bare "conflict" message would waste the main
  advantage this design has over Nix.
- Import tooling emits `tier = "generated"` and never claims higher.
