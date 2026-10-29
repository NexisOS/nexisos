import std/[strutils, unittest]
import ../../../src/nexis/build/[isolate, sandbox]

proc spec(inputs: seq[string] = @["/store/abc"], net = false): SandboxSpec =
  newSandbox(inputs, allowNetwork = net)

suite "namespace flags":
  test "every requested namespace appears in the flags":
    let f = flagsFor(Namespaces(mount: true, pid: true, ipc: true, uts: true,
                                user: true, net: true))
    for bit in [0x00020000, 0x04000000, 0x08000000, 0x10000000,
                0x20000000, 0x40000000]:
      check (f and bit.cint) != 0

  test "nothing requested is nothing unshared":
    check flagsFor(Namespaces()) == 0

  test "allowing the network drops only the network namespace":
    let with = flagsFor(spec(net = false).namespaces)
    let without = flagsFor(spec(net = true).namespaces)
    check (with and 0x40000000.cint) != 0
    check (without and 0x40000000.cint) == 0
    check (without and 0x00020000.cint) != 0     ## mount ns still there

suite "the mount plan":
  test "the first step makes / private, or mounts escape to the host":
    let steps = planMounts(spec(), "/newroot")
    check steps[0].kind == stMakePrivate
    check steps[0].target == "/"

  test "a read-only bind gets its remount, because one call is not enough":
    # MS_BIND | MS_RDONLY silently ignores the read-only flag. A single call
    # leaves every store input writable while the code reads as though it were
    # not.
    let steps = planMounts(spec(@["/store/abc"]), "/newroot")
    var binds = 0
    var remounts = 0
    for s in steps:
      if s.kind == stBind and "store/abc" in s.target: inc binds
      if s.kind == stBindReadOnly and "store/abc" in s.target: inc remounts
    check binds == 1
    check remounts == 1

  test "the remount actually carries RDONLY and REMOUNT":
    for s in planMounts(spec(), "/newroot"):
      if s.kind == stBindReadOnly:
        check (s.flags and 1.culong) != 0        ## MS_RDONLY
        check (s.flags and 32.culong) != 0       ## MS_REMOUNT

  test "writable mounts get no read-only remount":
    var rw = 0
    for s in planMounts(spec(), "/newroot"):
      if s.kind == stBind and "/build/dest" in s.target: inc rw
      if s.kind == stBindReadOnly and "/build/dest" in s.target:
        fail()
    check rw == 1

  test "everything is nosuid and nodev":
    # A store input with a setuid binary must not confer privilege inside the
    # build, and a device node in an input is a mistake or an attack.
    for m in spec().mounts:
      if m.kind in {mkBind, mkBindRw, mkTmpfs}:
        let f = mountFlagsFor(m)
        check (f and 2.culong) != 0              ## MS_NOSUID
        check (f and 4.culong) != 0              ## MS_NODEV

  test "/dev is a tmpfs, not a bind of the host's":
    # Binding the host's would put every block device in the machine inside
    # the sandbox.
    for s in planMounts(spec(), "/newroot"):
      if s.target.endsWith("/dev"):
        check s.kind in {stMount, stMkdir}
        if s.kind == stMount: check s.fstype == "tmpfs"

  test "/proc is mounted fresh, and noexec":
    for s in planMounts(spec(), "/newroot"):
      if s.kind == stMount and s.fstype == "proc":
        check (s.flags and 8.culong) != 0        ## MS_NOEXEC

  test "every mount target is created first":
    var made: seq[string]
    for s in planMounts(spec(), "/newroot"):
      if s.kind == stMkdir: made.add s.target
      if s.kind in {stMount, stBind}:
        check s.target in made or s.target == "/newroot"

  test "the plan pivots exactly once and detaches the old root":
    let steps = planMounts(spec(), "/newroot")
    var pivots = 0
    var detaches = 0
    for s in steps:
      if s.kind == stPivot: inc pivots
      if s.kind == stUnmountOld: inc detaches
    check pivots == 1
    check detaches == 1

  test "the pivot comes before the old root is unmounted":
    let steps = planMounts(spec(), "/newroot")
    var pivotAt = -1
    var detachAt = -1
    for i, s in steps:
      if s.kind == stPivot: pivotAt = i
      if s.kind == stUnmountOld: detachAt = i
    check pivotAt >= 0 and detachAt > pivotAt

  test "several inputs each get their own pair of steps":
    let steps = planMounts(spec(@["/store/a", "/store/b", "/store/c"]),
                           "/newroot")
    check readOnlyTargets(steps).len == 3

suite "auditing the plan":
  test "a sound plan has nothing to report":
    let s = spec()
    check auditPlan(s, planMounts(s, "/newroot")).len == 0

  test "a bind with no remount is caught":
    # This is the check that would have caught an MS_BIND | MS_RDONLY
    # shortcut, and it runs in CI rather than in production.
    let s = spec()
    var steps = planMounts(s, "/newroot")
    var stripped: seq[Step]
    for step in steps:
      if step.kind != stBindReadOnly: stripped.add step
    let problems = auditPlan(s, stripped)
    check problems.len > 0
    check "would be writable" in problems[0]

  test "a missing pivot is caught":
    let s = spec()
    var stripped: seq[Step]
    for step in planMounts(s, "/newroot"):
      if step.kind != stPivot: stripped.add step
    check "pivot_root" in auditPlan(s, stripped).join(" ")

  test "a plan that does not start by making / private is caught":
    let s = spec()
    var steps = planMounts(s, "/newroot")
    steps.delete(0)
    check "propagate" in auditPlan(s, steps).join(" ")

  test "an empty plan is unsound, not vacuously fine":
    check auditPlan(spec(), @[]).len > 0

suite "uid mapping":
  test "one entry, because an unprivileged namespace may map only one uid":
    check uidMapContent(1000, 501) == "1000 501 1\n"

  test "the build uid is the one from the spec, not the caller's":
    let s = spec()
    check uidMapContent(s.uid, 12345).startsWith($BuildUid & " 12345")

suite "refusing rather than degrading":
  test "an invalid sandbox is refused before anything is unshared":
    # A partially applied sandbox is the worst outcome: the build runs, an
    # artifact is produced, and it is unreproducible for a reason nobody
    # recorded.
    var bad = spec()
    bad.namespaces.mount = false
    var raised = false
    try:
      bad.enter("/tmp/nexis-should-not-happen")
    except IsolationError as e:
      raised = true
      check "invalid sandbox" in e.msg
    except CatchableError:
      raised = true
    check raised

  test "the spec's own violations are what gate entry":
    var bad = spec()
    bad.hostname = "whatever-the-host-is-called"
    check bad.violations().len > 0
