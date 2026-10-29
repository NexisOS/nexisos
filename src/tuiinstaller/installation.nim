## Executing the plan, with progress the UI can render.
##
## The runner does not draw anything. It holds the state of a run — which
## command is current, what finished, what failed — and the UI reads it each
## frame. That split is what lets `--dry-run` walk the identical sequence with
## a dry executor and produce an identical-looking screen.
##
## Steps are grouped, not listed one command per line. A user watching an
## install wants to know it reached "building generation 1", not that command
## 9 of 14 was `udevadm settle`.


import ./command, ./state, ./plan, ./anim

type
  Stage* = enum
    sgPartition = "Partitioning the disk"
    sgFormat    = "Creating filesystems"
    sgMount     = "Mounting the target"
    sgConfig    = "Writing /etc/nexis"
    sgGenerate  = "Building generation 1"
    sgBoot      = "Installing the bootloader"
    sgFinish    = "Unmounting"

  Runner* = object
    cfg*: InstallConfig
    plan*: seq[Command]
    ex*: Executor
    at*: int                  ## index of the next command to run
    failed*: bool
    failedAt*: int
    started*: bool
    finished*: bool
    log*: seq[string]

func stageOf*(name: string): Stage =
  ## Maps a command's short label to the stage the user sees.
  case name
  of "wipe", "esp", "root", "biosboot", "settle": sgPartition
  of "mkfs-esp", "mkfs-root": sgFormat
  of "mount-root", "mkdir-boot", "mount-boot": sgMount
  of "mkdir-etc", "write-config", "user": sgConfig
  of "generation": sgGenerate
  of "bootloader": sgBoot
  else: sgFinish

func initRunner*(cfg: InstallConfig): Runner =
  Runner(cfg: cfg, plan: buildPlan(cfg), ex: initExecutor(cfg.dryRun),
         at: 0, failed: false, failedAt: -1, started: false, finished: false)

func total*(r: Runner): int = r.plan.len

func fraction*(r: Runner): float =
  if r.plan.len == 0: 1.0 else: float(r.at) / float(r.plan.len)

func currentStage*(r: Runner): Stage =
  if r.at >= r.plan.len: sgFinish
  else: stageOf(r.plan[r.at].name)

func stageState*(r: Runner, s: Stage): StepState =
  ## A stage is done when every command mapping to it has been passed, running
  ## when the cursor is inside it, and failed when the cursor stopped there.
  var firstIdx = -1
  var lastIdx = -1
  for i, c in r.plan:
    if stageOf(c.name) == s:
      if firstIdx < 0: firstIdx = i
      lastIdx = i
  if firstIdx < 0: return ssDone          ## stage has no commands in this plan
  if r.failed and r.failedAt >= firstIdx and r.failedAt <= lastIdx:
    return ssFailed
  if r.at > lastIdx: return ssDone
  if r.at >= firstIdx and r.started: return ssRunning
  ssPending

func stages*(r: Runner): seq[Stage] =
  ## Only the stages this plan actually contains — a BIOS install has no ESP
  ## to format, and showing an empty stage as instantly complete is a lie the
  ## user has no way to check.
  var seen: set[Stage]
  for c in r.plan:
    let s = stageOf(c.name)
    if s notin seen:
      seen.incl s
      result.add s

proc step*(r: var Runner): bool =
  ## Run exactly one command. Returning per-command rather than looping keeps
  ## the render loop responsive: a spinner that stops turning during a long
  ## `mkfs` is indistinguishable from a hang.
  r.started = true
  if r.finished or r.failed: return false
  if r.at >= r.plan.len:
    r.finished = true
    return false

  let c = r.plan[r.at]
  let res = r.ex.run(c)
  r.log.add (if res.skipped: "[dry-run] " else: "") & c.render()
  if res.code != 0:
    r.failed = true
    r.failedAt = r.at
    r.log.add "  ^ exited " & $res.code
    return false
  inc r.at
  if r.at >= r.plan.len: r.finished = true
  true

func statusLine*(r: Runner): string =
  if r.failed:
    "FAILED at step " & $(r.failedAt + 1) & " of " & $r.plan.len &
      " - nothing further was run"
  elif r.finished:
    if r.cfg.dryRun:
      "Dry run complete. " & $r.plan.len & " commands, none executed."
    else:
      "Installation complete. Remove the medium and reboot."
  elif r.started:
    $currentStage(r)
  else:
    "Ready."

func tailLog*(r: Runner, n: int): seq[string] =
  let start = max(0, r.log.len - n)
  for i in start ..< r.log.len: result.add r.log[i]
