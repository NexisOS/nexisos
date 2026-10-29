import std/[os, strutils, tables, unittest]
import ../../../src/lib/[process, errors]

suite "rendering":
  test "plain argv needs no quoting":
    check render("sgdisk", ["--zap-all", "/dev/vda"]) ==
      "sgdisk --zap-all /dev/vda"

  test "arguments with spaces are quoted for display":
    check render("mkfs.ext4", ["-L", "nexis root"]) ==
      "mkfs.ext4 -L 'nexis root'"

  test "embedded quotes survive the rendering":
    check "'\\''" in render("echo", ["it's"])

  test "an empty argument is visible rather than vanishing":
    check render("prog", [""]) == "prog ''"

suite "execution":
  test "exit codes are reported, not swallowed":
    check exec("true").code == 0
    check exec("false").code != 0

  test "output is captured with stderr interleaved":
    let r = exec("sh", ["-c", "echo out; echo err >&2"])
    check "out" in r.output
    check "err" in r.output

  test "a missing program is 127, distinct from a failed one":
    # A missing build dependency and a real build failure need different
    # answers, so they must not arrive as the same code.
    check exec("/definitely/not/a/real/binary").code == 127
    check exec("false").code != 127

  test "arguments are passed directly, never through a shell":
    # If this went through a shell the semicolon would run a second command
    # and the output would contain 'pwned'.
    let r = exec("echo", ["a; echo pwned"])
    check "pwned" in r.output          ## echoed as literal text...
    check r.output.strip() == "a; echo pwned"   ## ...as one argument

  test "globs are not expanded behind the caller's back":
    let r = exec("echo", ["*"])
    check r.output.strip() == "*"

suite "environment":
  test "the environment is constructed, not inherited":
    # A build reading $CFLAGS from whoever ran it is not reproducible, and the
    # failure stays invisible until two machines disagree.
    putEnv("NEXIS_TEST_LEAK", "leaked")
    var o = defaultExecOpts()
    let r = exec("sh", ["-c", "echo [$NEXIS_TEST_LEAK]"], o)
    check r.output.strip() == "[]"

  test "declared variables are present":
    var o = defaultExecOpts()
    o.env["NEXIS_DECLARED"] = "yes"
    let r = exec("sh", ["-c", "echo $NEXIS_DECLARED"], o)
    check r.output.strip() == "yes"

  test "inheritEnv is opt-in and still lets declarations win":
    putEnv("NEXIS_TEST_LEAK", "host")
    var o = defaultExecOpts()
    o.inheritEnv = true
    check exec("sh", ["-c", "echo $NEXIS_TEST_LEAK"], o).output.strip() == "host"
    o.env["NEXIS_TEST_LEAK"] = "declared"
    check exec("sh", ["-c", "echo $NEXIS_TEST_LEAK"], o).output.strip() ==
      "declared"

  test "the working directory is honoured":
    var o = defaultExecOpts()
    o.cwd = "/tmp"
    check exec("pwd", [], o).output.strip() == "/tmp"

suite "timeouts":
  test "a hung program is killed and reported as timed out":
    var o = defaultExecOpts()
    o.timeoutMs = 300
    let r = exec("sleep", ["30"], o)
    check r.timedOut
    check r.code == 124

  test "a fast program is untouched by a generous timeout":
    var o = defaultExecOpts()
    o.timeoutMs = 5000
    let r = exec("true", [], o)
    check not r.timedOut
    check r.code == 0

suite "checkExec":
  test "success is silent":
    checkExec("true")

  test "failure carries the command and its output":
    var raised = false
    try:
      checkExec("sh", ["-c", "echo why >&2; exit 3"])
    except NexisError as e:
      raised = true
      check e.kind == ekBuild
      check "exited 3" in e.msg
      check "why" in e.hint
    check raised

suite "which":
  test "finds a program on PATH and returns an absolute path":
    let p = which("sh")
    check p.len > 0
    check p.startsWith("/")

  test "an absent program is the empty string, not an exception":
    check which("definitely-not-installed-anywhere") == ""

  test "a path with a slash is checked directly":
    check which("/bin/sh").len > 0
    check which("./nope/nope") == ""

  test "every missing program is reported at once":
    # Reporting the first means the user installs it, re-runs, and waits to be
    # told about the next one.
    var msg = ""
    try:
      requireAll(["sh", "no-such-a", "no-such-b"])
    except NexisError as e:
      msg = e.msg
    check "no-such-a" in msg
    check "no-such-b" in msg

  test "requireAll passes when everything is present":
    requireAll(["sh", "echo"])
