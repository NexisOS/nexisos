import std/[strutils, unittest]
import ../../../src/init/sleep

suite "inhibitors":
  test "a block inhibitor refuses sleep; a delay one does not":
    var m = newSleepManager()
    discard m.take({ihSleep}, "vlc", "Playing video", imBlock, 100, 0)
    check m.requestSleep(1000) == sdBlocked

    var d = newSleepManager()
    discard d.take({ihSleep}, "backup", "Writing", imDelay, 100, 0)
    check d.requestSleep(1000) == sdWaitForDelays

  test "with nothing held, sleep proceeds":
    var m = newSleepManager()
    check m.requestSleep(1000) == sdProceed
    check m.state == slSuspending

  test "an inhibitor on another lock does not block sleep":
    var m = newSleepManager()
    discard m.take({ihIdle}, "player", "Music", imBlock, 100, 0)
    check m.requestSleep(1000) == sdProceed

  test "the refusal names who is holding it and why":
    # systemd-inhibit --list exists because this question is asked constantly.
    # Making it the text of the refusal means it never has to be asked.
    var m = newSleepManager()
    discard m.take({ihSleep}, "PowerDevil", "Presentation mode", imBlock,
                   4242, 0)
    let e = m.explain(ihSleep)
    check "PowerDevil" in e
    check "Presentation mode" in e
    check "4242" in e

  test "with nothing held the explanation says so plainly":
    check "nothing is inhibiting" in newSleepManager().explain(ihSleep)

  test "releasing an unknown id is false, not a crash":
    var m = newSleepManager()
    check not m.release(999)

  test "a dead process's locks are dropped":
    # A crashed media player leaving a block inhibitor behind is the classic
    # "my laptop stopped sleeping and nothing says why" bug, and it otherwise
    # persists until reboot.
    var m = newSleepManager()
    discard m.take({ihSleep}, "vlc", "Playing", imBlock, 500, 0)
    discard m.take({ihSleep}, "vlc-helper", "Playing", imBlock, 500, 0)
    discard m.take({ihSleep}, "backup", "Writing", imBlock, 600, 0)
    check m.releaseByPid(500) == 2
    check m.blockers(ihSleep).len == 1
    check m.requestSleep(1000) == sdBlocked      ## backup still holds one

suite "idempotence":
  test "a request while a suspend is in flight is dropped, not queued":
    # A power manager whose idle timer keeps resetting can otherwise issue
    # several requests per second, each restarting the sequence.
    var m = newSleepManager()
    check m.requestSleep(1000) == sdProceed
    check m.requestSleep(1001) == sdAlreadyInFlight
    check m.requestSleep(1002) == sdAlreadyInFlight

  test "requests during the delay window are also dropped":
    var m = newSleepManager()
    discard m.take({ihSleep}, "backup", "Writing", imDelay, 100, 0)
    check m.requestSleep(1000) == sdWaitForDelays
    check m.requestSleep(1050) == sdAlreadyInFlight

  test "one cycle is recorded per suspend, not per request":
    var m = newSleepManager()
    discard m.requestSleep(1000)
    discard m.requestSleep(1001)
    discard m.requestSleep(1002)
    check m.recentCycles(1010) == 1

suite "delay bounds":
  test "a hung delay inhibitor cannot hold sleep open forever":
    # The same escalate-rather-than-wait rule the shutdown sequence follows.
    var m = newSleepManager()
    discard m.take({ihSleep}, "backup", "Writing", imDelay, 100, 0)
    discard m.requestSleep(1000)
    check not m.delayExpired(2000)
    check m.delayExpired(1000 + m.delayMaxMs)

  test "the delay default matches logind, so existing software behaves":
    check newSleepManager().delayMaxMs == 5000

  test "proceeding after delays moves to suspending exactly once":
    var m = newSleepManager()
    discard m.take({ihSleep}, "backup", "Writing", imDelay, 100, 0)
    discard m.requestSleep(1000)
    check m.proceedAfterDelays(1200)
    check m.state == slSuspending
    check not m.proceedAfterDelays(1300)

suite "thrash detection":
  proc cycled(times: int, spacingMs: int64): SleepManager =
    result = newSleepManager()
    var t: int64 = 0
    for _ in 0 ..< times:
      discard result.requestSleep(t)
      result.onResume(t + 100)
      t += spacingMs

  test "a broken loop is stopped, and the machine stays awake":
    # Staying awake is the better failure: the user sees a laptop that will not
    # sleep, rather than a screen strobing at 2Hz.
    var m = cycled(3, 500)
    check m.isThrashing(1500)
    check m.requestSleep(1600) == sdThrashing
    check m.state == slRefused

  test "the refusal explains what to check, not just that it refused":
    var m = cycled(3, 500)
    discard m.requestSleep(1600)
    check "wakeup sources" in m.refusedReason
    check "display" in m.refusedReason

  test "normal use is not mistaken for thrashing":
    # Suspend, resume to check something, suspend again - twice in an hour.
    var m = cycled(2, 600_000)
    check not m.isThrashing(1_300_000)

  test "old cycles fall out of the window":
    var m = cycled(3, 500)
    check m.isThrashing(1500)
    check not m.isThrashing(1500 + m.thrashWindowMs)

  test "an explicit user request clears the refusal":
    # A lid close or a menu choice is different from an idle timer asking on
    # the user's behalf.
    var m = cycled(3, 500)
    discard m.requestSleep(1600)
    check m.state == slRefused
    m.clearRefusal()
    check m.requestSleep(1700) == sdProceed

suite "wakeup sources":
  const Sample = """
Device	S-state	  Status   Sysfs node
GPP0	  S4	*disabled  pci:0000:00:01.1
XHC0	  S3	*enabled   pci:0000:00:08.1
LID	  S4	*enabled   platform:PNP0C0D:00
GPP8	  S4	*disabled
"""

  test "armed and disarmed devices are distinguished":
    let s = parseAcpiWakeup(Sample)
    check s.len == 4
    check "XHC0" in armedSources(s)
    check "LID" in armedSources(s)
    check "GPP0" notin armedSources(s)

  test "the header is not parsed as a device":
    for s in parseAcpiWakeup(Sample):
      check s.device != "Device"

  test "a row with no sysfs node still parses":
    let s = parseAcpiWakeup(Sample)
    for entry in s:
      if entry.device == "GPP8": check entry.sysfsPath == ""

  test "armed but undeclared sources are a diff, not a mystery":
    # A laptop that resumes the instant it suspends should be answerable by
    # reading the configuration.
    let s = parseAcpiWakeup(Sample)
    check unexpectedlyArmed(s, @["LID"]) == @["XHC0"]
    check unexpectedlyArmed(s, @["LID", "XHC0"]).len == 0

  test "garbage does not crash the parser":
    check parseAcpiWakeup("").len == 0
    check parseAcpiWakeup("nonsense\n\n").len == 0

suite "sleep state selection":
  test "suspend-to-idle is preferred when the firmware offers it":
    # On modern laptops `deep` is frequently the broken path: many vendors ship
    # an S3 implementation that resumes spuriously, which is the symptom this
    # module exists to bound.
    check bestState(@["freeze", "mem", "disk"]) == "freeze"

  test "mem is used when freeze is unavailable":
    check bestState(@["mem", "disk"]) == "mem"

  test "no supported state is empty, not a wrong guess":
    check bestState(@[]) == ""
