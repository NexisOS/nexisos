import std/[os, posix, strutils, tables, unittest]
import ../../../src/init/notify

suite "wire format":
  test "READY=1 is recognised":
    let n = parseMessage("READY=1")
    check n.len == 1
    check n[0].kind == nkReady

  test "one datagram may carry several assignments":
    let n = parseMessage("READY=1\nSTATUS=Serving\nMAINPID=4242")
    check n.len == 3
    check n[0].kind == nkReady
    check n[2].mainPid() == 4242

  test "a status containing = is not truncated":
    # Splitting on every '=' truncates status text at the first equals sign,
    # which surfaces months later inside someone's error message.
    let n = parseMessage("STATUS=Connected to db=primary port=5432")
    check n.len == 1
    check n[0].value == "Connected to db=primary port=5432"

  test "READY with any value but 1 is not readiness":
    check parseMessage("READY=0").len == 0
    check parseMessage("READY=yes").len == 0

  test "unknown keys are ignored, not errors":
    # Newer systemd keys appear over time; a daemon sending one should not
    # have its READY=1 in the same datagram discarded.
    let n = parseMessage("FDSTORE=1\nREADY=1\nBARRIER=1")
    check n.len == 1
    check n[0].kind == nkReady

  test "malformed lines are skipped":
    check parseMessage("").len == 0
    check parseMessage("no-equals-sign").len == 0
    check parseMessage("=novalue").len == 0
    check parseMessage("\n\n\n").len == 0

  test "the other lifecycle signals parse":
    check parseMessage("RELOADING=1")[0].kind == nkReloading
    check parseMessage("STOPPING=1")[0].kind == nkStopping
    check parseMessage("WATCHDOG=1")[0].kind == nkWatchdog

  test "a non-numeric MAINPID is zero, not a crash":
    check parseMessage("MAINPID=abc")[0].mainPid() == 0

  test "notifications describe themselves for the log":
    check "ready" in parseMessage("READY=1")[0].describe()
    check "Serving" in parseMessage("STATUS=Serving")[0].describe()

suite "routing":
  test "a notification is attributed by pid, not by its payload":
    # Trusting a pid in the message would let any process on the machine mark
    # any service ready.
    var index: PidIndex = {100: "nginx", 200: "postgres"}.toTable
    check index.route(Notification(kind: nkReady, pid: 100)) == "nginx"
    check index.route(Notification(kind: nkReady, pid: 200)) == "postgres"

  test "an unknown sender routes nowhere rather than to a guess":
    # A double-forking service reports from a child we have not indexed; the
    # correct answer is to ignore it until MAINPID arrives.
    var index: PidIndex = {100: "nginx"}.toTable
    check index.route(Notification(kind: nkReady, pid: 999)) == ""

suite "the socket, end to end":
  const TestPath = "/tmp/nexis-notify-test.sock"

  test "a real datagram arrives with the sender's pid attached":
    let s = openNotifySocket(TestPath)
    if s.fd < 0:
      skip()          ## no AF_UNIX here; the parser tests still cover the rest
    else:
      defer:
        s.close()
        removeFile(TestPath)

      # Send exactly as a daemon would.
      let client = socket(AF_UNIX, SOCK_DGRAM, 0)
      check client.cint >= 0
      var sa = Sockaddr_un(sun_family: AF_UNIX.uint16)
      for i, c in TestPath: sa.sun_path[i] = c
      let payload = "READY=1\nSTATUS=up"
      check sendto(client, payload.cstring, payload.len, 0,
                   cast[ptr SockAddr](addr sa),
                   SockLen(sizeof(sa))) > 0
      discard close(client.cint)

      let got = s.receive()
      check got.len == 2
      check got[0].kind == nkReady
      # The kernel supplied this, not the message.
      check got[0].pid == getpid().int
      check got[1].value == "up"

  test "receiving from an empty socket returns nothing, and does not block":
    let s = openNotifySocket(TestPath)
    if s.fd < 0:
      skip()
    else:
      defer:
        s.close()
        removeFile(TestPath)
      check s.receive().len == 0

  test "the socket is world-writable, because authority is not the path":
    # Services run as their own users and must be able to write here; the
    # socket is safe to expose because identity comes from SO_PASSCRED.
    let s = openNotifySocket(TestPath)
    if s.fd < 0:
      skip()
    else:
      defer:
        s.close()
        removeFile(TestPath)
      let perms = getFilePermissions(TestPath)
      check fpOthersWrite in perms

  test "a stale socket file is replaced rather than failing the bind":
    # After an unclean shutdown the path still exists, and refusing to bind
    # would mean no service could ever report ready again.
    writeFile(TestPath, "stale")
    let s = openNotifySocket(TestPath)
    check s.fd >= 0
    s.close()
    removeFile(TestPath)
