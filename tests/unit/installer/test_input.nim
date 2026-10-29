import std/unittest
import ../../../src/tuiinstaller/input

suite "plain bytes":
  test "printable characters":
    check decodeSequence("a") == charKey('a')
    check decodeSequence("Q").kind == kChar
    check decodeSequence("Q").ch == 'Q'

  test "both newline conventions are enter":
    check decodeSequence("\r").kind == kEnter
    check decodeSequence("\n").kind == kEnter

  test "both backspace conventions":
    check decodeSequence("\x7F").kind == kBackspace
    check decodeSequence("\b").kind == kBackspace

  test "ctrl-c quits rather than killing the process":
    # PID-1-adjacent code aside, an installer that dies mid-partition on a
    # stray ctrl-c leaves a half-written table. It gets treated as Q.
    check decodeSequence("\x03") == charKey('q')

  test "control bytes with no meaning are ignored, not typed":
    check decodeSequence("\x01").kind == kNone
    check decodeSequence("\x1F").kind == kNone

suite "escape sequences":
  test "csi arrows":
    check decodeSequence("\e[A").kind == kUp
    check decodeSequence("\e[B").kind == kDown
    check decodeSequence("\e[C").kind == kRight
    check decodeSequence("\e[D").kind == kLeft

  test "ss3 arrows, which foot emits in application cursor mode":
    check decodeSequence("\eOA").kind == kUp
    check decodeSequence("\eOB").kind == kDown
    check decodeSequence("\eOC").kind == kRight
    check decodeSequence("\eOD").kind == kLeft

  test "home, end, page and delete in both forms":
    check decodeSequence("\e[H").kind == kHome
    check decodeSequence("\e[F").kind == kEnd
    check decodeSequence("\e[1~").kind == kHome
    check decodeSequence("\e[4~").kind == kEnd
    check decodeSequence("\e[3~").kind == kDelete
    check decodeSequence("\e[5~").kind == kPageUp
    check decodeSequence("\e[6~").kind == kPageDown

  test "modified arrows still resolve to the arrow":
    # xterm sends ESC [ 1 ; 5 A for ctrl-up. Losing the key entirely because
    # of an unread modifier is worse than ignoring the modifier.
    check decodeSequence("\e[1;5A").kind == kUp
    check decodeSequence("\e[1;2D").kind == kLeft

  test "a bare escape is escape":
    check decodeSequence("\e").kind == kEscape

  test "an incomplete csi is not mistaken for a key":
    # This is the sequence in flight. Treating it as a keypress is how an
    # installer exits the moment someone presses Up.
    check decodeSequence("\e[").kind == kNone
    check decodeSequence("\e[1;5").kind == kNone

  test "an unknown final byte yields nothing rather than a wrong key":
    check decodeSequence("\e[Z").kind == kNone
    check decodeSequence("\e[99~").kind == kNone

  test "empty input":
    check decodeSequence("").kind == kNone
