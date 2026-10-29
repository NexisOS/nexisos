## Choosing where the installer draws itself.
##
## The installer is a plain TUI and never links Wayland. What this module does
## is decide whether to *re-exec itself inside* a compositor and terminal
## emulator, or to run where it already is.
##
## The reason to prefer cage + foot is not colour, quite. The kernel console
## does 16 colours and the theme already quantises to them. The real limit is
## the **font**: the console font holds 256 or 512 glyphs, so box drawing,
## braille spinners and block progress bars are frequently absent and render as
## blanks or garbage. `detectCaps` already turns unicode off there and the
## ASCII fallbacks take over — the UI stays correct, it just gets plainer.
##
## So the graphical path is an improvement, never a requirement. Everything
## here degrades to "run right here", and the fallback needs nothing beyond the
## kernel.

import std/[os, posix, strutils]

type
  Surface* = enum
    sfGraphical      ## cage + foot
    sfConsole        ## a Linux VT
    sfSerial         ## a serial line, or anything else

  Probe* = object
    hasDrm*: bool
    hasCage*: bool
    hasFoot*: bool
    isSerial*: bool
    alreadyInside*: bool     ## we are the client cage launched
    reason*: string

const
  DrmDir = "/dev/dri"
  ReentryVar = "NEXIS_INSTALLER_SESSION"

proc hasDrmDevice*(dir = DrmDir): bool =
  ## A card node, not just the directory. `/dev/dri` exists on machines with no
  ## working KMS driver, so its presence proves nothing — which is exactly the
  ## `nomodeset` case the fallback exists for.
  if not dirExists(dir): return false
  for kind, path in walkDir(dir):
    if path.lastPathPart.startsWith("card"): return true
  false

proc isSerialConsole*(): bool =
  ## `/dev/console` on a serial line has no VT behind it. Checked by asking
  ## whether stdin is a VT rather than by parsing the kernel command line,
  ## because the command line says what was *requested* and this says what was
  ## actually got.
  if isatty(0) == 0: return true
  let name = ttyname(0)
  if name.isNil: return true
  let n = $name
  not (n.startsWith("/dev/tty") and n.len > 8 and n[8].isDigit()) and
    n != "/dev/console"

proc which*(prog: string): string =
  for dir in getEnv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin").split(':'):
    if dir.len == 0: continue
    let candidate = dir / prog
    if fileExists(candidate): return candidate
  ""

proc probe*(): Probe =
  result.alreadyInside = getEnv(ReentryVar).len > 0
  result.hasDrm = hasDrmDevice()
  result.hasCage = which("cage").len > 0
  result.hasFoot = which("foot").len > 0
  result.isSerial = isSerialConsole()

func choose*(p: Probe): (Surface, string) =
  ## The decision, as a pure function, so every branch is testable without a
  ## GPU. The reason is returned alongside: a machine that fell back to the
  ## console should be able to say why, or the user is left guessing whether
  ## the graphical path was even attempted.
  if p.alreadyInside:
    return (sfGraphical, "running inside the compositor")
  if p.isSerial:
    return (sfSerial, "no virtual terminal; this looks like a serial console")
  if not p.hasDrm:
    return (sfConsole, "no DRM device with a card node (nomodeset, or no " &
                       "supported GPU)")
  if not p.hasCage:
    return (sfConsole, "cage is not installed on this medium")
  if not p.hasFoot:
    return (sfConsole, "foot is not installed on this medium")
  (sfGraphical, "")

func sessionCommand*(self: string, extra: seq[string] = @[]): seq[string] =
  ## `cage -- foot -- <self>`.
  ##
  ## cage runs exactly one client fullscreen with no decorations, no launcher
  ## and nothing to click on — which is what an installation medium wants and
  ## why it is a better fit here than a general compositor. foot inside it
  ## provides the terminal the TUI actually talks to.
  ##
  ## `-s` on cage allows the client to be restarted rather than ending the
  ## session, so a crashed installer leaves a usable screen instead of a black
  ## one.
  result = @["cage", "-s", "--", "foot", "--"]
  result.add self
  for e in extra: result.add e

func sessionEnv*(): seq[(string, string)] =
  ## What the child needs.
  ##
  ## `LIBSEAT_BACKEND=builtin` is the important one: the installer runs as
  ## root, so cage can open DRM and input devices directly and the `seatd`
  ## daemon is not needed at all. That removes a service, a socket, and a
  ## startup ordering problem from the medium.
  ##
  ## `XDG_RUNTIME_DIR` must exist and be private, or the Wayland socket has
  ## nowhere to live and cage exits with a message most users will not connect
  ## to the cause.
  @[(ReentryVar, "1"),
    ("LIBSEAT_BACKEND", "builtin"),
    ("XDG_RUNTIME_DIR", "/run/nexis-session"),
    ("WLR_RENDERER_ALLOW_SOFTWARE", "1"),   ## llvmpipe in a VM with no GPU
    ("TERM", "foot")]

proc prepareRuntimeDir*(path = "/run/nexis-session"): bool =
  try:
    createDir(path)
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    true
  except CatchableError:
    false

proc reexecIntoSession*(self: string, extra: seq[string] = @[]): string =
  ## Replace this process with the compositor. Returns an error string; on
  ## success it does not return at all.
  ##
  ## exec rather than fork: nothing here needs to outlive the session, and a
  ## supervisor watching this pid should be watching the compositor. Forking
  ## would leave a parent doing nothing but waiting, which is a process that
  ## can only add failure modes.
  if not prepareRuntimeDir():
    return "cannot create the session runtime directory"
  for (k, v) in sessionEnv():
    putEnv(k, v)
  let argv = sessionCommand(self, extra)
  discard execvp(argv[0].cstring, allocCStringArray(argv))
  "could not start " & argv[0] & "; falling back to this terminal"
