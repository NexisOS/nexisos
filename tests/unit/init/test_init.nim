import std/[posix, strutils, tables, unittest]
import ../../../src/init/[process, signals, service, supervisor, cgroup,
                          sandbox, shutdown]

suite "exit status":
  test "a clean exit and a failure are distinguished":
    check decodeWaitStatus(0).isClean()
    check decodeWaitStatus(3 shl 8).code == 3
    check not decodeWaitStatus(3 shl 8).isClean()

  test "a signalled death is not an exit":
    let e = decodeWaitStatus(11)
    check not e.exited
    check e.signal == 11
    check "signal 11" in e.describe()

  test "a core dump is reported":
    check decodeWaitStatus(11 or 0x80).coreDumped

suite "signals":
  test "each handled signal has exactly one meaning":
    check classify(SIGCHLD) == seChild
    check classify(SIGINT) == seReboot
    check classify(SIGUSR2) == sePowerOff
    check classify(SIGHUP) == seReload

  test "an unhandled signal is not silently reinterpreted":
    check classify(28) == seNone      ## SIGWINCH

suite "dependency ordering":
  proc graph(): Table[string, Service] =
    result = initTable[string, Service]()
    for n in ["network", "postgres", "nginx", "cron"]:
      result[n] = defaultService(n)
    result["postgres"].requires = @["network"]
    result["nginx"].requires = @["network", "postgres"]

  test "dependencies start before their dependants":
    let r = graph().resolveOrder()
    check r.cycle.len == 0
    check r.order.find("network") < r.order.find("postgres")
    check r.order.find("postgres") < r.order.find("nginx")

  test "requires implies after, without it being declared":
    # The single most common source of confusion in systemd units is that a
    # dependency does not imply an ordering.
    var s = defaultService("x")
    s.requires = @["y"]
    check "y" in s.orderingDeps()

  test "the order is deterministic across runs":
    # A race that only fires in one ordering would otherwise appear and vanish
    # across reboots of an identical machine.
    let a = graph().resolveOrder().order
    for _ in 0 .. 5:
      check graph().resolveOrder().order == a

  test "a cycle is reported as the path, not just as a fact":
    var g = graph()
    g["network"].requires = @["nginx"]
    let r = g.resolveOrder()
    check r.cycle.len > 0
    check r.cycle[0] == r.cycle[^1]     ## it closes

  test "a requires on a name that does not exist is caught":
    var g = graph()
    g["nginx"].requires = @["nonexistent"]
    check "nonexistent" in g.resolveOrder().missing

  test "a wants on an absent name is not an error":
    # That is how an optional component is expressed.
    var g = graph()
    g["nginx"].wants = @["optional-thing"]
    check g.resolveOrder().missing.len == 0

  test "stop order is the reverse of start order":
    # Stopping in start order tears down a dependency while its dependants are
    # still using it.
    let r = graph().resolveOrder()
    let stopped = stopOrder(r.order)
    check stopped.len == r.order.len
    for i in 0 ..< r.order.len:
      check stopped[i] == r.order[r.order.high - i]

  test "an empty service set resolves rather than crashing":
    check initTable[string, Service]().resolveOrder().order.len == 0

suite "restart policy":
  proc unit(policy: RestartPolicy, oneshot = false): Unit =
    var s = defaultService("svc")
    s.restart = policy
    s.oneshot = oneshot
    initUnit(s)

  test "never means never, whatever the exit":
    check not unit(rpNever).shouldRestart(decodeWaitStatus(0))
    check not unit(rpNever).shouldRestart(decodeWaitStatus(11))

  test "on-failure restarts a crash but not a clean exit of a oneshot":
    check unit(rpOnFailure).shouldRestart(decodeWaitStatus(11))
    check not unit(rpOnFailure, oneshot = true)
      .shouldRestart(decodeWaitStatus(0))

  test "a long-running service exiting 0 is still a failure":
    # Same status word as a successful oneshot, opposite meaning: it stopped
    # when it should not have.
    check unit(rpOnFailure).shouldRestart(decodeWaitStatus(0))

  test "always does not resurrect a oneshot":
    check not unit(rpAlways, oneshot = true).shouldRestart(decodeWaitStatus(0))

suite "flap detection":
  test "restarts outside the window do not count":
    # A lifetime counter would eventually refuse to restart a healthy service
    # forever.
    var u = initUnit(defaultService("svc"))
    u.restarts = @[1000'i64, 2000, 3000]
    check u.recentRestarts(now = 1_000_000) == 0
    check u.recentRestarts(now = 3500) == 3

  test "enough restarts inside the window is flapping":
    var u = initUnit(defaultService("svc"))
    u.restarts = @[1000'i64, 1100, 1200, 1300, 1400]
    check u.isFlapping(1500)

  test "backoff grows and then caps":
    var u = initUnit(defaultService("svc"))
    let base = u.restartDelay(1000)
    u.restarts = @[900'i64, 950]
    check u.restartDelay(1000) > base
    u.restarts = @[900'i64, 910, 920, 930, 940, 950, 960, 970]
    check u.restartDelay(1000) <= 30_000

  test "giving up is a state, not an infinite loop":
    # A service restarted forever hides its own failure: logs fill, the machine
    # looks busy, and nothing says the system is not working.
    var u = initUnit(defaultService("svc"))
    u.restarts = @[1000'i64, 1010, 1020, 1030, 1040]
    check u.onExit(decodeWaitStatus(1 shl 8), 1050) == acMarkFailed
    check u.state == stFailed
    check "giving up" in u.reason

suite "state machine":
  test "a service with no readiness protocol is running once spawned":
    # Otherwise every dependant stalls behind a signal that never arrives.
    var u = initUnit(defaultService("svc"))
    check u.onSpawned(Pid(42), InvalidPidfd, 1000) == acMarkRunning
    check u.state == stRunning

  test "a notify service waits for READY=1":
    var s = defaultService("svc")
    s.readiness = rdNotify
    var u = initUnit(s)
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    check u.state == stStarting
    check u.onReady(1200) == acMarkRunning
    check u.state == stRunning

  test "a service that never reports ready is terminated, not waited on":
    var s = defaultService("svc")
    s.readiness = rdNotify
    s.startTimeout = 5000
    var u = initUnit(s)
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    check u.onStartTimeout(3000) == acNothing
    check u.onStartTimeout(7000) == acSendTerm
    check "did not become ready" in u.reason

  test "an exit during stopping is not a failure":
    var u = initUnit(defaultService("svc"))
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    discard u.beginStop(2000)
    check u.onExit(decodeWaitStatus(15), 2100) == acNothing
    check u.state == stInactive

  test "a stop deadline escalates to kill rather than waiting":
    # This is the rule that keeps a machine from sitting in "a stop job is
    # running" indefinitely.
    var s = defaultService("svc")
    s.stopTimeout = 5000
    var u = initUnit(s)
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    check u.beginStop(1000) == acSendTerm
    check u.onStopTimeout(3000) == acNothing
    check u.onStopTimeout(9000) == acSendKill

  test "a oneshot that completes is finished, not failed":
    var s = defaultService("migrate")
    s.oneshot = true
    var u = initUnit(s)
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    check u.onExit(decodeWaitStatus(0), 2000) == acMarkFinished
    check u.state == stFinished
    check u.isUp()

suite "readiness gating":
  proc pair(): Table[string, Unit] =
    result = initTable[string, Unit]()
    result["network"] = initUnit(defaultService("network"))
    var s = defaultService("nginx")
    s.requires = @["network"]
    s.wants = @["optional"]
    result["nginx"] = initUnit(s)

  test "a service waits for what it requires":
    var units = pair()
    check not units["nginx"].canStart(units)
    discard units["network"].onSpawned(Pid(1), InvalidPidfd, 0)
    check units["nginx"].canStart(units)

  test "wants does not gate, which is the difference from requires":
    var units = pair()
    discard units["network"].onSpawned(Pid(1), InvalidPidfd, 0)
    check units["nginx"].canStart(units)   ## 'optional' is absent

  test "an operator is told what is holding a service back":
    var units = pair()
    check units["nginx"].blockedBy(units).len == 1
    check "network" in units["nginx"].blockedBy(units)[0]

suite "cgroups":
  test "sizes parse with every common suffix":
    check parseSize("512M") == 512 * 1024 * 1024
    check parseSize("2G") == 2'i64 * 1024 * 1024 * 1024
    check parseSize("1024") == 1024

  test "an unparseable limit is rejected, not read as zero":
    # The kernel would read zero as "no memory at all".
    check parseSize("junk") == -1
    check parseSize("") == -1
    check parseSize("512X") == -1

  test "only non-default limits are written":
    var l = defaultLimits()
    check l.limitFiles().len == 0
    l.memoryMax = "512M"
    check ("memory.max", $(512 * 1024 * 1024)) in l.limitFiles()

  test "a bad size is not written at all":
    var l = defaultLimits()
    l.memoryMax = "nonsense"
    check l.limitFiles().len == 0

  test "PSI parsing distinguishes some from full":
    let p = parsePressure("some avg10=12.34 avg60=1.0\nfull avg10=70.5 avg60=2.0")
    check p.some10 == 12.34
    check p.full10 == 70.5

  test "pressure acts on full, not some":
    # 'some' fires whenever any task waits on memory, which is normal.
    check underPressure(Pressure(some10: 99.0, full10: 1.0)) == false
    check underPressure(Pressure(some10: 99.0, full10: 80.0))

suite "sandbox":
  test "the defaults deny rather than permit":
    # Permissive defaults mean every unaudited service is unconfined, and there
    # are always more of those than audited ones.
    let s = strictDefaults()
    check s.privateNetwork
    check s.privateTmp
    check s.noNewPrivileges

  test "namespace flags follow from what was asked for":
    var c = Confinement()
    check c.namespaceFlags() == 0
    c.privateNetwork = true
    check (c.namespaceFlags() and CLONE_NEWNET) != 0
    c.privateTmp = true
    check c.needsMountNamespace()

  test "a misspelt capability is caught, not silently dropped":
    # CAP_NET_BIND_SREVICE would otherwise leave a service unable to bind
    # port 80 with no indication why.
    check capIndex("CAP_NET_BIND_SERVICE") == 10
    check capIndex("CAP_NET_BIND_SREVICE") == -1
    var c = Confinement(capabilities: @["CAP_TYPO"])
    check c.validate().len == 1

  test "capability names are case-insensitive and trimmed":
    check capIndex(" cap_net_admin ") == capIndex("CAP_NET_ADMIN")

  test "relative paths in a confinement are rejected":
    var c = Confinement(readOnlyPaths: @["etc/passwd"])
    check c.validate().len == 1

  test "a contradictory confinement is surfaced":
    var c = Confinement(privateNetwork: true, capabilities: @["CAP_NET_ADMIN"])
    check c.validate().len == 1

suite "shutdown":
  test "every phase has a deadline, so the sequence terminates":
    let p = defaultPlan(siReboot)
    for ph in Phase:
      if ph != shFinal: check p.deadlines[ph] > 0

  test "the worst case is bounded and short enough not to be power-cycled":
    # A hard power cut during unmount is what the shutdown was protecting
    # against, so the total has to stay under an impatient user's patience.
    check defaultPlan(siReboot).totalDeadline() <= 120_000

  test "phases escalate and terminate at the final one":
    check nextPhase(shStopServices) == shKillRemaining
    check nextPhase(shFinal) == shFinal

  test "each intent maps to its own reboot command":
    check rebootCommand(siReboot) != rebootCommand(siPowerOff)
    check rebootCommand(siHalt) != rebootCommand(siReboot)

  test "mounts are unmounted deepest first":
    # Unmounting a parent before its child fails with EBUSY, and the natural
    # order in /proc/mounts is parents first.
    let m = parseMounts("""
/dev/sda1 / ext4 rw 0 0
/dev/sda2 /var ext4 rw 0 0
/dev/sda3 /var/lib/nexis ext4 rw 0 0
""")
    check m.find("/var/lib/nexis") < m.find("/var")

  test "virtual filesystems and root are not unmounted":
    let m = parseMounts("""
/dev/sda1 / ext4 rw 0 0
proc /proc proc rw 0 0
sysfs /sys sysfs rw 0 0
cgroup2 /sys/fs/cgroup cgroup2 rw 0 0
/dev/sda2 /home ext4 rw 0 0
""")
    check m == @["/home"]

  test "malformed lines are skipped rather than crashing shutdown":
    check parseMounts("garbage\n\n/dev/sda2 /home ext4 rw 0 0") == @["/home"]

suite "watchdog":
  proc armed(sec: int): Unit =
    var s = defaultService("svc")
    s.readiness = rdNotify
    s.watchdogSec = sec
    result = initUnit(s)
    discard result.onSpawned(Pid(42), InvalidPidfd, 1000)
    discard result.onReady(1000)

  test "off by default, because a watchdog on a service that cannot ping is a restart loop":
    var u = initUnit(defaultService("svc"))
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    check not u.watchdogArmed()
    check not u.watchdogExpired(999_999)

  test "a ping resets the deadline":
    var u = armed(5000)
    check not u.watchdogExpired(4000)
    u.onPing(4000)
    check not u.watchdogExpired(8000)
    check u.watchdogExpired(10_000)

  test "a service that never pings is measured from when it became ready":
    # Otherwise arming a watchdog kills the service instantly.
    var u = armed(5000)
    check not u.watchdogExpired(2000)
    check u.watchdogExpired(7000)

  test "expiry aborts rather than terminating":
    # A wedged process will not handle SIGTERM either; SIGABRT produces a core
    # dump that says where it was stuck.
    var u = armed(5000)
    check u.onWatchdogTimeout(2000) == acNothing
    check u.onWatchdogTimeout(7000) == acSendAbort
    check "watchdog" in u.reason

  test "the watchdog does not run while the service is starting":
    var s = defaultService("svc")
    s.readiness = rdNotify
    s.watchdogSec = 1000
    var u = initUnit(s)
    discard u.onSpawned(Pid(42), InvalidPidfd, 1000)
    check u.state == stStarting
    check not u.watchdogArmed()
