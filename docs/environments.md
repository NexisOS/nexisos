# Development environments and language package managers

Every Linux system accumulates a graveyard:

```
~/.local/lib/python3.11/site-packages     built against a Python that is gone
~/.local/bin                              shadowing /usr/bin, invisibly
~/.cargo/bin                              installed in 2023, from what version?
~/.npm-global/lib/node_modules            8GB
~/go/bin                                  a binary whose source no longer exists
~/.gem/ruby/3.1.0                         same
```

None of it is declared. None of it is rolled back. None of it is garbage
collected. It survives system upgrades and breaks silently — a `pip --user`
package compiled against Python 3.11 does not announce itself when Python 3.12
arrives, it just fails at import six weeks later. Uninstalling is unreliable.
Nobody can answer what is in these directories or why.

This is the same problem as imperative package installation, one layer down, and
it deserves the same answer.

## Three use cases that get conflated

The reason language package managers behave badly is that they cannot tell these
apart, so they default to writing into the user's home:

1. **Application delivery.** "I want `ripgrep`, which happens to be written in
   Rust." The user does not care about cargo. This is a **system package**,
   generated from the lockfile. `cargo install` should never be how a user
   obtains a tool.
2. **Project dependencies.** "This project needs numpy 1.26." This belongs to
   the **project directory** — not the system, not the user. This is the
   `nix-shell` case.
3. **Ad-hoc exploration.** "Let me try this library for ten minutes." This
   should **evaporate**.

Case 1 is a definition. Case 2 is `dev.toml`. Case 3 is where the graveyard
comes from, and the fix is not to forbid it — it is to make it *enumerable and
collectable* rather than invisible and immortal.

## Global language installs are prevented, not discouraged

Documentation asking people not to run `pip install --user` does not work. The
enforcement is structural, using mechanisms that already exist for other reasons.

**The graveyard directories are not writable.** Per-user session mount
namespaces already exist for per-user package layers (see
[home.md](home.md)). `~/.local/lib`, `~/.cargo`, `~/.npm-global`, `~/go` and
`~/.gem` are `managed` paths: read-only outside a project environment.

**They are not on `PATH`.** `~/.local/bin` in particular is the single most
common source of "why is this old version running" — a binary silently shadowing
`/usr/bin` with no record of where it came from. It is not on the default
`PATH`.

**The tools are configured to agree.** Environment defaults are set so the
failure is early and legible rather than a permission error:

```
PIP_REQUIRE_VIRTUALENV=true
CARGO_INSTALL_ROOT=<project env or unset>
GOBIN=<project env>
GEM_HOME=<project env>
npm_config_prefix=<project env>
```

A `pip install --user` outside an environment fails immediately with a message
pointing at `dev.toml` and `nexis shell`. That is a far better outcome than
succeeding and being forgotten.

## `nexis shell`

A project declares its environment in `dev.toml`:

```toml
schema = 1
name   = "myproject"

packages = ["rustc@1.83", "cargo", "pkg-config", "openssl:dev"]

[env]
RUST_BACKTRACE = "1"

[language.python]
version      = "3.12"
lockfile     = "requirements.lock"

[language.node]
version  = "22"
lockfile = "package-lock.json"
```

```
nexis shell              enter the environment for ./dev.toml
nexis shell -p rustc     ad-hoc, no file needed
nexis run rg -- pattern  run one program in a transient environment
```

### Lockfiles are the bridge

`[language.*]` does not require hand-written definitions for four hundred npm
packages. A lockfile already contains exactly what is needed — resolved
versions and integrity hashes — because these ecosystems solved pinning
themselves. NexisOS reads it, fetches each artifact, verifies the hash it was
given, and stores it content-addressed.

The result is that a project's language dependencies are **as reproducible as its
system dependencies, from a file the project already has**. No `poetry2nix`, no
`node2nix`, no generated-and-committed intermediate. Regenerating on lockfile
change is automatic because the lockfile hash is part of the environment
identity.

Where a lockfile does not exist, `nexis shell` says so rather than resolving
versions itself. Resolution is the language ecosystem's job and doing it twice
produces disagreement.

### Environments are composefs layers

An environment is identified by:

```
env-id = H(dev.toml, each lockfile, resolved closure artifact ids)
```

and composed the same way everything else is: a metadata image over the content
store, mounted into a namespace.

This is why entry is fast. `nix-shell` re-evaluates nixpkgs on every entry, which
is why people reach for `direnv` caching and lorri and still wait. `nexis shell`
hashes a few files, looks up the composed layer, and mounts it — the same
operation as activating a generation, which is already measured in seconds for
an entire `/usr`. A cached environment is a mount.

It also means environments are **shared**. Two projects with identical
dependencies compose the same layer and consume no additional space. A hundred
Rust projects on one machine share one rustc.

### Why this does not multiply memory

Environments, containers and the host system are all composefs compositions
over the **same** object store. A file used by all three is literally the same
inode, so the kernel caches its pages once.

That is the difference from every layer- or copy-based scheme. OCI images have
no cross-image file dedup; a copy-based environment caches each copy
separately. Here a hundred Rust projects share one `rustc` inode and one page
cache entry, and a scratch overlay holds only the files that differ.

### Scratch: making case 3 survivable

Strict declarative environments are correct and they are hostile to exploration.
Adding a line to `dev.toml` to try a library for ten minutes is friction, and
friction routes around itself — straight back to `pip install --user`.

```
nexis shell --scratch
```

gives the environment a **writable overlay** for the language tools' install
roots. `pip install` works. `cargo install` works. Nothing is declared.

The difference from the graveyard is that the scratch overlay is:

- **attributed** to a project directory and an environment id;
- **enumerable** — `nexis env list` shows every scratch overlay with its
  project, size, and last use;
- **collectable** — `nexis gc` removes overlays untouched past a threshold;
- **never on `PATH` outside its environment**, so it cannot shadow anything;
- **visibly non-reproducible** — the shell prompt marks it, and `nexis env
  freeze` writes the installed set back into `dev.toml` as pinned entries.

```
$ nexis env list
PROJECT              ENV                SCRATCH   SIZE    LAST USED
~/src/myproject      a3f9c1…            yes       412 MB  2 hours ago
~/src/oldthing       7b2e04…            yes       1.8 GB  8 months ago
~/work/api           e91d55…            no        —       yesterday
```

That second row is the graveyard, except now it has a name, a size, an owner and
an expiry. `nexis gc` reclaims it.

`nexis env freeze` is the escalation path: explore in scratch, then promote what
you kept into the declaration. This is the loop that makes strictness bearable —
the same reasoning as `nexis add` versus hand-editing TOML in
[cli.md](cli.md).

## Global versus local, resolved

`PATH` inside a session, in order:

```
<project env>/bin       only inside nexis shell; scratch overlay included
~/.nexis/user/bin       the user's declared package layer (home.md)
/usr/bin  /usr/sbin     the system generation
```

Every entry is declared somewhere and owned by something. There is no fourth
location, and `~/.local/bin` is deliberately absent.

`nexis owns $(which python)` answers which layer a binary came from, and `nexis
why python` answers what asked for it. The question "where did this come from"
always has an answer, which is the property the graveyard destroys.

## Application delivery is not a language concern

Restating, because it is the most common mistake and the most costly:

`cargo install ripgrep` is the wrong way to get ripgrep, on any distribution. It
builds an unpinned version from an unrecorded toolchain into an undeclared
location with no uninstall path.

On NexisOS, ripgrep is a definition — generated from its `Cargo.lock` by `nexis
import cargo`, pinned, sandboxed, shared through the store, and rolled back with
everything else. That it is written in Rust is an implementation detail of the
definition, invisible to whoever installs it.

The same holds for every `pipx`, `npm -g`, `gem install --user` and `go install`
of an application. Language package managers are for project dependencies. They
are not a distribution mechanism, and treating them as one is how the graveyard
starts.
