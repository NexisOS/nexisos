## `nexis-init` — PID 1.
##
## One thread, one epoll loop, no shell in the service path, no dynamic
## linking beyond libc. A PID 1 that cannot start is an unbootable machine, so
## its failure modes and its attack surface are both kept small enough to read
## in an afternoon.
##
## Three kinds of event arrive on the same loop:
##
##   signalfd   signals, as ordinary bytes at a consistent point
##   pidfd      a supervised process died — pollable, not a SIGCHLD race
##   timerfd    the next deadline (start timeout, restart backoff, stop kill)
##
## Everything else is derived from those. There is no polling, no sleep loop,
## and no second thread that could observe state mid-update.
##
## `sd_notify` compatibility is deliberate. The goal is not to reproduce
## systemd, it is to reduce the cost of running software that already exists —
## a service that writes `READY=1` to `$NOTIFY_SOCKET` works here unchanged.

import std/[os, posix, strutils, tables, times]
import ./sandbox
import ./process, ./signals, ./service, ./supervisor, ./cgroup, ./shutdown,
       ./sleep, ./config, ./notify, ./socket

const
  Version = "0.1.0"
  DefaultConfigRoot = "/etc/nexis"

type
  Init = object
    units: Table[string, Unit]
    order: seq[string]
    sleeper: SleepManager
    confinement: Table[string, Confinement]
    limits: Table[string, Limits]
    notifySock: NotifySocket
    byPid: PidIndex
    sockets: seq[BoundSocket]
    sigfd: SignalFd
    epfd: cint
    running: bool
    intent: Intent
    shuttingDown: bool

proc nowMs(): int64 = (epochTime() * 1000).int64

proc log(level, msg: string) =
  ## Straight to the console until `nexis-log` exists. PID 1 logging through a
  ## service it also supervises is a bootstrap problem, so the early path never
  ## depends on one.
  stderr.writeLine "[" & level & "] " & msg
  stderr.flushFile()

# --- Early boot --------------------------------------------------------------

proc mountFs(source, target, fstype: cstring, flags: culong,
             data: cstring): cint {.importc: "mount", header: "<sys/mount.h>".}

# Nim's posix module does not export this one.
const TIOCSCTTY = 0x540E.cint

proc mountEarly() =
  ## The filesystems everything else assumes.
  ##
  ## `mount(2)` directly rather than shelling out to `mount(8)`. PID 1 running
  ## before `/proc` exists cannot rely on a shell, a PATH, or a mount binary
  ## being present — and if any of them is missing, the failure is a boot that
  ## stops with no output. The syscall has no such dependencies.
  ##
  ## EBUSY means already mounted, which is the normal case when an initramfs
  ## did the work, and is not an error.
  type MountSpec = tuple[src, dst, fs: string]
  const Early: seq[MountSpec] = @[
    ("proc", "/proc", "proc"),
    ("sysfs", "/sys", "sysfs"),
    ("devtmpfs", "/dev", "devtmpfs"),
    ("tmpfs", "/run", "tmpfs"),
    ("cgroup2", "/sys/fs/cgroup", "cgroup2"),
  ]
  for m in Early:
    try: createDir(m.dst)
    except OSError: discard
    if mountFs(m.src.cstring, m.dst.cstring, m.fs.cstring, 0.culong, nil) != 0:
      if osLastError().int != EBUSY:
        log "warn", "could not mount " & m.dst & " (" & m.fs & ")"

# --- Spawning ----------------------------------------------------------------

proc spawn(u: var Unit, conf: Confinement, lim: Limits,
           socks: seq[BoundSocket]): bool =
  ## fork, confine, exec. The child does its own setup and never returns.
  if u.svc.exec.len == 0:
    u.state = stFailed
    u.reason = "no exec declared"
    return false

  let cg = cgroup.create(u.svc.name, lim)
  let pid = fork()
  if pid < 0:
    u.state = stFailed
    u.reason = "fork failed"
    return false

  if pid == 0:
    # Child. Nothing here may allocate in a way that could fail silently, and
    # every failure is a hard exit — a child that half-configures itself and
    # then execs is a service running with privileges it was not granted.
    signals.unblockAll()
    discard setsid()
    if cg.len > 0: discard cgroup.attach(cg, getpid().int)
    putEnv("NOTIFY_SOCKET", NotifyPath)

    # A confinement that cannot be applied is a failure to start, never a
    # warning. A sandbox that might not be on is worse than none, because it
    # is trusted.
    try:
      conf.applyInChild()
    except SandboxError as e:
      stderr.writeLine "nexis-init: " & u.svc.name & ": " & e.msg
      quit(126)

    # A controlling terminal, when the service asked for one.
    #
    # All three descriptors and TIOCSCTTY, not just stdout: an interactive
    # program given only stdout draws its first frame and then blocks forever
    # on a read that can never return. Without the controlling terminal it
    # also gets no SIGINT and no window-size changes, so Ctrl-C would do
    # nothing and a resize would never be noticed.
    if u.svc.tty.len > 0:
      let fd = posix.open(u.svc.tty.cstring, O_RDWR or O_NOCTTY)
      if fd < 0:
        stderr.writeLine "nexis-init: " & u.svc.name & ": cannot open " &
                         u.svc.tty
        quit(126)
      discard dup2(fd, 0)
      discard dup2(fd, 1)
      discard dup2(fd, 2)
      if fd > 2: discard posix.close(fd)
      # setsid() above already detached us from any old terminal, which is
      # what makes this one able to become the controlling one.
      discard ioctl(0.cint, TIOCSCTTY.uint, 0.cint)

    # Socket activation: the listening fds are already bound, so a client can
    # have connected before this service ever ran.
    if socks.len > 0:
      if not dupOntoListenFds(socks):
        stderr.writeLine "nexis-init: " & u.svc.name & ": cannot hand over sockets"
        quit(126)
      for (k, v) in environmentFor(socks, getpid().int):
        putEnv(k, v)

    var argv: seq[string]
    for a in u.svc.exec: argv.add a
    let prog = argv[0]
    var cargs = allocCStringArray(argv)
    discard execvp(prog.cstring, cargs)
    # execvp only returns on failure.
    quit(127)

  # Parent. The pidfd is taken immediately, so the window in which only a PID
  # identifies the child is as short as it can be made.
  let pfd = pidfdOpen(pid)
  discard u.onSpawned(pid, pfd, nowMs())
  u.svc.cgroup = cg
  true

proc startReady(self: var Init) =
  ## Start everything whose requirements are satisfied. Called after every
  ## state change rather than once at boot, so a service that becomes ready
  ## late unblocks its dependants without a separate scheduler.
  for name in self.order:
    if name notin self.units: continue
    if self.units[name].state != stInactive: continue
    if not self.units[name].canStart(self.units): continue
    var u = self.units[name]
    log "info", "starting " & name
    let conf = self.confinement.getOrDefault(name, strictDefaults())
    let lim = self.limits.getOrDefault(name, defaultLimits())
    if spawn(u, conf, lim, socketsFor(self.sockets, name)):
      # Index before anything else can run: a service can write READY=1 before
      # this returns, and an unindexed sender is dropped.
      self.byPid[u.pid.int] = name
    else:
      log "error", name & ": " & u.reason
    self.units[name] = u

proc handleExit(self: var Init, pid: Pid, status: ExitStatus) =
  # Any process, supervised or not, may hold a sleep inhibitor. PID 1 learns
  # of every death, so this is the only place that can reliably clean them up —
  # and a leaked block inhibitor is why a laptop silently stops sleeping.
  self.byPid.del(pid.int)
  let dropped = self.sleeper.releaseByPid(pid.int)
  if dropped > 0:
    log "info", "released " & $dropped & " inhibitor(s) held by pid " & $pid

  for name, u in self.units.mpairs:
    if u.pid != pid: continue
    let act = u.onExit(status, nowMs())
    case act
    of acSpawn:
      log "warn", name & ": " & u.reason
      discard spawn(u, self.confinement.getOrDefault(name, strictDefaults()),
                    self.limits.getOrDefault(name, defaultLimits()),
                    socketsFor(self.sockets, name))
    of acMarkFailed:
      log "error", name & ": " & u.reason
    of acMarkFinished:
      log "info", name & ": " & u.reason
    else: discard
    return

# --- Shutdown ----------------------------------------------------------------

proc doShutdown(self: var Init, intent: Intent) {.noreturn.} =
  let plan = defaultPlan(intent)
  log "info", "shutting down (" & $intent & "), " &
              $(plan.totalDeadline() div 1000) & "s worst case"

  # Reverse dependency order: stopping a service while its dependants still
  # use it turns a clean shutdown into a cascade of error logs.
  log "info", describe(shStopServices)
  for name in stopOrder(self.order):
    if name notin self.units: continue
    var u = self.units[name]
    if u.beginStop(nowMs()) == acSendTerm and u.pidfd.isValid:
      discard u.pidfd.pidfdSendSignal(SIGTERM)
    self.units[name] = u
  discard waitForQuiet(plan.deadlines[shStopServices])

  log "info", describe(shKillRemaining)
  var cgs: seq[string]
  for _, u in self.units: cgs.add u.svc.cgroup
  discard killRemaining(cgs)
  discard waitForQuiet(plan.deadlines[shKillRemaining])

  log "info", describe(shKillAll)
  signalEverything(SIGTERM)
  discard waitForQuiet(2000)
  signalEverything(SIGKILL)
  discard waitForQuiet(plan.deadlines[shKillAll])

  log "info", describe(shFlush)
  flush()

  log "info", describe(shUnmount)
  var mounts: seq[string]
  try: mounts = parseMounts(readFile("/proc/mounts"))
  except IOError, OSError: discard
  discard unmountAll(mounts)
  discard remountRootReadOnly()

  log "info", describe(shFinal)
  finalise(intent)

# --- Main loop ---------------------------------------------------------------

proc run(self: var Init) =
  self.running = true
  self.startReady()

  while self.running:
    for ev in self.sigfd.read():
      case ev
      of seChild:
        # Drain: several children can die between two wakeups, and SIGCHLD
        # does not queue.
        while true:
          let (pid, status, got) = reapOne()
          if not got: break
          self.handleExit(pid, status)
        self.startReady()
      of seReboot: self.doShutdown(siReboot)
      of sePowerOff: self.doShutdown(siPowerOff)
      of seHalt: self.doShutdown(siHalt)
      of seReload: log "info", "reload is not implemented yet"
      of seTerm: log "warn", "SIGTERM to PID 1 has no meaning; ignoring"
      of seNone: discard

    # Readiness. A service that reports ready unblocks everything ordered
    # after it, so this runs before the deadline sweep — otherwise a service
    # that became ready this tick could still be killed by its own start
    # timeout in the same iteration.
    for note in self.notifySock.receive():
      let name = self.byPid.route(note)
      if name.len == 0 or name notin self.units: continue
      case note.kind
      of nkReady:
        if self.units[name].onReady(nowMs()) == acMarkRunning:
          log "info", name & " is ready"
          self.startReady()
      of nkWatchdog:
        self.units[name].onPing(nowMs())
      of nkStatus:
        log "info", name & ": " & note.value
      of nkStopping:
        log "info", name & " is stopping"
      of nkMainPid:
        # Advisory: a double-forking service names its real process. Accepted
        # only for a service we already track, so it cannot claim a stranger.
        let mp = note.mainPid()
        if mp > 0:
          self.byPid[mp] = name
          log "info", name & ": main pid is now " & $mp
      else: discard

    # Deadlines. Checked here rather than by timerfd until the loop grows a
    # need for sub-second precision; a 100ms tick is well inside every
    # timeout in the model.
    let now = nowMs()
    for name, u in self.units.mpairs:
      case u.onStartTimeout(now)
      of acSendTerm:
        log "warn", name & ": " & u.reason
        if u.pidfd.isValid: discard u.pidfd.pidfdSendSignal(SIGTERM)
      else: discard
      if u.onWatchdogTimeout(now) == acSendAbort:
        log "error", name & ": " & u.reason
        # SIGABRT, not SIGTERM: a wedged process will not handle SIGTERM
        # either, and the core dump says where it was stuck.
        if u.pidfd.isValid: discard u.pidfd.pidfdSendSignal(SIGABRT)

      if u.onStopTimeout(now) == acSendKill:
        log "warn", name & ": " & u.reason
        if u.pidfd.isValid: discard u.pidfd.pidfdSendSignal(SIGKILL)
        elif u.svc.cgroup.len > 0: discard cgroup.killAll(u.svc.cgroup)

    discard usleep(Useconds(100_000))

# --- Entry -------------------------------------------------------------------

proc usage() =
  echo """
nexis-init """ & Version & """ - PID 1 for NexisOS

  nexis-init                run as PID 1
  nexis-init --check        validate the service set and print the start order
  nexis-init --config DIR   configuration root (default /etc/nexis)
  nexis-init --version

Built on pidfd rather than SIGCHLD bookkeeping: a pidfd cannot be recycled onto
a different process, which removes the class of supervision bug where a slow
reaper signals a PID that has already been reused."""

proc printDiagnostics(set: ServiceSet) =
  for d in set.diagnostics:
    let level = if d.severity == sevError: "error" else: "warn"
    log level, d.format()

proc checkMode(root: string): int =
  ## Validate without starting anything. This is what makes a service set
  ## reviewable in CI: the same loading and the same checks the real boot does,
  ## with nothing spawned.
  echo "nexis-init ", Version
  echo ""
  echo "cgroup v2:      ", (if cgroup.isV2(): "available" else: "NOT AVAILABLE")
  let states = supportedStates()
  echo "sleep states:   ", (if states.len > 0: states.join(" ") else: "none")
  echo "preferred:      ", (if bestState(states).len > 0: bestState(states)
                            else: "n/a")
  let armed = armedSources(readWakeupSources())
  echo "armed wakeups:  ", (if armed.len > 0: armed.join(" ") else: "none")
  echo "pidfd:          ", (if pidfdOpen(getpid()).isValid: "available"
                            else: "NOT AVAILABLE (needs Linux 5.3+)")
  echo "notify socket:  ", NotifyPath
  echo ""

  if not dirExists(root):
    echo "no configuration at ", root
    return 2

  let set = loadServiceSet(root)
  echo root, ": ", set.services.len, " service(s)"
  for d in set.diagnostics:
    echo "  ", (if d.severity == sevError: "error" else: "warn"), ": ",
         d.format()

  if set.hasErrors():
    echo ""
    echo set.errorCount(), " error(s). Nothing would start."
    return 2

  if set.services.len > 0:
    echo ""
    echo "start order:"
    for i, name in set.order:
      let svc = set.services[name]
      echo "  ", i + 1, ". ", name,
           (if svc.oneshot: "  (oneshot)" else: ""),
           (if svc.requires.len > 0: "  requires " & svc.requires.join(", ")
            else: "")
    echo ""
    echo "stop order is the reverse."
  0

when isMainModule:
  var args: seq[string]
  for i in 1 .. paramCount(): args.add paramStr(i)

  if "--version" in args:
    echo "nexis-init ", Version
    quit(0)
  if "--help" in args or "-h" in args:
    usage()
    quit(0)
  var configRoot = DefaultConfigRoot
  for i, a in args:
    if a == "--config" and i + 1 < args.len: configRoot = args[i + 1]
    elif a.startsWith("--config="): configRoot = a[9 .. ^1]

  if "--check" in args:
    quit(checkMode(configRoot))

  if getpid() != 1:
    stderr.writeLine "nexis-init must run as PID 1."
    stderr.writeLine "  Use --check to validate this machine's support instead."
    quit(1)

  log "info", "nexis-init " & Version
  mountEarly()

  var self = Init(units: initTable[string, Unit](), intent: siPowerOff,
                  sleeper: newSleepManager())

  let set = loadServiceSet(configRoot)
  printDiagnostics(set)
  if set.hasErrors():
    # Refuse rather than boot a partial system. A machine that silently omits
    # a service looks fine and is not, which is strictly worse than one that
    # stops and names the file.
    log "error", $set.errorCount() & " error(s) in " & configRoot &
                 "; refusing to start a partial system"
    log "error", "boot with init=/bin/sh to repair, or fix the declaration"
    quit(2)

  for name, svc in set.services:
    self.units[name] = initUnit(svc)
  self.confinement = set.confinement
  self.limits = set.limits
  self.order = set.order
  log "info", $self.units.len & " service(s) declared"
  self.byPid = initTable[int, string]()
  try: createDir(NotifyDir)
  except OSError: discard
  self.notifySock = openNotifySocket(NotifyPath)
  if self.notifySock.fd < 0:
    # Not fatal, but it changes behaviour enough to be worth saying: every
    # `readiness = "notify"` service will now stall until its start timeout.
    log "warn", "could not open " & NotifyPath &
                "; notify services will wait for their start timeout"

  self.sigfd = openSignalFd()
  if self.sigfd.fd < 0:
    log "error", "signalfd failed; cannot supervise anything"
    quit(1)

  self.run()
  # The loop only exits through doShutdown, which does not return. Reaching
  # here means a bug, and a PID 1 that returns causes a kernel panic — so it
  # halts deliberately with a message instead.
  log "error", "main loop exited; halting"
  finalise(siHalt)
