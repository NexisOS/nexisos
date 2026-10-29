## Suspend, resume, inhibitors, and wakeup policy.
##
## This exists because of a specific, common failure: a machine that cycles
## between suspend and resume, or between screen-off and screen-on, without
## ever settling. The usual root cause is above PID 1 — a compositor re-enabling
## outputs when a monitor drops its hotplug-detect line on DPMS-off, or a device
## whose wakeup is armed resuming the machine the moment it suspends.
##
## Init cannot fix either of those. What it can do is refuse to be the thing
## that makes them unbounded:
##
##   1. **Suspend is idempotent.** A request while a suspend is in flight is
##      dropped, not queued. systemd-logind will happily accept overlapping
##      requests, and a power manager with a resetting idle timer can then
##      issue several per second.
##   2. **Thrash is detected and stopped.** Suspend/resume cycles inside a
##      window are counted exactly like service restarts are counted in
##      `supervisor.nim`, and past a threshold the machine stays awake and says
##      why. Staying awake is the better failure: the user sees a laptop that
##      will not sleep, rather than a screen strobing at 2Hz.
##   3. **Wakeup sources are declared.** A machine that resumes instantly
##      because a device is armed is a configuration error, and in a
##      declarative system that fact belongs in the configuration rather than
##      in whatever the firmware left in /proc/acpi/wakeup.
##
## The inhibitor model is logind's, because that is what PowerDevil,
## GNOME Settings Daemon and every media player already speak. Reducing
## migration cost is the goal; reproducing systemd is not.

import std/strutils

type
  InhibitWhat* = enum
    ihSleep = "sleep"
    ihShutdown = "shutdown"
    ihIdle = "idle"
    ihHandlePowerKey = "handle-power-key"
    ihHandleLidSwitch = "handle-lid-switch"

  InhibitMode* = enum
    imDelay      ## hold sleep briefly to finish work
    imBlock      ## refuse sleep entirely

  Inhibitor* = object
    id*: int
    what*: set[InhibitWhat]
    who*: string          ## "PowerDevil"
    why*: string          ## "Playing video"
    mode*: InhibitMode
    pid*: int
    takenAt*: int64

  SleepState* = enum
    slAwake
    slPreparing          ## delay inhibitors are being waited on
    slSuspending         ## writing to /sys/power/state
    slResuming
    slRefused            ## thrashing; deliberately staying awake

  SleepManager* = object
    state*: SleepState
    inhibitors*: seq[Inhibitor]
    nextId*: int
    cycles*: seq[int64]           ## suspend timestamps, for thrash detection
    delayMaxMs*: int
    thrashWindowMs*: int
    maxCyclesInWindow*: int
    refusedReason*: string
    preparingSince*: int64

func newSleepManager*(): SleepManager =
  ## Five seconds of delay matches logind's `InhibitDelayMaxSec` default, so
  ## software written against logind behaves the same here.
  ##
  ## Three cycles in two minutes is the thrash threshold. A user who suspends,
  ## resumes to check something, and suspends again will do that twice; a
  ## broken DPMS loop does it several times a second.
  SleepManager(state: slAwake, nextId: 1, delayMaxMs: 5000,
               thrashWindowMs: 120_000, maxCyclesInWindow: 3)

# --- Inhibitors --------------------------------------------------------------

func take*(m: var SleepManager, what: set[InhibitWhat], who, why: string,
           mode: InhibitMode, pid: int, now: int64): int =
  ## Returns the lock id. The caller holds it until it releases it or dies.
  result = m.nextId
  inc m.nextId
  m.inhibitors.add Inhibitor(id: result, what: what, who: who, why: why,
                             mode: mode, pid: pid, takenAt: now)

func release*(m: var SleepManager, id: int): bool =
  for i, inh in m.inhibitors:
    if inh.id == id:
      m.inhibitors.delete(i)
      return true
  false

func releaseByPid*(m: var SleepManager, pid: int): int =
  ## Drop every lock held by a dead process.
  ##
  ## This is not housekeeping. A crashed media player leaving a block inhibitor
  ## behind is the classic "my laptop stopped sleeping and nothing says why"
  ## bug, and it persists until reboot. PID 1 already learns of every death, so
  ## it is the right place to clean up — and because supervision is pidfd-based,
  ## the death it learns about is genuinely that process.
  var kept: seq[Inhibitor]
  for inh in m.inhibitors:
    if inh.pid == pid: inc result
    else: kept.add inh
  m.inhibitors = kept

func blockers*(m: SleepManager, what: InhibitWhat): seq[Inhibitor] =
  for inh in m.inhibitors:
    if what in inh.what and inh.mode == imBlock: result.add inh

func delayers*(m: SleepManager, what: InhibitWhat): seq[Inhibitor] =
  for inh in m.inhibitors:
    if what in inh.what and inh.mode == imDelay: result.add inh

func explain*(m: SleepManager, what: InhibitWhat): string =
  ## Who is holding this, in one line. `systemd-inhibit --list` exists because
  ## this question is asked constantly; making it the text of the refusal
  ## itself means it never has to be asked.
  let b = m.blockers(what)
  if b.len == 0: return "nothing is inhibiting " & $what
  var parts: seq[string]
  for inh in b: parts.add inh.who & " (" & inh.why & ", pid " & $inh.pid & ")"
  "inhibited by " & parts.join("; ")

# --- Thrash detection --------------------------------------------------------

func recentCycles*(m: SleepManager, now: int64): int =
  for t in m.cycles:
    if now - t <= int64(m.thrashWindowMs): inc result

func isThrashing*(m: SleepManager, now: int64): bool =
  m.maxCyclesInWindow > 0 and m.recentCycles(now) >= m.maxCyclesInWindow

# --- The sequence ------------------------------------------------------------

type SleepDecision* = enum
  sdProceed          ## no blockers, no delayers: suspend now
  sdWaitForDelays    ## delay inhibitors present; wait, bounded
  sdBlocked          ## a block inhibitor refuses
  sdAlreadyInFlight  ## a suspend is already happening
  sdThrashing        ## too many cycles; staying awake on purpose

func requestSleep*(m: var SleepManager, now: int64): SleepDecision =
  ## The whole point of this function is that it can say no.
  if m.state != slAwake and m.state != slRefused:
    # Dropped, not queued. A power manager whose idle timer keeps resetting
    # can otherwise issue several requests per second, and each one restarts
    # the sequence before the last finished.
    return sdAlreadyInFlight

  if m.isThrashing(now):
    m.state = slRefused
    m.refusedReason =
      "suspended " & $m.recentCycles(now) & " times in " &
      $(m.thrashWindowMs div 1000) & "s; staying awake. Something is waking " &
      "the machine or resetting the idle timer - check wakeup sources and " &
      "the display configuration."
    return sdThrashing

  if m.blockers(ihSleep).len > 0:
    return sdBlocked

  if m.delayers(ihSleep).len > 0:
    m.state = slPreparing
    m.preparingSince = now
    return sdWaitForDelays

  m.state = slSuspending
  m.cycles.add now
  sdProceed

func delayExpired*(m: SleepManager, now: int64): bool =
  m.state == slPreparing and now - m.preparingSince >= int64(m.delayMaxMs)

func proceedAfterDelays*(m: var SleepManager, now: int64): bool =
  ## Called when every delay inhibitor has released, or the deadline passed.
  ## A hung inhibitor cannot hold sleep open forever — the same escalate-rather-
  ## than-wait rule the shutdown sequence follows.
  if m.state != slPreparing: return false
  m.state = slSuspending
  m.cycles.add now
  true

func onResume*(m: var SleepManager, now: int64) =
  m.state = slAwake
  if m.isThrashing(now):
    m.state = slRefused
    m.refusedReason = "suspend/resume cycled " & $m.recentCycles(now) &
                      " times in " & $(m.thrashWindowMs div 1000) & "s"

func clearRefusal*(m: var SleepManager) =
  ## A refusal is not permanent. Cleared on an explicit user request — a lid
  ## close or a menu choice — because the user asking directly is different
  ## from an idle timer asking on their behalf.
  m.state = slAwake
  m.cycles = @[]
  m.refusedReason = ""

# --- Wakeup sources ----------------------------------------------------------

type WakeupSource* = object
  device*: string
  sysfsPath*: string
  enabled*: bool

func parseAcpiWakeup*(content: string): seq[WakeupSource] =
  ## `/proc/acpi/wakeup` is columnar: device, S-state, status, sysfs node.
  ## A device armed here can resume the machine the instant it suspends, which
  ## presents to the user as "it will not stay asleep" with nothing to read.
  for line in content.splitLines():
    let f = line.splitWhitespace()
    if f.len < 3: continue
    if f[0] == "Device": continue          ## header
    result.add WakeupSource(
      device: f[0],
      enabled: f[2].startsWith("*enabled"),
      sysfsPath: (if f.len >= 4: f[3] else: ""))

func armedSources*(sources: seq[WakeupSource]): seq[string] =
  for s in sources:
    if s.enabled: result.add s.device

func unexpectedlyArmed*(sources: seq[WakeupSource],
                        declared: seq[string]): seq[string] =
  ## Armed on the machine but not in the configuration.
  ##
  ## This is the declarative payoff: the set of things that may wake the
  ## machine is a stated fact, not whatever the firmware happened to leave
  ## enabled. A laptop that resumes immediately becomes a diff instead of a
  ## mystery.
  for s in sources:
    if s.enabled and s.device notin declared: result.add s.device

# --- Applying ----------------------------------------------------------------

const
  PowerStatePath* = "/sys/power/state"
  AcpiWakeupPath* = "/proc/acpi/wakeup"

proc readWakeupSources*(path = AcpiWakeupPath): seq[WakeupSource] =
  try: parseAcpiWakeup(readFile(path))
  except IOError, OSError: @[]

proc setWakeup*(device: string, enabled: bool, path = AcpiWakeupPath): bool =
  ## Toggling is a write of the device name; the file has no way to set a
  ## state directly, so the current state is read first.
  let current = readWakeupSources(path)
  for s in current:
    if s.device != device: continue
    if s.enabled == enabled: return true
    try:
      writeFile(path, device)
      return true
    except IOError, OSError:
      return false
  false

proc supportedStates*(path = PowerStatePath): seq[string] =
  try:
    for s in readFile(path).strip().splitWhitespace(): result.add s
  except IOError, OSError: discard

func bestState*(supported: seq[string]): string =
  ## Prefer suspend-to-idle where the firmware offers it, because on modern
  ## laptops `deep` is frequently the broken path — many vendors ship an S3
  ## implementation that resumes spuriously, which is exactly the symptom this
  ## module exists to bound.
  if "mem" in supported and "freeze" notin supported: return "mem"
  if "freeze" in supported: return "freeze"
  if "mem" in supported: return "mem"
  if supported.len > 0: return supported[0]
  ""
