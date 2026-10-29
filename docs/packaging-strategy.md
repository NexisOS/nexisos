# Getting software onto NexisOS

Every new distribution dies the same way. Someone tries it, wants a program that
isn't packaged, finds no way to get it that doesn't feel like a defeat, and
leaves. "When will you package X" is not a support question — it is the question
that decides whether the project survives.

nixpkgs has on the order of 120,000 package definitions and thousands of
contributors. NexisOS will not have that, and no amount of enthusiasm changes
it. So the strategy cannot be "catch up." It has to be that **NexisOS needs far
fewer definitions to cover the same ground**, and that writing the ones it does
need is close to free.

Both of those follow from the FHS decision that was already made for other
reasons.

---

## 1. Most of nixpkgs' size is self-inflicted

This is worth stating plainly because it reframes the whole problem.

Under Nix, a prebuilt Linux binary does not run. The ELF interpreter it asks for
is `/lib64/ld-linux-x86-64.so.2`, which does not exist. Its `DT_NEEDED`
libraries are not on any path the loader will search. So every piece of
already-working software must be wrapped: `autoPatchelfHook`, `steam-run`,
`nix-ld`, FHS user environments, `buildFHSEnv`. Each of these exists to
reconstruct, at great effort, the environment the binary already expected.

A large share of nixpkgs' definition count is that reconstruction work, applied
once per binary distribution.

**NexisOS runs a conventional FHS.** `/lib64/ld-linux-x86-64.so.2` is where the
binary expects it. `/usr/lib` contains libraries with conventional sonames. A
vendor tarball, an AppImage, a Flatpak runtime, the payload of a `.deb` — these
execute unmodified.

So for a large category of software, the NexisOS answer to "when will you
package X" is **"you don't need to."** The declaration is a fetch, a hash, and a
statement of where the files go. There is no build, no patching, no wrapper.

That is not a small ergonomic win. It is the difference between needing 120,000
definitions and needing something in the low thousands.

---

## 2. Four ways software arrives, in increasing cost

| Kind | Example | What a definition contains | Who writes it |
| --- | --- | --- | --- |
| **Prebuilt binary** | vendor tarballs, AppImages, proprietary tools | fetch + hash + file placement | anyone, in minutes |
| **Language ecosystem** | crates, npm, PyPI, Go modules, Hackage | machine-generated from a lockfile | a generator, not a human |
| **Conventional source** | autotools / cmake / meson C and C++ | template plus a handful of fields | anyone, in minutes |
| **Complex source** | browsers, kernels, desktop stacks | real patches, real judgement | maintainers |

Only the fourth row needs people. It is also the row that is genuinely small —
a few hundred packages, not a hundred thousand. Keeping that set curated and
well-maintained is achievable by a small project. Everything above it should be
generated, templated, or unnecessary.

The design goal follows: **push work down the table.** Every mechanism that lets
a package be satisfied by a cheaper row is worth more than any number of
hand-written definitions.

---

## 3. Definitions are decentralized by construction

There is no privileged repository. A definition source is declared like anything
else:

```toml
[[sources]]
name = "core"
git  = "https://github.com/NexisOS/definitions"
rev  = "9f2c1ab..."
keys = ["nexis-core-2026"]

[[sources]]
name = "kyle"
path = "~/src/my-definitions"
```

**Order is the resolution rule.** A dependency resolves to the first source
providing a definition of that name whose version satisfies the bound. See
[adr-0005-spec-sources-and-resolution.md](adr-0005-spec-sources-and-resolution.md);
a dependency may also carry its own inline source when nothing declares one.

Consequences:

- Using a package **never requires a pull request.** Write a definition, point
  at it, rebuild. If it is good, publish it; if not, it still works for you.
- Organizations run private sources for internal software without forking
  anything.
- A definition that upstream rejects is not a dead end.
- Trust is explicit and per-source. `keys` names the signers a source is
  accepted from. There is no ambient trust in "the repository."

The failure mode this avoids is the nixpkgs monorepo bottleneck, where the path
from "I need this" to "I have this" runs through review latency. That bottleneck
is exactly what generates the "when will you fix this package" feeling, and it
is structural rather than cultural — a single tree with a single review queue
produces it regardless of how good the maintainers are.

---

## 4. Shell in build recipes, and what tiers actually measure

An earlier draft resolved the shell question with a tier meaning "shell
allowed." That framing did not survive review, and
[adr-0002-build-recipes-and-tiers.md](adr-0002-build-recipes-and-tiers.md)
replaces it. The short version:

**Banning shell buys almost no security.** `configure` is a 40,000-line shell
script that every autotools build runs. `make` runs arbitrary code. `cmake`
evaluates a Turing-complete language. `cargo build` executes `build.rs`. An
argv-only phase list invoking `./configure && make` is already running a large
shell program; it merely does not contain the text. What contains that code is
the sandbox — no network after fetch, no host `/usr`, declared inputs only —
and the sandbox is identical either way.

**So shell is allowed, as a hashed source.** Not as a phase mode:

```toml
[[source]]
role = "build-script"
path = "build.sh"
hash = "sha256-..."
```

It enters `source-id` exactly like a patch. Pinned, diffable, signed with the
definition source, and impossible to edit without invalidating cached artifacts.
This unlocks `PKGBUILD` import without weakening anything.

**Tiers now measure provenance**, which is the thing a user actually wants to
know:

| Tier | Meaning |
| --- | --- |
| `audited` | Reviewed by a person, reproducibility verified by rebuilding |
| `standard` | Hashes pinned, builds reproducibly in CI, not individually reviewed |
| `generated` | Machine-produced from a lockfile or foreign packaging; unreviewed |
| `binary` | Prebuilt upstream artifact, no build performed |

`generated` is a statement about who read it, not about how safe it is. Import
tooling emits `generated` and never claims higher. `nexis check <definition>`
rebuilds twice and compares artifact ids, so `audited` and `standard` are
falsifiable rather than self-asserted, and a profile can require a floor:

```toml
[security]
minimum-definition-tier = "standard"
```

## 5. What has to be built

In rough order of coverage-per-effort:

**`nexis new`** — generate a definition from a URL. Fetch, hash, detect the
build system from the tree (`configure.ac`, `CMakeLists.txt`, `meson.build`,
`Cargo.toml`, `go.mod`), infer outputs from what `make install` lands, emit a
definition ready to edit. The gap between "I want this" and "I have a working
definition" should be one command and a few minutes.

**Language-ecosystem importers** — `nexis import cargo|npm|pypi|go`, reading a
lockfile and emitting definitions with hashes already pinned. Lockfiles exist
precisely because these ecosystems already solved dependency pinning; there is
no reason to redo it by hand. This is where the raw count lives.

**Foreign packaging importers** — `nexis import pkgbuild` first, because
`PKGBUILD` is the most conventional of the shell formats: `pkgname`, `pkgver`,
`source`, `sha256sums`, `build()`, `package()` map onto the definition format
almost field for field. Output is tier `generated`.

**Binary passthrough helpers** — `nexis new --binary` for vendor tarballs, and
first-class handling of AppImage and Flatpak, since both already work on FHS and
should be declarable rather than special.

**`nexis import deb|rpm`** — and this is the largest single coverage lever
available. A `.deb` or `.rpm` payload is already laid out for the FHS this
system runs: `/usr/bin`, `/usr/lib`, `/usr/share`, with conventional sonames.
Converting one to a `binary`-tier definition is close to mechanical — read the
control metadata for name, version and dependencies, hash the payload, map the
paths to outputs. It puts Debian's and Fedora's archives within reach as a
fallback for anything not yet packaged natively.

The caveats are real and worth stating: dependency names must be mapped to
NexisOS names, maintainer scripts are discarded rather than run (a package that
needs one to become usable is not reproducible anyway), and the payload's
libraries must be ABI-compatible with what the generation provides. It is a
coverage floor, not a substitute for native definitions — but a floor of tens
of thousands of packages changes what a new distribution can credibly offer on
day one.

**A definition test harness** — `nexis check <definition>` building in the
sandbox and reporting what tier it actually qualifies for, so hardening is
measurable rather than a matter of opinion.

---

## 6. What this does not fix

- **Patched software still needs maintainers.** Firefox, the kernel, Mesa and
  the desktop stack carry distribution patches, and no generator writes those.
  This set is irreducible and it is where a small project's attention should go.
- **Language importers produce large closures.** A generated npm tree can be
  thousands of definitions. Deduplication in the store makes it cheap on disk,
  but `nexis why` needs to stay fast at that scale.
- **Imported definitions inherit upstream's assumptions.** A `PKGBUILD` that
  reaches for a host tool NexisOS doesn't provide fails at build time, not at
  import time. Import is a starting point, not a guarantee.
