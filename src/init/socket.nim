## Socket activation.
##
## The problem it solves is not "start services lazily". It is **start-order
## independence**: if init binds the listening socket before any service runs,
## a client can connect at any time and the kernel buffers the connection until
## the provider is ready. Ordering constraints that existed only to prevent
## connection-refused stop being needed at all, and the dependency graph gets
## smaller rather than better-scheduled.
##
## That matters more here than in systemd, because a declarative system wants
## its graph to describe real requirements. An `after = ["postgres"]` that is
## really "otherwise psql gets ECONNREFUSED" is noise in the declaration.
##
## The protocol is systemd's, exactly: inherited sockets start at fd 3, with
## `LISTEN_FDS` counting them, `LISTEN_PID` naming the intended recipient, and
## `LISTEN_FDNAMES` labelling them. Daemons implementing `sd_listen_fds()`
## already work.
##
## `LISTEN_PID` is the part that is easy to get wrong and is worth stating: it
## exists so a service that re-execs, or spawns a helper, does not have the
## helper mistake inherited fds for its own. A recipient must check that
## `LISTEN_PID` equals its own pid before touching fd 3.

import std/[nativesockets, posix, strutils]

type
  SocketKind* = enum
    skStream = "stream"     ## SOCK_STREAM — TCP, or a unix stream socket
    skDatagram = "datagram" ## SOCK_DGRAM
    skSeqpacket = "seqpacket"

  SocketSpec* = object
    name*: string           ## goes in LISTEN_FDNAMES
    kind*: SocketKind
    listen*: string         ## "0.0.0.0:80", "[::]:443", "/run/foo.sock"
    backlog*: int
    mode*: int              ## unix socket permissions
    service*: string        ## which service receives it

  BoundSocket* = object
    spec*: SocketSpec
    fd*: cint

func defaultSpec*(name: string): SocketSpec =
  SocketSpec(name: name, kind: skStream, backlog: 128, mode: 0o666)

# --- Address parsing ---------------------------------------------------------

type
  AddressKind* = enum
    adUnix
    adIPv4
    adIPv6
    adInvalid

  Address* = object
    kind*: AddressKind
    host*: string
    port*: int
    path*: string
    error*: string

func parseAddress*(s: string): Address =
  ## `listen = ` in the four shapes people actually write.
  ##
  ## An IPv6 literal must be bracketed, because `::1:80` is ambiguous — it is
  ## either the address `::1` on port 80 or the address `::1:80` with no port,
  ## and guessing produces a service listening somewhere nobody intended.
  if s.len == 0:
    return Address(kind: adInvalid, error: "empty listen address")

  if s.startsWith("/") or s.startsWith("@"):
    return Address(kind: adUnix, path: s)

  if s.startsWith("["):
    let close = s.find(']')
    if close < 0:
      return Address(kind: adInvalid,
                     error: "unclosed [ in IPv6 address: " & s)
    let host = s[1 ..< close]
    if close + 1 >= s.len:
      return Address(kind: adInvalid,
                     error: "IPv6 address with no port: " & s &
                            " (try [" & host & "]:80)")
    if s[close + 1] != ':':
      return Address(kind: adInvalid, error: "expected : after ] in " & s)
    let portStr = s[close + 2 .. ^1]
    try:
      return Address(kind: adIPv6, host: host, port: parseInt(portStr))
    except ValueError:
      return Address(kind: adInvalid, error: "not a port: " & portStr)

  let colon = s.rfind(':')
  if colon < 0:
    # A bare number is a port on all interfaces; anything else is a mistake
    # rather than a hostname, because a listen address with no port cannot be
    # bound and silently defaulting one is worse than refusing.
    try:
      return Address(kind: adIPv6, host: "::", port: parseInt(s))
    except ValueError:
      return Address(kind: adInvalid,
                     error: "no port in listen address: " & s)

  if ':' in s[0 ..< colon]:
    return Address(kind: adInvalid,
                   error: "unbracketed IPv6 address: " & s &
                          " (try [" & s[0 ..< colon] & "]:" &
                          s[colon + 1 .. ^1] & ")")

  let host = s[0 ..< colon]
  try:
    let port = parseInt(s[colon + 1 .. ^1])
    if port < 1 or port > 65535:
      return Address(kind: adInvalid, error: "port out of range: " & $port)
    Address(kind: adIPv4, host: (if host.len == 0: "0.0.0.0" else: host),
            port: port)
  except ValueError:
    Address(kind: adInvalid, error: "not a port: " & s[colon + 1 .. ^1])

func validate*(spec: SocketSpec): seq[string] =
  let a = parseAddress(spec.listen)
  if a.kind == adInvalid: result.add a.error
  if spec.backlog < 1: result.add "backlog must be at least 1"
  if spec.name.len == 0: result.add "socket has no name"
  # A name with a colon would corrupt LISTEN_FDNAMES, which is colon-separated.
  if ':' in spec.name:
    result.add "socket name may not contain ':' (it separates LISTEN_FDNAMES)"

func requiresPrivilege*(spec: SocketSpec): bool =
  ## Ports below 1024 need CAP_NET_BIND_SERVICE — unless init binds them, which
  ## is the other reason socket activation is worth having: the service itself
  ## never needs the capability.
  let a = parseAddress(spec.listen)
  a.kind in {adIPv4, adIPv6} and a.port < 1024

# --- Binding -----------------------------------------------------------------

proc sockTypeOf(k: SocketKind): cint =
  case k
  of skStream: SOCK_STREAM
  of skDatagram: SOCK_DGRAM
  of skSeqpacket: cint(5)          ## SOCK_SEQPACKET

proc setsockopt(s, level, optname: cint, optval: pointer,
                optlen: SockLen): cint {.importc, header: "<sys/socket.h>".}

const IPV6_V6ONLY = 26.cint

proc bindOne*(spec: SocketSpec): BoundSocket =
  ## Bind and listen, before any service exists. Returns fd -1 on failure; the
  ## caller reports it rather than this raising, because one unbindable socket
  ## should name itself rather than abort the boot.
  result.spec = spec
  result.fd = -1
  let a = parseAddress(spec.listen)

  case a.kind
  of adInvalid:
    return
  of adUnix:
    let fd = cint(socket(AF_UNIX, sockTypeOf(spec.kind), 0))
    if fd < 0: return
    # A stale socket file from an unclean shutdown would otherwise make every
    # boot after a crash fail to bind.
    if a.path.startsWith("/"): discard unlink(a.path.cstring)
    var sa = Sockaddr_un(sun_family: AF_UNIX.uint16)
    let n = min(a.path.len, sa.sun_path.len - 1)
    for i in 0 ..< n: sa.sun_path[i] = a.path[i]
    if bindSocket(SocketHandle(fd), cast[ptr SockAddr](addr sa),
                  SockLen(sizeof(sa))) != 0:
      discard close(fd)
      return
    if a.path.startsWith("/"):
      discard chmod(a.path.cstring, Mode(spec.mode))
    result.fd = fd
  of adIPv4:
    let fd = cint(socket(AF_INET, sockTypeOf(spec.kind), 0))
    if fd < 0: return
    var one: cint = 1
    discard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr one,
                       SockLen(sizeof(one)))
    var sa = Sockaddr_in(sin_family: AF_INET.uint16,
                         sin_port: nativesockets.htons(uint16(a.port)))
    sa.sin_addr.s_addr = inet_addr(a.host.cstring)
    if bindSocket(SocketHandle(fd), cast[ptr SockAddr](addr sa),
                  SockLen(sizeof(sa))) != 0:
      discard close(fd)
      return
    result.fd = fd
  of adIPv6:
    let fd = cint(socket(AF_INET6, sockTypeOf(spec.kind), 0))
    if fd < 0: return
    var one: cint = 1
    discard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, addr one,
                       SockLen(sizeof(one)))
    # Dual-stack off deliberately: whether :: also accepts IPv4 depends on a
    # sysctl, so a service's reachability would otherwise vary by machine.
    # Declare both families explicitly if both are wanted.
    var zero: cint = 0
    discard setsockopt(fd, cint(IPPROTO_IPV6), IPV6_V6ONLY, addr zero,
                       SockLen(sizeof(zero)))
    var sa = Sockaddr_in6(sin6_family: AF_INET6.uint16,
                          sin6_port: nativesockets.htons(uint16(a.port)))
    if bindSocket(SocketHandle(fd), cast[ptr SockAddr](addr sa),
                  SockLen(sizeof(sa))) != 0:
      discard close(fd)
      return
    result.fd = fd

  if spec.kind == skStream and result.fd >= 0:
    if posix.listen(SocketHandle(result.fd), cint(spec.backlog)) != 0:
      discard close(result.fd)
      result.fd = -1

# --- Handing them over -------------------------------------------------------

const ListenFdsStart* = 3

func listenFdNames*(sockets: seq[BoundSocket]): string =
  ## `LISTEN_FDNAMES`, colon-separated in fd order.
  var parts: seq[string]
  for s in sockets: parts.add s.spec.name
  parts.join(":")

func environmentFor*(sockets: seq[BoundSocket], childPid: int):
    seq[(string, string)] =
  ## The three variables a recipient reads. `LISTEN_PID` is what stops a helper
  ## process from mistaking inherited fds for its own.
  if sockets.len == 0: return
  @[("LISTEN_FDS", $sockets.len),
    ("LISTEN_PID", $childPid),
    ("LISTEN_FDNAMES", listenFdNames(sockets))]

proc dupOntoListenFds*(sockets: seq[BoundSocket]): bool =
  ## Runs in the child. Move each socket to 3, 4, 5... and clear CLOEXEC so it
  ## survives exec.
  ##
  ## Done in two passes because a socket may already occupy a target fd, and
  ## dup2'ing onto it would close the very socket about to be moved.
  var moved: seq[cint]
  for s in sockets:
    let tmp = fcntl(s.fd, F_DUPFD, 64.cint)
    if tmp < 0: return false
    moved.add tmp

  for i, fd in moved:
    let target = cint(ListenFdsStart + i)
    if dup2(fd, target) < 0: return false
    discard close(fd)
    let flags = fcntl(target, F_GETFD, 0)
    if flags >= 0:
      discard fcntl(target, F_SETFD, flags and not FD_CLOEXEC)
  true

func socketsFor*(all: seq[BoundSocket], service: string): seq[BoundSocket] =
  for s in all:
    if s.spec.service == service: result.add s
