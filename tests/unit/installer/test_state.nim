import std/[strutils, unittest]
import ../../../src/tuiinstaller/state

suite "wizard navigation":
  test "starts at welcome with nothing done":
    let w = initWizard()
    check w.step == stWelcome
    check w.done == {}

  test "next advances and records completion":
    var w = initWizard()
    check w.next()
    check w.step == stDisk
    check stWelcome in w.done

  test "next is blocked while the step is invalid":
    var w = initWizard()
    discard w.next()                 # -> stDisk, no disk selected
    check not w.next()
    check w.step == stDisk
    w.cfg.disk = "/dev/vda"
    check w.next()
    check w.step == stPartition

  test "prev walks back and stops at the first step":
    var w = initWizard()
    check not w.prev()
    w.cfg.disk = "/dev/vda"
    discard w.next()
    discard w.next()
    check w.prev()
    check w.step == stDisk

  test "cannot advance past the last step":
    var w = initWizard()
    w.cfg.disk = "/dev/vda"
    for _ in 0 ..< StepCount * 2:
      discard w.next()
    check w.step == stInstall
    check not w.next()

suite "validation":
  test "hostnames":
    check validHostname("nexisos")
    check validHostname("web-01")
    check not validHostname("")
    check not validHostname("-bad")
    check not validHostname("bad-")
    check not validHostname("has space")
    check not validHostname('a'.repeat(64))

  test "usernames":
    check validUsername("kyle")
    check validUsername("_svc")
    check validUsername("a-b_c9")
    check not validUsername("")
    check not validUsername("9start")
    check not validUsername("Upper")
    check not validUsername('a'.repeat(33))

  test "stepValid points at the broken field":
    var w = initWizard()
    w.step = stSystem
    w.cfg.hostname = "bad host"
    check not w.stepValid().ok
    w.cfg.hostname = "goodhost"
    check w.stepValid().ok

suite "summary":
  test "dry-run mode is visible in the summary":
    var cfg = defaultConfig(dryRun = true)
    cfg.disk = "/dev/vda"
    let lines = summaryLines(cfg)
    check lines.len == 8
    var sawDry = false
    for l in lines:
      if "DRY RUN" in l: sawDry = true
    check sawDry
