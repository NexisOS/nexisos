## Running programs.
##
## Never through a shell. Every caller has an argv array already — build phases
## are argv by construction (`phases.nim`), and the installer builds `Command`
## values — so introducing a shell here would mean re-serialising a correct
## array into a string that has to be re-parsed. A package name containing a
## space would become two arguments, and the quoting rules would become part of
## the build identity.
##
## The environment is *constructed*, never inherited. A build that reads
## `$CFLAGS` from whoever ran it is not reproducible, and the failure is
## invisible until two machines disagree. `runSandboxed` therefore takes the
## full environment and passes nothing else through.

import std/[os, osproc, streams, strtabs, strutils, tables]
import ./errors

type
  ExecResult* = object
    code*: int
    output*: string        ## stdout and stderr interleaved, as the user saw it
    timedOut*: bool

  ExecOpts* = object
    cwd*: string
    env*: OrderedTable[string, string]
    inheritEnv*: bool      ## false is the default and the correct one
    timeoutMs*: int        ## 0 means wait indefinitely
    captureOutput*: bool

func defaultExecOpts*(): ExecOpts =
  ExecOpts(cwd: "", inheritEnv: false, timeoutMs: 0, captureOutput: true,
           env: initOrderedTable[string, string]())

func render*(prog: string, args: openArray[string]): string =
  ## Shell-equivalent text, for logs and error messages only. Nothing is ever
  ## executed from this string — see the module comment.
  result = prog
  for a in args:
    var needsQuote = a.len == 0
    for c in a:
      if c notin {'a'..'z', 'A'..'Z', '0'..'9', '/', '.', '-', '_', '=', ',',
                  ':', '+', '@', '%'}:
        needsQuote = true
        break
    result.add " "
    if needsQuote: result.add "'" & a.replace("'", "'\\''") & "'"
    else: result.add a

proc toEnvTable(o: ExecOpts): StringTableRef =
  if o.inheritEnv and o.env.len == 0:
    return nil                      ## nil means "inherit", per osproc
  result = newStringTable()
  if o.inheritEnv:
    for k, v in envPairs(): result[k] = v
  for k, v in o.env: result[k] = v

proc exec*(prog: string, args: openArray[string] = [],
           opts = defaultExecOpts()): ExecResult =
  ## Run to completion. Output is captured rather than streamed, because a
  ## build log is only useful attached to the build that produced it.
  var options = {poUsePath}
  if opts.captureOutput: options.incl poStdErrToStdOut

  var p: Process
  try:
    p = startProcess(prog, workingDir = opts.cwd, args = @args,
                     env = opts.toEnvTable(), options = options)
  except OSError as e:
    # 127 is the shell's "command not found", and callers already branch on
    # it. Distinguishing "could not start" from "started and failed" matters:
    # the first is a missing build dependency, the second is a real failure.
    return ExecResult(code: 127, output: "cannot execute " & prog & ": " & e.msg)

  defer: p.close()

  if opts.timeoutMs > 0:
    var waited = 0
    const Slice = 25
    while waited < opts.timeoutMs:
      if not p.running: break
      sleep(Slice)
      waited += Slice
    if p.running:
      p.terminate()
      sleep(200)
      if p.running: p.kill()
      discard p.waitForExit()
      return ExecResult(code: 124, timedOut: true,
                        output: "timed out after " & $opts.timeoutMs & "ms")

  if opts.captureOutput:
    result.output = p.outputStream.readAll()
  result.code = p.waitForExit()

proc checkExec*(prog: string, args: openArray[string] = [],
                opts = defaultExecOpts(), kind = ekBuild) =
  ## Run, and raise with the command and its output on failure. Callers that
  ## want to inspect the code use `exec`; callers for whom any failure is fatal
  ## use this, so the failure carries what was run rather than just a number.
  let r = exec(prog, args, opts)
  if r.code != 0:
    raiseNexis(kind,
               render(prog, args) & " exited " & $r.code,
               hint = (if r.output.len > 0: r.output.strip() else: ""))

proc which*(prog: string): string =
  ## Absolute path, or the empty string. Used to report a missing build
  ## dependency by name before a phase runs, rather than as exit 127 partway
  ## through a build.
  if prog.contains('/'):
    return (if fileExists(prog): prog else: "")
  for dir in getEnv("PATH").split(PathSep):
    if dir.len == 0: continue
    let candidate = dir / prog
    if fileExists(candidate): return candidate
  ""

proc requireAll*(progs: openArray[string], kind = ekBuild) =
  ## Report every missing program at once. Reporting the first one means the
  ## user installs it, re-runs, and waits to be told about the next.
  var missing: seq[string]
  for p in progs:
    if which(p).len == 0: missing.add p
  if missing.len > 0:
    raiseNexis(kind, "missing required program(s): " & missing.join(", "),
               hint = "these must be present in the build environment")
