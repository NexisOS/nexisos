import std/[strutils, tables, unittest]
import ../../../src/nexis/config/system
import ../../../src/nexis/package/types

proc parse(src: string): (SystemConfig, seq[Diagnostic]) =
  parseSystemConfig(src, "inline")

proc msgs(ds: seq[Diagnostic]): string =
  for d in ds: result.add d.msg & "\n"

const base = """
hostname = "nexis-host"
timezone = "auto"
locale   = "en_US.UTF-8"

[system]
packages = ["fish", "vim", "btop"]

[services]
sshd = true
cups = false
"""

suite "system configuration":
  test "parses the base shape":
    let (c, diags) = parse(base)
    check not diags.hasErrors()
    check c.hostname == "nexis-host"
    check c.locale == "en_US.UTF-8"
    check c.packages == @["fish", "vim", "btop"]
    check c.services["sshd"]
    check not c.services["cups"]

  test "a missing hostname is an error":
    let (_, diags) = parse("timezone = \"auto\"\n")
    check "no hostname" in msgs(diags)

  test "the 'local' typo is named explicitly":
    let (_, diags) = parse(base.replace("locale   =", "local    ="))
    check "the key is 'locale'" in msgs(diags)

suite "users":
  test "parses packages, groups and environment":
    let (c, diags) = parse(base & """

[users.kyle]
uid    = 1000
groups = ["wheel", "audio"]
shell  = "fish"
packages = ["firefox", "mpv"]

[users.kyle.environment]
EDITOR = "nvim"
""")
    check not diags.hasErrors()
    check c.users["kyle"].uid == 1000
    check c.users["kyle"].packages == @["firefox", "mpv"]
    check c.users["kyle"].environment["EDITOR"] == "nvim"

  test "two users sharing a uid is an error":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.bob]
uid = 1000
""")
    check "share uid 1000" in msgs(diags)

  test "a uid below 1000 warns but does not fail":
    let (_, diags) = parse(base & "\n[users.svc]\nuid = 400\n")
    check not diags.hasErrors()
    check "below the usual 1000 floor" in msgs(diags)

  test "shadowing a package the user does not declare is an error":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000
packages = ["firefox"]
shadows = ["python"]
""")
    check "nothing to shadow the system package with" in msgs(diags)

  test "shadowing a package the user does declare is fine":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000
packages = ["python"]
shadows = ["python"]
""")
    check not diags.hasErrors()

suite "home ownership modes":
  test "all three modes parse":
    let (c, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
managed = [{ path = ".config/fish/config.fish", source = "dotfiles/fish.fish" }]
seeded  = [{ path = ".gitconfig", source = "dotfiles/gitconfig" }]
merged  = [{ path = ".config/nvim", source = "dotfiles/nvim" }]
""")
    check not diags.hasErrors()
    let h = c.users["kyle"].home
    check h.len == 3
    var modes: seq[HomeMode]
    for e in h: modes.add e.mode
    check hmManaged in modes
    check hmSeeded in modes
    check hmMerged in modes

  test "an absolute home path is rejected":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
managed = [{ path = "/etc/passwd", source = "x" }]
""")
    check "must be relative" in msgs(diags)

  test "a path escaping the home directory is rejected":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
managed = [{ path = "../../etc/shadow", source = "x" }]
""")
    check "must not escape the home directory" in msgs(diags)

  test "a leading ~ is rejected":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
managed = [{ path = "~/.bashrc", source = "x" }]
""")
    check "must not start with ~" in msgs(diags)

  test "an entry without a source is rejected":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
managed = [{ path = ".bashrc" }]
""")
    check "has no source" in msgs(diags)

  test "the same path in two modes is an error":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
managed = [{ path = ".gitconfig", source = "a" }]
seeded  = [{ path = ".gitconfig", source = "b" }]
""")
    check "twice" in msgs(diags)

  test "a managed file inside a seeded tree is a contradiction":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
seeded  = [{ path = ".config/nvim", source = "a" }]
managed = [{ path = ".config/nvim/init.lua", source = "b" }]
""")
    check "would not stay authoritative" in msgs(diags)

  test "a managed file inside a merged tree is allowed":
    let (_, diags) = parse(base & """

[users.kyle]
uid = 1000

[users.kyle.home]
merged  = [{ path = ".config/nvim", source = "a" }]
managed = [{ path = ".config/nvim/init.lua", source = "b" }]
""")
    check not diags.hasErrors()
