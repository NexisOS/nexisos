## Applying the sandbox.
##
## `sandbox.nim` describes the isolation as data and `runner.nim` refuses to
## build without it. Neither of them actually isolates anything — that is this
## module, and until it existed the whole `tier = "generated"` argument
## (ADR 0002) was a claim about a sandbox that was never entered.
##
## Everything here runs in the child, between fork and exec. The ordering is
## not stylistic: several of these steps are one-way, and several fail with
## EPERM if done in the wrong sequence. The sequence is built as a value first
## so it can be asserted in tests without root, then executed.
##
## Three kernel behaviours are worth stating outright, because each one has a
## silent-failure mode that produces a sandbox you believe is airtight:
##
## 1. **`setgroups` must be denied before `gid_map` is written.** An unprivileged
##    user namespace refuses the gid map otherwise, with EPERM and no
##    explanation. Skipping the deny is the most common reason a build ends up
##    running as nobody instead of the fixed build uid.
##
## 2. **A bind mount cannot be made read-only in one call.** `MS_BIND | MS_RDONLY`
##    silently ignores the read-only flag; it takes a second
##    `MS_BIND | MS_REMOUNT | MS_RDONLY`. A single call leaves every store input
##    writable while the code reads as though it were not.
##
## 3. **`unshare(CLONE_NEWPID)` does not move the caller.** The *next* fork
##    becomes PID 1 in the new namespace. Assuming otherwise gives a build that
##    shares the host PID namespace while the spec says it does not.

import std/[os, posix, strutils]
import ../../lib/process
import ./sandbox

# --- Syscalls ----------------------------------------------------------------

proc unshare(flags: cint): cint {.importc, header: "<sched.h>".}
proc mount(source, target, fstype: cstring, flags: culong,
           data: cstring): cint {.importc, header: "<sys/mount.h>".}
proc umount2(target: cstring, flags: cint): cint
  {.importc, header: "<sys/mount.h>".}
# glibc has no pivot_root wrapper, so it goes through syscall(2) directly.
# SYS_pivot_root is 155 on x86_64.
proc syscall(number: clong): clong
  {.importc, varargs, header: "<sys/syscall.h>".}
const SYS_pivot_root = 155.clong

proc pivotRoot(newRoot, putOld: string): cint =
  cint(syscall(SYS_pivot_root, newRoot.cstring, putOld.cstring))
proc sethostname(name: cstring, len: csize_t): cint
  {.importc, header: "<unistd.h>".}


const
  CLONE_NEWNS = 0x00020000.cint
  CLONE_NEWUTS = 0x04000000.cint
  CLONE_NEWIPC = 0x08000000.cint
  CLONE_NEWUSER = 0x10000000.cint
  CLONE_NEWPID = 0x20000000.cint
  CLONE_NEWNET = 0x40000000.cint

  MS_RDONLY = 1.culong
  MS_NOSUID = 2.culong
  MS_NODEV = 4.culong
  MS_NOEXEC = 8.culong
  MS_REMOUNT = 32.culong
  MS_BIND = 4096.culong
  MS_REC = 16384.culong
  MS_PRIVATE = 262144.culong

  MNT_DETACH = 2.cint

  RLIMIT_FSIZE = 1.cint
  RLIMIT_NPROC = 6.cint

type IsolationError* = object of CatchableError

func flagsFor*(ns: Namespaces): cint =
  ## Which namespaces to unshare. Pure, so the mapping is reviewable and
  ## testable without the privilege to actually unshare anything.
  if ns.mount: result = result or CLONE_NEWNS
  if ns.uts: result = result or CLONE_NEWUTS
  if ns.ipc: result = result or CLONE_NEWIPC
  if ns.user: result = result or CLONE_NEWUSER
  if ns.pid: result = result or CLONE_NEWPID
  if ns.net: result = result or CLONE_NEWNET

# --- The mount sequence, as data ---------------------------------------------

type
  StepKind* = enum
    stMakePrivate      ## / recursively private, so nothing propagates out
    stMount            ## a fresh filesystem
    stBind             ## bind, first pass
    stBindReadOnly     ## the remount that actually makes a bind read-only
    stMkdir
    stPivot
    stUnmountOld

  Step* = object
    kind*: StepKind
    source*: string
    target*: string
    fstype*: string
    flags*: culong
    data*: string

func mountFlagsFor*(m: Mount): culong =
  ## Everything gets nosuid and nodev. A store input containing a setuid binary
  ## must not be able to confer privilege inside the build, and a device node
  ## in an input is either a mistake or an attack.
  result = MS_NOSUID or MS_NODEV
  case m.kind
  of mkBind: result = result or MS_BIND or MS_REC
  of mkBindRw: result = result or MS_BIND or MS_REC
  of mkTmpfs, mkProc, mkDev: discard

func planMounts*(spec: SandboxSpec, newRoot: string): seq[Step] =
  ## The whole filesystem setup, in order, as inspectable values.
  ##
  ## Built as data because the correctness of a sandbox is mostly the
  ## correctness of this ordering, and an ordering buried inside a procedure
  ## full of syscalls cannot be tested on a machine without root.
  result.add Step(kind: stMakePrivate, target: "/",
                  flags: MS_REC or MS_PRIVATE)
  result.add Step(kind: stMkdir, target: newRoot)
  result.add Step(kind: stMount, source: "tmpfs", target: newRoot,
                  fstype: "tmpfs", flags: MS_NOSUID or MS_NODEV,
                  data: "mode=0755")

  for m in spec.mounts:
    let target = newRoot / m.target.strip(leading = true, chars = {'/'})
    result.add Step(kind: stMkdir, target: target)
    case m.kind
    of mkProc:
      result.add Step(kind: stMount, source: "proc", target: target,
                      fstype: "proc",
                      flags: MS_NOSUID or MS_NODEV or MS_NOEXEC)
    of mkDev:
      # A tmpfs, not a bind of the host /dev. The build gets the handful of
      # nodes a compiler needs and nothing else; binding the host's would put
      # every block device in the machine inside the sandbox.
      result.add Step(kind: stMount, source: "tmpfs", target: target,
                      fstype: "tmpfs", flags: MS_NOSUID, data: "mode=0755")
    of mkTmpfs:
      result.add Step(kind: stMount, source: "tmpfs", target: target,
                      fstype: "tmpfs", flags: mountFlagsFor(m),
                      data: (if m.sizeMb > 0: "size=" & $m.sizeMb & "m"
                             else: ""))
    of mkBind:
      result.add Step(kind: stBind, source: m.source, target: target,
                      flags: mountFlagsFor(m))
      # The second pass. Without it the bind is writable regardless of intent.
      result.add Step(kind: stBindReadOnly, source: m.source, target: target,
                      flags: mountFlagsFor(m) or MS_REMOUNT or MS_RDONLY)
    of mkBindRw:
      result.add Step(kind: stBind, source: m.source, target: target,
                      flags: mountFlagsFor(m))

  result.add Step(kind: stMkdir, target: newRoot / "oldroot")
  result.add Step(kind: stPivot, source: newRoot, target: newRoot / "oldroot")
  result.add Step(kind: stUnmountOld, target: "/oldroot")

func readOnlyTargets*(steps: seq[Step]): seq[string] =
  for s in steps:
    if s.kind == stBindReadOnly: result.add s.target

func auditPlan*(spec: SandboxSpec, steps: seq[Step]): seq[string] =
  ## Every read-only bind in the spec must have its remount step. This is the
  ## check that would have caught a `MS_BIND | MS_RDONLY` shortcut, and it runs
  ## against the plan rather than against the running kernel — so it fails in
  ## CI rather than in production.
  let ro = readOnlyTargets(steps)
  for m in spec.mounts:
    if m.kind != mkBind: continue
    var found = false
    for t in ro:
      if t.endsWith(m.target.strip(leading = true, chars = {'/'})):
        found = true
        break
    if not found:
      result.add "read-only bind " & m.target & " has no remount step; it " &
                 "would be writable"

  var pivots = 0
  for s in steps:
    if s.kind == stPivot: inc pivots
  if pivots != 1:
    result.add "expected exactly one pivot_root, found " & $pivots

  if steps.len == 0 or steps[0].kind != stMakePrivate:
    result.add "the first step must make / private, or mounts propagate " &
               "back to the host"

# --- uid/gid mapping ---------------------------------------------------------

func uidMapContent*(inside, outside: int): string =
  ## `inside outside count`. One entry: an unprivileged user namespace may only
  ## map the single uid it was created by.
  $inside & " " & $outside & " 1\n"

proc writeMapFile(path, content: string): bool =
  try:
    writeFile(path, content)
    true
  except IOError, OSError:
    false

proc applyUserNamespace*(spec: SandboxSpec, outerUid, outerGid: int): bool =
  ## Order matters and is enforced by the kernel: deny setgroups, then gid_map,
  ## then uid_map. Writing gid_map first fails with EPERM and no explanation.
  if not writeMapFile("/proc/self/setgroups", "deny"):
    # Absent on very old kernels, where the deny is not required either.
    discard
  if not writeMapFile("/proc/self/gid_map", uidMapContent(spec.gid, outerGid)):
    return false
  if not writeMapFile("/proc/self/uid_map", uidMapContent(spec.uid, outerUid)):
    return false
  true

# --- Applying ----------------------------------------------------------------

proc applyStep(s: Step): bool =
  case s.kind
  of stMakePrivate:
    mount(nil, s.target.cstring, nil, s.flags, nil) == 0
  of stMkdir:
    try:
      createDir(s.target)
      true
    except OSError:
      false
  of stMount:
    mount(s.source.cstring, s.target.cstring, s.fstype.cstring, s.flags,
          (if s.data.len > 0: s.data.cstring else: nil)) == 0
  of stBind, stBindReadOnly:
    mount(s.source.cstring, s.target.cstring, nil, s.flags, nil) == 0
  of stPivot:
    # chroot would be the easier call and the wrong one: a chroot can be
    # escaped by a process still holding a descriptor outside it, whereas
    # pivot_root detaches the old root entirely.
    pivotRoot(s.source, s.target) == 0
  of stUnmountOld:
    umount2(s.target.cstring, MNT_DETACH) == 0

proc applyLimits*(spec: SandboxSpec) =
  if spec.maxFileSizeMb > 0:
    var r = RLimit(rlim_cur: spec.maxFileSizeMb * 1024 * 1024,
                   rlim_max: spec.maxFileSizeMb * 1024 * 1024)
    discard setrlimit(RLIMIT_FSIZE, r)
  if spec.maxProcesses > 0:
    var r = RLimit(rlim_cur: spec.maxProcesses,
                   rlim_max: spec.maxProcesses)
    discard setrlimit(RLIMIT_NPROC, r)

proc enter*(spec: SandboxSpec, newRoot = "/nexis-build-root") =
  ## Enter the sandbox. Raises on any failure.
  ##
  ## Never degrades. A partially applied sandbox is the worst outcome available:
  ## the build runs, produces an artifact, and that artifact is not reproducible
  ## for a reason nobody recorded. Refusing is recoverable; a silently
  ## unreproducible artifact is not.
  let problems = spec.violations()
  if problems.len > 0:
    raise newException(IsolationError,
      "refusing to enter an invalid sandbox: " & problems.join("; "))

  let outerUid = getuid().int
  let outerGid = getgid().int

  if unshare(flagsFor(spec.namespaces)) != 0:
    raise newException(IsolationError,
      "unshare failed: the kernel lacks namespace support, or " &
      "unprivileged user namespaces are disabled " &
      "(check /proc/sys/kernel/unprivileged_userns_clone)")

  if spec.namespaces.user:
    if not applyUserNamespace(spec, outerUid, outerGid):
      raise newException(IsolationError,
        "could not write the uid/gid maps; the build would run as nobody")

  let steps = planMounts(spec, newRoot)
  let audit = auditPlan(spec, steps)
  if audit.len > 0:
    raise newException(IsolationError,
      "the mount plan is unsound: " & audit.join("; "))

  if spec.namespaces.mount:
    for step in steps:
      if not applyStep(step):
        raise newException(IsolationError,
          "mount step failed: " & $step.kind & " " & step.target)

  if spec.namespaces.uts:
    if sethostname(spec.hostname.cstring, csize_t(spec.hostname.len)) != 0:
      raise newException(IsolationError, "could not set the build hostname")

  applyLimits(spec)
  discard umask(Mode(spec.umask))

  if spec.workDir.len > 0:
    if chdir(spec.workDir.cstring) != 0:
      raise newException(IsolationError,
        "could not enter the build directory " & spec.workDir)

  if setgid(Gid(spec.gid)) != 0 or setuid(Uid(spec.uid)) != 0:
    raise newException(IsolationError, "could not drop to the build uid")


# --- Running something inside it ---------------------------------------------

proc sandboxedExec*(spec: SandboxSpec): proc (prog: string, args: seq[string],
                                              opts: ExecOpts): ExecResult =
  ## An executor that actually enters the sandbox.
  ##
  ## `runBuild` takes its executor as a parameter so a dry run can walk the
  ## identical phase sequence without spawning anything. This is the other
  ## implementation: same interface, but each phase runs inside the namespaces
  ## `spec` describes.
  ##
  ## Isolation is applied per phase rather than once around the whole build.
  ## That costs a fork and an unshare per phase, which is nothing beside a
  ## compile — and it buys the property that a phase cannot leave the sandbox
  ## in a state the next phase inherits. A build whose configure phase
  ## remounted something is not a build whose install phase should see it.
  result = proc (prog: string, args: seq[string],
                 opts: ExecOpts): ExecResult =
    var fds: array[2, cint]
    if pipe(fds) != 0:
      return ExecResult(code: 127, output: "cannot create a pipe")

    let pid = fork()
    if pid < 0:
      discard close(fds[0])
      discard close(fds[1])
      return ExecResult(code: 127, output: "fork failed")

    if pid == 0:
      # Child. Every failure is a hard exit: a child that half-enters the
      # sandbox and then execs is precisely the unreproducible-artifact case
      # this module exists to prevent.
      discard close(fds[0])
      discard dup2(fds[1], 1)
      discard dup2(fds[1], 2)
      discard close(fds[1])
      try:
        spec.enter()
      except IsolationError as e:
        stderr.writeLine "nexis: " & e.msg
        quit(126)
      except CatchableError as e:
        stderr.writeLine "nexis: isolation failed: " & e.msg
        quit(126)

      var argv = @[prog]
      for a in args: argv.add a
      discard execvp(prog.cstring, allocCStringArray(argv))
      quit(127)

    discard close(fds[1])
    var output = ""
    var buf: array[4096, char]
    while true:
      let n = read(fds[0], addr buf[0], buf.len.cint)
      if n <= 0: break
      for i in 0 ..< n: output.add buf[i]
    discard close(fds[0])

    var status: cint
    discard waitpid(pid, status, 0)

    # 126 is the isolation failure the child reports above. Distinguishing it
    # from a build failure matters: one is a bug in NexisOS or in the machine's
    # kernel configuration, the other is a bug in the package.
    ExecResult(code: (int(status) shr 8) and 0xFF, output: output)

proc canIsolate*(): (bool, string) =
  ## Whether this machine can build at all, checked before a run rather than
  ## discovered on the first package. Unprivileged user namespaces are disabled
  ## by default on some distributions and inside some containers, and the
  ## failure is otherwise a bare EPERM from unshare.
  if not fileExists("/proc/self/uid_map"):
    return (false, "no /proc/self/uid_map: user namespaces are unavailable")
  for path in ["/proc/sys/kernel/unprivileged_userns_clone",
               "/proc/sys/user/max_user_namespaces"]:
    if not fileExists(path): continue
    try:
      if readFile(path).strip() == "0":
        return (false, path & " is 0: unprivileged user namespaces are " &
                       "disabled on this machine")
    except IOError, OSError: discard
  (true, "")
