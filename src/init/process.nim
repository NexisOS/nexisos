## Process handles that cannot be confused with the wrong process.
##
## A PID is not a stable identifier. Between noticing that a service exited and
## acting on it, the kernel is free to allocate that number to something else —
## so a supervisor holding a PID can send SIGKILL to whatever now owns it. The
## window is small and the consequence is a supervisor that occasionally kills
## an unrelated process, which is exactly the class of bug that is impossible to
## reproduce and therefore never gets fixed.
##
## A pidfd refers to *the process*, not to the number. It cannot be recycled: if
## the process is gone, operations on the fd return ESRCH rather than acting on
## a stranger. That property is why `nexis-init` is built on pidfd rather than
## on SIGCHLD bookkeeping, and it is the single biggest correctness difference
## from a traditional supervisor.
##
## It also makes exit notification pollable. A pidfd becomes readable when the
## process dies, so process death is just another epoll event alongside signals
## and timers — one loop, no SIGCHLD handler racing with the main path.

import std/posix

# --- Raw syscalls ------------------------------------------------------------
# glibc did not wrap these until 2.36, and NexisOS has to build against what is
# on the machine, so they are issued directly.

const
  SYS_pidfd_open* = 434
  SYS_pidfd_send_signal* = 424
  SYS_pidfd_getfd* = 438

proc syscall(number: clong): clong {.importc, varargs,
                                     header: "<sys/syscall.h>", discardable.}

type
  Pidfd* = distinct cint

  ExitStatus* = object
    exited*: bool          ## terminated normally
    code*: int             ## exit code, when exited
    signal*: int           ## signal number, when killed
    coreDumped*: bool

const InvalidPidfd* = Pidfd(-1)

func isValid*(p: Pidfd): bool = cint(p) >= 0
func fd*(p: Pidfd): cint = cint(p)

proc pidfdOpen*(pid: Pid): Pidfd =
  Pidfd(syscall(SYS_pidfd_open, cint(pid), cuint(0)).cint)

proc pidfdSendSignal*(p: Pidfd, sig: int): bool =
  ## Signal *this* process, or fail. The whole point: if the process is gone
  ## this returns false rather than signalling whoever inherited its number.
  syscall(SYS_pidfd_send_signal, cint(p), cint(sig), pointer(nil), cuint(0)) == 0

proc close*(p: Pidfd) =
  if p.isValid: discard posix.close(cint(p))

# --- Exit status -------------------------------------------------------------

func decodeWaitStatus*(status: cint): ExitStatus =
  ## `wait(2)`'s packed status word, unpacked. Written as a pure function
  ## because every branch of it matters to restart policy — "exited 0",
  ## "exited 3" and "killed by SIGSEGV" are three different decisions — and
  ## macro-based extraction is not testable.
  let s = int(status)
  if (s and 0x7F) == 0:
    ExitStatus(exited: true, code: (s shr 8) and 0xFF)
  elif ((s and 0x7F) + 1) shr 1 > 0:
    ExitStatus(exited: false, signal: s and 0x7F,
               coreDumped: (s and 0x80) != 0)
  else:
    ExitStatus(exited: true, code: 0)

func describe*(e: ExitStatus): string =
  if e.exited:
    result = (if e.code == 0: "exited cleanly" else: "exited " & $e.code)
  else:
    result = "killed by signal " & $e.signal
    if e.coreDumped: result.add " (core dumped)"

func isClean*(e: ExitStatus): bool = e.exited and e.code == 0

proc reapOne*(): (Pid, ExitStatus, bool) =
  ## Reap one zombie without blocking.
  ##
  ## PID 1 inherits every orphan on the system, so this runs whether or not
  ## anything is being supervised. A PID 1 that fails to reap leaks zombies
  ## until the process table fills, and the machine then cannot fork — which
  ## presents as "nothing works" rather than as an init bug.
  var status: cint
  let pid = waitpid(Pid(-1), status, WNOHANG)
  if pid <= 0: (Pid(0), ExitStatus(), false)
  else: (pid, decodeWaitStatus(status), true)
