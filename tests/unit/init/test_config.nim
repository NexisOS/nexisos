import std/[strutils, tables, unittest]
import ../../../src/init/[config, service, sandbox, cgroup]

proc load(doc: string): ServiceSet =
  result = ServiceSet(services: initTable[string, Service](),
                      confinement: initTable[string, Confinement](),
                      limits: initTable[string, Limits]())
  loadString(doc, "test.toml", result)
  resolve(result)

proc messages(s: ServiceSet): string =
  for d in s.diagnostics: result.add d.format() & "\n"

suite "durations":
  test "the common spellings parse":
    check parseDuration("30s", 0) == 30_000
    check parseDuration("500ms", 0) == 500
    check parseDuration("2min", 0) == 120_000
    check parseDuration("1h", 0) == 3_600_000

  test "a bare number is seconds":
    check parseDuration("30", 0) == 30_000

  test "an unparseable duration is -1, not zero":
    # Zero would mean "kill it immediately", the opposite of what someone
    # writing stop_timeout = "30x" intended.
    check parseDuration("30x", 999) == -1
    check parseDuration("abc", 999) == -1

  test "an absent value takes the default":
    check parseDuration("", 5000) == 5000

suite "enums":
  test "known values parse and unknown ones are flagged":
    check parseRestart("always") == (rpAlways, true)
    check parseRestart("nonsense")[1] == false
    check parseReadiness("notify") == (rdNotify, true)
    check parseReadiness("nonsense")[1] == false

  test "an empty value is the default, not an error":
    check parseRestart("")[1]
    check parseReadiness("")[1]

suite "loading":
  test "a complete service round-trips":
    let s = load("""
[service.nginx]
exec = ["/usr/bin/nginx", "-g", "daemon off;"]
readiness = "notify"
stop_timeout = "10s"
[service.nginx.dependencies]
requires = ["network"]
[service.nginx.resources]
memory_max = "512M"
[service.network]
exec = "/usr/bin/dhcpcd"
""")
    check not s.hasErrors()
    check s.services["nginx"].exec == @["/usr/bin/nginx", "-g", "daemon off;"]
    check s.services["nginx"].readiness == rdNotify
    check s.services["nginx"].stopTimeout == 10_000
    check s.limits["nginx"].memoryMax == "512M"

  test "dependencies determine the order":
    let s = load("""
[service.a]
exec = "/bin/a"
[service.a.dependencies]
requires = ["b"]
[service.b]
exec = "/bin/b"
""")
    check s.order == @["b", "a"]

  test "an empty document is not an error":
    check not load("").hasErrors()

  test "invalid TOML is one diagnostic, not a crash":
    let s = load("[service.broken\nexec =")
    check s.hasErrors()
    check "invalid TOML" in s.messages()

suite "argv, not shell":
  test "a shell metacharacter is rejected":
    # Accepting a shell string would make a service's real behaviour depend on
    # quoting rules rather than on what the file says.
    for bad in ["|", "&", ";", ">", "$", "`"]:
      let s = load("[service.x]\nexec = \"/bin/sh -c 'a " & bad & " b'\"\n")
      check s.hasErrors()
      check "metacharacter" in s.messages()

  test "a plain string is split on whitespace":
    let s = load("[service.x]\nexec = \"/usr/bin/dhcpcd -B eth0\"\n")
    check not s.hasErrors()
    check s.services["x"].exec == @["/usr/bin/dhcpcd", "-B", "eth0"]

  test "a missing exec is an error, not an empty service":
    let s = load("[service.x]\nrestart = \"always\"\n")
    check s.hasErrors()
    check "no `exec`" in s.messages()

  test "a relative program name warns but does not fail":
    let s = load("[service.x]\nexec = \"dhcpcd\"\n")
    check not s.hasErrors()
    check "relative program name" in s.messages()

suite "confinement defaults":
  test "a service with no security block gets the strict defaults":
    # A service nobody has thought about should be the most confined; there
    # are always more of those than audited ones.
    let s = load("[service.x]\nexec = \"/bin/x\"\n")
    check s.confinement["x"].privateNetwork
    check s.confinement["x"].privateTmp
    check s.confinement["x"].noNewPrivileges

  test "needs_network is the readable spelling of no network namespace":
    let s = load("""
[service.x]
exec = "/bin/x"
[service.x.security]
needs_network = true
""")
    check not s.confinement["x"].privateNetwork

  test "a misspelt capability fails the load":
    let s = load("""
[service.x]
exec = "/bin/x"
[service.x.security]
capabilities = ["CAP_TYPO"]
""")
    check s.hasErrors()
    check "unknown capability" in s.messages()

suite "limits":
  test "a bad size is an error naming the field and a working example":
    let s = load("""
[service.x]
exec = "/bin/x"
[service.x.resources]
memory_max = "512X"
""")
    check s.hasErrors()
    check "memory_max" in s.messages()
    check "512M" in s.messages()

  test "cpu_weight is range-checked":
    let s = load("""
[service.x]
exec = "/bin/x"
[service.x.resources]
cpu_weight = 99999
""")
    check s.hasErrors()
    check "1..10000" in s.messages()

suite "whole-set checks":
  test "a required service that does not exist is caught":
    let s = load("""
[service.x]
exec = "/bin/x"
[service.x.dependencies]
requires = ["nowhere"]
""")
    check s.hasErrors()
    check "nowhere" in s.messages()

  test "a cycle is reported as its path":
    let s = load("""
[service.a]
exec = "/bin/a"
[service.a.dependencies]
requires = ["b"]
[service.b]
exec = "/bin/b"
[service.b.dependencies]
requires = ["a"]
""")
    check s.hasErrors()
    check "cycle" in s.messages()
    check "->" in s.messages()

  test "a duplicate declaration is ambiguous and refused":
    # Picking one silently would make the machine depend on directory
    # iteration order.
    var s = ServiceSet(services: initTable[string, Service](),
                       confinement: initTable[string, Confinement](),
                       limits: initTable[string, Limits]())
    loadString("[service.x]\nexec = \"/bin/a\"\n", "a.toml", s)
    loadString("[service.x]\nexec = \"/bin/b\"\n", "b.toml", s)
    check s.hasErrors()
    check "more than once" in s.messages()

  test "every error is reported at once, not one per run":
    let s = load("""
[service.x]
exec = "/bin/x"
restart = "sometimes"
readiness = "eventually"
stop_timeout = "30x"
""")
    check s.errorCount() >= 3

  test "diagnostics come out in a stable order":
    # Output that reorders between runs cannot be diffed.
    let a = load("""
[service.z]
exec = "/bin/z"
restart = "bad"
[service.a]
exec = "/bin/a"
restart = "bad"
""").messages()
    for _ in 0 .. 3:
      check load("""
[service.z]
exec = "/bin/z"
restart = "bad"
[service.a]
exec = "/bin/a"
restart = "bad"
""").messages() == a

suite "diagnostics":
  test "a diagnostic names the file and the service":
    let s = load("[service.nginx]\nrestart = \"bad\"\n")
    let m = s.messages()
    check "test.toml" in m
    check "[service.nginx]" in m

  test "oneshot implies exit readiness":
    let s = load("[service.x]\nexec = \"/bin/x\"\noneshot = true\n")
    check s.services["x"].readiness == rdExit

suite "watchdog configuration":
  test "a watchdog parses as a duration":
    let s = load("""
[service.x]
exec = "/bin/x"
readiness = "notify"
watchdog = "30s"
""")
    check not s.hasErrors()
    check s.services["x"].watchdogSec == 30_000

  test "a watchdog without notify readiness is refused":
    # It needs the notify socket to ping through; arming one on a service that
    # cannot ping produces a restart loop indistinguishable from a crash.
    let s = load("""
[service.x]
exec = "/bin/x"
watchdog = "30s"
""")
    check s.hasErrors()
    check "requires readiness" in s.messages()

  test "no watchdog is the default":
    let s = load("[service.x]\nexec = \"/bin/x\"\n")
    check s.services["x"].watchdogSec == 0

  test "an unparseable watchdog is an error, not silently zero":
    let s = load("""
[service.x]
exec = "/bin/x"
readiness = "notify"
watchdog = "30x"
""")
    check s.hasErrors()
    check "not a duration" in s.messages()

suite "controlling terminal":
  test "a tty is parsed":
    let s = load("[service.x]\nexec = \"/bin/x\"\ntty = \"/dev/tty1\"\n")
    check not s.hasErrors()
    check s.services["x"].tty == "/dev/tty1"

  test "no tty is the default":
    check load("[service.x]\nexec = \"/bin/x\"\n").services["x"].tty == ""

  test "a tty that is not a device path is refused":
    # An interactive program given only stdout draws one frame and then blocks
    # forever on a read that can never return, which looks exactly like a hang.
    let s = load("[service.x]\nexec = \"/bin/x\"\ntty = \"tty1\"\n")
    check s.hasErrors()
    check "device path" in s.messages()
