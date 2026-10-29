## Signals as file descriptors.
##
## An async signal handler runs at an arbitrary point in the main loop and may
## only call async-signal-safe functions. Every classic init bug of the form
## "it deadlocked in malloc" comes from ignoring that. `signalfd` converts
## signals into bytes on an fd: they arrive in the epoll loop, in order, at a
## point where all state is consistent, and the handler is ordinary code.
##
## The signals PID 1 must answer are few, and each has exactly one meaning.

import std/posix

type
  SignalEvent* = enum
    seNone
    seChild         ## SIGCHLD  — a child died; reap it
    seReboot        ## SIGINT   — ctrl-alt-del on the console
    sePowerOff      ## SIGUSR2  — deliberate power off
    seHalt          ## SIGUSR1  — halt without powering off
    seReload        ## SIGHUP   — re-read the generation's service set
    seTerm          ## SIGTERM  — meaningless for PID 1; logged and ignored

  SignalFd* = object
    fd*: cint

const
  SFD_CLOEXEC = 0x80000
  SFD_NONBLOCK = 0x800

# struct signalfd_siginfo. Only the first field is read, but the whole struct
# must be consumed per read or the fd desynchronises.
type SignalfdSiginfo {.importc: "struct signalfd_siginfo", pure, final,
                       header: "<sys/signalfd.h>".} = object
  ssi_signo {.importc.}: uint32

proc signalfd(fd: cint, mask: ptr Sigset, flags: cint): cint
  {.importc, header: "<sys/signalfd.h>".}

proc sigprocmaskPtr(how: cint, sset, oldset: ptr Sigset): cint
  {.importc: "sigprocmask", header: "<signal.h>".}

func classify*(signo: int): SignalEvent =
  ## Signal number to intent. Separated from the reading so the mapping can be
  ## tested without a signalfd — and because the mapping is a policy decision,
  ## not plumbing.
  case signo
  of SIGCHLD: seChild
  of SIGINT: seReboot
  of SIGUSR2: sePowerOff
  of SIGUSR1: seHalt
  of SIGHUP: seReload
  of SIGTERM: seTerm
  else: seNone

const Handled* = [SIGCHLD, SIGINT, SIGUSR1, SIGUSR2, SIGHUP, SIGTERM]

proc openSignalFd*(): SignalFd =
  ## Block the handled signals first, then take them from the fd.
  ##
  ## The blocking is not optional and the order is not arbitrary: a signal
  ## delivered between creating the fd and blocking the signal takes the
  ## default action instead, and the default action for SIGINT on PID 1 is to
  ## be ignored — but for SIGTERM in a child that inherits the mask, it is
  ## death. Blocking first closes that window.
  var mask: Sigset
  discard sigemptyset(mask)
  for s in Handled: discard sigaddset(mask, cint(s))
  discard sigprocmaskPtr(SIG_BLOCK, addr mask, nil)
  SignalFd(fd: signalfd(-1, addr mask, SFD_CLOEXEC or SFD_NONBLOCK))

proc unblockAll*() =
  ## Children must not inherit PID 1's signal mask. A service that starts with
  ## SIGTERM blocked cannot be stopped, and the failure appears at shutdown —
  ## long after the cause.
  var mask: Sigset
  discard sigemptyset(mask)
  for s in Handled: discard sigaddset(mask, cint(s))
  discard sigprocmaskPtr(SIG_UNBLOCK, addr mask, nil)

proc read*(sf: SignalFd): seq[SignalEvent] =
  ## Drain everything queued. Draining rather than reading one keeps the loop
  ## from spinning when several signals arrive together, which is the normal
  ## case during shutdown.
  if sf.fd < 0: return
  var info: SignalfdSiginfo
  while true:
    let n = posix.read(sf.fd, addr info, sizeof(info).cint)
    if n != sizeof(info): break
    let ev = classify(int(info.ssi_signo))
    if ev != seNone: result.add ev
