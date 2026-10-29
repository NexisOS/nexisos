import std/[strutils, unittest]
import ../../../src/tuiinstaller/command

suite "cmd rendering":
  test "plain args":
    check cmd("x", "sgdisk", "--zap-all", "/dev/vda").render() ==
      "sgdisk --zap-all /dev/vda"

  test "args with spaces get quoted":
    check cmd("x", "echo", "hello world").render() == "echo 'hello world'"

suite "dry-run executor":
  test "dry run never executes, records everything, reports success":
    var ex = initExecutor(dryRun = true)
    # A program that cannot exist: if this ever executed, it would fail.
    let r = ex.run(cmd("nope", "/definitely/not/a/real/binary", "--boom"))
    check r.skipped
    check r.code == 0
    check ex.history.len == 1

  test "runAll in dry-run walks the whole plan":
    var ex = initExecutor(dryRun = true)
    let plan = @[
      cmd("a", "/no/such/bin-a"),
      cmd("b", "/no/such/bin-b"),
      cmd("c", "/no/such/bin-c")]
    check ex.runAll(plan)
    check ex.history.len == 3

  test "transcript prefixes dry-run lines":
    var ex = initExecutor(dryRun = true)
    discard ex.run(cmd("x", "mkfs.ext4", "-L", "root", "/dev/vda2"))
    let t = ex.transcript()
    check t.len == 1
    check t[0].startsWith("[dry-run] mkfs.ext4")

suite "real executor":
  test "executes and captures exit code":
    var ex = initExecutor(dryRun = false)
    let r = ex.run(cmd("truth", "true"))
    check not r.skipped
    check r.code == 0
    let bad = ex.run(cmd("lie", "false"))
    check bad.code != 0

  test "runAll stops at the first failure":
    var ex = initExecutor(dryRun = false)
    let plan = @[cmd("ok", "true"), cmd("bad", "false"), cmd("never", "true")]
    check not ex.runAll(plan)
    check ex.history.len == 2
