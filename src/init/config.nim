## Loading a service set from TOML.
##
## This is what turns `nexis-init` from a supervisor with nothing to supervise
## into PID 1. It is deliberately the *only* way services enter the system:
## there is no drop-in directory scanned at runtime, no generator programs
## producing units on the fly, and no equivalent of
## `/etc/systemd/system/*.wants/` where a symlink nobody wrote deliberately
## changes what boots.
##
## Everything a service is, is in the generation that built it. That is what
## makes "the machine is what the declaration says" checkable rather than
## aspirational — and it is why loading refuses on error rather than skipping
## the broken unit and carrying on. A boot that silently omits a service is
## worse than one that stops and says which file is wrong: the first produces a
## machine that looks fine and is not.

import std/[algorithm, os, strutils, tables]
import parsetoml
import ./service, ./sandbox, ./cgroup

type
  Severity* = enum
    sevError
    sevWarning

  Diagnostic* = object
    severity*: Severity
    file*: string
    service*: string
    msg*: string

  ServiceSet* = object
    services*: Table[string, Service]
    confinement*: Table[string, Confinement]
    limits*: Table[string, Limits]
    order*: seq[string]
    diagnostics*: seq[Diagnostic]

func hasErrors*(s: ServiceSet): bool =
  for d in s.diagnostics:
    if d.severity == sevError: return true
  false

func errorCount*(s: ServiceSet): int =
  for d in s.diagnostics:
    if d.severity == sevError: inc result

func format*(d: Diagnostic): string =
  result = d.file
  if d.service.len > 0: result.add ": [service." & d.service & "]"
  result.add ": " & d.msg

# --- TOML helpers ------------------------------------------------------------

proc get(t: TomlValueRef, key: string): TomlValueRef =
  if t.isNil or t.kind != TomlValueKind.Table: return nil
  if not t.tableVal.hasKey(key): return nil
  t.tableVal[key]

proc getStr(t: TomlValueRef, key: string, dflt = ""): string =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.String: dflt else: v.stringVal

proc getInt(t: TomlValueRef, key: string, dflt: int): int =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.Int: dflt else: int(v.intVal)

proc getBool(t: TomlValueRef, key: string, dflt: bool): bool =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.Bool: dflt else: v.boolVal

proc strSeq(t: TomlValueRef, key: string): seq[string] =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.Array: return
  for item in v.arrayVal:
    if item.kind == TomlValueKind.String: result.add item.stringVal

# --- Duration parsing --------------------------------------------------------

func parseDuration*(s: string, dflt: int): int =
  ## "30s", "500ms", "2min" to milliseconds. -1 for anything unparseable, so a
  ## typo becomes a diagnostic rather than silently becoming zero — and a zero
  ## timeout means "kill it immediately", which is the opposite of what someone
  ## writing `stop_timeout = "30x"` intended.
  if s.len == 0: return dflt
  var digits = ""
  var unit = ""
  for c in s:
    if c.isDigit(): digits.add c
    else: unit.add c
  if digits.len == 0: return -1
  var n: int
  try: n = parseInt(digits)
  except ValueError: return -1
  case unit.strip().toLowerAscii()
  of "ms": n
  of "", "s", "sec": n * 1000
  of "m", "min": n * 60_000
  of "h", "hr": n * 3_600_000
  else: -1

func parseRestart*(s: string): (RestartPolicy, bool) =
  case s.strip().toLowerAscii()
  of "", "on-failure", "onfailure": (rpOnFailure, true)
  of "never", "no", "none": (rpNever, true)
  of "always": (rpAlways, true)
  else: (rpOnFailure, false)

func parseReadiness*(s: string): (ReadinessKind, bool) =
  case s.strip().toLowerAscii()
  of "", "immediate", "simple": (rdImmediate, true)
  of "notify": (rdNotify, true)
  of "socket": (rdSocket, true)
  of "exit", "oneshot": (rdExit, true)
  else: (rdImmediate, false)

# --- One service -------------------------------------------------------------

proc parseExec(v: TomlValueRef, name, file: string,
               diags: var seq[Diagnostic]): seq[string] =
  ## argv only. A string is accepted and split on whitespace as a convenience,
  ## but it is not shell-parsed: no quoting, no globs, no `&&`. Accepting a
  ## shell string here would make a service's real behaviour depend on quoting
  ## rules rather than on what the file says.
  if v.isNil:
    diags.add Diagnostic(severity: sevError, file: file, service: name,
                         msg: "no `exec` declared")
    return
  case v.kind
  of TomlValueKind.Array:
    for item in v.arrayVal:
      if item.kind == TomlValueKind.String: result.add item.stringVal
  of TomlValueKind.String:
    for part in v.stringVal.splitWhitespace(): result.add part
    for c in v.stringVal:
      if c in {'|', '&', ';', '>', '<', '$', '`'}:
        diags.add Diagnostic(severity: sevError, file: file, service: name,
          msg: "`exec` contains a shell metacharacter (" & c &
               "). Services are argv, not shell commands - use a wrapper " &
               "program if you need a pipeline.")
        break
  else:
    diags.add Diagnostic(severity: sevError, file: file, service: name,
                         msg: "`exec` must be a string or an array of strings")

  if result.len > 0 and not result[0].startsWith("/"):
    diags.add Diagnostic(severity: sevWarning, file: file, service: name,
      msg: "`exec` uses a relative program name (" & result[0] &
           "); it will be resolved through PATH at start time")

proc parseConfinement(t: TomlValueRef, name, file: string,
                      diags: var seq[Diagnostic]): Confinement =
  ## Absent security block means strict defaults, not permissive ones. A
  ## service nobody has thought about should be the most confined, because
  ## there are always more of those than audited ones.
  result = strictDefaults()
  if t.isNil: return

  result.user = t.getStr("user")
  result.group = t.getStr("group")
  result.privateTmp = t.getBool("private_tmp", result.privateTmp)
  result.privateDevices = t.getBool("private_devices", result.privateDevices)
  result.noNewPrivileges = t.getBool("no_new_privileges", true)
  result.selinuxDomain = t.getStr("selinux_domain")
  result.seccompProfile = t.getStr("seccomp")
  result.workingDir = t.getStr("working_directory")
  result.readOnlyPaths = t.strSeq("read_only_paths")
  result.inaccessiblePaths = t.strSeq("inaccessible_paths")
  result.capabilities = t.strSeq("capabilities")

  # `needs_network = true` is the readable spelling; the mechanism is the
  # absence of a network namespace. Stating the intent rather than the
  # mechanism is what lets the firewall generator read the same field to
  # decide which ports to open.
  let needsNet = t.get("needs_network")
  if not needsNet.isNil and needsNet.kind == TomlValueKind.Bool:
    result.privateNetwork = not needsNet.boolVal
  elif not t.get("private_network").isNil:
    result.privateNetwork = t.getBool("private_network", true)

  for problem in result.validate():
    diags.add Diagnostic(severity: sevError, file: file, service: name,
                         msg: problem)

proc parseLimits(t: TomlValueRef, name, file: string,
                 diags: var seq[Diagnostic]): Limits =
  result = defaultLimits()
  if t.isNil: return
  result.memoryMax = t.getStr("memory_max")
  result.memoryHigh = t.getStr("memory_high")
  result.cpuWeight = t.getInt("cpu_weight", 100)
  result.tasksMax = t.getInt("tasks_max", 0)
  result.ioWeight = t.getInt("io_weight", 100)

  for (field, value) in {"memory_max": result.memoryMax,
                         "memory_high": result.memoryHigh}:
    if value.len > 0 and parseSize(value) <= 0:
      diags.add Diagnostic(severity: sevError, file: file, service: name,
        msg: field & " = \"" & value & "\" is not a size (try \"512M\")")

  if result.cpuWeight < 1 or result.cpuWeight > 10000:
    diags.add Diagnostic(severity: sevError, file: file, service: name,
      msg: "cpu_weight must be 1..10000, got " & $result.cpuWeight)

proc parseService(name: string, t: TomlValueRef, file: string,
                  s: var ServiceSet) =
  var svc = defaultService(name)
  svc.exec = parseExec(t.get("exec"), name, file, s.diagnostics)

  let deps = t.get("dependencies")
  if not deps.isNil:
    svc.requires = deps.strSeq("requires")
    svc.wants = deps.strSeq("wants")
    svc.after = deps.strSeq("after")

  svc.oneshot = t.getBool("oneshot", false)

  # A service asking for a terminal is asking for stdin, stdout, stderr and a
  # controlling terminal — all four, or none of it works. An interactive
  # program given only stdout renders its first frame and then blocks forever
  # on a read that can never return, which looks exactly like a hang.
  svc.tty = t.getStr("tty")
  if svc.tty.len > 0 and not svc.tty.startsWith("/dev/"):
    s.diagnostics.add Diagnostic(severity: sevError, file: file, service: name,
      msg: "tty = \"" & svc.tty & "\" must be a device path (try \"/dev/tty1\")")

  let (policy, policyOk) = parseRestart(t.getStr("restart"))
  if not policyOk:
    s.diagnostics.add Diagnostic(severity: sevError, file: file, service: name,
      msg: "restart = \"" & t.getStr("restart") &
           "\" is not one of: never, on-failure, always")
  svc.restart = policy

  let (ready, readyOk) = parseReadiness(t.getStr("readiness"))
  if not readyOk:
    s.diagnostics.add Diagnostic(severity: sevError, file: file, service: name,
      msg: "readiness = \"" & t.getStr("readiness") &
           "\" is not one of: immediate, notify, socket, exit")
  svc.readiness = ready
  if svc.oneshot and svc.readiness == rdImmediate: svc.readiness = rdExit

  for (field, target, dflt) in [
      ("start_timeout", addr svc.startTimeout, 30_000),
      ("stop_timeout", addr svc.stopTimeout, 30_000),
      ("restart_delay", addr svc.restartSec, 200)]:
    let raw = t.getStr(field)
    let ms = parseDuration(raw, dflt)
    if ms < 0:
      s.diagnostics.add Diagnostic(severity: sevError, file: file,
        service: name,
        msg: field & " = \"" & raw & "\" is not a duration (try \"30s\")")
    else:
      target[] = ms

  let wd = t.getStr("watchdog")
  svc.watchdogSec = parseDuration(wd, 0)
  if svc.watchdogSec < 0:
    s.diagnostics.add Diagnostic(severity: sevError, file: file, service: name,
      msg: "watchdog = \"" & wd & "\" is not a duration (try \"30s\")")
    svc.watchdogSec = 0
  if svc.watchdogSec > 0 and svc.readiness != rdNotify:
    # A watchdog needs the notify socket to ping through. Arming one on a
    # service that cannot ping produces a restart loop indistinguishable from
    # a crash.
    s.diagnostics.add Diagnostic(severity: sevError, file: file, service: name,
      msg: "watchdog requires readiness = \"notify\"; this service uses \"" &
           $svc.readiness & "\"")

  svc.maxRestarts = t.getInt("max_restarts", 5)
  svc.restartWindow = parseDuration(t.getStr("restart_window"), 60_000)
  if svc.restartWindow < 0: svc.restartWindow = 60_000

  let sec = t.get("security")
  svc.selinuxDomain = (if sec.isNil: "" else: sec.getStr("selinux_domain"))

  s.services[name] = svc
  s.confinement[name] = parseConfinement(sec, name, file, s.diagnostics)
  s.limits[name] = parseLimits(t.get("resources"), name, file, s.diagnostics)

# --- Files -------------------------------------------------------------------

proc loadString*(content, file: string, s: var ServiceSet) =
  var root: TomlValueRef
  try:
    root = parsetoml.parseString(content)
  except CatchableError as e:
    s.diagnostics.add Diagnostic(severity: sevError, file: file,
                                 msg: "invalid TOML: " & e.msg)
    return

  let services = root.get("service")
  if services.isNil or services.kind != TomlValueKind.Table: return

  # Sorted so diagnostics come out in the same order every run. A build that
  # reports its errors in a different sequence each time is a build whose
  # output cannot be diffed.
  var names: seq[string]
  for name in services.tableVal.keys: names.add name
  names.sort()

  for name in names:
    let t = services.tableVal[name]
    if t.kind != TomlValueKind.Table:
      s.diagnostics.add Diagnostic(severity: sevError, file: file,
        service: name, msg: "[service." & name & "] must be a table")
      continue
    if name in s.services:
      # Two files declaring the same service is ambiguous, and picking one
      # silently means the machine depends on directory iteration order.
      s.diagnostics.add Diagnostic(severity: sevError, file: file,
        service: name, msg: "declared more than once")
      continue
    parseService(name, t, file, s)

proc loadDir*(dir: string, s: var ServiceSet) =
  ## Every `.toml` under the directory, in sorted order.
  if not dirExists(dir): return
  var files: seq[string]
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".toml"): files.add path
  files.sort()
  for f in files:
    try: loadString(readFile(f), f, s)
    except IOError, OSError:
      s.diagnostics.add Diagnostic(severity: sevError, file: f,
                                   msg: "cannot read")

proc resolve*(s: var ServiceSet) =
  ## Ordering, plus the checks that only make sense across the whole set.
  let r = resolveOrder(s.services)
  for m in r.missing:
    s.diagnostics.add Diagnostic(severity: sevError, file: "<service set>",
      msg: "required service `" & m & "` is declared by something but does " &
           "not exist")
  if r.cycle.len > 0:
    s.diagnostics.add Diagnostic(severity: sevError, file: "<service set>",
      msg: "dependency cycle: " & r.cycle.join(" -> "))
  s.order = r.order

proc loadServiceSet*(root: string): ServiceSet =
  ## `/etc/nexis/services.toml` plus `/etc/nexis/services/*.toml`.
  result.services = initTable[string, Service]()
  result.confinement = initTable[string, Confinement]()
  result.limits = initTable[string, Limits]()

  let single = root / "services.toml"
  if fileExists(single):
    try: loadString(readFile(single), single, result)
    except IOError, OSError:
      result.diagnostics.add Diagnostic(severity: sevError, file: single,
                                        msg: "cannot read")
  loadDir(root / "services", result)
  result.resolve()
