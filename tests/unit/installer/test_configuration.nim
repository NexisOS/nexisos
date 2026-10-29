import std/[strutils, unittest]
import ../../../src/tuiinstaller/[configuration, state]

proc cfg(): InstallConfig =
  result = defaultConfig(dryRun = true)
  result.disk = "/dev/nvme0n1"
  result.hostname = "webbox"
  result.username = "kyle"
  result.scheme = psEfiGpt
  result.profile = prServer

suite "generation zero":
  test "the answers reach the file":
    let t = renderSystemToml(cfg())
    check "hostname = \"webbox\"" in t
    check "[users.kyle]" in t
    check "name = \"server\"" in t
    check "disk   = \"/dev/nvme0n1\"" in t

  test "the boot scheme is written as efi or bios, not as the label":
    var c = cfg()
    check "\"efi\"" in renderSystemToml(c)
    c.scheme = psBiosGpt
    check "\"bios\"" in renderSystemToml(c)

  test "the file explains itself to someone who has never seen it":
    # The first thing a user does after booting is open this file. It has to
    # say what editing it does and that the change is reversible.
    let t = renderSystemToml(cfg())
    check "nexis rebuild switch" in t
    check "roll back" in t or "rollback" in t

  test "it states that there is no install command":
    check "nexis install" in renderSystemToml(cfg())

  test "free-text fields cannot break the file":
    # Timezone and locale are typed, so a stray quote would otherwise produce
    # an unparseable system configuration on first boot.
    var c = cfg()
    c.timezone = "Weird\"Zone"
    let t = renderSystemToml(c)
    check "timezone = \"Weird\\\"Zone\"" in t

  test "every section header is closed by a newline-delimited table":
    for line in renderSystemToml(cfg()).splitLines():
      if line.startsWith("["):
        check line.endsWith("]")

suite "review preview":
  test "comments and blank runs are stripped for display":
    let lines = configPreviewLines(cfg())
    check lines.len > 0
    check not lines[0].startsWith("#")
    for l in lines:
      check not l.startsWith("#")

  test "no leading blank line, and no doubled blanks":
    let lines = configPreviewLines(cfg())
    check lines[0].len > 0
    for i in 1 ..< lines.len:
      check not (lines[i].len == 0 and lines[i - 1].len == 0)

  test "the preview still carries the values":
    let joined = configPreviewLines(cfg()).join("\n")
    check "webbox" in joined
    check "[users.kyle]" in joined
