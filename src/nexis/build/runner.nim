## Running one build, under an enforced sandbox.
##
## `sandbox.nim` describes the conditions a build must run under.
## `violations()` checks that description. Nothing, until now, refused to
## *start* a build whose sandbox was wrong — which meant the reproducibility
## argument rested on a function nobody called.
##
## This module closes that gap, and the rule it enforces has one shape:
##
##   **A sandbox that cannot be applied is a failed build, never a warning.**
##
## The temptation is to degrade — to run without a user namespace on a kernel
## that forbids unprivileged ones, and note it in the log. That produces
## artifacts indistinguishable from correct ones which cannot be reproduced
## anywhere else, and they will be cached, shipped, and depended upon before
## anyone reads the log.
##
## The second rule concerns what happens after a failure:
##
##   **A failed build leaves no live reference.**
##
## Staging is committed only on success. Everything else is removed, so the
## store never accumulates entries pointing at a partial tree.

import std/[os, strutils, tables]
import ../../lib/[process, filesystem]
import ./sandbox, ./phases

type
  BuildOutcome* = enum
    boSuccess
    boSandboxRefused    ## the spec was wrong; nothing ran
    boPhaseFailed
    boTimedOut

  BuildResult* = object
    outcome*: BuildOutcome
    failedPhase*: PhaseName
    exitCode*: int
    log*: string
    violations*: seq[string]

  BuildRequest* = object
    name*: string
    spec*: SandboxSpec
    phases*: seq[ResolvedPhase]
    staging*: string          ## where DESTDIR lands before it is committed
    timeoutMs*: int

func describe*(r: BuildResult): string =
  case r.outcome
  of boSuccess: "built"
  of boSandboxRefused:
    "refused: " & $r.violations.len & " sandbox violation(s)"
  of boPhaseFailed:
    "failed in " & $r.failedPhase & " (exit " & $r.exitCode & ")"
  of boTimedOut: "timed out in " & $r.failedPhase

# --- Preflight ---------------------------------------------------------------

func requiredTools*(phases: seq[ResolvedPhase]): seq[string] =
  ## Every program the phases will invoke. Checked before the first one runs,
  ## so a missing `cmake` is reported as a missing build dependency rather than
  ## as exit 127 forty minutes into a configure.
  var seen: seq[string]
  for p in phases:
    if p.skipped: continue
    for argv in p.argv:
      if argv.len == 0: continue
      let prog = argv[0]
      if prog notin seen and not prog.startsWith("./"):
        seen.add prog
  seen

func unsubstituted*(phases: seq[ResolvedPhase]): seq[string] =
  ## Any `@name@` left in a resolved phase.
  ##
  ## `phases.nim` already treats this as an error at substitution time; this
  ## is the belt-and-braces check at the boundary where it would actually do
  ## damage. Passing a literal `@out@` to `make install` produces a directory
  ## with that name, and the build "succeeds".
  for p in phases:
    if p.skipped: continue
    for argv in p.argv:
      for a in argv:
        let first = a.find('@')
        if first < 0: continue
        let second = a.find('@', first + 1)
        if second > first:
          let token = a[first .. second]
          if token notin result: result.add token

proc preflight*(req: BuildRequest): seq[string] =
  ## Everything wrong before anything runs. All of it at once: reporting the
  ## first problem means the reader fixes it, re-runs, waits, and is told about
  ## the next.
  result = req.spec.violations()
  for token in unsubstituted(req.phases):
    result.add "unsubstituted variable " & token & " in a build phase"
  if req.phases.len == 0:
    result.add "no phases to run"
  if req.staging.len == 0:
    result.add "no staging directory"
  elif not req.staging.startsWith("/"):
    result.add "staging directory must be absolute: " & req.staging

# --- Execution ---------------------------------------------------------------

proc execOptsFor*(spec: SandboxSpec, cwd: string, timeoutMs: int): ExecOpts =
  ## The environment is the sandbox's, entirely. `inheritEnv` stays false: a
  ## build that reads a variable from whoever invoked it is not reproducible,
  ## and the failure is invisible until two machines disagree.
  result = defaultExecOpts()
  result.cwd = cwd
  result.inheritEnv = false
  result.timeoutMs = timeoutMs
  result.captureOutput = true
  for k, v in spec.env: result.env[k] = v

proc runBuild*(req: BuildRequest,
               exec: proc (prog: string, args: seq[string],
                           opts: ExecOpts): ExecResult): BuildResult =
  ## Run every phase in order. The executor is injected so a dry run walks the
  ## identical sequence without spawning anything — and so this is testable
  ## without a compiler on the machine.
  let problems = preflight(req)
  if problems.len > 0:
    # Refused, not failed. The distinction matters to the caller: a sandbox
    # violation is a bug in NexisOS or in the definition, whereas a phase
    # failure is usually a bug in the package.
    return BuildResult(outcome: boSandboxRefused, violations: problems)

  result.log.add "# " & req.name & "\n"
  result.log.add req.spec.render()
  result.log.add "\n"

  for phase in req.phases:
    if phase.skipped:
      result.log.add "## " & $phase.name & ": skipped\n"
      continue
    result.log.add "## " & $phase.name & "\n"

    let cwd = if phase.name == phConfigure: SrcDir else: BuildTmp
    let opts = execOptsFor(req.spec, cwd, req.timeoutMs)

    for argv in phase.argv:
      if argv.len == 0: continue
      result.log.add "$ " & render(argv[0], argv[1 .. ^1]) & "\n"
      let r = exec(argv[0], argv[1 .. ^1], opts)
      if r.output.len > 0: result.log.add r.output
      if r.timedOut:
        result.outcome = boTimedOut
        result.failedPhase = phase.name
        return
      if r.code != 0:
        result.outcome = boPhaseFailed
        result.failedPhase = phase.name
        result.exitCode = r.code
        return

  result.outcome = boSuccess

# --- Committing --------------------------------------------------------------

proc discardStaging*(staging: string) =
  ## A failed build leaves nothing behind. Called on every non-success path,
  ## because a partial tree that survives is a partial tree something will
  ## eventually reference.
  if staging.len == 0: return
  removeTree(staging)

proc commitReady*(staging: string): (bool, string) =
  ## Whether a staging tree is fit to enter the store.
  ##
  ## An empty output is treated as a failure rather than as an empty package.
  ## It almost always means `make install` ignored DESTDIR and wrote into the
  ## sandbox's own `/usr` instead — a mistake that otherwise surfaces much
  ## later as a package that installs nothing.
  if not dirExists(staging):
    return (false, "the build produced no output directory")
  let entries = walkTree(staging)
  if entries.len == 0:
    return (false,
      "the build produced an empty output. Check that the install phase " &
      "honours DESTDIR rather than writing to the prefix directly.")
  (true, "")
