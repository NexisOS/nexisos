## `nexis` — entry point.
##
## Dispatch is deliberately thin. Each subcommand either does its work or
## reports honestly that it is not built yet; nothing here pretends. A
## declarative system's whole claim is that the machine is what the declaration
## says, and a CLI that prints plausible output for a subsystem that does not
## exist would undermine exactly that claim on the first day someone trusted it.
##
## Exit codes come from `lib/errors` so that CI validating a config and a fleet
## tool checking drift see the codes documented in docs/cli.md.

import std/[os, strutils, tables]
import ./cli
import ../lib/[errors, filesystem, paths]
import ./build/[realise, isolate, declare]
import ./config/system as sysconfig
import ./package/types
import ./store/store
import ./compose/activate

proc notYet(what, blockedOn: string): int =
  ## The honest stub. Names the phase it belongs to, so `nexis <anything>` is a
  ## readable status report on the project rather than a wall of the same
  ## sentence.
  stderr.writeLine what & " is not implemented yet."
  stderr.writeLine "  blocked on: " & blockedOn
  stderr.writeLine "  see TODO.md and docs/roadmap.md"
  1

proc cmdCheckConfig(inv: Invocation): int =
  ## The one command that can do real work today: does the configuration root
  ## exist, is it readable, and does it contain anything at all. Parsing and
  ## schema validation arrive with the resolver; this is the part that does not
  ## need it, and it is genuinely useful for scripting an install.
  let root = inv.configRoot()
  if not dirExists(root):
    stderr.writeLine "no configuration at " & root
    stderr.writeLine "  a NexisOS system is defined entirely by the TOML here"
    return exitCode(ekConfig)

  var files: seq[string]
  for e in walkTree(root):
    if e.kind == ekFile and e.path.endsWith(".toml"):
      files.add e.path

  if files.len == 0:
    stderr.writeLine root & " contains no .toml files"
    stderr.writeLine "  nothing would describe this machine"
    return exitCode(ekConfig)

  echo root
  for f in files: echo "  " & f
  echo ""
  echo $files.len & " file(s) found. Schema validation is not implemented yet;"
  echo "this checks presence and readability only."
  0

proc cmdRebuildDryRun(inv: Invocation): int =
  ## What a rebuild would do, computed by the same code the real run uses.
  ##
  ## The whole chain runs here: read the declaration, walk the closure,
  ## resolve every package, plan against the store. Only the builds themselves
  ## are skipped — which is what makes a dry run worth trusting.
  let root = inv.configRoot()
  let (ok, why) = canIsolate()

  echo "build isolation: ", (if ok: "available" else: "UNAVAILABLE")
  if not ok: echo "  ", why

  let storeRoot = inv.flags.getOrDefault("store", DefaultStoreRoot)
  echo "store:           ", storeRoot,
       (if dirExists(storeRoot): "" else: "  (not created yet)")
  echo "config:          ", root

  let sysFile = root / "system.toml"
  if not fileExists(sysFile):
    stderr.writeLine "\nno declaration at " & sysFile
    return exitCode(ekConfig)

  var cfg: SystemConfig
  var diags: seq[Diagnostic]
  try:
    (cfg, diags) = parseSystemConfig(readFile(sysFile), sysFile)
  except IOError, OSError:
    stderr.writeLine "cannot read " & sysFile
    return exitCode(ekConfig)

  var fatal = false
  for d in diags:
    if d.severity == sevError:
      fatal = true
      stderr.writeLine sysFile & ":" & $d.line & ": " & d.msg
  if fatal: return exitCode(ekConfig)

  echo "declared:        ", cfg.packages.len, " package(s)"
  echo ""

  let closure = closureFor(cfg.packages, root)
  if closure.hasErrors():
    stdout.write closure.renderClosure()
    # Resolution failure, not build failure: the declaration names something
    # that cannot be found or cannot be resolved, and no build was attempted.
    return exitCode(ekResolve)

  stdout.write closure.renderClosure()
  echo ""

  var opts = defaultOptions()
  opts.storeRoot = storeRoot
  opts.dryRun = true
  let p = plan(closure.packages, initStore(storeRoot), opts)
  stdout.write p.renderPlan()
  if p.diagnostics.len > 0:
    return exitCode(ekResolve)

  if not ok:
    echo ""
    echo "Note: the plan is sound, but this machine cannot enter a build"
    echo "sandbox, so `nexis rebuild switch` would refuse."
    return 1
  0

proc cmdGenerations(inv: Invocation): int =
  let root = inv.flags.getOrDefault("generations", GenerationsDir)
  let listed = listGenerations(root)
  if listed.len == 0:
    echo "no generations at ", root
    echo "  A generation is created by `nexis rebuild switch`."
    return 0
  for e in listed:
    echo (if e.current: "* " else: "  "), e.id,
         (if e.label.len > 0: "  " & e.label else: "")
  echo ""
  if canRollback(listed):
    echo "rollback would activate generation ", rollbackTarget(listed)
  else:
    echo "nothing to roll back to: this is the oldest generation"
  0

proc cmdRollback(inv: Invocation): int =
  let root = inv.flags.getOrDefault("generations", GenerationsDir)
  let listed = listGenerations(root)
  let target = rollbackTarget(listed)
  if target < 0:
    # A refusal, not a no-op. Silently doing nothing is how someone reboots
    # expecting a fix.
    stderr.writeLine "nothing to roll back to."
    if listed.len == 0:
      stderr.writeLine "  There are no generations yet."
    else:
      stderr.writeLine "  Generation " & $listed[0].id & " is the oldest."
    return 1
  echo "would activate generation ", target
  echo ""
  echo "Activation is not wired to the running system yet: the gates, the"
  echo "ordering and the boot entries are implemented and tested, but nothing"
  echo "mounts an image. See TODO.md."
  0

proc cmdDiff(inv: Invocation): int =
  if inv.args.len < 2:
    stderr.writeLine "usage: nexis diff <from> <to>"
    return exitCode(ekConfig)
  echo "Generation manifests are not read back from disk yet, so there is"
  echo "nothing to diff. The comparison itself is implemented and tested."
  1

proc dispatch(inv: Invocation): int =
  case inv.kind
  of ckHelp:
    stdout.write usage()
    0
  of ckVersion:
    echo "nexis ", Version
    0
  of ckNone:
    if inv.args.len > 0:
      stderr.writeLine "unknown command: " & inv.args[0]
      let s = suggest(inv.args[0])
      if s.len > 0: stderr.writeLine "  did you mean: nexis " & s
      stderr.writeLine "  nexis --help lists every command"
      exitCode(ekConfig)
    else:
      stdout.write usage()
      0

  of ckRefused:
    # Not an error path. A refusal that does not say what to type instead is
    # the reason people reach for imperative installs in the first place.
    stdout.write refusal(inv.refusedName, replacementFor(inv.refusedName),
                         (if inv.args.len > 0: inv.args[0] else: ""))
    exitCode(ekConfig)

  of ckCheck:
    if "config" in inv.flags or inv.args.len == 0:
      cmdCheckConfig(inv)
    else:
      notYet("nexis check --store", "the generation builder (phase 2)")

  of ckRebuild:
    if inv.isDryRun():
      cmdRebuildDryRun(inv)
    else:
      notYet("nexis rebuild " & inv.sub,
             "the generation builder (phase 2); dry-run works today")
  of ckGenerations: cmdGenerations(inv)
  of ckRollback: cmdRollback(inv)
  of ckDiff: cmdDiff(inv)
  of ckGc:
    notYet("nexis gc", "compositions as GC roots (phase 2)")
  of ckSearch, ckShow, ckWhy, ckOwns, ckExplain, ckOutputs:
    notYet("introspection", "a resolved graph to introspect (phase 1)")
  of ckShell, ckRun:
    notYet("ephemeral environments", "composition (phase 6)")
  of ckAdd, ckRemove:
    notYet("nexis " & (if inv.kind == ckAdd: "add" else: "remove"),
           "TOML round-tripping, then rebuild (phase 6)")

when isMainModule:
  var argv: seq[string]
  for i in 1 .. paramCount(): argv.add paramStr(i)

  try:
    quit(dispatch(parse(argv)))
  except NexisError as e:
    stderr.writeLine e[].format()
    quit(exitCode(e.kind))
  except CatchableError as e:
    # Anything reaching here is a bug rather than a user error, and should say
    # so instead of masquerading as one of the documented exit codes.
    stderr.writeLine "internal error: " & e.msg
    quit(1)
