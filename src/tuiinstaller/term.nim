## Screen buffer and terminal capability detection.
##
## Everything draws into a cell grid; the grid is diffed against the previous
## frame and only changed cells are emitted. That matters here because the logo
## animates continuously — repainting 80x24 every frame over a serial console
## at 115200 baud would be visibly slow, and on a VT it flickers.

import std/[os, strutils, terminal]
import ./theme

type
  Caps* = object
    depth*: ColorDepth
    unicode*: bool     ## can we draw box-drawing and block glyphs?
    width*, height*: int

  Cell* = object
    ch*: Rune32
    fg*, bg*: Rgb
    bold*: bool

  Rune32* = uint32

  Screen* = object
    caps*: Caps
    cells: seq[Cell]
    prev: seq[Cell]
    w, h: int

func toRune32*(s: string): Rune32 =
  ## Minimal UTF-8 decode of the first character. The installer only ever needs
  ## single glyphs from literals, so a full unicode dependency is not worth it.
  if s.len == 0: return uint32(' ')
  let b0 = uint32(uint8(s[0]))
  if b0 < 0x80: return b0
  if s.len >= 2 and (b0 and 0xE0) == 0xC0:
    return ((b0 and 0x1F) shl 6) or (uint32(uint8(s[1])) and 0x3F)
  if s.len >= 3 and (b0 and 0xF0) == 0xE0:
    return ((b0 and 0x0F) shl 12) or
           ((uint32(uint8(s[1])) and 0x3F) shl 6) or
           (uint32(uint8(s[2])) and 0x3F)
  if s.len >= 4:
    return ((b0 and 0x07) shl 18) or
           ((uint32(uint8(s[1])) and 0x3F) shl 12) or
           ((uint32(uint8(s[2])) and 0x3F) shl 6) or
           (uint32(uint8(s[3])) and 0x3F)
  uint32('?')

func encodeRune*(r: Rune32): string =
  if r < 0x80:
    result = $char(r)
  elif r < 0x800:
    result = $char(0xC0 or (r shr 6)) & $char(0x80 or (r and 0x3F))
  elif r < 0x10000:
    result = $char(0xE0 or (r shr 12)) &
             $char(0x80 or ((r shr 6) and 0x3F)) &
             $char(0x80 or (r and 0x3F))
  else:
    result = $char(0xF0 or (r shr 18)) &
             $char(0x80 or ((r shr 12) and 0x3F)) &
             $char(0x80 or ((r shr 6) and 0x3F)) &
             $char(0x80 or (r and 0x3F))

proc detectCaps*(): Caps =
  ## Deliberately conservative. Guessing high produces a screen full of
  ## question marks on the console the user fell back to *because something
  ## already went wrong*; guessing low costs some colour fidelity.
  let term = getEnv("TERM", "dumb")
  let colorterm = getEnv("COLORTERM", "").toLowerAscii()

  result.depth =
    if getEnv("NO_COLOR", "").len > 0: cdMono
    elif colorterm in ["truecolor", "24bit"]: cdTrue
    elif "256color" in term: cd256
    elif term in ["dumb", ""]: cdMono
    else: cd16

  # The kernel console's built-in font has no box-drawing or block glyphs at
  # the codepoints we would want, and TERM=linux is how we know we are on it.
  let lang = getEnv("LC_ALL", getEnv("LC_CTYPE", getEnv("LANG", "")))
  result.unicode = term != "linux" and
                   ("UTF-8" in lang or "utf8" in lang.toLowerAscii())

  try:
    result.width = terminalWidth()
    result.height = terminalHeight()
  except CatchableError:
    result.width = 80
    result.height = 24
  if result.width <= 0: result.width = 80
  if result.height <= 0: result.height = 24

proc newScreen*(caps: Caps): Screen =
  result.caps = caps
  result.w = caps.width
  result.h = caps.height
  let blank = Cell(ch: uint32(' '), fg: clFg, bg: clBg, bold: false)
  result.cells = newSeq[Cell](result.w * result.h)
  result.prev = newSeq[Cell](result.w * result.h)
  for i in 0 ..< result.cells.len:
    result.cells[i] = blank
    # Force a full first paint by making prev differ.
    result.prev[i] = Cell(ch: 0, fg: clFg, bg: clBg)

func width*(s: Screen): int = s.w
func height*(s: Screen): int = s.h

proc clear*(s: var Screen) =
  let blank = Cell(ch: uint32(' '), fg: clFg, bg: clBg, bold: false)
  for i in 0 ..< s.cells.len: s.cells[i] = blank

proc put*(s: var Screen, x, y: int, ch: Rune32, fg: Rgb, bg = clBg,
          bold = false) =
  if x < 0 or y < 0 or x >= s.w or y >= s.h: return
  s.cells[y * s.w + x] = Cell(ch: ch, fg: fg, bg: bg, bold: bold)

proc putStr*(s: var Screen, x, y: int, text: string, fg: Rgb, bg = clBg,
             bold = false) =
  var cx = x
  var i = 0
  while i < text.len:
    var len = 1
    let b = uint8(text[i])
    if b >= 0xF0: len = 4
    elif b >= 0xE0: len = 3
    elif b >= 0xC0: len = 2
    if i + len > text.len: len = 1
    s.put(cx, y, toRune32(text[i ..< i + len]), fg, bg, bold)
    inc cx
    i += len

func at*(s: Screen, x, y: int): Cell =
  if x < 0 or y < 0 or x >= s.w or y >= s.h:
    Cell(ch: uint32(' '), fg: clFg, bg: clBg)
  else:
    s.cells[y * s.w + x]

proc fgSeq(depth: ColorDepth, c: Rgb): string =
  case depth
  of cdMono: ""
  of cd16:
    let i = to16(c)
    if i < 8: "\e[" & $(30 + i) & "m" else: "\e[" & $(90 + i - 8) & "m"
  of cd256: "\e[38;5;" & $to256(c) & "m"
  of cdTrue: "\e[38;2;" & $c.r & ";" & $c.g & ";" & $c.b & "m"

proc bgSeq(depth: ColorDepth, c: Rgb): string =
  case depth
  of cdMono: ""
  of cd16:
    let i = to16(c)
    if i < 8: "\e[" & $(40 + i) & "m" else: "\e[" & $(100 + i - 8) & "m"
  of cd256: "\e[48;5;" & $to256(c) & "m"
  of cdTrue: "\e[48;2;" & $c.r & ";" & $c.g & ";" & $c.b & "m"

proc render*(s: var Screen): string =
  ## Emit only the cells that changed since the last render. Runs of adjacent
  ## changed cells with identical attributes share one escape sequence.
  var buf = ""
  var lastFg = Rgb(r: -1, g: -1, b: -1)
  var lastBg = Rgb(r: -1, g: -1, b: -1)
  var lastBold = false
  var cursorX = -1
  var cursorY = -1

  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      let i = y * s.w + x
      let c = s.cells[i]
      if c == s.prev[i]: continue

      if cursorY != y or cursorX != x:
        buf.add "\e[" & $(y + 1) & ";" & $(x + 1) & "H"
        cursorY = y
        cursorX = x

      if s.caps.depth != cdMono:
        if c.fg != lastFg:
          buf.add fgSeq(s.caps.depth, c.fg)
          lastFg = c.fg
        if c.bg != lastBg:
          buf.add bgSeq(s.caps.depth, c.bg)
          lastBg = c.bg
      if c.bold != lastBold:
        buf.add(if c.bold: "\e[1m" else: "\e[22m")
        lastBold = c.bold

      buf.add encodeRune(c.ch)
      inc cursorX
      s.prev[i] = c

  buf

proc renderFull*(s: Screen): string =
  ## Whole frame as plain text, for tests and for `--dump`.
  for y in 0 ..< s.h:
    for x in 0 ..< s.w:
      result.add encodeRune(s.cells[y * s.w + x].ch)
    result.add "\n"

const
  altScreenOn* = "\e[?1049h\e[?25l"
  altScreenOff* = "\e[?25h\e[?1049l\e[0m"
