import std/[strutils, unittest]
import ../../../src/tuiinstaller/[anim, term, theme]

suite "spinners":
  test "frames cycle and every frame is one glyph wide":
    var seen: seq[string]
    for t in 0 ..< BrailleFrames.len:
      seen.add spinnerFrame(true, t)
    check seen.len == BrailleFrames.len
    check spinnerFrame(true, BrailleFrames.len) == spinnerFrame(true, 0)

  test "ascii fallback exists for every unicode frame":
    # The VT is the surface a user only reaches because something already went
    # wrong. A spinner that renders as '?' there is worse than none.
    for t in 0 ..< 20:
      let a = spinnerFrame(false, t)
      check a.len == 1
      check a[0] in {'-', '\\', '|', '/'}

  test "negative ticks clamp rather than indexing backwards":
    check spinnerFrame(true, -5) == spinnerFrame(true, 0)
    check spinnerFrame(false, -1) == spinnerFrame(false, 0)

suite "progress bars":
  test "ascii bar is exactly the requested width at every fraction":
    for f in [0.0, 0.01, 0.33, 0.5, 0.99, 1.0]:
      check progressBar(false, 20, f).len == 20

  test "empty and full are unambiguous":
    check progressBar(false, 10, 0.0) == "----------"
    check progressBar(false, 10, 1.0) == "##########"

  test "fractions clamp outside 0..1":
    check progressBar(false, 8, -3.0) == progressBar(false, 8, 0.0)
    check progressBar(false, 8, 9.0) == progressBar(false, 8, 1.0)

  test "unicode bar gets sub-cell resolution":
    # At 20 cells a whole-cell bar has 21 states and looks stuck; the eighth
    # blocks are what make slow progress visibly move.
    check progressBar(true, 20, 0.50) != progressBar(true, 20, 0.52)

  test "zero width is not a crash":
    check progressBar(true, 0, 0.5) == ""
    check progressBar(false, -4, 0.5) == ""

  test "percent text is right-aligned to a stable width":
    check percentText(0.0) == "  0%"
    check percentText(0.5) == " 50%"
    check percentText(1.0) == "100%"

suite "the build wave":
  test "row is the requested width and travels with the tick":
    check waveRow(false, 30, 0).len == 30
    check waveRow(false, 30, 0) != waveRow(false, 30, 1)

  test "the wave repeats rather than running out of glyphs":
    check waveRow(false, 5, 0) == waveRow(false, 5, 14)

suite "step states":
  test "state is carried by the glyph, not only by the colour":
    # 16-colour mode cannot reliably distinguish running from done, and the
    # fallback console is exactly where a stalled step most needs to be seen.
    let g = [stepGlyph(false, ssPending, 0), stepGlyph(false, ssDone, 0),
             stepGlyph(false, ssFailed, 0)]
    check g[0] != g[1]
    check g[1] != g[2]
    check g[0] != g[2]

  test "a running step animates, the others do not":
    check stepGlyph(true, ssRunning, 0) != stepGlyph(true, ssRunning, 1)
    check stepGlyph(true, ssDone, 0) == stepGlyph(true, ssDone, 5)

  test "colours differ between states at 16 colours":
    check to16(stepColor(ssDone)) != to16(stepColor(ssFailed))
    check to16(stepColor(ssRunning)) != to16(stepColor(ssPending))

suite "drawing":
  test "animations render into a screen without escaping it":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true, width: 30,
                             height: 4))
    drawSpinner(scr, 0, 0, 3, "working")
    drawProgress(scr, 0, 1, 20, 0.4)
    drawWave(scr, 0, 2, 25, 7)
    drawStepLine(scr, 0, 3, ssRunning, 2, "Building generation 1")
    let f = scr.renderFull()
    check "working" in f
    check "Building generation 1" in f

  test "drawing past the right edge is dropped, not wrapped":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true, width: 12,
                             height: 2))
    drawWave(scr, 0, 0, 40, 0)          # deliberately wider than the screen
    drawStepLine(scr, 0, 1, ssDone, 0, "a very long stage label indeed")
    # Nothing bled onto the next row.
    check encodeRune(scr.at(11, 0).ch) != " "
    check encodeRune(scr.at(0, 1).ch) == stepGlyph(true, ssDone, 0)
