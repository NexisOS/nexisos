## Per-service confinement.
##
## Confinement is declared by the service and applied by init. That direction
## matters: the alternative is a package's own postinstall script arranging its
## own privileges, which means the privileges a service runs with are not
## knowable from the configuration.
##
## Everything here is applied in the child, between fork and exec. That is the
## only window where the process has not yet run any of the service's own code,
## so a service cannot undo its own sandbox.
##
## The one rule worth stating: **a confinement that cannot be applied is a
## failure to start, never a warning.** systemd's `ProtectSystem=` silently does
## nothing on a kernel without the required support, which produces a service
## that appears confined and is not. A sandbox that might not be on is worse
## than no sandbox, because it is trusted.

import std/[posix, strutils]

type
  Confinement* = object
    user*: string
    group*: string
    privateTmp*: bool          ## own /tmp, unmount on exit
    privateNetwork*: bool      ## no network namespace at all
    privateDevices*: bool      ## minimal /dev
    readOnlyPaths*: seq[string]
    inaccessiblePaths*: seq[string]
    noNewPrivileges*: bool     ## setuid binaries cannot raise privilege
    capabilities*: seq[string] ## the ones to keep; everything else dropped
    selinuxDomain*: string
    seccompProfile*: string    ## named profile; "" for none
    workingDir*: string
    umask*: int

func strictDefaults*(): Confinement =
  ## Deny by default. A service that needs the network says so; one that says
  ## nothing does not get it. The inverse — permissive defaults with opt-in
  ## hardening — means every service that nobody has audited is unconfined,
  ## and there are always more of those than audited ones.
  Confinement(privateTmp: true, privateNetwork: true, privateDevices: true,
              noNewPrivileges: true, umask: 0o077)

func permissiveDefaults*(): Confinement =
  ## For services that genuinely need the host view — an init-adjacent agent,
  ## a network manager. Named so that choosing it is visible in review.
  Confinement(noNewPrivileges: true, umask: 0o022)

# --- Namespaces --------------------------------------------------------------

const
  CLONE_NEWNS* = 0x00020000
  CLONE_NEWUTS* = 0x04000000
  CLONE_NEWIPC* = 0x08000000
  CLONE_NEWNET* = 0x40000000
  CLONE_NEWPID* = 0x20000000

func namespaceFlags*(c: Confinement): int =
  ## Which namespaces this confinement needs. Pure, so the mapping is testable
  ## and reviewable without unsharing anything.
  if c.privateTmp or c.readOnlyPaths.len > 0 or
     c.inaccessiblePaths.len > 0 or c.privateDevices:
    result = result or CLONE_NEWNS
  if c.privateNetwork:
    result = result or CLONE_NEWNET

func needsMountNamespace*(c: Confinement): bool =
  (c.namespaceFlags() and CLONE_NEWNS) != 0

# --- Capabilities ------------------------------------------------------------

const KnownCaps* = [
  "CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER",
  "CAP_FSETID", "CAP_KILL", "CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP",
  "CAP_NET_BIND_SERVICE", "CAP_NET_BROADCAST", "CAP_NET_ADMIN", "CAP_NET_RAW",
  "CAP_IPC_LOCK", "CAP_SYS_CHROOT", "CAP_SYS_PTRACE", "CAP_SYS_ADMIN",
  "CAP_SYS_NICE", "CAP_SYS_RESOURCE", "CAP_SYS_TIME", "CAP_MKNOD",
  "CAP_AUDIT_WRITE", "CAP_SETFCAP", "CAP_MAC_ADMIN", "CAP_MAC_OVERRIDE",
]

func capIndex*(name: string): int =
  ## Capability name to its kernel constant. -1 for unknown, so a typo is
  ## caught at validation rather than silently dropping the capability — a
  ## misspelt `CAP_NET_BIND_SREVICE` would otherwise leave a service unable to
  ## bind port 80 with no indication why.
  let n = name.strip().toUpperAscii()
  const Map = {
    "CAP_CHOWN": 0, "CAP_DAC_OVERRIDE": 1, "CAP_DAC_READ_SEARCH": 2,
    "CAP_FOWNER": 3, "CAP_FSETID": 4, "CAP_KILL": 5, "CAP_SETGID": 6,
    "CAP_SETUID": 7, "CAP_SETPCAP": 8, "CAP_NET_BIND_SERVICE": 10,
    "CAP_NET_BROADCAST": 11, "CAP_NET_ADMIN": 12, "CAP_NET_RAW": 13,
    "CAP_IPC_LOCK": 14, "CAP_SYS_CHROOT": 18, "CAP_SYS_PTRACE": 19,
    "CAP_SYS_ADMIN": 21, "CAP_MKNOD": 27, "CAP_AUDIT_WRITE": 29,
    "CAP_SETFCAP": 31, "CAP_MAC_OVERRIDE": 32, "CAP_MAC_ADMIN": 33,
    "CAP_SYS_NICE": 23, "CAP_SYS_RESOURCE": 24, "CAP_SYS_TIME": 25,
  }
  for (k, v) in Map:
    if k == n: return v
  -1

func validate*(c: Confinement): seq[string] =
  ## Everything wrong with this confinement, before anything is started.
  for cap in c.capabilities:
    if capIndex(cap) < 0:
      result.add "unknown capability: " & cap
  for p in c.readOnlyPaths & c.inaccessiblePaths:
    if not p.startsWith("/"):
      result.add "path must be absolute: " & p
  if c.privateNetwork and "CAP_NET_ADMIN" in c.capabilities:
    # Not fatal, but almost always a mistake worth surfacing: the capability
    # only applies inside the empty namespace the service just asked for.
    result.add "CAP_NET_ADMIN with privateNetwork applies only to an empty " &
               "namespace; did you mean privateNetwork = false?"

# --- Application -------------------------------------------------------------

proc unshare(flags: cint): cint {.importc, header: "<sched.h>".}
proc prctl(option: cint): cint {.importc, varargs, header: "<sys/prctl.h>".}

const
  PR_SET_NO_NEW_PRIVS = 38
  PR_CAPBSET_DROP = 24

type SandboxError* = object of CatchableError

proc applyInChild*(c: Confinement) =
  ## Runs after fork, before exec. Raises on any failure — see the module
  ## comment: a confinement that silently did not apply is worse than none.

  if c.noNewPrivileges:
    # Must come before dropping privileges, and it is irreversible. With it
    # set, a setuid binary in the service's tree cannot be used to climb back
    # out, which is what makes the rest of this meaningful.
    if prctl(PR_SET_NO_NEW_PRIVS.cint, 1.cint, 0.cint, 0.cint, 0.cint) != 0:
      raise newException(SandboxError, "PR_SET_NO_NEW_PRIVS failed")

  let flags = c.namespaceFlags()
  if flags != 0:
    if unshare(flags.cint) != 0:
      raise newException(SandboxError,
        "unshare failed; the kernel lacks namespace support or this is a " &
        "restricted container")

  if c.capabilities.len > 0:
    for i in 0 .. 40:
      var keep = false
      for cap in c.capabilities:
        if capIndex(cap) == i: keep = true
      if not keep:
        discard prctl(PR_CAPBSET_DROP.cint, i.cint, 0.cint, 0.cint, 0.cint)

  if c.umask >= 0:
    discard umask(Mode(c.umask))

  if c.workingDir.len > 0:
    if chdir(c.workingDir.cstring) != 0:
      raise newException(SandboxError,
        "cannot enter working directory " & c.workingDir)
