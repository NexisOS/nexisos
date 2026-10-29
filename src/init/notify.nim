## `sd_notify` — readiness, without waiting for a timeout.
##
## A service that forks and then takes four seconds to bind its socket is not
## ready when it is spawned, and anything ordered after it will fail if started
## too early. The traditional answer is `Type=forking` plus a PID file, which is
## racy in both directions: the daemon may write the file before it is ready, or
## the supervisor may read it before it is written.
##
## The notify protocol replaces that with the service saying so. It writes
## `READY=1` to a datagram socket whose path is in `$NOTIFY_SOCKET`, and the
## supervisor knows exactly when — no polling, no PID file, no guessing.
##
## This is systemd's wire format deliberately and exactly. Thousands of daemons
## already implement it, and a NexisOS-specific protocol would mean patching
## every one of them for no gain. Reducing migration cost is the goal;
## reproducing systemd is not.
##
## The security property that makes this usable: the sender's credentials come
## from `SO_PASSCRED`, not from the message. A service cannot claim to be
## another service, because the kernel supplies the pid. Trusting a pid in the
## payload would let any process on the machine mark any service ready.

import std/[posix, strutils, tables]

type
  NotifyKind* = enum
    nkReady          ## READY=1
    nkReloading      ## RELOADING=1
    nkStopping       ## STOPPING=1
    nkStatus         ## STATUS=free text
    nkWatchdog       ## WATCHDOG=1
    nkMainPid        ## MAINPID=n
    nkErrno          ## ERRNO=n
    nkUnknown

  Notification* = object
    kind*: NotifyKind
    value*: string
    pid*: int          ## from SCM_CREDENTIALS, never from the message

func parseMessage*(payload: string): seq[Notification] =
  ## One datagram may carry several newline-separated assignments, and a
  ## `STATUS=` line may contain anything including `=`, so only the first `=`
  ## separates. Splitting on every `=` truncates status text at the first
  ## equals sign, which is the sort of bug that only shows up in someone's
  ## error message months later.
  for line in payload.splitLines():
    let t = line.strip()
    if t.len == 0: continue
    let eq = t.find('=')
    if eq <= 0: continue
    let key = t[0 ..< eq]
    let value = t[eq + 1 .. ^1]
    let kind =
      case key
      of "READY": (if value == "1": nkReady else: nkUnknown)
      of "RELOADING": (if value == "1": nkReloading else: nkUnknown)
      of "STOPPING": (if value == "1": nkStopping else: nkUnknown)
      of "STATUS": nkStatus
      of "WATCHDOG": (if value == "1": nkWatchdog else: nkUnknown)
      of "MAINPID": nkMainPid
      of "ERRNO": nkErrno
      else: nkUnknown
    if kind != nkUnknown:
      result.add Notification(kind: kind, value: value)

func mainPid*(n: Notification): int =
  ## MAINPID is advisory and comes from the payload, so it is validated rather
  ## than trusted: a service may tell us which of its processes is the main
  ## one, but it cannot name a pid it does not own — that check belongs to the
  ## caller, which knows the cgroup.
  if n.kind != nkMainPid: return 0
  try: parseInt(n.value.strip()) except ValueError: 0

# --- The socket --------------------------------------------------------------

const
  NotifyDir* = "/run/nexis"
  NotifyPath* = "/run/nexis/notify"
  MaxDatagram* = 4096

type NotifySocket* = object
  fd*: cint

proc setsockopt(s, level, optname: cint, optval: pointer,
                optlen: SockLen): cint {.importc, header: "<sys/socket.h>".}

# Nim's posix module does not export these socket type flags.
const
  SOCK_CLOEXEC = 0o2000000.cint
  SOCK_NONBLOCK = 0o4000.cint
  SO_PASSCRED = 16.cint
  SCM_CREDENTIALS = 2.cint

proc openNotifySocket*(path = NotifyPath): NotifySocket =
  ## A datagram socket, so a service that writes and exits immediately does
  ## not need us to have accepted a connection first — which is exactly what a
  ## oneshot doing `READY=1` then `exit 0` does.
  result.fd = cint(socket(AF_UNIX, SOCK_DGRAM or SOCK_CLOEXEC or
                          SOCK_NONBLOCK, 0))
  if result.fd < 0: return

  discard unlink(path.cstring)

  var addr0 = Sockaddr_un(sun_family: AF_UNIX.uint16)
  let n = min(path.len, addr0.sun_path.len - 1)
  for i in 0 ..< n: addr0.sun_path[i] = path[i]

  if bindSocket(SocketHandle(result.fd), cast[ptr SockAddr](addr addr0),
                SockLen(sizeof(addr0))) != 0:
    discard close(result.fd)
    result.fd = -1
    return

  # Without SO_PASSCRED the kernel does not attach the sender's identity and
  # every notification is anonymous — at which point any process could mark
  # any service ready.
  var one: cint = 1
  discard setsockopt(result.fd, SOL_SOCKET, SO_PASSCRED, addr one,
                     SockLen(sizeof(one)))

  # 0666: services run as their own users and must be able to write here. The
  # socket is safe to expose because authority comes from SO_PASSCRED, not
  # from who can reach the path.
  discard chmod(path.cstring, 0o666.Mode)

proc close*(s: NotifySocket) =
  if s.fd >= 0: discard close(s.fd)

proc receive*(s: NotifySocket): seq[Notification] =
  ## Drain every queued datagram. Draining rather than reading one keeps the
  ## loop from spinning when several services report ready at once, which is
  ## the normal case a second into a boot.
  if s.fd < 0: return

  while true:
    var buf: array[MaxDatagram, char]
    var control: array[256, byte]
    var iov = IOVec(iov_base: addr buf[0], iov_len: csize_t(buf.len))
    var msg = Tmsghdr(msg_iov: addr iov, msg_iovlen: 1,
                      msg_control: addr control[0],
                      msg_controllen: SockLen(control.len))

    let n = recvmsg(SocketHandle(s.fd), addr msg, 0)
    if n <= 0: break

    var senderPid = 0
    var cmsg = CMSG_FIRSTHDR(addr msg)
    while cmsg != nil:
      if cmsg.cmsg_level == SOL_SOCKET and cmsg.cmsg_type == SCM_CREDENTIALS:
        # struct ucred is {pid, uid, gid} of int32; the pid is the first word.
        let data = cast[ptr int32](CMSG_DATA(cmsg))
        senderPid = int(data[])
      cmsg = CMSG_NXTHDR(addr msg, cmsg)

    var payload = newString(n)
    for i in 0 ..< n: payload[i] = buf[i]
    for note in parseMessage(payload):
      var withPid = note
      withPid.pid = senderPid
      result.add withPid

# --- Routing -----------------------------------------------------------------

type PidIndex* = Table[int, string]   ## pid -> service name

func route*(index: PidIndex, n: Notification): string =
  ## Which service sent this. Empty when the sender is not a known service —
  ## in which case the notification is dropped rather than guessed at.
  ##
  ## A notification from an unknown pid is not an error worth failing a boot
  ## over: a service that double-forks reports from a child we have not
  ## indexed, and the correct answer is to ignore it until MAINPID arrives.
  index.getOrDefault(n.pid, "")

func describe*(n: Notification): string =
  case n.kind
  of nkReady: "ready"
  of nkReloading: "reloading"
  of nkStopping: "stopping"
  of nkStatus: "status: " & n.value
  of nkWatchdog: "watchdog ping"
  of nkMainPid: "main pid is " & n.value
  of nkErrno: "errno " & n.value
  of nkUnknown: "unknown"
