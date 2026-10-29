## Shutdown, with a deadline on every step.
##
## The requirement is one sentence: **the machine must never sit indefinitely in
## "stopping".** "A stop job is running for ... (1min 30s / no limit)" is the
## most visible way an init system fails in front of a user, and it happens
## because a step is allowed to wait rather than escalate.
##
## Every phase here has a bound, and exceeding a bound moves to something
## stronger. The sequence always terminates.

import std/[algorithm, posix, strutils]
import ./cgroup

type
  Intent* = enum
    siReboot = "reboot"
    siPowerOff = "poweroff"
    siHalt = "halt"

  Phase* = enum
    shStopServices    ## SIGTERM in reverse dependency order
    shKillRemaining   ## SIGKILL what is left in each cgroup
    shKillAll         ## SIGKILL everything on the machine
    shFlush           ## sync filesystem state
    shUnmount         ## unmount what can be unmounted
    shFinal           ## reboot(2)

  Plan* = object
    intent*: Intent
    deadlines*: array[Phase, int]     ## ms per phase

func defaultPlan*(intent: Intent): Plan =
  ## Ninety seconds total, worst case. Chosen so an impatient user does not
  ## reach for the power button — which is the actual failure mode, because a
  ## hard power cut during unmount is exactly what the shutdown was protecting
  ## against.
  result.intent = intent
  result.deadlines[shStopServices] = 30_000
  result.deadlines[shKillRemaining] = 5_000
  result.deadlines[shKillAll] = 10_000
  result.deadlines[shFlush] = 30_000
  result.deadlines[shUnmount] = 15_000
  result.deadlines[shFinal] = 0

func totalDeadline*(p: Plan): int =
  for ph in Phase: result += p.deadlines[ph]

func nextPhase*(p: Phase): Phase =
  if p == shFinal: shFinal else: succ(p)

func describe*(p: Phase): string =
  case p
  of shStopServices: "stopping services"
  of shKillRemaining: "killing what did not stop"
  of shKillAll: "killing remaining processes"
  of shFlush: "flushing filesystems"
  of shUnmount: "unmounting"
  of shFinal: "shutting down"

# --- reboot(2) ---------------------------------------------------------------

const
  # The kernel's magic values. They are unsigned 32-bit, so they are written
  # as int64 and narrowed at the call — two of the three do not fit in a
  # 32-bit signed int.
  LINUX_REBOOT_CMD_RESTART* = 0x01234567'i64
  LINUX_REBOOT_CMD_HALT* = 0xCDEF0123'i64
  LINUX_REBOOT_CMD_POWER_OFF* = 0x4321FEDC'i64

proc reboot(cmd: cint): cint {.importc, header: "<sys/reboot.h>".}

# Nim's posix module does not wrap these two.
proc umount(target: cstring): cint {.importc, header: "<sys/mount.h>".}
proc mount(source, target, fstype: cstring, flags: culong,
           data: pointer): cint {.importc, header: "<sys/mount.h>".}

const
  MS_RDONLY = 1.culong
  MS_REMOUNT = 32.culong

func rebootCommand*(i: Intent): int64 =
  case i
  of siReboot: LINUX_REBOOT_CMD_RESTART
  of siPowerOff: LINUX_REBOOT_CMD_POWER_OFF
  of siHalt: LINUX_REBOOT_CMD_HALT

# --- Phases ------------------------------------------------------------------

proc killRemaining*(cgroups: seq[string]): int =
  ## Kill whatever survived SIGTERM, per cgroup.
  ##
  ## Per cgroup rather than by PID: a service that double-forked has children
  ## PID 1 never learned about, and the cgroup is the only structure that knows
  ## the full set. This is the step that makes "stopped" mean stopped.
  for path in cgroups:
    if path.len == 0: continue
    if not cgroup.isEmpty(path):
      discard cgroup.killAll(path)
      inc result

proc signalEverything*(sig: int) =
  ## The blunt instrument. `kill(-1, sig)` reaches every process the caller may
  ## signal except itself, so anything not in a service cgroup — a stray login
  ## shell, an orphan PID 1 inherited — is included.
  discard posix.kill(Pid(-1), cint(sig))

proc waitForQuiet*(timeoutMs: int): bool =
  ## Reap until nothing is left, or the deadline passes. Returns false on
  ## timeout, which is not fatal: the next phase is stronger.
  var waited = 0
  const Slice = 50
  while waited < timeoutMs:
    var status: cint
    let pid = waitpid(Pid(-1), status, WNOHANG)
    if pid < 0: return true          ## ECHILD: nothing left
    if pid == 0:
      discard usleep(Useconds(Slice * 1000))
      waited += Slice
  false

proc flush*() =
  ## `sync(2)` before unmounting. Cheap, and the difference between a clean
  ## filesystem and a journal replay on the next boot.
  sync()

proc parseMounts*(content: string): seq[string] =
  ## Mount points from /proc/mounts, deepest first.
  ##
  ## Deepest first because unmounting a parent before its child fails with
  ## EBUSY, and the natural file order is parents first. Virtual filesystems
  ## are skipped: unmounting /proc while still running is not useful, and the
  ## kernel handles them at reboot.
  var points: seq[string]
  for line in content.splitLines():
    let f = line.splitWhitespace()
    if f.len < 3: continue
    let point = f[1]
    let fstype = f[2]
    if fstype in ["proc", "sysfs", "devtmpfs", "devpts", "cgroup2",
                  "securityfs", "efivarfs", "bpf", "tracefs", "pstore",
                  "mqueue", "hugetlbfs", "debugfs", "configfs"]:
      continue
    if point == "/": continue        ## remounted read-only, never unmounted
    points.add point
  # Sort by depth descending, then by name, so the order is deterministic.
  points.sort(proc (a, b: string): int =
    let da = a.count('/')
    let db = b.count('/')
    if da != db: db - da else: cmp(a, b))
  points

proc unmountAll*(points: seq[string]): int =
  for p in points:
    if umount(p.cstring) == 0: inc result

proc remountRootReadOnly*(): bool =
  ## The last thing before reboot(2). Even if an unmount failed, a read-only
  ## root means the next boot does not replay a journal.
  mount(nil, "/".cstring, nil, MS_REMOUNT or MS_RDONLY, nil) == 0

proc finalise*(intent: Intent) {.noreturn.} =
  ## reboot(2) does not return. If it somehow does, the machine is in a state
  ## with no correct next action, so it halts rather than continuing to run an
  ## init that has already torn down the system it was managing.
  discard reboot(cast[cint](uint32(rebootCommand(intent))))
  discard reboot(cast[cint](uint32(LINUX_REBOOT_CMD_HALT)))
  while true: discard usleep(Useconds(1_000_000))
