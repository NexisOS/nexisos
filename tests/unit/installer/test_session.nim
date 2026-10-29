import std/[strutils, unittest]
import ../../../src/tuiinstaller/session

proc p(drm = true, cage = true, foot = true, serial = false,
       inside = false): Probe =
  Probe(hasDrm: drm, hasCage: cage, hasFoot: foot, isSerial: serial,
        alreadyInside: inside)

suite "choosing a surface":
  test "everything present means the graphical path":
    check p().choose()[0] == sfGraphical

  test "no DRM card node falls back to the console":
    # /dev/dri exists on machines with no working KMS driver, so its presence
    # proves nothing — which is exactly the nomodeset case.
    let (s, why) = p(drm = false).choose()
    check s == sfConsole
    check "nomodeset" in why

  test "a missing compositor falls back rather than failing":
    check p(cage = false).choose()[0] == sfConsole
    check p(foot = false).choose()[0] == sfConsole

  test "the fallback says which piece was missing":
    check "cage" in p(cage = false).choose()[1]
    check "foot" in p(foot = false).choose()[1]

  test "a serial console never launches a compositor":
    # Even with a GPU present: there is no VT to hand it.
    check p(serial = true).choose()[0] == sfSerial
    check p(serial = true, drm = true).choose()[0] == sfSerial

  test "already inside the session does not launch a second one":
    # Without this the installer re-execs itself forever.
    let (s, why) = p(inside = true).choose()
    check s == sfGraphical
    check "inside" in why

  test "being inside wins over every other signal":
    check p(inside = true, drm = false, cage = false).choose()[0] == sfGraphical

  test "a chosen graphical path gives no reason; a fallback always does":
    check p().choose()[1].len == 0
    check p(drm = false).choose()[1].len > 0

suite "the session command":
  test "cage runs foot runs the installer":
    let argv = sessionCommand("/usr/bin/nexis-installer")
    check argv[0] == "cage"
    check "foot" in argv
    check argv[^1] == "/usr/bin/nexis-installer"

  test "cage is told to survive a client restart":
    # Otherwise a crashed installer leaves a black screen rather than a
    # usable one.
    check "-s" in sessionCommand("/x")

  test "extra arguments reach the installer, not the compositor":
    let argv = sessionCommand("/x", @["--here", "--dry-run"])
    check argv[^2] == "--here"
    check argv[^1] == "--dry-run"
    check argv.find("--dry-run") > argv.find("foot")

  test "each stage is separated so arguments cannot be misattributed":
    var separators = 0
    for a in sessionCommand("/x"):
      if a == "--": inc separators
    check separators == 2

suite "the session environment":
  proc envHas(key: string): bool =
    for (k, _) in sessionEnv():
      if k == key: return true
    false

  proc envGet(key: string): string =
    for (k, v) in sessionEnv():
      if k == key: return v
    ""

  test "the builtin seat backend is used, so seatd is not needed":
    # The installer runs as root, so cage opens DRM directly — removing a
    # daemon, a socket and an ordering problem from the medium.
    check envGet("LIBSEAT_BACKEND") == "builtin"

  test "a runtime directory is declared, or the Wayland socket has no home":
    check envGet("XDG_RUNTIME_DIR").len > 0
    check envGet("XDG_RUNTIME_DIR").startsWith("/run")

  test "software rendering is allowed, for a VM with no GPU":
    check envHas("WLR_RENDERER_ALLOW_SOFTWARE")

  test "the re-entry marker is set, which is what stops the exec loop":
    let probeInside = Probe(alreadyInside: true)
    check probeInside.choose()[0] == sfGraphical
    check envHas("NEXIS_INSTALLER_SESSION")

  test "TERM is set, or the terminal's capabilities are guessed wrong":
    check envGet("TERM").len > 0
