# NexisOS Package Definition Format v1

Status: draft. This document is normative for `nexis-pkg` and the generation
builder; where it disagrees with the README, this document wins and the README
should be updated.

A package definition is a single TOML file that fully describes how a piece of
software is obtained, built, split into outputs, and merged into an FHS runtime.

**Anyone may author one.** There is no privileged repository and no review
queue between writing a definition and using it: a definition can live in a git
repository, on a URL, or in a directory on your machine, and a dependency
resolves from whatever sources the configuration declares. Publishing is
optional and comes after it already works. See
[packaging-strategy.md](packaging-strategy.md) §3.

---

## 1. Identity model

The README names four identities but does not say what feeds them. It matters,
because each one answers a different question:

| Identity | Answers | Recomputed when |
| --- | --- | --- |
| Source | "did the inputs we fetch change?" | any source or patch hash changes |
| Build | "must we build again?" | source, resolved deps, features, phases, toolchain, target, revision |
| Artifact | "is this byte-identical to what we have?" | output tree content changes |
| Interface | "must *dependents* build again?" | exported ABI/API surface changes |

### 1.1 Source identity

```
source-id = H( name, version, sorted[ (role, uri-independent content hash) ] )
```

Deliberately **excludes** the URL. Two mirrors of the same tarball have the same
source identity; changing a mirror is not a rebuild. `role` distinguishes a
primary source from a patch so that swapping the two is a different identity.

### 1.2 Build identity

```
build-id = H( source-id,
              revision,
              target-triple,
              builder-name,
              resolved-phases,           # after all overrides applied, argv arrays
              sorted[ enabled-feature-names ],
              sorted[ build-dep artifact-ids ],
              sorted[ runtime-dep interface-ids ],
              declared-environment,
              output-names )
```

Three consequences worth stating explicitly:

- **Dependency groups expand before hashing.** A group is pure authoring sugar.
  If the contents of group `cpp` change, the expanded list changes, `build-id`
  changes, and the package rebuilds. This is the correct behaviour and it means
  groups need no version numbers — but it also means group files are build
  inputs and belong under version control alongside definitions.
- **Build deps enter by artifact id, runtime deps by interface id.** A compiler
  patch release changes what you built *with*, so you rebuild. A runtime library
  rebuild that preserves ABI does not force the world to rebuild.
- **Features are hashed as the resolved enabled set,** not as the declaration.
  `gtk3 = true` on one host and a profile override to `false` on another produce
  two different build ids, as they must.

### 1.3 Artifact identity

Content address of the output tree after normalisation: sorted directory
entries, timestamps zeroed, uid/gid zeroed, mode bits preserved. One artifact id
per output, plus one over the set.

### 1.4 Interface identity

Computed from the output, not declared by hand:

- for each installed `ELF DSO`: `SONAME` + sorted exported dynamic symbols with
  their versions
- sorted list of installed headers with their content hashes
- sorted `pkg-config` `.pc` files with `Requires`, `Libs`, `Cflags` normalised
- sorted list of installed executables by name (not content)

A package whose artifact id changed but interface id did not is a **drop-in
replacement**: the generation builder may swap it without rebuilding dependents.
This is the payoff for having a separate interface identity at all, and it is
the mechanism that makes a security patch to `zlib` cheap.

---

### 1.5 Definition tier

Every definition declares a tier. The tier records **whether a human reviewed
it**, which is the property a user needs to know:

```toml
tier = "standard"      # audited | standard | generated | binary
```

| Tier | Meaning |
| --- | --- |
| `audited` | Reviewed by a person, reproducibility verified by rebuilding |
| `standard` | Hashes pinned, builds reproducibly in CI, not individually reviewed |
| `generated` | Machine-produced from a lockfile or foreign packaging; unreviewed |
| `binary` | Prebuilt upstream artifact, no build performed |

The tier does **not** record whether the build uses shell. Shell is permitted
via a hashed `build-script` source (§2.1) and carries the same reproducibility
guarantees as any other input — see
[adr-0002-build-recipes-and-tiers.md](adr-0002-build-recipes-and-tiers.md) for
why that framing replaced the earlier one.

A security profile may set `minimum-definition-tier`. Tier claims are
falsifiable: `nexis check <definition>` rebuilds twice and compares artifact ids.

### 1.6 Abstraction without a language

The obvious criticism of TOML definitions is that they cannot abstract. Nix
definitions are functions; ours are data. In practice Nix's abstraction is used
for three things, and two of them are expressible as data.

**Inheritance.** Shared build boilerplate:

```toml
extends = "templates/autotools-gnu"
```

The named definition is loaded first and this file's keys override it. Rules
that keep it from becoming a language:

- **One level.** A template may not itself `extend`. Chains are how a data
  format becomes a program you have to execute to understand.
- **Templates are ordinary definitions** in a definition source, fetched and
  hashed like anything else.
- **Merge is shallow per table**, and arrays replace rather than append. A
  definition's own `dependencies` is its dependencies, not its dependencies
  plus whatever the template had.
- **The template's content hash enters `build-id`**, so changing a template
  rebuilds everything that extends it.

**Version matrices.** One file describing a family:

```toml
[matrix]
version = ["3.11.9", "3.12.7", "3.13.1"]
slot    = ["3.11", "3.12", "3.13"]
```

Expands to one definition per row before validation. Parallel arrays must be
the same length, and the cross product is deliberately *not* supported — a
cross product is where a matrix stops being a table and starts being a loop.

**Overrides.** Already covered by features, phase modes, and `revision`.

What remains genuinely unavailable is computation: a definition cannot derive
a value from another definition, or branch on anything but a feature. That is
the intended limit. Where a Nix user would write a function, a NexisOS user
writes a generator that emits definitions — worse for the few people
maintaining highly parameterised package sets, better for everyone reading,
diffing, verifying or machine-generating them, and it keeps evaluation a parse
rather than an interpretation.

---

## 2. File structure

```toml
schema = 1

name     = "libreoffice"
version  = "25.2.5"
revision = 1                      # bump to force rebuild without a version change
```

`revision` changes `build-id` but not `source-id`.

### 2.1 Sources

Sources are a list. Patches are sources with `role = "patch"`, which is what
makes them hash into `source-id` correctly.

```toml
[[source]]
role   = "primary"
urls   = [
  "https://download.documentfoundation.org/libreoffice/src/25.2.5/libreoffice-25.2.5.tar.xz",
  "https://mirror.example.org/libreoffice-25.2.5.tar.xz",
]
hash   = "sha256-YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY3ODkwPT0="
unpack = "auto"                   # auto | none | tar | zip

[[source]]
role  = "patch"
urls  = ["https://example.org/patches/fix-build-gcc15.patch"]
hash  = "sha256-..."
strip = 1                         # -pN
```

**Hashes are SRI strings: `<algo>-<base64>`.** The algorithm is inside the
value, so adding BLAKE3 later is a per-package migration rather than a flag day.
A bare hex string is a schema error.

`urls` is an ordered list; the fetcher tries in order and verifies against
`hash` regardless of which succeeded.

### 2.2 Build

```toml
[build]
builder = "autotools"             # autotools | cmake | meson | make | cargo | go | script
target  = "x86_64-linux-gnu"      # optional; defaults to host target

native-groups     = ["gnu-build"]
dependency-groups = ["cpp", "xml", "image", "compression"]

native      = ["bison", "flex"]   # extra, beyond the groups
dependencies = []

environment = { SOURCE_DATE_EPOCH = "0" }
```

`environment` is a **table**, not an array of `KEY=value` strings. It is the
complete environment: nothing is inherited from the build host. Notably, do
*not* set `CC`/`CXX` here — the toolchain comes from `native` dependencies so
that it is pinned by artifact id. An `environment` key that shadows a
toolchain-provided variable is a schema error.

`native` are dependencies needed *to build* (build-host architecture);
`dependencies` are needed *at runtime* (target architecture). Cross-compilation
depends on this distinction being enforced, so it is not optional even when they
are the same.

### 2.3 Phases

A builder supplies default phases. Every phase is a list of argv arrays — never
a shell string. This keeps builds auditable, keeps quoting bugs out, and matches
the project's stance against shell-driven service execution.

```toml
[build.phases]
configure = { mode = "args", add = ["--disable-debug", "--disable-tests"] }
build     = { mode = "default" }
check     = { mode = "skip" }
install   = { mode = "default" }

# Full replacement when the default is useless:
[build.phases.configure]
mode = "replace"
argv = [
  ["./autogen.sh"],
  ["./configure", "--prefix=/usr", "--disable-debug"],
]
```

Modes: `default`, `skip`, `args` (append flags to the default invocation),
`prepend`, `append` (extra argv arrays before/after the default), `replace`.

`script` builder means all phases are `replace` and there is no default.

### 2.4 Features

Features are the fix for the biggest gap in the current draft: they must select
dependencies, not merely flip a flag the build system happens to read.

```toml
[features.gtk3]
default      = true
dependencies = ["gtk3", "glib", "cairo"]
configure    = ["--enable-gtk3"]
configure-off = ["--disable-gtk3"]

[features.qt6]
default      = false
dependencies = ["qt6-base"]
configure    = ["--enable-qt6"]

[features.java]
default = false
native  = ["openjdk"]
configure = ["--with-java"]

[features.translations]
default = true
outputs = ["locale"]              # this feature produces this output

[features.help]
default = false
outputs = ["doc"]
```

Resolution order: definition `default` → profile override → host config
override. The resolved set is hashed into `build-id`, and every enabled
feature's `dependencies`/`native` are unioned into the closure *before*
resolution. A dependency reachable only through a disabled feature is not in the
closure — which is the property the current flat-list design silently violates.

Mutual exclusion is declared, not implied:

```toml
[features]
conflicts = [["gtk3", "qt6"]]
```

### 2.5 Outputs

```toml
outputs = ["out", "lib", "dev", "doc", "locale"]

[output.out]
paths = ["/usr/bin/**", "/usr/libexec/**", "/usr/share/applications/**"]

[output.lib]
paths = ["/usr/lib/**.so.*"]

[output.dev]
paths = ["/usr/include/**", "/usr/lib/pkgconfig/**", "/usr/lib/**.so"]

[output.doc]
paths = ["/usr/share/doc/**", "/usr/share/man/**", "/usr/share/help/**"]

[output.locale]
paths = ["/usr/share/locale/**"]
```

Rules:

- The first output listed is the default; `dep = "libreoffice"` means
  `libreoffice:out`.
- Patterns are matched in `outputs` declaration order and **the first match
  wins**. Overlap between outputs is therefore legal and expected: the natural
  way to write `dev` and `lib` rules produces overlapping globs
  (`/usr/lib/**/*.so` and `/usr/lib/**` both match a symlink), and forbidding
  overlap would make the common case unwriteable. Order carries the intent —
  declare `dev` before `lib` and the `.so` symlinks land in `dev`.
- Two outputs declaring the **identical** pattern is an error: the later one is
  unreachable, so the author meant something they did not write.
- Overlapping-but-distinct patterns produce a **warning** naming which output
  wins, so the ordering decision is visible rather than silent.
- Every installed file must match at least one output pattern. Unmatched files
  are a **build error**, not a silent drop — this is how you catch an upstream
  that started installing somewhere new.
- Dependents may depend on a specific output with `:`, e.g.
  `dependencies = ["openssl:dev"]`. See §3.3 for the `@slot` sigil; a full
  reference is `name[@slot][:output]`.

Multi-output matters more here than it does under Nix. Because a generation is a
single merged FHS image rather than a set of symlinked store paths, every byte
of `translations` and `help` you don't split out is a byte in every generation
image on disk.

---

## 3. FHS composition and file conflicts

This is the section with no NixOS equivalent. Under Nix, two versions of a
library coexist because each lives at its own store path and nothing merges.
NexisOS merges into a real `/usr`, so collisions are real and must be a defined
part of the package format rather than an accident of build order.

### 3.1 Hard rule

Within a generation, every path maps to exactly one `(package, output)`. A
collision is a **generation build failure** naming both packages and the path.
Last-write-wins is never used. Build order must never affect the resulting
image, or reproducibility is a fiction.

### 3.2 Virtual provides and alternatives

For the legitimate case of several packages offering the same interface:

```toml
provides = [
  { name = "cc",     path = "/usr/bin/cc",     priority = 50 },
  { name = "editor", path = "/usr/bin/editor", priority = 10 },
]
```

The generation builder creates each virtual path from the highest-priority
provider. Ties are an error. The system config may pin explicitly:

```toml
[alternatives]
cc = "gcc"
```

A `provides` path is exempt from §3.1 because no package owns it directly.

### 3.3 Slots

**How narrow this constraint actually is.** "One version of a library per view"
overstates it, and the overstatement matters because it is the most-cited
reason to prefer Nix.

Shared libraries carry sonames. `libfoo.so.2` and `libfoo.so.3` are different
filenames, so they do not collide and both can be installed with no slot
declaration at all — the dynamic linker already distinguishes them, which is
what sonames are for. The only file that genuinely collides is the unversioned
`libfoo.so` development symlink, which lives in the `dev` output and matters
only when building.

So the constraint bites in exactly three places:

1. Two versions of the same **executable** at the same path.
2. Two libraries with the **same soname** and incompatible ABIs, which is an
   upstream versioning bug rather than a packaging problem.
3. The unversioned `dev` symlink when two slots are installed together.

All three are handled by declaring a slot. And because a user's package set
composes as its own layer (see [home.md](home.md)), two users can hold
different versions of anything without either declaring a slot, since their
views are never composed together.



For deliberate parallel versions:

```toml
slot = "3"                        # e.g. python 3.11 vs 3.12, llvm 17 vs 18
```

Packages with different slots may coexist. They must not collide, which means
slotted packages are responsible for slot-qualifying their own paths
(`/usr/bin/python3.12`, `/usr/lib/llvm-18/`). The unqualified name is then
supplied through §3.2 `provides`. Dependencies may also carry a version bound, which is **checked, not solved**:

```toml
[[dependencies]]
name     = "pcre2"
requires = ">=10.40"
```

The resolver resolves `pcre2` by name from the declared sources, then asserts
the resolved version satisfies the bound and fails naming both versions if it
does not. That catches a source silently providing a version too old for the
package.

It deliberately stops short of constraint solving. A solver's output depends on
the universe of definitions available at resolve time, so two machines — or the
same machine a week later — would resolve one declaration to different
closures, which breaks the property the whole system rests on. See
[adr-0004-scheduling-and-constraints.md](adr-0004-scheduling-and-constraints.md).

Dependents may require a slot with `@`:
`dependencies = ["python@3.12"]`. The two sigils are distinct because a
dependency can carry both — `llvm@18:dev` is the dev output of the LLVM 18
slot. A reference is `name[@slot][:output]`.

Sonames make this free for shared libraries: `libfoo.so.1` and `libfoo.so.2`
don't collide on their own, and only the `dev` output's unversioned `libfoo.so`
needs a slot decision.

### 3.4 Explicit conflicts and replaces

```toml
conflicts = ["other-package"]     # cannot be in the same generation
replaces  = ["old-name"]          # takes over its paths on upgrade
```

`conflicts` is checked at configuration-resolution time, before any build
starts, so the user gets the error in seconds rather than after a LibreOffice
compile.

### 3.5 Conflict scope is per composed view

Collision checking applies to a **composed view**, not to the store globally.

The system `/usr` is one view. Each user's session — the system layer plus that
user's package layer — is another. So:

- Two packages in the system set claiming one path: error.
- Two packages in one user's set claiming one path: error.
- A package in kyle's set and a package in bob's set claiming one path: **not**
  an error. They are never composed together.
- A user package claiming a path the system layer also provides: legal, but only
  when declared:

```toml
shadows = ["python"]
```

Silent per-user divergence from the system is the failure this whole design
exists to prevent, so shadowing is opt-in and `nexis explain` reports it. See
[home.md](home.md) for how the per-user layers are composed.

---

## 4. Security contract

Carried in the definition, consumed by the generation builder and `nexis-init`:

```toml
[security]
needs-network = false
needs-mount   = false
needs-ptrace  = false

[security.capabilities]
allow = ["CAP_NET_BIND_SERVICE"]

[security.selinux]
domain          = "soffice_t"
executable-type = "soffice_exec_t"
```

The **build** sandbox is separate and not negotiable per-package: no network
after fetch, no host `/usr`, no ambient environment, fixed `SOURCE_DATE_EPOCH`,
fixed uid/gid, fixed hostname. A definition that needs network during build must
say so and is thereby marked non-reproducible in its build record.

---

## 5. Validation rules

The parser rejects, rather than warns on:

0. **A top-level key appearing after the first table header.** TOML binds a bare
   key to the most recently opened table, so `outputs = [...]` written below
   `[features.translations]` silently becomes `features.translations.outputs`.
   This is not a hypothetical: it is the single easiest mistake to make in this
   format, it produces a valid TOML document, and it fails only much later as a
   missing-field error. Requiring all top-level keys to precede any table header
   turns it into a parse error at the point of the mistake.
1. `schema` missing or unknown.
2. A hash without an `<algo>-` prefix.
3. An empty `urls` list on any source.
4. A feature listed in `conflicts` that isn't declared.
5. A `dependency-groups` entry that doesn't resolve.
6. An `environment` key that shadows a toolchain variable.
7. Two outputs declaring an identical path pattern. (Overlapping but distinct
   patterns are legal and resolved by declaration order; they warn.)
8. `slot` set on a package with no slot-qualified paths.
9. `provides` priority collisions within one definition.
10. A dependency on an output the target package doesn't declare.

Rule 10 needs the whole set loaded, so validation is two-phase: per-file
schema validation, then closure validation. The Nim types should make that split
explicit — parse into a `RawDefinition`, validate into a `Definition`, resolve
into a `ResolvedDefinition` that owns the computed ids.

---

## 6. Implementation notes

### Rule 0 cannot be checked from the parsed tree

This is worth stating because it dictates the parser's shape. A TOML value tree
records that `features.translations.outputs` exists; it cannot record that the
author meant it to be top-level. Both a misbinding and an intentional key
produce the same tree.

So the parser runs a **lexical pre-pass over the source text** before handing it
to the TOML parser (`src/nexis/package/lexical.nim`). That pass:

- tracks bracket depth and multi-line strings so array continuations and
  comments aren't mistaken for keys or table headers;
- maintains the current table path, normalising `source[3]` → `source[]` and
  `features.gtk3` → `features.*`;
- checks each bare key against the legal key set for its table context.

A key that is legal nowhere in its table is reported as an unknown key — which
catches plain typos (`bulider = "make"`) for free. A key that is illegal *and*
is a reserved top-level name gets the specific rule-0 message naming the table
it was actually bound to, because that is the mistake the author made.

The pre-pass also builds a path→line index. `parsetoml` reports line and column
for syntax errors but its value tree carries no locations, so without this index
a semantic error like "hash is missing its algorithm prefix" would have nowhere
to point.

### Field hashing must be length-prefixed

Identity hashes join their fields with an explicit length prefix
(`"<len>:<value>"`) rather than a separator. Concatenating raw strings lets
`("ab", "c")` and `("a", "bc")` produce the same digest, which for a build
identity means two different packages silently sharing a cache entry. A
separator character merely moves the problem to inputs containing that
character.

### Library choices

- **`parsetoml`** for TOML. Chosen over hand-rolling: the only thing a custom
  parser would buy is source locations on values, and the lexical pre-pass
  above already supplies those for the keys that need them.
- **`checksums/sha2`** for SHA-256. Note the API is `initSha_256()` /
  `update` / `digest()` over `openArray[char]`, not the `init`/`final` shape
  that a `Sha256` context type would suggest.
- **BLAKE3** is reserved in the `HashAlgo` enum but not implemented; it needs a
  C wrapper. `parseSri` will accept `blake3-` prefixed values as soon as one
  exists, with no format change.
