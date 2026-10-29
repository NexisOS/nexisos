## Keyboard input.
##
## Decoding is a pure function over the bytes read, so the whole key table is
## testable without a terminal. Reading is the only part that touches the
## outside world.
##
## Arrow keys arrive as `ESC [ A`, which is three separate reads. A naive
## installer treats the bare `ESC` as "quit" and exits the moment someone
## presses Up. So `ESC` alone is only a key if no byte follows it promptly.

import std/[termios, posix]

type
  KeyKind* = enum
    kNone
    kChar
    kEnter
    kEscape
    kBackspace
    kTab
    kUp, kDown, kLeft, kRight
    kHome, kEnd, kPageUp, kPageDown
    kDelete

  Key* = object
    kind*: KeyKind
    ch*: char        ## valid when kind == kChar

func key*(k: KeyKind): Key = Key(kind: k)
func charKey*(c: char): Key = Key(kind: kChar, ch: c)

func decodeCsi*(final: char, param: string): Key =
  ## The `ESC [ ... final` family. Parameters are only consulted for the
  ## tilde forms, where the number is the whole meaning.
  case final
  of 'A': key(kUp)
  of 'B': key(kDown)
  of 'C': key(kRight)
  of 'D': key(kLeft)
  of 'H': key(kHome)
  of 'F': key(kEnd)
  of '~':
    case param
    of "1", "7": key(kHome)
    of "3": key(kDelete)
    of "4", "8": key(kEnd)
    of "5": key(kPageUp)
    of "6": key(kPageDown)
    else: key(kNone)
  else: key(kNone)

func decodeSs3*(final: char): Key =
  ## `ESC O x`. Emitted by some terminals in application cursor mode, which
  ## `foot` uses by default for the arrow keys.
  case final
  of 'A': key(kUp)
  of 'B': key(kDown)
  of 'C': key(kRight)
  of 'D': key(kLeft)
  of 'H': key(kHome)
  of 'F': key(kEnd)
  else: key(kNone)

func decodeByte*(c: char): Key =
  ## A single byte with no escape prefix.
  case c
  of '\r', '\n': key(kEnter)
  of '\t': key(kTab)
  of '\x7F', '\b': key(kBackspace)
  of '\x1B': key(kEscape)
  of '\x03': charKey('q')      ## Ctrl-C quits like Q rather than dying
  else:
    if c >= ' ' and c < '\x7F': charKey(c) else: key(kNone)

func decodeSequence*(s: string): Key =
  ## Decode a complete byte sequence. Used by the tests and by any caller that
  ## already has the bytes in hand.
  if s.len == 0: return key(kNone)
  if s[0] != '\x1B': return decodeByte(s[0])
  if s.len == 1: return key(kEscape)
  if s[1] == '[':
    var i = 2
    var param = ""
    while i < s.len and (s[i] in {'0'..'9'} or s[i] == ';'):
      param.add s[i]
      inc i
    if i < s.len: return decodeCsi(s[i], param)
    return key(kNone)
  if s[1] == 'O' and s.len >= 3:
    return decodeSs3(s[2])
  key(kEscape)

# --- Raw mode ----------------------------------------------------------------

type RawMode* = object
  saved: Termios
  active: bool

proc enterRaw*(): RawMode =
  ## Canonical mode buffers until Enter and echoes; both are wrong for a full
  ## screen UI. ISIG stays *on* deliberately, so Ctrl-C still reaches us as a
  ## byte we translate to quit rather than being swallowed entirely.
  if isatty(0) == 0:
    return RawMode(active: false)
  var t: Termios
  discard tcGetAttr(0, addr t)
  result.saved = t
  result.active = true
  t.c_lflag = t.c_lflag and not (Cflag(ICANON) or Cflag(ECHO))
  t.c_cc[VMIN] = 0.char
  t.c_cc[VTIME] = 1.char        ## 100ms poll, which sets the frame rate
  discard tcSetAttr(0, TCSANOW, addr t)

proc leaveRaw*(m: RawMode) =
  if not m.active: return
  var t = m.saved
  discard tcSetAttr(0, TCSANOW, addr t)

proc readByte(): (bool, char) =
  ## One byte, or nothing if the terminal stays quiet. VTIME already bounds
  ## the read, so this does not spin.
  var buf: array[1, char]
  let n = read(0, addr buf[0], 1)
  if n == 1: (true, buf[0]) else: (false, '\0')

proc readKey*(): Key =
  ## Non-blocking-ish: returns `kNone` when nothing arrived within the VTIME
  ## window, which is what drives the animation tick.
  let (got, c) = readByte()
  if not got: return key(kNone)
  if c != '\x1B': return decodeByte(c)

  # An escape *might* be the start of a sequence. Give the rest a brief chance
  # to arrive; a real ESC keypress has nothing behind it.
  var pending = "\x1B"
  for _ in 0 ..< 8:
    let (more, m) = readByte()
    if not more: break
    pending.add m
    if pending.len >= 2 and pending[1] notin {'[', 'O'}: break
    let k = decodeSequence(pending)
    if k.kind != kNone: return k
  decodeSequence(pending)
