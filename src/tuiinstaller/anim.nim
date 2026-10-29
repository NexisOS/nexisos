## Loading animations.
##
## Every animation here is a pure function of a tick counter. Nothing holds a
## timer, a thread, or a start timestamp. That is what makes them testable —
## `spinnerFrame(caps, 7)` is checkable — and it is also what keeps the render
## loop honest: the frame you see is derived from the frame number, so a
## dropped frame skips ahead rather than falling behind and accumulating lag.
##
## The title is deliberately static (see `title.nim`). The animation budget is
## spent here instead, on the screens where something is actually happening and
## the user needs to know the machine has not hung.
##
## Three surfaces, again:
##
##   unicode terminal    braille spinner, eighth-block progress bar
##   VT / no unicode     ASCII spinner, `#` progress bar
##   serial console      same as VT, and the frame diff keeps it cheap
##
## A spinner that renders as `?` on the console someone fell back to *because
## something already went wrong* is worse than no spinner, so every frame set
## has an ASCII twin of the same length.

import std/strutils
import ./theme, ./term

# --- Spinners ----------------------------------------------------------------

const
  BrailleFrames* = ["\u280B", "\u2819", "\u2839", "\u2838", "\u283C", "\u2834",
                    "\u2826", "\u2827", "\u2807", "\u280F"]
  AsciiFrames*   = ["-", "\\", "|", "/"]

func spinnerFrame*(unicode: bool, tick: int): string =
  ## Frame for this tick. Negative ticks are clamped rather than wrapping into
  ## a negative index, because a caller passing an elapsed-time subtraction
  ## should get a spinner, not a crash.
  let t = if tick < 0: 0 else: tick
  if unicode: BrailleFrames[t mod BrailleFrames.len]
  else: AsciiFrames[t mod AsciiFrames.len]

proc drawSpinner*(scr: var Screen, x, y, tick: int, label: string,
                  col = clAccent) =
  scr.putStr(x, y, spinnerFrame(scr.caps.unicode, tick), col, clBg,
             bold = true)
  if label.len > 0:
    scr.putStr(x + 2, y, label, clFg)

# --- Progress bars -----------------------------------------------------------

const EighthBlocks = ["", "\u258F", "\u258E", "\u258D", "\u258C", "\u258B",
                      "\u258A", "\u2589"]

func progressBar*(unicode: bool, width: int, fraction: float): string =
  ## A bar of exactly `width` cells. Unicode gets sub-cell resolution from the
  ## eighth-block glyphs, which matters at 20 cells wide where a whole-cell bar
  ## only has 21 distinguishable states and looks stuck.
  if width <= 0: return ""
  let f = if fraction < 0.0: 0.0 elif fraction > 1.0: 1.0 else: fraction

  if not unicode:
    let filled = int(f * float(width) + 0.5)
    return "#".repeat(filled) & "-".repeat(width - filled)

  let eighths = int(f * float(width * 8) + 0.5)
  let full = eighths div 8
  let rem = eighths mod 8
  result = "\u2588".repeat(min(full, width))
  if full < width:
    result.add EighthBlocks[rem]
    let used = full + (if rem > 0: 1 else: 0)
    result.add " ".repeat(width - used)

func percentText*(fraction: float): string =
  let f = if fraction < 0.0: 0.0 elif fraction > 1.0: 1.0 else: fraction
  align($int(f * 100.0 + 0.5), 3) & "%"

proc drawProgress*(scr: var Screen, x, y, width: int, fraction: float,
                   label = "") =
  ## `[####------]  40%  label`
  let inner = width - 2
  if inner <= 0: return
  scr.putStr(x, y, "[", clDim)
  let bar = progressBar(scr.caps.unicode, inner, fraction)
  scr.putStr(x + 1, y, bar, clAccent)
  scr.putStr(x + 1 + inner, y, "]", clDim)
  scr.putStr(x + width + 1, y, percentText(fraction), clFg, clBg, bold = true)
  if label.len > 0:
    scr.putStr(x + width + 7, y, label, clDim)

# --- The build wave ----------------------------------------------------------
#
# Shown while a generation builds, which is the longest wait in the install and
# the one with no meaningful percentage to report — the build is a graph being
# drained, not a file being copied. A travelling wave says "working" without
# implying a completion estimate the installer cannot honestly make.

const
  WaveUnicode = "\u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588\u2587\u2586\u2585\u2584\u2583\u2582"
  WaveAscii   = ".:-=+*#%#*+=-:"

func waveGlyphs(unicode: bool): seq[string] =
  if unicode:
    for i in countup(0, WaveUnicode.len - 1, 3):
      result.add WaveUnicode[i ..< i + 3]
  else:
    for c in WaveAscii:
      result.add $c

func waveRow*(unicode: bool, width, tick: int): string =
  ## One row of a travelling wave, `width` cells wide.
  if width <= 0: return ""
  let g = waveGlyphs(unicode)
  let t = if tick < 0: 0 else: tick
  for i in 0 ..< width:
    result.add g[(i + t) mod g.len]

proc drawWave*(scr: var Screen, x, y, width, tick: int) =
  ## Coloured across the same cyan-to-green range as the wordmark, so the two
  ## animated-looking things on screen read as the same family.
  let g = waveGlyphs(scr.caps.unicode)
  let t = if tick < 0: 0 else: tick
  for i in 0 ..< width:
    let glyph = g[(i + t) mod g.len]
    scr.put(x + i, y, toRune32(glyph),
            blend(mkCyan, mkGreen, float(i) / float(max(width - 1, 1))),
            clBg, bold = true)

# --- Step ticker -------------------------------------------------------------

type
  StepState* = enum
    ssPending
    ssRunning
    ssDone
    ssFailed

func stepGlyph*(unicode: bool, st: StepState, tick: int): string =
  case st
  of ssPending: (if unicode: "\u25CB" else: "-")
  of ssRunning: spinnerFrame(unicode, tick)
  of ssDone:    (if unicode: "\u2713" else: "*")
  of ssFailed:  (if unicode: "\u2717" else: "!")

func stepColor*(st: StepState): Rgb =
  case st
  of ssPending: clPending
  of ssRunning: clAccent
  of ssDone:    clDone
  of ssFailed:  clError

proc drawStepLine*(scr: var Screen, x, y: int, st: StepState, tick: int,
                   label: string) =
  ## One line of the install progress list. The glyph carries the state as well
  ## as the colour, because at 16 colours running and done are not reliably
  ## distinguishable and the fallback console is exactly where a stalled step
  ## most needs to be visible.
  scr.putStr(x, y, stepGlyph(scr.caps.unicode, st, tick), stepColor(st), clBg,
             bold = st == ssRunning)
  scr.putStr(x + 2, y, label,
             (if st == ssPending: clPending else: clFg),
             clBg, bold = st == ssRunning)
