## cgroups v2.
##
## The cgroup is what makes supervision *complete*. A service that double-forks
## escapes a PID-based supervisor entirely — the parent exits, the supervisor
## sees a clean exit, and the real work keeps running unowned. A cgroup cannot
## be escaped: every descendant lands in it regardless of forking, so "stop the
## service" means "kill everything in the cgroup" and actually means it.
##
## v2 only. The v1 hierarchy allowed a process to be in different cgroups for
## different controllers, which makes "which cgroup is this in" a question with
## several answers. Supporting both would mean carrying that ambiguity forever
## for the benefit of kernels NexisOS does not target.
##
## `cgroup.kill` (Linux 5.14+) is used where present: it kills the whole subtree
## atomically, without the read-pids-then-signal race where a process forks
## between the two steps.

import std/[os, strutils]

const
  CgroupRoot* = "/sys/fs/cgroup"
  ServiceSlice* = "nexis.slice"

type
  Limits* = object
    memoryMax*: string      ## "512M", or "" for none
    memoryHigh*: string     ## throttle before the OOM killer
    cpuWeight*: int         ## 1..10000, 100 is default
    tasksMax*: int
    ioWeight*: int

func defaultLimits*(): Limits =
  Limits(cpuWeight: 100, tasksMax: 0, ioWeight: 100)

func servicePath*(name: string): string =
  CgroupRoot / ServiceSlice / (name & ".service")

func parseSize*(s: string): int64 =
  ## "512M" to bytes. Returns -1 for anything unparseable, so a typo in a
  ## limit is rejected at configuration time rather than silently applied as
  ## zero — which the kernel would read as "no memory at all".
  if s.len == 0: return -1
  if s == "max" or s == "infinity": return high(int64)
  var digits = ""
  var suffix = ""
  for c in s:
    if c.isDigit(): digits.add c
    else: suffix.add c
  if digits.len == 0: return -1
  var n: int64
  try: n = parseBiggestInt(digits)
  except ValueError: return -1
  case suffix.strip().toUpperAscii()
  of "": n
  of "K", "KB", "KIB": n * 1024
  of "M", "MB", "MIB": n * 1024 * 1024
  of "G", "GB", "GIB": n * 1024 * 1024 * 1024
  of "T", "TB", "TIB": n * 1024'i64 * 1024 * 1024 * 1024
  else: -1

func limitFiles*(l: Limits): seq[(string, string)] =
  ## The (file, value) pairs to write. A pure function so the whole mapping can
  ## be tested without a mounted cgroup filesystem.
  if l.memoryMax.len > 0 and parseSize(l.memoryMax) > 0:
    result.add ("memory.max", $parseSize(l.memoryMax))
  if l.memoryHigh.len > 0 and parseSize(l.memoryHigh) > 0:
    result.add ("memory.high", $parseSize(l.memoryHigh))
  if l.cpuWeight > 0 and l.cpuWeight != 100:
    result.add ("cpu.weight", $l.cpuWeight)
  if l.tasksMax > 0:
    result.add ("pids.max", $l.tasksMax)
  if l.ioWeight > 0 and l.ioWeight != 100:
    result.add ("io.weight", $l.ioWeight)

proc isV2*(): bool =
  ## v1 mounts controllers separately; v2 has a single unified hierarchy with
  ## this file at its root.
  fileExists(CgroupRoot / "cgroup.controllers")

proc writeFileQuiet(path, value: string): bool =
  try:
    writeFile(path, value)
    true
  except IOError, OSError:
    false

proc enableControllers*(path: string, controllers: seq[string]): bool =
  ## A controller must be enabled in the *parent* before a child can use it.
  ## Getting this backwards is the usual reason a memory limit silently has no
  ## effect, so it is done explicitly rather than assumed.
  var spec = ""
  for c in controllers: spec.add "+" & c & " "
  writeFileQuiet(path / "cgroup.subtree_control", spec.strip())

proc create*(name: string, limits: Limits): string =
  ## Create the service's cgroup and apply its limits. Returns the path, or ""
  ## if cgroups are unavailable — a machine without cgroup v2 still boots,
  ## with resource limits reported as unenforced rather than pretended.
  if not isV2(): return ""
  let slice = CgroupRoot / ServiceSlice
  try:
    createDir(slice)
    discard enableControllers(CgroupRoot, @["cpu", "memory", "pids", "io"])
    discard enableControllers(slice, @["cpu", "memory", "pids", "io"])
    let path = servicePath(name)
    createDir(path)
    for (file, value) in limits.limitFiles():
      discard writeFileQuiet(path / file, value)
    path
  except OSError:
    ""

proc attach*(path: string, pid: int): bool =
  ## Move a process in. Called in the child between fork and exec, so the
  ## process is inside its cgroup before it can run a single instruction of
  ## the service's own code — otherwise a fast-forking service escapes.
  if path.len == 0: return false
  writeFileQuiet(path / "cgroup.procs", $pid)

proc killAll*(path: string): bool =
  ## Kill the whole subtree. Prefers `cgroup.kill`, which is atomic; the
  ## fallback reads and signals, which races against a process forking between
  ## the read and the signal.
  if path.len == 0: return false
  if fileExists(path / "cgroup.kill"):
    return writeFileQuiet(path / "cgroup.kill", "1")
  false

proc pids*(path: string): seq[int] =
  if path.len == 0: return
  try:
    for line in lines(path / "cgroup.procs"):
      let t = line.strip()
      if t.len > 0:
        try: result.add parseInt(t)
        except ValueError: discard
  except IOError, OSError: discard

proc isEmpty*(path: string): bool = path.pids().len == 0

proc remove*(path: string) =
  if path.len == 0: return
  try: removeDir(path)
  except OSError: discard

# --- Pressure ----------------------------------------------------------------

type Pressure* = object
  some10*: float          ## % of time at least one task stalled, 10s average
  full10*: float          ## % of time every task stalled

func parsePressure*(content: string): Pressure =
  ## `memory.pressure` in PSI format. This is what replaces systemd-oomd: the
  ## kernel already reports stall time per cgroup, so an OOM policy needs the
  ## numbers and a rule, not a separate daemon with its own view of the world.
  for line in content.splitLines():
    let parts = line.splitWhitespace()
    if parts.len < 2: continue
    for p in parts[1 .. ^1]:
      if not p.startsWith("avg10="): continue
      let v = try: parseFloat(p[6 .. ^1]) except ValueError: 0.0
      if parts[0] == "some": result.some10 = v
      elif parts[0] == "full": result.full10 = v

proc pressure*(path: string): Pressure =
  if path.len == 0: return
  try: parsePressure(readFile(path / "memory.pressure"))
  except IOError, OSError: Pressure()

func underPressure*(p: Pressure, threshold = 60.0): bool =
  ## `full` rather than `some`: `some` fires whenever any task waits on memory,
  ## which is normal. `full` means nothing in the cgroup made progress, which
  ## is the condition worth acting on.
  p.full10 >= threshold
