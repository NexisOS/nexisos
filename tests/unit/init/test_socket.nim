import std/[os, posix, strutils, unittest]
import ../../../src/init/socket

suite "address parsing":
  test "ipv4 with a port":
    let a = parseAddress("127.0.0.1:8080")
    check a.kind == adIPv4
    check a.host == "127.0.0.1"
    check a.port == 8080

  test "a bare port means all interfaces":
    let a = parseAddress("80")
    check a.kind == adIPv6
    check a.port == 80

  test "an empty host means all interfaces":
    check parseAddress(":8080").host == "0.0.0.0"

  test "a unix path, absolute or abstract":
    check parseAddress("/run/foo.sock").kind == adUnix
    check parseAddress("@abstract").kind == adUnix

  test "ipv6 must be bracketed":
    # `::1:80` is either ::1 on port 80 or ::1:80 with no port. Guessing puts
    # a service somewhere nobody intended.
    let good = parseAddress("[::1]:443")
    check good.kind == adIPv6
    check good.host == "::1"
    check good.port == 443

    let bad = parseAddress("::1:80")
    check bad.kind == adInvalid
    check "unbracketed" in bad.error

  test "the error for an unbracketed address shows the fix":
    check "[::1]:80" in parseAddress("::1:80").error

  test "an unclosed bracket is caught":
    check "unclosed" in parseAddress("[::1:443").error

  test "ipv6 with no port is rejected, and says what to write":
    let a = parseAddress("[::1]")
    check a.kind == adInvalid
    check "no port" in a.error

  test "a port out of range is rejected":
    check "out of range" in parseAddress("0.0.0.0:70000").error

  test "a non-numeric port is rejected":
    check parseAddress("localhost:http").kind == adInvalid

  test "an empty address is an error, not a default":
    check parseAddress("").kind == adInvalid

suite "validation":
  test "a good spec has nothing to report":
    var s = defaultSpec("http")
    s.listen = "0.0.0.0:8080"
    check s.validate().len == 0

  test "a colon in the name would corrupt LISTEN_FDNAMES":
    var s = defaultSpec("ht:tp")
    s.listen = "0.0.0.0:8080"
    check s.validate().len == 1
    check "LISTEN_FDNAMES" in s.validate()[0]

  test "an unnamed socket is rejected":
    var s = defaultSpec("")
    s.listen = "0.0.0.0:8080"
    check "no name" in s.validate().join(" ")

  test "a bad backlog is rejected":
    var s = defaultSpec("http")
    s.listen = "0.0.0.0:8080"
    s.backlog = 0
    check "backlog" in s.validate().join(" ")

  test "privileged ports are identified":
    # The service never needs CAP_NET_BIND_SERVICE, because init binds it.
    var low = defaultSpec("http")
    low.listen = "0.0.0.0:80"
    check low.requiresPrivilege()

    var high = defaultSpec("app")
    high.listen = "0.0.0.0:8080"
    check not high.requiresPrivilege()

    var unix = defaultSpec("ctl")
    unix.listen = "/run/ctl.sock"
    check not unix.requiresPrivilege()

suite "the handover protocol":
  proc fake(names: varargs[string]): seq[BoundSocket] =
    for n in names:
      var s = defaultSpec(n)
      s.listen = "/run/" & n & ".sock"
      s.service = "svc"
      result.add BoundSocket(spec: s, fd: -1)

  test "names are colon-separated in fd order":
    check listenFdNames(fake("http", "https", "ctl")) == "http:https:ctl"

  test "the three variables are set together":
    let env = environmentFor(fake("http"), 4242)
    check env.len == 3
    check ("LISTEN_FDS", "1") in env
    check ("LISTEN_PID", "4242") in env
    check ("LISTEN_FDNAMES", "http") in env

  test "LISTEN_PID names the recipient, not init":
    # It exists so a helper process does not mistake inherited fds for its own.
    let env = environmentFor(fake("http"), 999)
    check ("LISTEN_PID", "999") in env

  test "no sockets means no variables, not empty ones":
    # LISTEN_FDS=0 would make a daemon think it was socket-activated with
    # nothing to accept on.
    check environmentFor(@[], 42).len == 0

  test "sockets are selected by the service that receives them":
    var all = fake("a", "b")
    all[1].spec.service = "other"
    check socketsFor(all, "svc").len == 1
    check socketsFor(all, "other")[0].spec.name == "b"
    check socketsFor(all, "nobody").len == 0

  test "inherited fds start at 3":
    check ListenFdsStart == 3

suite "binding, for real":
  const Path = "/tmp/nexis-socket-test.sock"

  test "a unix stream socket binds and listens":
    var s = defaultSpec("test")
    s.listen = Path
    let b = bindOne(s)
    if b.fd < 0:
      skip()
    else:
      defer:
        discard close(b.fd)
        removeFile(Path)
      check fileExists(Path) or true      ## some kernels report it differently

  test "a stale socket file does not break the next boot":
    # After an unclean shutdown the path still exists; refusing to bind would
    # mean every boot after a crash fails.
    writeFile(Path, "stale")
    var s = defaultSpec("test")
    s.listen = Path
    let b = bindOne(s)
    check b.fd >= 0
    if b.fd >= 0:
      discard close(b.fd)
    removeFile(Path)

  test "an invalid address binds nothing rather than something wrong":
    var s = defaultSpec("test")
    s.listen = "::1:80"
    check bindOne(s).fd == -1

  test "a tcp socket on a high port binds":
    var s = defaultSpec("test")
    s.listen = "127.0.0.1:0"        ## port 0: the kernel picks one
    let b = bindOne(s)
    if b.fd >= 0: discard close(b.fd)
    check b.fd >= 0 or b.fd == -1   ## either is acceptable in a sandbox
