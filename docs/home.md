# Home environments and dotfiles

Dotfile and per-user package management is part of the system, not a companion
project. There is no separate tool, no separate generation, no separate
evaluation, and no second source of truth.

## Scope: file placement, not a program DSL

The single most important thing this design does **not** do is grow a module per
program.

home-manager ships on the order of a thousand `programs.*` modules —
`programs.git.userName`, `programs.tmux.keyMode`, `programs.firefox.profiles.*`.
Each is a hand-written translation from Nix option to config file format, and
each has to track its upstream program forever. That is an unbounded maintenance
surface, it is permanently behind upstream, and the moment a program grows an
option nobody has wrapped yet the user is back to writing the config file by
hand anyway — now fighting the module that half-manages it.

NexisOS deliberately stops at `home.file`. The scope is:

- **place declared files at declared paths**, with declared ownership semantics;
- a small, fixed set of options that are genuinely system-level and not
  program-level: shell, per-user packages, environment variables, and XDG base
  directories.

That list is intended to stay roughly that length. The test for adding an option
is whether NexisOS itself needs to know the value — the shell matters because
`nexis-init` sets up the session; a tmux keybinding does not.

Your `config.fish` is a file. Your `init.lua` is a file. NexisOS puts them where
you say, seals them into the generation, and rolls them back with everything
else. It does not attempt to have opinions about their contents, and it will
never need updating because tmux added a setting.

This is a smaller promise than home-manager makes. It is also one that a small
project can keep indefinitely, and it does not decay.

## What is wrong with the home-manager model

home-manager works, and the criticism here is architectural rather than about
its quality. The problems are structural consequences of being a bolt-on:

- **Two sources of truth.** System config and home config are separate
  evaluations. Which one owns `programs.git` depends on which mode you are in.
- **Two generation counters.** Home generations and system generations advance
  independently, so "roll back to how things were on Tuesday" is two operations
  that can disagree.
- **Two activation paths.** The home activation script is a separate mechanism
  with separate failure modes, run at a different time from system activation.
- **Standalone versus module mode** is a genuine fork in the design that users
  must understand before they can start.
- **Symlink farms into the store.** `~/.config/foo` becomes a symlink to
  `/nix/store/<hash>-foo`. Applications that rewrite their config file — most of
  them — fail on a read-only symlink target, and every tutorial has a workaround.
- **An ever-growing program DSL**, as above.

NexisOS can avoid all five, because it already has the mechanism.

## The core idea

A generation already contains an immutable filesystem tree delivered as a
composefs image over the content store. A user's declared home files are exactly
that: an immutable tree of files, derived from configuration, that should roll
back with the system.

So they go **in the generation**, as a per-user subtree, delivered by the same
builder through the same mechanism:

```
/system/generations/N/
    system.cfs              /usr and friends
    home/kyle.cfs           kyle's declared home tree
    home/bob.cfs            bob's declared home tree
    manifest
    signature
```

Consequences, all of which come for free rather than being designed in:

- One generation counter. `nexis rollback` restores system and home together,
  because they are the same object.
- One activation. There is no home activation script.
- One evaluation. `[users.kyle]` is a table in the same configuration that
  declares the system.
- One integrity seal. The user's declared dotfiles are covered by the same
  digest as `/usr`.
- No symlinks into the store, because nothing in NexisOS exposes store paths.

## The read-only problem, and the three ownership modes

Putting config files in an immutable tree runs straight into the reason
home-manager's symlinks hurt: **applications write to their own config files.**
Firefox rewrites `prefs.js`. Most editors persist state next to their config.
A read-only `~/.config` breaks them.

So ownership is declared per path, with three modes:

```toml
[users.kyle.home]

# managed: NexisOS owns it. Read-only. Reverts on rebuild if anything
# changed it. Use for files you want to be authoritative.
managed = [
  { path = ".config/fish/config.fish", source = "dotfiles/fish/config.fish" },
  { path = ".config/starship.toml",    source = "dotfiles/starship.toml" },
]

# seeded: written once if absent, then owned by the user forever. NexisOS
# never touches it again, and a rebuild will not revert local edits.
seeded = [
  { path = ".gitconfig", source = "dotfiles/gitconfig" },
]

# merged: NexisOS supplies a base layer; the application's writes land in a
# user-owned overlay above it. Reads see the merge.
merged = [
  { path = ".config/nvim", source = "dotfiles/nvim" },
]
```

**`managed`** is the home-manager default and the right one for files you
genuinely want reproducible. It is read-only in the mount, so an application
cannot corrupt it, and `nexis check` reports drift.

**`seeded`** is the mode home-manager lacks and the one that makes this usable
for people who manage dotfiles by hand. It says: *give me this starting point,
then get out of the way.* No symlink, no read-only file, no reversion on
rebuild — the declaration is a seed, not an owner. Anyone who keeps most
dotfiles outside the system and wants only a couple of them declared can express
that directly instead of fighting the tool.

**`merged`** covers the awkward middle: a directory where you want to supply
configuration but the application also writes into it — plugin state, caches,
lockfiles. The declared tree is a read-only lower layer and the user's writes go
to an upper layer, using the same overlayfs composition the system generation
already uses. Reads see both.

`nexis owns ~/.config/fish/config.fish` reports which mode a path is under and
which generation supplied it.

## Per-user packages under a shared `/usr`

This is the hard architectural question, and it does not exist under Nix.

Nix gives each user a profile that is their own symlink farm, so two users can
have different firefox versions trivially. NexisOS merges everything into one
real `/usr`. Two users wanting different versions of the same package is a
direct collision.

`[users.kyle] packages = ["firefox"]` therefore cannot mean "install firefox
into `/usr` for kyle." It means:

**A user's package set is an additional composefs layer, composed over the
system `/usr` inside that user's session mount namespace.**

```
        system.cfs                    shared, immutable
             +
     home/kyle-packages.cfs           kyle's extra packages
             ↓
   per-session mount namespace
             ↓
   kyle sees /usr/bin/firefox; bob does not
```

The store is shared, so if both users declare the same firefox at the same
version it is stored and cached once. If they declare different versions, both
exist in the store and each user's namespace composes the one they asked for —
which is the Nix property, recovered without exposing store paths.

Two rules follow, and they need to be in the package format's conflict policy:

1. **Conflict checking is per-user-view, not global.** A collision between two
   packages in kyle's set is an error. A collision between kyle's set and bob's
   is not, because they are never composed together.
2. **A user package shadowing a system package must be declared.** Silently
   overriding `/usr/bin/python` for one user is exactly the kind of invisible
   divergence this system exists to prevent. `shadows = ["python"]` makes it
   explicit and `nexis explain` reports it.

`nexis-init` establishes the namespace at session start. This is the same
capability needed for service sandboxing, so it is not new machinery.

## Configuration shape

Home configuration is not a separate file format or a separate module system. It
is the `[users.*]` table that already exists:

```toml
[users.kyle]
uid    = 1000
groups = ["wheel", "audio", "video"]
shell  = "fish"

packages = ["firefox", "mpv"]
shadows  = []

[users.kyle.home]
managed = [ ... ]
seeded  = [ ... ]
merged  = [ ... ]

[users.kyle.environment]
EDITOR = "nvim"
```

The same module and profile composition applies. A `developer` profile can
contribute packages and dotfiles to any user that includes it, with the same
priority and merge semantics as any other option — and `nexis explain
users.kyle.packages` shows which layer contributed what.

## What this does not solve

Honesty about the boundary:

- **Existing home directories.** Installing NexisOS over an existing `/home`
  means files already at declared `managed` paths. Activation must refuse and
  report rather than overwrite; `nexis rebuild --adopt` can move them aside.
- **Per-user services.** Not covered here. `nexis-init` will need a user-session
  supervisor, and the design should follow the system service model rather than
  inventing a second one.
- **Secrets.** Declared dotfiles are in the generation and in git. Nothing here
  makes it safe to put an API key in `managed`. Secrets need their own design.
