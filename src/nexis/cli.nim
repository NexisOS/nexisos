## The `nexis` command surface: parsing, dispatch, and the refusal machinery.
##
## Two things here are load-bearing rather than plumbing.
##
## First, **`install` is not an unknown command.** It is a known command that
## refuses, and explains where the package would go and which command edits the
## declaration instead. Erroring with "unknown command" is the failure mode
## docs/cli.md exists to avoid: the user googles, finds a forum post, edits TOML
## by hand, gets the table nesting wrong, and concludes the distribution is
## hostile. Friction routes around itself, so the convenient path has to be the
## correct one.
##
## Second, **exit codes are part of the interface.** CI validating a config and
## a fleet tool checking drift both script against this, so the codes come from
## `lib/errors` rather than being chosen at each call site.

import std/[editdistance, strutils, tables]

const
  Version* = "0.1.0"

type
  CommandKind* = enum
    ckNone
    ckRebuild, ckGenerations, ckRollback, ckDiff, ckGc
    ckSearch, ckShow, ckWhy, ckOwns, ckExplain, ckOutputs
    ckShell, ckRun
    ckCheck
    ckAdd, ckRemove
    ckRefused          ## a real command, deliberately not provided
    ckHelp, ckVersion

  Invocation* = object
    kind*: CommandKind
    sub*: string                 ## `switch` in `rebuild switch`
    args*: seq[string]
    flags*: Table[string, string]
    refusedName*: string         ## what they typed, when kind is ckRefused

  Spec = object
    kind: CommandKind
    name: string
    subs: seq[string]
    summary: string

const Commands = [
  Spec(kind: ckRebuild, name: "rebuild",
       subs: @["switch", "boot", "test", "dry-run", "build"],
       summary: "build a generation, and what to do with it"),
  Spec(kind: ckGenerations, name: "generations", subs: @[],
       summary: "list generations, with dates, sizes and the current marker"),
  Spec(kind: ckRollback, name: "rollback", subs: @[],
       summary: "activate the previous generation, or --to N"),
  Spec(kind: ckDiff, name: "diff", subs: @[],
       summary: "what changed between two generations"),
  Spec(kind: ckGc, name: "gc", subs: @[],
       summary: "collect store objects no composition references"),
  Spec(kind: ckSearch, name: "search", subs: @[],
       summary: "search available package definitions"),
  Spec(kind: ckShow, name: "show", subs: @[],
       summary: "definition, resolved features, outputs, closure"),
  Spec(kind: ckWhy, name: "why", subs: @[],
       summary: "why is this in my system? show the dependency path"),
  Spec(kind: ckOwns, name: "owns", subs: @[],
       summary: "which package output provides this file"),
  Spec(kind: ckExplain, name: "explain", subs: @[],
       summary: "where an option's value came from, layer by layer"),
  Spec(kind: ckOutputs, name: "outputs", subs: @[],
       summary: "which outputs are active, and why"),
  Spec(kind: ckShell, name: "shell", subs: @[],
       summary: "an ephemeral environment; changes nothing"),
  Spec(kind: ckRun, name: "run", subs: @[],
       summary: "run one program without entering a shell"),
  Spec(kind: ckCheck, name: "check", subs: @[],
       summary: "does the running system match its declaration?"),
  Spec(kind: ckAdd, name: "add", subs: @[],
       summary: "add a package to the declaration, then rebuild"),
  Spec(kind: ckRemove, name: "remove", subs: @[],
       summary: "remove a package from the declaration, then rebuild"),
]

## Commands a user will reasonably type because another distribution has them.
## Each maps to what NexisOS does instead. The value is the replacement.
## Flags that consume the next argument. Kept next to the parser so adding a
## flag and forgetting to register it is a one-line diff away from being
## noticed, rather than a silent misparse discovered at runtime.
const ValueFlags* = ["config", "store", "generations", "boot", "to", "keep",
                     "root", "target", "label", "output"]

const Refusals = {
  "install":   "add",
  "uninstall": "remove",
  "upgrade":   "rebuild switch",
  "update":    "rebuild switch",
  "sync":      "rebuild switch",
  "-S":        "add",
  "-Syu":      "rebuild switch",
  "env":       "shell",
}.toTable

func known*(name: string): bool =
  for c in Commands:
    if c.name == name: return true
  false

func specFor(name: string): Spec =
  for c in Commands:
    if c.name == name: return c
  Spec(kind: ckNone)

func suggest*(typed: string): string =
  ## Nearest known command by edit distance, when it is close enough to be a
  ## typo rather than a different word entirely.
  ##
  ## The threshold scales with length, because a fixed distance of 2 lets any
  ## short nonsense match a short command — "gc" is two edits from most
  ## two-letter strings, and suggesting it for an unrelated word is worse than
  ## suggesting nothing.
  if typed.len < 3: return ""
  var best = ""
  var bestD = high(int)
  for c in Commands:
    let d = editDistance(typed, c.name)
    if d < bestD:
      bestD = d
      best = c.name
  let limit = min(2, max(1, typed.len div 3))
  if bestD <= limit: best else: ""

## `nexis` installs and manages a NexisOS system. It does not build
## installation media — that is `nimble distro`, the scripts under `tools/`, and
## Buildroot for release images (ADR 0008). Those are development tooling and
## are not shipped as part of the distribution.
##
## The boundary is worth enforcing rather than merely observing: a system
## manager that can also build media grows a second set of concepts — media
## layouts, bootloader packaging, host toolchains — that have nothing to do
## with managing a running machine, and every one of them becomes a surface
## users have to understand.
func usage*(): string =
  result = "nexis " & Version & " - declare a system, then realise it\n\n"
  result.add "  nexis <command> [options]\n\n"
  var width = 0
  for c in Commands: width = max(width, c.name.len)
  for c in Commands:
    result.add "  " & c.name.alignLeft(width + 2) & c.summary & "\n"
  result.add "\nThere is no `nexis install`. System state is a pure function\n"
  result.add "of the TOML under /etc/nexis; `nexis add` edits it and rebuilds.\n"
  result.add "\n  --help          this text        --version   version\n"
  result.add "  --config DIR    configuration root (default /etc/nexis)\n"
  result.add "  --dry-run       resolve and report; change nothing\n"

func refusal*(typed, replacement: string, pkg = ""): string =
  ## The message that decides whether someone can live with this system.
  let name = if pkg.len > 0: pkg else: "<package>"
  result = "`" & typed & "` is not a NexisOS command - packages are declared, "
  result.add "not installed.\n\n"
  if replacement.startsWith("rebuild"):
    result.add "  Versions come from your declaration, so there is nothing to\n"
    result.add "  upgrade in place. Change the pin, then:\n\n"
    result.add "    nexis " & replacement & "\n"
  else:
    result.add "  " & name & " would go in /etc/nexis/system.toml under\n"
    result.add "  [system] packages, or under [users.<you>] packages for just\n"
    result.add "  your account.\n\n"
    result.add "    nexis " & replacement & " " & name &
               "              edit the system list and rebuild\n"
    result.add "    nexis " & replacement & " --user " & name &
               "       edit your user list instead\n"
    result.add "    nexis " & replacement & " --edit " & name &
               "       open the file at the right line\n"
  result.add "\n  `add` writes to the TOML and then rebuilds. It has no code\n"
  result.add "  path to the store, so the declaration stays the only input\n"
  result.add "  to system state.\n"

func parse*(argv: openArray[string]): Invocation =
  ## Flags may appear anywhere. `--` stops flag parsing, so `nexis run prog --
  ## --flag` passes the flag to the program rather than to nexis.
  result.flags = initTable[string, string]()
  var positional: seq[string]
  var i = 0
  var literal = false

  while i < argv.len:
    let a = argv[i]
    if literal:
      positional.add a
    elif a == "--":
      literal = true
    elif a.startsWith("--"):
      let body = a[2 .. ^1]
      let eq = body.find('=')
      if eq >= 0:
        result.flags[body[0 ..< eq]] = body[eq + 1 .. ^1]
      # Flags that take a following value.
      #
      # A flag missing from this list silently becomes a boolean and eats
      # nothing, so `--store /path` sets store=true and leaves /path as a
      # positional — which then looks like an unknown subcommand. This has bitten
      # twice, so the rule is now mechanical rather than a list to remember:
      # a flag naming a path or a value takes one, and `ValueFlags` is that set.
      elif body in ValueFlags and i + 1 < argv.len:
        inc i
        result.flags[body] = argv[i]
      else:
        result.flags[body] = "true"
    elif a.startsWith("-") and a.len > 1 and not a[1].isDigit():
      # Short flags are only recognised where they are a package-manager
      # habit worth catching; everything else is positional so that a
      # negative number or a path is not eaten.
      if a in Refusals: positional.add a
      else: result.flags[a[1 .. ^1]] = "true"
    else:
      positional.add a
    inc i

  if "help" in result.flags or "h" in result.flags:
    return Invocation(kind: ckHelp, flags: result.flags)
  if "version" in result.flags or "V" in result.flags:
    return Invocation(kind: ckVersion, flags: result.flags)
  if positional.len == 0:
    return Invocation(kind: ckNone, flags: result.flags)

  let head = positional[0]
  if head in Refusals:
    result.kind = ckRefused
    result.refusedName = head
    result.args = positional[1 .. ^1]
    return

  if not known(head):
    result.kind = ckNone
    result.args = positional
    return

  let spec = specFor(head)
  result.kind = spec.kind
  var rest = positional[1 .. ^1]
  if spec.subs.len > 0 and rest.len > 0 and rest[0] in spec.subs:
    result.sub = rest[0]
    rest = rest[1 .. ^1]
  elif spec.subs.len > 0:
    result.sub = spec.subs[0]      ## `nexis rebuild` means `rebuild switch`
  result.args = rest

func replacementFor*(typed: string): string =
  Refusals.getOrDefault(typed, "add")

func configRoot*(inv: Invocation): string =
  inv.flags.getOrDefault("config", "/etc/nexis")

func isDryRun*(inv: Invocation): bool =
  "dry-run" in inv.flags or inv.sub == "dry-run"
