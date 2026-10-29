# The `nexis` command

NexisOS has **no imperative package installation**. There is no `nexis install
firefox` that puts firefox on the system. The only input to system state is the
TOML under `/etc/nexis/`.

This is a deliberate rejection of `nix-env`. Nix has the escape hatch, and its
existence means a NixOS system can be in a state its configuration does not
describe — which quietly destroys the property the whole design exists to
provide. A user who installs one package imperatively now has a machine that
does not rebuild to itself, and they usually find out months later.

## The ergonomic problem this creates, and the answer to it

Removing the escape hatch is correct and it is not free. Someone will type:

```
$ nexis install firefox
```

What happens next decides whether people can live with this system. Three
possible answers:

1. **Error out.** "Unknown command." The user googles, finds a forum post,
   edits TOML by hand, gets the table nesting wrong, and concludes the
   distribution is hostile. This is the failure mode to avoid.
2. **Install it.** Now the invariant is gone and there was no point to any of
   this.
3. **Edit the declaration, then rebuild.**

Answer 3 is what NexisOS does:

```
$ nexis install firefox
`install` is not a NexisOS command — packages are declared, not installed.

  firefox would go in /etc/nexis/system.toml under [system] packages,
  or under [users.kyle] packages for just your account.

  nexis add firefox              add to the system package list
  nexis add --user firefox       add to your user package list
  nexis add --edit firefox       open the file at the right line instead
```

`nexis add` **writes to the TOML file and then rebuilds**. It does not touch the
running system directly.

This distinction is the whole point and it is worth being precise about, because
"add" sounds like the thing we just said we would not do. The invariant is not
*"the user must type TOML by hand."* The invariant is:

> System state is a pure function of the declaration. Nothing exists on the
> system that is not in `/etc/nexis/`.

A command that edits the declaration and then rebuilds preserves that exactly.
The configuration remains the single source of truth, the change is in git, the
rebuild is atomic, and the generation is a rollback target. What is forbidden is
a command that mutates the *system* without going through the declaration — and
`nexis add` structurally cannot, because it has no code path to the store or the
generation builder. It writes a file and shells out to `nexis rebuild`.

Getting this right matters more than it looks. The reason `nix-env` is used is
not that people want unreproducible systems; it is that editing configuration by
hand for a one-line change is friction, and friction routes around itself. Give
the convenient path the correct semantics and there is nothing to route around.

`nexis add` refuses to guess when the config is ambiguous — several `[system]`
package lists across modules, or a list built from a profile — and falls back to
`--edit`, opening the file at the line rather than mangling it.

## Command surface

### Building and activating

```
nexis rebuild switch          build a generation and activate it now
nexis rebuild boot            build it; activate on next boot
nexis rebuild test            activate without adding a boot entry
nexis rebuild dry-run         resolve and report; build nothing
nexis rebuild build           build the generation; do not activate
```

`dry-run` reports what would change: packages added, removed, rebuilt, and
services restarted. It is the answer to "what will this do to my machine", and
it should be good enough that people use it habitually.

### Generations

```
nexis generations             list, with dates, sizes and current marker
nexis rollback                activate the previous generation
nexis rollback --to 41        activate a specific generation
nexis diff 41 42              what changed between two generations
nexis gc                      collect store objects no generation references
nexis gc --keep 10            drop all but the ten most recent generations
```

`nexis diff` matters more here than under an imperative system: since a
generation is a pure function of a configuration, the diff between two
generations *is* the diff between two configurations, plus whatever upstream
sources moved. Showing both halves is the interesting part.

### Introspection

```
nexis search <term>           search available package definitions
nexis show <package>          definition, resolved features, outputs, closure
nexis why <package>           why is this in my system? show the dependency path
nexis owns <path>             which package output provides this file
nexis explain <option>        where an option's value came from, layer by layer
nexis outputs <package>       which outputs are active and why
```

`nexis why` and `nexis explain` are the two that make a declarative system
livable. When `/usr/lib/libfoo.so.2` appears and nobody knows why, `nexis why`
answers it from the resolved graph. When a config option has a value the user
did not write, `nexis explain` shows the profile, module and host layers that
produced it, in precedence order.

### Ephemeral environments

```
nexis shell -p rustc cargo    a shell with these packages, changing nothing
nexis shell                   use ./dev.toml
nexis run <package> -- args    run one program without entering a shell
```

These do not modify the system generation and leave nothing behind. They are the
legitimate answer to "I need this tool for ten minutes", which is the other
reason people reach for imperative installs.

### Verification

```
nexis check                   does the running system match its declaration?
nexis check --store           verify store object integrity against their hashes
nexis check --config          validate the configuration without building
```

`nexis check` is what makes the no-escape-hatch guarantee testable rather than
assumed. Because a generation is sealed, verifying it is a digest comparison,
not a filesystem walk.

## What is deliberately absent

| Not provided | Why |
| --- | --- |
| `nexis install` / `remove` | State comes from the declaration. `nexis add` / `remove` edit it instead. |
| `nexis upgrade <package>` | Versions are declared. Upgrading one package means changing its definition or its channel pin. |
| A package database to query "what is installed" | The declaration is that database. `nexis show` reads it. |
| Post-install scripts | A package that needs to run arbitrary code to become usable is not reproducible. Use tmpfiles-style declarations and service definitions. |
| `--force` on activation | If validation fails, the generation is wrong. Fixing the config is the path forward. |

## Exit codes

Scripting against a declarative system is normal — CI validating a config, a
fleet tool checking drift — so the exit codes are part of the interface:

```
0   success
1   general failure
2   configuration invalid (parse or validation error)
3   dependency resolution failed
4   build failed
5   generation validation failed; nothing was activated
6   drift detected (nexis check only)
```
