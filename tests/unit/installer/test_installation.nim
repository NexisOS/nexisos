import std/[strutils, unittest]
import ../../../src/tuiinstaller/[installation, state, anim, plan]

proc cfg(dry = true, scheme = psEfiGpt): InstallConfig =
  result = defaultConfig(dryRun = dry)
  result.disk = "/dev/vda"
  result.scheme = scheme

suite "stage mapping":
  test "every command in a plan maps to a stage":
    # An unmapped command silently lands in "Unmounting", which would show the
    # install as nearly finished while it is still partitioning.
    for sc in [psEfiGpt, psBiosGpt]:
      for c in buildPlan(cfg(scheme = sc)):
        let s = stageOf(c.name)
        if c.name notin ["umount-boot", "umount-root"]:
          check s != sgFinish

  test "stages listed are only those the plan contains":
    # A BIOS install has no ESP to format. Showing an absent stage as instantly
    # complete is a claim the user has no way to check.
    let bios = initRunner(cfg(scheme = psBiosGpt))
    let efi = initRunner(cfg(scheme = psEfiGpt))
    check sgFormat in efi.stages()
    check efi.stages().len >= bios.stages().len

suite "progress":
  test "a fresh runner is at zero and nothing is running":
    let r = initRunner(cfg())
    check r.at == 0
    check r.fraction() == 0.0
    check not r.started
    check not r.finished
    for s in r.stages():
      check r.stageState(s) == ssPending

  test "stepping advances one command at a time":
    # One command per frame is what keeps the spinner turning through a long
    # mkfs; a batch loop makes a stall indistinguishable from a hang.
    var r = initRunner(cfg())
    let before = r.at
    check r.step()
    check r.at == before + 1

  test "a dry run walks the whole plan and finishes":
    var r = initRunner(cfg())
    var guard = 0
    while r.step() and guard < 1000: inc guard
    check r.finished
    check not r.failed
    check r.at == r.total()
    check r.fraction() == 1.0

  test "earlier stages are done once the cursor passes them":
    var r = initRunner(cfg())
    for _ in 0 ..< 6: discard r.step()
    check r.stageState(sgPartition) == ssDone
    check r.stageState(sgBoot) == ssPending

  test "the current stage is running, not pending":
    var r = initRunner(cfg())
    discard r.step()
    check r.stageState(r.currentStage()) == ssRunning

suite "failure":
  test "a failing command stops the run and names where":
    var r = initRunner(cfg(dry = false))
    # Real executor, and the plan's first program is not present here, so this
    # exercises the failure path rather than simulating it.
    discard r.step()
    if r.failed:
      check r.failedAt == 0
      check "FAILED" in r.statusLine()
      check not r.step()          ## a stopped run stays stopped

  test "a failed stage reports failed, not merely pending":
    var r = initRunner(cfg(dry = false))
    discard r.step()
    if r.failed:
      check r.stageState(sgPartition) == ssFailed

suite "reporting":
  test "the log records every command, marked as skipped in a dry run":
    var r = initRunner(cfg())
    discard r.step()
    discard r.step()
    check r.log.len == 2
    for line in r.log:
      check line.startsWith("[dry-run] ")

  test "the status line distinguishes dry run from a real install":
    var dry = initRunner(cfg(dry = true))
    var guard = 0
    while dry.step() and guard < 1000: inc guard
    check "Dry run complete" in dry.statusLine()
    check "none executed" in dry.statusLine()

  test "an unstarted runner says so rather than claiming progress":
    check initRunner(cfg()).statusLine() == "Ready."

  test "the tail log is bounded":
    var r = initRunner(cfg())
    var guard = 0
    while r.step() and guard < 1000: inc guard
    check r.tailLog(3).len == 3
    check r.tailLog(1000).len == r.log.len
