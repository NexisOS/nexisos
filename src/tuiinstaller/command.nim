## Commands are values, not strings.
##
## Every action the installer takes is built as a `Command` first and executed
## second. That split is what makes `--dry-run` honest: the same list is either
## rendered or run, so a dry run cannot diverge from the real thing by taking a
## different code path.

import std/[osproc, strutils]

type
  Command* = object
    name*: string          ## short label, for progress reporting
    prog*: string
    args*: seq[string]

  CmdResult* = object
    cmd*: Command
    code*: int
    skipped*: bool         ## true when the executor was in dry-run mode

  Executor* = object
    dryRun*: bool
    history*: seq[CmdResult]

func cmd*(name, prog: string, args: varargs[string]): Command =
  Command(name: name, prog: prog, args: @args)

func needsQuoting(s: string): bool =
  if s.len == 0: return true
  for c in s:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '/', '.', '-', '_', '=', ',',
                ':', '+', '@', '%'}:
      return true
  false

func shellQuote*(s: string): string =
  if not needsQuoting(s): return s
  "'" & s.replace("'", "'\\''") & "'"

func render*(c: Command): string =
  ## A shell-equivalent rendering, for display only. Execution never goes
  ## through a shell — args are passed to the process directly, so a device
  ## name containing a space cannot become two arguments.
  result = shellQuote(c.prog)
  for a in c.args:
    result.add " " & shellQuote(a)

func initExecutor*(dryRun: bool): Executor =
  Executor(dryRun: dryRun, history: @[])

proc run*(ex: var Executor, c: Command): CmdResult =
  if ex.dryRun:
    result = CmdResult(cmd: c, code: 0, skipped: true)
  else:
    var code = 127
    try:
      let p = startProcess(c.prog, args = c.args,
                           options = {poUsePath, poStdErrToStdOut})
      code = p.waitForExit()
      p.close()
    except OSError:
      code = 127
    result = CmdResult(cmd: c, code: code, skipped: false)
  ex.history.add result

proc runAll*(ex: var Executor, plan: seq[Command]): bool =
  ## Stops at the first failure. A partially applied disk layout is worse than
  ## a clearly aborted one.
  for c in plan:
    if ex.run(c).code != 0: return false
  true

func transcript*(ex: Executor): seq[string] =
  for r in ex.history:
    result.add (if r.skipped: "[dry-run] " else: "") & r.cmd.render()
