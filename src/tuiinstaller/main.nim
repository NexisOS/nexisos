## `nexis-installer` — entry point and event loop.
##
## The installer is a plain TUI. It reads a terminal and writes escape
## sequences, and it has no idea what is hosting it: cage + foot on the
## graphical path, tty1 when KMS fails, a serial line when there is no console
## at all. Keeping it host-agnostic is what makes the fallback free, and it is
## why this can be developed in an ordinary terminal without booting an ISO.
##
## The loop is: read a key (bounded wait), apply it, advance the tick, redraw
## the cells that changed. The bounded read is what sets the frame rate — there
## is no sleep and no timer thread. When nothing is animating the screen simply
## stops changing and the diff emits nothing.

import std/[os, osproc, strutils, terminal]
import ./term, ./ui, ./state, ./input, ./plan, ./installation,
       ./partition, ./disk, ./session

const
  Version = "0.1.0"
  Usage = """
nexis-installer - the NexisOS installer

  nexis-installer                 run the installer
  nexis-installer --dry-run       run it, but execute nothing
  nexis-installer --here          do not launch a compositor; draw here
  nexis-installer --surface       report which surface would be used, and why
  nexis-installer --plan          print the plan for the defaults and exit
  nexis-installer --version       print the version and exit
  nexis-installer --help          this text

--dry-run is not a separate code path. The installer builds the same ordered
list of commands either way; a dry run renders it instead of executing it, so
a dry run cannot diverge from what a real install would do.
"""

type Args = object
  dryRun: bool
  showPlan: bool
  here: bool
  surface: bool
  quit: bool
  code: int

proc parseArgs(): Args =
  for i in 1 .. paramCount():
    case paramStr(i)
    of "--dry-run", "-n": result.dryRun = true
    of "--plan": result.showPlan = true
    of "--here": result.here = true
    of "--surface": result.surface = true
    of "--version", "-V":
      echo "nexis-installer ", Version
      return Args(quit: true, code: 0)
    of "--help", "-h":
      echo Usage
      return Args(quit: true, code: 0)
    else:
      stderr.writeLine "unknown option: " & paramStr(i)
      stderr.writeLine Usage
      return Args(quit: true, code: 2)

proc probeDisks(): seq[Disk] =
  ## Real devices when we can see them, the sample set otherwise. Falling back
  ## rather than showing an empty list is what lets the wizard be walked end to
  ## end on a laptop without root.
  try:
    let (output, code) = execCmdEx("lsblk -dno NAME,SIZE,TYPE,MODEL")
    if code == 0:
      let found = parseLsblk(output)
      if found.len > 0: return found
  except OSError, IOError:
    discard
  sampleDisks()

# --- Key handling ------------------------------------------------------------

proc applyText(w: var Wizard, k: Key): bool =
  ## Typed input on a text row. Returns true if the key was consumed.
  var target: ptr string =
    case w.step
    of stSystem:
      case w.sel
      of 0: addr w.cfg.hostname
      of 1: addr w.cfg.timezone
      else: addr w.cfg.locale
    of stUser: addr w.cfg.username
    else: return false

  case k.kind
  of kChar:
    if target[].len < 63: target[].add k.ch
    true
  of kBackspace:
    if target[].len > 0: target[].setLen(target[].len - 1)
    true
  else:
    false

proc adjust(w: var Wizard, delta: int) =
  ## Left/right on an option row.
  case w.step
  of stPartition:
    if w.sel == 0: w.cfg.scheme = cycleScheme(w.cfg.scheme, delta)
    else: w.cfg.rootFs = cycleFs(w.cfg.rootFs, delta)
  of stUser:
    if w.sel == 1: w.cfg.profile = cycleProfile(w.cfg.profile, delta)
  of stDisk:
    discard        ## disks move with up/down, not left/right
  else: discard

proc handleKey(u: var Ui, k: Key): bool =
  ## Returns false when the installer should exit.
  case k.kind
  of kEscape:
    if u.wiz.editing:
      u.wiz.editing = false
      return true
    return false
  of kUp:
    u.wiz.editing = false
    dec u.wiz.sel
    if u.wiz.sel < 0: u.wiz.sel = max(u.wiz.rowCount() - 1, 0)
    u.wiz.clampSel()
  of kDown, kTab:
    u.wiz.editing = false
    inc u.wiz.sel
    if u.wiz.sel >= u.wiz.rowCount(): u.wiz.sel = 0
    u.wiz.clampSel()
  of kLeft:
    if u.wiz.editing:
      discard
    elif u.wiz.rowIsText():
      discard
    else:
      u.wiz.adjust(-1)
    if not u.wiz.editing and u.wiz.step == stWelcome:
      discard u.wiz.prev()
  of kRight:
    if u.wiz.rowIsText() or u.wiz.editing: discard
    else: u.wiz.adjust(1)
  of kEnter:
    case u.wiz.step
    of stDisk:
      if u.wiz.disks.len > 0:
        u.wiz.cfg.disk = u.wiz.disks[u.wiz.sel].device
      discard u.wiz.next()
    of stInstall:
      if not u.runner.started:
        u.runner = initRunner(u.wiz.cfg)
        u.runner.started = true
      elif u.runner.finished or u.runner.failed:
        return false
    of stSystem, stUser:
      if u.wiz.rowIsText() and not u.wiz.editing:
        u.wiz.editing = true
      else:
        u.wiz.editing = false
        discard u.wiz.next()
    else:
      discard u.wiz.next()
  of kBackspace:
    if u.wiz.editing:
      discard u.wiz.applyText(k)
    else:
      discard u.wiz.prev()
  of kChar:
    if u.wiz.editing:
      discard u.wiz.applyText(k)
    else:
      case k.ch.toLowerAscii()
      of 'q': return false
      of 'd':
        # Print the plan below the UI, on the normal screen, so it can be
        # scrolled back and read. A plan that only exists inside an alt-screen
        # frame is a plan nobody can check.
        stdout.write altScreenOff
        stdout.write renderPlan(u.wiz.cfg)
        stdout.write "\npress enter to return to the installer"
        stdout.flushFile()
        discard readLine(stdin)
        stdout.write altScreenOn
        u.scr = newScreen(detectCaps())
      of 'b': discard u.wiz.prev()
      of 'n': discard u.wiz.next()
      of 'e':
        if u.wiz.rowIsText(): u.wiz.editing = true
      else: discard
  else: discard
  true

proc statusFor(u: Ui): string =
  if u.wiz.editing:
    "typing   esc done   backspace delete"
  else:
    case u.wiz.step
    of stWelcome: "enter begin   Q quit"
    of stDisk:    "up/down choose   enter select   B back   Q quit"
    of stPartition, stUser:
      "up/down row   left/right change   enter next   B back   Q quit"
    of stSystem:  "up/down row   enter edit   B back   Q quit"
    of stReview:  "enter continue   D show plan   B back   Q quit"
    of stInstall:
      if u.runner.finished or u.runner.failed: "enter exit   Q quit"
      elif u.runner.started: "installing..."
      else: "enter start   D show plan   B back   Q quit"

# --- Main --------------------------------------------------------------------

proc runInstaller(dryRun: bool): int =
  var u = newUi(dryRun)
  u.wiz.disks = probeDisks()
  u.wiz.clampSel()
  u.runner = initRunner(u.wiz.cfg)

  let raw = enterRaw()
  stdout.write altScreenOn
  defer:
    stdout.write altScreenOff
    stdout.flushFile()
    leaveRaw(raw)

  var running = true
  while running:
    # Re-detect on every frame so a resized terminal is handled without a
    # SIGWINCH handler. Cheap: it is two ioctls, and the diff means an
    # unchanged screen still emits nothing.
    let caps = detectCaps()
    if caps.width != u.scr.width or caps.height != u.scr.height:
      u.scr = newScreen(caps)

    u.status = statusFor(u)
    u.drawFrame()
    stdout.write u.scr.render()
    stdout.flushFile()

    # One command per frame, so the spinner keeps turning through a long
    # mkfs and a stalled step is visibly stalled rather than indistinguishable
    # from a hang.
    if u.wiz.step == stInstall and u.runner.started and
       not u.runner.finished and not u.runner.failed:
      discard u.runner.step()

    let k = readKey()
    if k.kind != kNone:
      running = u.handleKey(k)
    inc u.tick

  if u.runner.failed: 1 else: 0

when isMainModule:
  let args = parseArgs()
  if args.quit:
    quit(args.code)

  if args.showPlan:
    var cfg = defaultConfig(dryRun = true)
    cfg.scheme = detectScheme()
    let disks = probeDisks()
    if disks.len > 0: cfg.disk = disks[0].device
    stdout.write renderPlan(cfg)
    quit(0)

  # Surface selection. The installer never links Wayland; it decides whether to
  # re-exec itself inside cage + foot, and otherwise draws where it already is.
  let p = probe()
  let (surface, why) = p.choose()

  if args.surface:
    echo "surface: ", surface
    if why.len > 0: echo "reason:  ", why
    echo "drm:     ", p.hasDrm
    echo "cage:    ", p.hasCage
    echo "foot:    ", p.hasFoot
    echo "serial:  ", p.isSerial
    quit(0)

  if surface == sfGraphical and not p.alreadyInside and not args.here:
    var extra: seq[string] = @["--here"]
    if args.dryRun: extra.add "--dry-run"
    # Only returns on failure, and then we simply carry on here — a medium
    # whose compositor will not start must still install the machine.
    let err = reexecIntoSession(getAppFilename(), extra)
    stderr.writeLine "nexis-installer: " & err

  if not isatty(stdout):
    stderr.writeLine "nexis-installer needs a terminal. " &
                     "Use --plan for non-interactive output."
    quit(2)

  quit(runInstaller(args.dryRun))
