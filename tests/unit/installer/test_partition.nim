import std/[strutils, unittest]
import ../../../src/tuiinstaller/[partition, state, network]

suite "scheme guidance":
  test "a scheme matching the firmware carries no note":
    check schemeNote(psEfiGpt, efiBooted = true) == ""
    check schemeNote(psBiosGpt, efiBooted = false) == ""

  test "a scheme contradicting the firmware is labelled":
    # The scheme is a fact about how the machine booted, not a preference.
    # It stays selectable, because a detection that cannot be overridden is
    # worse than one that can — but the wrong answer says so.
    check schemeNote(psBiosGpt, efiBooted = true).len > 0
    check schemeNote(psEfiGpt, efiBooted = false).len > 0

  test "every filesystem has a one-line reason to pick it":
    for fs in filesystems():
      check fsNote(fs).len > 0

suite "cycling":
  test "options wrap in both directions":
    check cycleScheme(psEfiGpt, 1) == psBiosGpt
    check cycleScheme(psBiosGpt, 1) == psEfiGpt
    check cycleScheme(psEfiGpt, -1) == psBiosGpt

  test "a three-item list wraps at both ends":
    check cycleFs(rfExt4, -1) == rfXfs
    check cycleFs(rfXfs, 1) == rfExt4

  test "cycling a full lap returns the original":
    var p = prMinimal
    for _ in 0 ..< (ord(high(Profile)) + 1): p = cycleProfile(p, 1)
    check p == prMinimal

suite "layout preview":
  test "efi shows an ESP and a root partition":
    var c = defaultConfig(true)
    c.disk = "/dev/nvme0n1"
    let lines = layoutLines(c)
    check lines.len == 2
    check "/dev/nvme0n1p1" in lines[0]
    check "EFI" in lines[0]
    check "/dev/nvme0n1p2" in lines[1]

  test "bios shows a boot partition with no filesystem":
    var c = defaultConfig(true)
    c.disk = "/dev/sda"
    c.scheme = psBiosGpt
    let lines = layoutLines(c)
    check "BIOS boot" in lines[0]
    check "none" in lines[0]

  test "the filesystem choice shows up in the preview":
    var c = defaultConfig(true)
    c.disk = "/dev/vda"
    c.rootFs = rfBtrfs
    check "btrfs" in layoutLines(c)[1]

  test "no disk selected says so instead of rendering a bad device name":
    let lines = layoutLines(defaultConfig(true))
    check lines.len == 1
    check "no disk" in lines[0]

suite "network state":
  test "operstate parsing":
    check parseOperstate("up") == lsUp
    check parseOperstate("down\n") == lsDown
    check parseOperstate("unknown") == lsUnknown
    check parseOperstate("") == lsUnknown

  test "loopback is never offered as a link":
    check isLoopback("lo")
    check not isLoopback("eth0")

  test "an offline machine gets a warning, an online one gets none":
    # A warning that is always present is furniture and gets read as furniture.
    let up = @[Link(name: "eth0", state: lsUp)]
    let down = @[Link(name: "eth0", state: lsDown)]
    check anyUp(up)
    check offlineWarning(up).len == 0
    check offlineWarning(down).len > 0

  test "the warning says the install itself still works":
    let down = @[Link(name: "eth0", state: lsDown)]
    check "does not need one" in offlineWarning(down).join(" ")

  test "summary names what is up, or says offline":
    check "eth0" in summary(@[Link(name: "eth0", state: lsUp)])
    check "offline" in summary(@[Link(name: "eth0", state: lsDown)])
    check "no interfaces" in summary(@[])
