# Authoring a package

The deal NexisOS offers: **you write what your software is; the system manager
does the hard parts.** Writing a definition should be the easy half. Verifying
it should be a command rather than a discipline you have to remember.

There is no repository to be admitted to, no maintainer to convince, and no
review queue. If your definition works for you, it works.

## The whole thing

```toml
schema = 1
tier   = "standard"

name    = "ripgrep"
version = "14.1.1"

outputs = ["out"]

[[source]]
role = "primary"
urls = ["https://github.com/BurntSushi/ripgrep/archive/14.1.1.tar.gz"]
hash = "sha256-"

[build]
builder = "cargo"

[[dependencies]]
name     = "pcre2"
requires = ">=10.40"

[output.out]
paths = ["/usr/bin/**"]
```

The hash is left empty on purpose. `nexis new` fills it in; `nexis check`
refuses to call the definition `standard` until it is pinned.

Then:

```
nexis check ./ripgrep.toml
```

and use it, from anywhere:

```toml
[dependencies.ripgrep]
path = "./ripgrep.toml"
```

That is the loop. No publishing step stands between writing a definition and
running the software.

## What `nexis check` does for you

This is where the system manager earns its keep. Every check below is
something a packager would otherwise have to know to worry about.

### Structural

| Check | Catches |
| --- | --- |
| Schema validation | Unknown keys, wrong types, missing fields |
| Top-level key binding | `outputs` written under `[features]` and silently becoming `features.outputs` |
| Hash format | A bare hex digest with no algorithm prefix |
| Hash pinning | An unpinned source that cannot be built reproducibly |
| Placeholder resolution | `@outdir@` reaching `make install` as a literal directory name |
| Output coverage | A file the build installed that no output pattern claims |
| Slot qualification | A slotted package whose paths would collide with its own other slots |

### Build-time observation

The sandbox already exists, so watching what a build *tries* to do is close to
free — and it is the part a packager has no other way to see.

| Check | Catches |
| --- | --- |
| Network attempts | A build that would silently download a dependency |
| Undeclared reads | A configure script finding a host tool that is not in the closure |
| Writes outside the build root | A build stamping on the store or `/etc` |
| Wall-clock reads | A build embedding the build date, so it will never reproduce |
| Non-determinism | Building twice and comparing artifact ids |

The last one is the important one, and it is why `audited` and `standard` are
falsifiable claims rather than self-assertions: `nexis check --reproduce`
builds twice in fresh sandboxes and diffs the manifests, reporting the exact
paths that differ.

### Output scanning

The build has finished, so the artifact can be examined directly.

| Check | Catches |
| --- | --- |
| ELF `DT_NEEDED` closure | A binary linking a library that is not a declared dependency — "works on my machine" |
| `RPATH` / `RUNPATH` | A path pointing outside the generation, or at a build directory |
| Interpreter | A shebang or ELF interpreter that will not exist at runtime |
| Setuid and setgid bits | Privilege escalation shipped by accident |
| World-writable files | The same, quieter |
| Symlink escapes | A link pointing out of the artifact |
| Embedded build paths | `/build/src` baked into a binary, which breaks reproducibility |
| pkg-config sanity | `.pc` files referencing paths the package does not install |
| Interface identity | Computed here — the exported symbol set that dependents key on |

The `DT_NEEDED` check deserves its own note. It is the single most common
packaging bug in every distribution: the build machine had `libfoo` installed,
the binary linked it, the dependency was never declared, and the package fails
for everyone whose closure lacks it. The sandbox makes this *detectable* rather
than merely likely, because the only libraries present were declared ones — so
any `DT_NEEDED` outside the closure is unambiguously a bug in the definition,
and the checker can say which line to add.

### Safety

| Check | Catches |
| --- | --- |
| Known-vulnerable versions | The declared version matching a CVE feed entry |
| Source provenance | A source URL whose host is not in the definition's declared origins |
| Unsigned sources | A source from a signed spec source whose payload is not itself pinned |
| Tier honesty | A definition claiming `audited` that has never been reproduced |
| Confinement | An unconfined service — reported, not blocked |
| License | A declared license that does not match what the source tree contains |

None of these block a build by default. They produce a report, and a security
profile decides which are fatal:

```toml
[security]
minimum-definition-tier = "standard"
fail-on = ["undeclared-library", "setuid", "network-during-build"]
```

## Why this is cheap to offer

Every check above is a consequence of an architectural decision made for
another reason:

- The **sandbox** was built so `generated`-tier definitions are reproducible
  despite containing shell. It happens to be a perfect instrument for observing
  what a build touches.
- **Content addressing** was chosen for dedup. It makes "build it twice and
  compare" a digest comparison.
- **Interface identity** was chosen so ABI-preserving rebuilds are cheap. It
  requires scanning exported symbols anyway, so the `DT_NEEDED` closure check
  is the same pass.
- **FHS output** means artifacts can be scanned with ordinary tools, rather
  than needing store-path-aware equivalents.

So the answer to "who checks the packages if there is no maintainer" is not
"nobody" and it is not "you, carefully". It is: the checks a distribution's
review process performs by eye are mechanical, and this design was already
paying for the machinery.

## What is still on you

Being straight about the limits:

- **Correctness of the build itself.** If your `configure` flags produce a
  broken program, nothing here notices. Tests are your `check` phase.
- **Whether the software is trustworthy.** Provenance checks tell you a source
  is pinned, not that it is benign. `nexis check` verifies you got what the
  definition said; it cannot verify that what the definition said is good.
- **Dependency naming.** Nothing prevents two sources from disagreeing about
  what `openssl` means. Ordered sources make the choice deterministic, not
  correct.
- **Upstream that fights reproducibility.** Some builds embed timestamps in
  ways no sandbox can normalise. `nexis check --reproduce` will tell you; fixing
  it means patching upstream.

## Publishing, if you want to

Optional and last:

1. Put the definition in a git repository.
2. Tag a revision.
3. Someone adds it to their `[[sources]]` with that rev and your key.

There is no index to register with. A source is a git rev, and a git rev is a
content hash.
