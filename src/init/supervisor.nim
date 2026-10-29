## The service state machine and restart policy.
##
## Kept free of syscalls on purpose. Every decision a supervisor makes — is this
## exit a failure, should it restart, has it flapped enough to give up, has it
## taken too long to become ready — is a pure function of the service's
## declaration, its history, and the current time. Making them pure means they
## are testable without spawning anything, and supervision bugs are the kind
## that otherwise surface once a month in production.

import std/[posix, tables]
import ./process, ./service

type
  State* = enum
    stInactive        ## not started
    stStarting        ## spawned, not yet ready
    stRunning         ## ready
    stStopping        ## SIGTERM sent, waiting
    stFailed          ## gave up
    stFinished        ## a oneshot that completed cleanly

  Unit* = object
    svc*: Service
    state*: State
    pid*: Pid
    pidfd*: Pidfd
    startedAt*: int64          ## ms
    readyAt*: int64
    stopDeadline*: int64
    restarts*: seq[int64]      ## timestamps, for the flap window
    lastExit*: ExitStatus
    reason*: string            ## why it is in this state, for the operator
    lastPing*: int64           ## last WATCHDOG=1, ms

  Action* = enum
    acNothing
    acSpawn
    acSendTerm
    acSendKill
    acSendAbort
    acMarkFailed
    acMarkFinished
    acMarkRunning

func initUnit*(s: Service): Unit =
  Unit(svc: s, state: stInactive, pid: Pid(0), pidfd: InvalidPidfd)

func isUp*(u: Unit): bool = u.state in {stRunning, stFinished}
func isSettled*(u: Unit): bool =
  u.state in {stInactive, stRunning, stFailed, stFinished}

# --- Restart policy ----------------------------------------------------------

func exitIsFailure*(u: Unit, e: ExitStatus): bool =
  ## A oneshot exiting 0 has succeeded; a long-running service exiting 0 has
  ## still stopped when it should not have. Same status word, opposite meaning,
  ## which is why this consults the declaration rather than the code alone.
  if not e.exited: return true
  if u.svc.oneshot: return e.code != 0
  true

func shouldRestart*(u: Unit, e: ExitStatus): bool =
  case u.svc.restart
  of rpNever: false
  of rpAlways: not u.svc.oneshot
  of rpOnFailure: u.exitIsFailure(e)

func recentRestarts*(u: Unit, now: int64): int =
  ## Restarts inside the flap window. A sliding window rather than a lifetime
  ## counter: a service that restarted three times last March is healthy, and
  ## a lifetime counter would eventually refuse to restart it forever.
  for t in u.restarts:
    if now - t <= int64(u.svc.restartWindow): inc result

func isFlapping*(u: Unit, now: int64): bool =
  u.svc.maxRestarts > 0 and u.recentRestarts(now) >= u.svc.maxRestarts

func restartDelay*(u: Unit, now: int64): int =
  ## Back off as a service flaps, capped. A fixed delay lets a service that
  ## crashes instantly consume a core spawning; unbounded backoff means a
  ## service that recovers is never noticed.
  let n = u.recentRestarts(now)
  var d = u.svc.restartSec
  for _ in 0 ..< min(n, 5): d = d * 2
  min(d, 30_000)

# --- Transitions -------------------------------------------------------------

func onExit*(u: var Unit, e: ExitStatus, now: int64): Action =
  ## What to do about a process that just died. The single place exit is
  ## interpreted, so "restarted unexpectedly" and "failed" cannot drift apart.
  u.lastExit = e
  u.pid = Pid(0)

  if u.state == stStopping:
    u.state = stInactive
    u.reason = "stopped"
    return acNothing

  if u.svc.oneshot and e.isClean():
    u.state = stFinished
    u.reason = "completed"
    return acMarkFinished

  if not u.shouldRestart(e):
    u.state = (if u.exitIsFailure(e): stFailed else: stInactive)
    u.reason = e.describe()
    return (if u.state == stFailed: acMarkFailed else: acNothing)

  if u.isFlapping(now):
    # Giving up is a feature. A service restarted forever hides its own
    # failure: the logs fill, the machine looks busy, and nothing says the
    # system is not working.
    u.state = stFailed
    u.reason = "restarted " & $u.recentRestarts(now) & " times in " &
               $(u.svc.restartWindow div 1000) & "s; giving up"
    return acMarkFailed

  u.restarts.add now
  u.state = stStarting
  u.reason = "restarting after " & e.describe()
  acSpawn

func onReady*(u: var Unit, now: int64): Action =
  ## sd_notify READY=1, or the equivalent for other readiness kinds.
  if u.state != stStarting: return acNothing
  u.state = stRunning
  u.readyAt = now
  u.reason = "ready"
  acMarkRunning

func onSpawned*(u: var Unit, pid: Pid, pfd: Pidfd, now: int64): Action =
  u.pid = pid
  u.pidfd = pfd
  u.startedAt = now
  u.state = stStarting
  u.reason = "starting"
  # A service with no readiness protocol is running the moment it is spawned.
  # Pretending otherwise would stall every dependant behind a signal that is
  # never going to arrive.
  if u.svc.readiness == rdImmediate: u.onReady(now) else: acNothing

# --- Watchdog ----------------------------------------------------------------
#
# A service can be running and useless: the process is alive, the port is open,
# and the event loop is wedged. Supervision that only watches for exit cannot
# see that, which is the gap the watchdog closes.
#
# It is opt-in per service and off by default, deliberately. A watchdog on a
# service that does not ping is a service that gets killed every interval, and
# the resulting restart loop looks exactly like a crash — so arming one is a
# statement that the service implements the protocol.

func watchdogArmed*(u: Unit): bool =
  u.svc.watchdogSec > 0 and u.state == stRunning

func onPing*(u: var Unit, now: int64) =
  u.lastPing = now

func watchdogExpired*(u: Unit, now: int64): bool =
  if not u.watchdogArmed(): return false
  # A service that has never pinged is measured from when it became ready, not
  # from epoch — otherwise arming a watchdog kills the service instantly.
  let since = if u.lastPing > 0: u.lastPing else: u.readyAt
  if since <= 0: return false
  now - since > int64(u.svc.watchdogSec)

func onWatchdogTimeout*(u: var Unit, now: int64): Action =
  ## SIGABRT rather than SIGTERM: a wedged process will not handle SIGTERM
  ## either, and SIGABRT produces a core dump that says where it was stuck.
  ## Killing it without that evidence means the next occurrence is just as
  ## mysterious as this one.
  if not u.watchdogExpired(now): return acNothing
  u.state = stStopping
  u.stopDeadline = now + int64(u.svc.stopTimeout)
  u.reason = "watchdog: no ping for " & $(u.svc.watchdogSec div 1000) & "s"
  acSendAbort

func onStartTimeout*(u: var Unit, now: int64): Action =
  ## A service that never reports ready must not hold the boot open forever.
  if u.state != stStarting: return acNothing
  if u.svc.startTimeout <= 0: return acNothing
  if now - u.startedAt < int64(u.svc.startTimeout): return acNothing
  u.state = stStopping
  u.stopDeadline = now + int64(u.svc.stopTimeout)
  u.reason = "did not become ready within " &
             $(u.svc.startTimeout div 1000) & "s"
  acSendTerm

func beginStop*(u: var Unit, now: int64): Action =
  if u.state in {stInactive, stFailed, stFinished}: return acNothing
  u.state = stStopping
  u.stopDeadline = now + int64(u.svc.stopTimeout)
  u.reason = "stopping"
  acSendTerm

func onStopTimeout*(u: var Unit, now: int64): Action =
  ## Every deadline escalates rather than waits. This is the rule that keeps a
  ## machine from sitting in "A stop job is running" indefinitely — the single
  ## most visible way systemd fails in front of a user.
  if u.state != stStopping: return acNothing
  if now < u.stopDeadline: return acNothing
  u.reason = "did not exit within " & $(u.svc.stopTimeout div 1000) &
             "s; killing"
  acSendKill

# --- Readiness gating --------------------------------------------------------

func canStart*(u: Unit, units: Table[string, Unit]): bool =
  ## A service starts once everything it requires is up. `wants` does not gate:
  ## that is the difference between the two, and the reason both exist.
  for dep in u.svc.requires:
    if dep notin units: return false
    if not units[dep].isUp(): return false
  true

func blockedBy*(u: Unit, units: Table[string, Unit]): seq[string] =
  ## What is holding this back. Exists so an operator is never left guessing
  ## why a service is still `stInactive` three minutes into a boot.
  for dep in u.svc.requires:
    if dep notin units: result.add dep & " (not declared)"
    elif units[dep].state == stFailed: result.add dep & " (failed)"
    elif not units[dep].isUp(): result.add dep & " (" & $units[dep].state & ")"
