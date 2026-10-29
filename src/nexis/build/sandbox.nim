## The build sandbox, described as data.
##
## This is the piece the whole `tier = "generated"` argument rests on
## (ADR 0002): shell in a recipe costs auditability but not reproducibility,
## *because* the sandbox is airtight. If the sandbox leaks, that argument
## collapses and imported definitions become unsafe rather than merely
## unreviewed. So the spec is built as a value and can be asserted against in
## tests, rather than being a sequence of syscalls buried in the build driver.
##
## What is denied, and why each matters:
##
##   network      after fetch, a build that reaches the network is not a
##                function of its declared inputs
##   host /usr    otherwise the build silently links whatever the builder
##                machine happened to have installed
##   ambient env  a build that reads $CFLAGS from the invoking shell produces
##                different output on two machines with identical inputs
##   real uid     uid appears in tarballs, in file ownership, and in some
##                build systems' output
##   hostname     embedded by autotools and by several test suites
##   wall clock   SOURCE_DATE_EPOCH pins timestamps that would otherwise be
##                baked into archives and binaries

import std/[strutils, tables]

type
  MountKind* = enum
    mkBind = "bind"          ## read-only bind of a store path
    mkBindRw = "bind-rw"     ## writable, only for the build and dest trees
    mkTmpfs = "tmpfs"
    mkProc = "proc"
    mkDev = "dev"

  Mount* = object
    kind*: MountKind
    source*: string
    target*: string
    sizeMb*: int             ## tmpfs only

  Namespaces* = object
    mount*, pid*, ipc*, uts*, user*, net*: bool

  SandboxSpec* = object
    namespaces*: Namespaces
    mounts*: seq[Mount]
    env*: OrderedTable[string, string]
    workDir*: string
    uid*, gid*: int
    hostname*: string
    umask*: int
    allowNetwork*: bool
    maxFileSizeMb*: int
    maxProcesses*: int
    timeoutSec*: int

const
  BuildRoot* = "/build"
  SrcDir* = "/build/src"
  BuildTmp* = "/build/build"
  DestDir* = "/build/dest"
  BuildUid* = 1000
  BuildGid* = 1000
  BuildHostname* = "nexis-build"

## Variables that are *never* inherited from the caller. Anything not built
## here is absent, so the list is the complete environment rather than a
## denylist — a denylist would let the next new variable through by default.
proc baseEnv*(): OrderedTable[string, string] =
  result = initOrderedTable[string, string]()
  result["PATH"] = "/usr/bin:/bin"
  result["HOME"] = BuildRoot
  result["TMPDIR"] = "/tmp"
  result["SOURCE_DATE_EPOCH"] = "0"
  result["TZ"] = "UTC"
  result["LC_ALL"] = "C"
  result["LANG"] = "C"
  result["USER"] = "nexis"
  result["LOGNAME"] = "nexis"
  result["SHELL"] = "/bin/sh"
  # Toolchains that consult these produce different output per machine.
  result["CCACHE_DISABLE"] = "1"
  result["PYTHONHASHSEED"] = "0"
  result["PYTHONDONTWRITEBYTECODE"] = "1"

proc newSandbox*(inputs: seq[string], allowNetwork = false,
                 jobs = 1): SandboxSpec =
  ## `inputs` are store paths bind-mounted read-only. Nothing else from the
  ## host filesystem is visible.
  result.namespaces = Namespaces(mount: true, pid: true, ipc: true, uts: true,
                                 user: true, net: not allowNetwork)
  result.allowNetwork = allowNetwork
  result.uid = BuildUid
  result.gid = BuildGid
  result.hostname = BuildHostname
  result.umask = 0o022
  result.workDir = SrcDir
  result.maxFileSizeMb = 8192
  result.maxProcesses = 4096
  result.timeoutSec = 6 * 3600

  result.mounts.add Mount(kind: mkProc, target: "/proc")
  result.mounts.add Mount(kind: mkDev, target: "/dev")
  result.mounts.add Mount(kind: mkTmpfs, target: "/tmp", sizeMb: 4096)
  result.mounts.add Mount(kind: mkTmpfs, target: BuildRoot, sizeMb: 16384)
  for p in inputs:
    result.mounts.add Mount(kind: mkBind, source: p, target: p)
  # The three trees the build may write to. Everything else is read-only.
  for p in [SrcDir, BuildTmp, DestDir]:
    result.mounts.add Mount(kind: mkBindRw, source: p, target: p)

  result.env = baseEnv()
  result.env["NEXIS_BUILD_JOBS"] = $jobs

proc writablePaths*(s: SandboxSpec): seq[string] =
  for m in s.mounts:
    if m.kind in {mkBindRw, mkTmpfs}: result.add m.target

proc isWritable*(s: SandboxSpec, path: string): bool =
  for w in s.writablePaths():
    if path == w or path.startsWith(w & "/"): return true
  false

proc violations*(s: SandboxSpec): seq[string] =
  ## Asserts the invariants the reproducibility argument depends on. Called
  ## before every build, so a spec built wrongly fails loudly instead of
  ## producing an artifact that cannot be reproduced elsewhere.
  if s.allowNetwork and s.namespaces.net:
    result.add "network is allowed but a network namespace is still isolated"
  if not s.allowNetwork and not s.namespaces.net:
    result.add "no network namespace: the build could reach the network"
  if not s.namespaces.mount:
    result.add "no mount namespace: the build could see the host filesystem"
  if not s.namespaces.user:
    result.add "no user namespace: the build would run with the caller's uid"
  if not s.namespaces.uts:
    result.add "no UTS namespace: the host name would leak into the build"
  if s.uid != BuildUid or s.gid != BuildGid:
    result.add "build uid/gid is not fixed"
  if s.hostname != BuildHostname:
    result.add "build hostname is not fixed"
  if s.env.getOrDefault("SOURCE_DATE_EPOCH", "") != "0":
    result.add "SOURCE_DATE_EPOCH is not pinned"
  if s.env.getOrDefault("TZ", "") != "UTC":
    result.add "TZ is not pinned to UTC"
  if s.env.getOrDefault("LC_ALL", "") != "C":
    result.add "LC_ALL is not pinned to C"
  for k in ["CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "LD_LIBRARY_PATH",
            "LD_PRELOAD", "PKG_CONFIG_PATH"]:
    if s.env.hasKey(k):
      result.add "environment sets " & k &
                 ", which belongs to the toolchain dependency"
  for m in s.mounts:
    if m.kind == mkBindRw and not m.target.startsWith(BuildRoot):
      result.add "writable mount outside the build root: " & m.target
    if m.kind == mkBind and m.target in ["/usr", "/etc", "/var"]:
      result.add "host " & m.target & " is bind-mounted into the build"

proc render*(s: SandboxSpec): string =
  ## Human-readable, and the canonical form recorded in the build log so a
  ## failed reproduction can be diffed against the original conditions.
  result.add "uid=" & $s.uid & " gid=" & $s.gid & " host=" & s.hostname &
             " umask=" & $s.umask & " network=" & $s.allowNetwork & "\n"
  result.add "namespaces:"
  if s.namespaces.mount: result.add " mount"
  if s.namespaces.pid: result.add " pid"
  if s.namespaces.ipc: result.add " ipc"
  if s.namespaces.uts: result.add " uts"
  if s.namespaces.user: result.add " user"
  if s.namespaces.net: result.add " net"
  result.add "\n"
  for m in s.mounts:
    result.add "mount " & $m.kind & " " &
               (if m.source.len > 0: m.source & " -> " else: "") &
               m.target & "\n"
  for k, v in s.env:
    result.add "env " & k & "=" & v & "\n"
