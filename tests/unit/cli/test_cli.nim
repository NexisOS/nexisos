import std/[strutils, tables, unittest]
import ../../../src/nexis/cli

suite "parsing":
  test "a bare command with its default subcommand":
    let i = parse(["rebuild"])
    check i.kind == ckRebuild
    check i.sub == "switch"          ## `rebuild` means `rebuild switch`

  test "an explicit subcommand wins":
    check parse(["rebuild", "boot"]).sub == "boot"
    check parse(["rebuild", "dry-run"]).sub == "dry-run"

  test "an unrecognised word after a command is an argument, not a subcommand":
    let i = parse(["rebuild", "nonsense"])
    check i.sub == "switch"
    check i.args == @["nonsense"]

  test "no arguments is help, not an error":
    check parse([]).kind == ckNone

  test "flags may appear anywhere":
    for argv in [@["--dry-run", "rebuild"], @["rebuild", "--dry-run"]]:
      let i = parse(argv)
      check i.kind == ckRebuild
      check "dry-run" in i.flags

  test "flags taking a value accept both forms":
    check parse(["check", "--config", "/etc/x"]).configRoot() == "/etc/x"
    check parse(["check", "--config=/etc/y"]).configRoot() == "/etc/y"

  test "the config root defaults to /etc/nexis":
    check parse(["check"]).configRoot() == "/etc/nexis"

  test "-- stops flag parsing so the program gets its own flags":
    let i = parse(["run", "cargo", "--", "--release"])
    check i.args == @["cargo", "--release"]
    check "release" notin i.flags

  test "a negative number is an argument, not a flag":
    check parse(["diff", "-1", "42"]).args == @["-1", "42"]

  test "help and version short-circuit whatever else was typed":
    check parse(["rebuild", "--help"]).kind == ckHelp
    check parse(["--version"]).kind == ckVersion

  test "dry-run is recognised as a flag or as a subcommand":
    check parse(["rebuild", "dry-run"]).isDryRun()
    check parse(["rebuild", "--dry-run"]).isDryRun()
    check not parse(["rebuild", "switch"]).isDryRun()

suite "refusals":
  test "install is a known command that refuses, not an unknown one":
    # Erroring with "unknown command" is the failure mode docs/cli.md exists
    # to avoid: the user googles, edits TOML by hand, gets the nesting wrong,
    # and concludes the distribution is hostile.
    let i = parse(["install", "firefox"])
    check i.kind == ckRefused
    check i.refusedName == "install"
    check i.args == @["firefox"]

  test "the habits of other package managers are caught too":
    for typed in ["install", "uninstall", "upgrade", "update", "sync", "-S"]:
      check parse(@[typed]).kind == ckRefused

  test "each refusal names the command that replaces it":
    check replacementFor("install") == "add"
    check replacementFor("uninstall") == "remove"
    check replacementFor("upgrade") == "rebuild switch"

  test "the message names the package the user actually typed":
    let m = refusal("install", "add", "firefox")
    check "firefox" in m
    check "nexis add firefox" in m

  test "with no package named it stays readable":
    check "<package>" in refusal("install", "add")

  test "the message says where the package goes, not just what is forbidden":
    let m = refusal("install", "add", "firefox")
    check "/etc/nexis" in m
    check "[system] packages" in m
    check "--user" in m

  test "upgrade gets the version-pin explanation, not the add explanation":
    let m = refusal("upgrade", "rebuild switch")
    check "rebuild switch" in m
    check "--user" notin m

  test "the refusal explains why add is not the thing it just refused":
    # "add" sounds like the thing we said we would not do, so the distinction
    # has to be stated: it edits the declaration and has no path to the store.
    let m = refusal("install", "add", "firefox")
    check "declaration" in m
    check "store" in m

suite "suggestions":
  test "a near miss is suggested":
    check suggest("rebiuld") == "rebuild"
    check suggest("genrations") == "generations"
    check suggest("rollbak") == "rollback"

  test "a distant word gets no suggestion rather than a wrong one":
    check suggest("frobnicate") == ""
    check suggest("") == ""

suite "help":
  test "every command is listed":
    let u = usage()
    for name in ["rebuild", "generations", "rollback", "gc", "why", "owns",
                 "explain", "shell", "check", "add", "remove"]:
      check name in u

  test "help states the no-install rule rather than leaving it implicit":
    let u = usage()
    check "no `nexis install`" in u
    check "pure function" in u

  test "known() matches the listed commands and nothing else":
    check known("rebuild")
    check known("gc")
    check not known("install")       ## refused, deliberately not "known"
    check not known("frobnicate")

suite "value-taking flags":
  test "every value flag consumes its argument":
    # A flag missing from ValueFlags silently becomes a boolean and eats
    # nothing, leaving its value as a stray positional that looks like an
    # unknown subcommand. This has bitten twice.
    for flag in ValueFlags:
      let i = parse(["generations", "--" & flag, "/some/path"])
      check i.flags[flag] == "/some/path"
      check i.args.len == 0

  test "the equals form works for every value flag too":
    for flag in ValueFlags:
      check parse(["check", "--" & flag & "=/p"]).flags[flag] == "/p"

  test "a value flag at the end of the line does not eat past it":
    let i = parse(["check", "--config"])
    check "config" in i.flags
