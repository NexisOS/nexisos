import std/[math, strutils, unittest]
import ../../../src/tuiinstaller/[theme, term, title, ui, state,
                                  installation, anim]

suite "colour quantisation":
  test "molokai colours map to distinct 256 indices":
    let idx = [to256(mkPink), to256(mkGreen), to256(mkYellow),
               to256(mkOrange), to256(mkPurple), to256(mkCyan)]
    for i in 0 ..< idx.len:
      for j in i + 1 ..< idx.len:
        check idx[i] != idx[j]

  test "the background maps to a dark index, not to black":
    let i = to256(mkBackground)
    check i != 16
    check luminance(mkBackground) < 60

  test "greyscale prefers the grey ramp over the colour cube":
    check to256(rgb(0x80, 0x80, 0x80)) >= 232

  test "pure black and white hit the ramp ends sensibly":
    check to16(rgb(0, 0, 0)) == 0
    check to16(rgb(255, 255, 255)) == 15

  test "16-colour mapping keeps accent and error distinguishable":
    # The sidebar cannot rely on colour alone at this depth, but the two must
    # still differ or the fallback is actively misleading.
    check to16(clAccent) != to16(clError)

  test "blend clamps outside 0..1":
    check blend(mkPink, mkCyan, -1.0) == mkPink
    check blend(mkPink, mkCyan, 2.0) == mkCyan

suite "terminal capabilities":
  test "utf-8 round-trips through the rune codec":
    for s in ["a", "\u2502", "\u2713", "\u25b8", "\u2717"]:
      check encodeRune(toRune32(s)) == s

  test "putStr advances one cell per glyph, not per byte":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true, width: 20, height: 3))
    scr.putStr(0, 0, "\u2713 ok", clFg)
    check encodeRune(scr.at(0, 0).ch) == "\u2713"
    check encodeRune(scr.at(1, 0).ch) == " "
    check encodeRune(scr.at(2, 0).ch) == "o"

  test "writes outside the screen are dropped, not wrapped":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true, width: 10, height: 2))
    scr.putStr(8, 0, "abcdef", clFg)
    check encodeRune(scr.at(9, 0).ch) == "b"
    check encodeRune(scr.at(0, 1).ch) == " "

  test "render emits nothing when nothing changed":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true, width: 20, height: 3))
    scr.putStr(0, 0, "hello", clFg)
    check render(scr).len > 0
    check render(scr).len == 0

  test "render cost tracks changed cells, not screen size":
    # The logo animates continuously and the fallback path may be a serial
    # console, so a frame must cost what changed rather than what is visible.
    var small = newScreen(Caps(depth: cdTrue, unicode: true, width: 40,
                               height: 6))
    var big = newScreen(Caps(depth: cdTrue, unicode: true, width: 200,
                             height: 50))
    discard render(small)
    discard render(big)
    small.putStr(3, 2, "x", clFg)
    big.putStr(3, 2, "x", clFg)
    check render(small) == render(big)

  test "mono depth emits no colour sequences":
    var scr = newScreen(Caps(depth: cdMono, unicode: false, width: 20, height: 2))
    scr.putStr(0, 0, "hi", clAccent)
    let emitted = render(scr)
    check "38;2" notin emitted
    check "38;5" notin emitted

suite "layout degradation":
  test "a wide terminal gets the sidebar and a full hint panel":
    let l = computeLayout(120, 34)
    check l.showSidebar
    check l.hintH == 6

  test "the 80x24 kernel console keeps the sidebar":
    # This is the fixed VT size and the case that has to look deliberate.
    let l = computeLayout(80, 24)
    check l.showSidebar
    check l.contentW > 40
    check l.hintH > 0

  test "a narrow terminal drops the sidebar entirely":
    let l = computeLayout(60, 24)
    check not l.showSidebar
    check l.sidebarW == 0

  test "content area stays positive at every size":
    for w in [40, 60, 70, 80, 100, 120, 200]:
      for h in [16, 24, 30, 50]:
        let l = computeLayout(w, h)
        check l.contentH > 0
        check l.contentX >= 0
        check l.hintY > l.contentY

suite "title":
  test "the wordmark is mixed case, not all caps":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true,
                             width: titleWidth() + 2, height: titleHeight() + 1))
    drawTitle(scr, 0, 0)
    # Lowercase glyphs leave the top two rows of their cell empty; an all-caps
    # banner would fill row 0 under every letter.
    var row0 = 0
    for x in 0 ..< titleWidth():
      if encodeRune(scr.at(x, 0).ch) == "#": inc row0
    var row4 = 0
    for x in 0 ..< titleWidth():
      if encodeRune(scr.at(x, 4).ch) == "#": inc row4
    check row0 > 0
    check row4 > row0

  test "all glyph rows are the same width":
    var scr = newScreen(Caps(depth: cdTrue, unicode: true,
                             width: titleWidth() + 4, height: titleHeight() + 1))
    drawTitle(scr, 0, 0)
    for y in 0 ..< titleHeight():
      check encodeRune(scr.at(titleWidth() + 1, y).ch) == " "

suite "steps and hints":
  proc uiAt(step: Step, w = 100, h = 28, uni = true, dry = true): Ui =
    result = Ui(scr: newScreen(Caps(depth: cdTrue, unicode: uni, width: w,
                                    height: h)),
                wiz: initWizard(dry), status: "")
    result.wiz.step = step
    result.wiz.cfg.disk = "/dev/nvme0n1"
    result.layout = computeLayout(w, h)

  test "every step has a hint":
    for s in Step:
      check stepHint(s).len > 0

  test "hints appear on the rendered page":
    var u = uiAt(stReview)
    u.drawFrame()
    check "erases the disk" in u.scr.renderFull()

  test "every step renders without crashing at every size":
    for s in Step:
      for (w, h) in [(60, 20), (80, 24), (100, 28), (200, 50)]:
        var u = uiAt(s, w, h)
        u.drawFrame()
        check u.scr.renderFull().len > 0

  test "dry-run mode is visible in the chrome":
    var u = uiAt(stInstall)
    u.drawFrame()
    check "DRY RUN" in u.scr.renderFull()

  test "a real install warns about erasing the disk":
    var u = uiAt(stInstall, dry = false)
    u.drawFrame()
    let f = u.scr.renderFull()
    check "erase /dev/nvme0n1" in f
    check "DRY RUN" notin f

  test "the current step is highlighted by fill, not only by colour":
    var u = uiAt(stPartition)
    u.drawFrame()
    check u.scr.at(1, 7).bg == clPanel
    check u.scr.at(1, 6).bg == clBg

  test "validation messages surface on the page":
    var u = uiAt(stSystem)
    u.wiz.cfg.hostname = "bad host"
    u.drawFrame()
    check "cannot start or" in u.scr.renderFull()

  test "the compact indicator replaces the sidebar when narrow":
    var u = uiAt(stSystem, 60, 24)
    u.drawFrame()
    let f = u.scr.renderFull()
    check "Step 4/7" in f
    check "Partitioning" notin f

suite "selection and editing":
  proc wizAt(step: Step): Wizard =
    result = initWizard(dryRun = true)
    result.step = step
    result.cfg.disk = "/dev/nvme0n1"

  test "every step's row count matches what it draws":
    var w = wizAt(stPartition)
    check w.rowCount() == 2
    w = wizAt(stSystem)
    check w.rowCount() == 3
    w = wizAt(stWelcome)
    check w.rowCount() == 0

  test "the cursor is clamped into range when a step has fewer rows":
    var w = wizAt(stPartition)
    w.sel = 99
    w.clampSel()
    check w.sel == 1
    w.sel = -3
    w.clampSel()
    check w.sel == 0

  test "a step with no rows keeps the cursor at zero":
    var w = wizAt(stReview)
    w.sel = 4
    w.clampSel()
    check w.sel == 0

  test "navigating resets the cursor and leaves edit mode":
    # Carrying a cursor across steps puts it on a row the user never chose.
    var w = wizAt(stPartition)
    w.sel = 1
    w.editing = true
    check w.next()
    check w.sel == 0
    check not w.editing

  test "text rows are text and option rows are not":
    var w = wizAt(stSystem)
    check w.rowIsText()
    w = wizAt(stUser)
    w.sel = 0
    check w.rowIsText()          ## username
    w.sel = 1
    check not w.rowIsText()      ## profile is an option
    w = wizAt(stPartition)
    check not w.rowIsText()

suite "install page":
  proc installUi(dry = true, started = false): Ui =
    result = Ui(scr: newScreen(Caps(depth: cdTrue, unicode: true, width: 100,
                                    height: 30)),
                wiz: initWizard(dry), status: "")
    result.wiz.step = stInstall
    result.wiz.cfg.disk = "/dev/nvme0n1"
    result.layout = computeLayout(100, 30)
    result.runner = initRunner(result.wiz.cfg)
    result.runner.started = started

  test "before starting it offers the plan rather than a fake progress bar":
    var u = installUi()
    u.drawFrame()
    let f = u.scr.renderFull()
    check "commands are planned" in f
    check "%" notin f

  test "once running it lists stages and a progress bar":
    var u = installUi(started = true)
    discard u.runner.step()
    u.drawFrame()
    let f = u.scr.renderFull()
    check "Partitioning the disk" in f
    check "Building generation 1" in f
    check "%" in f

  test "the spinner advances with the tick":
    var u = installUi(started = true)
    discard u.runner.step()
    u.drawFrame()
    let a = u.scr.renderFull()
    u.tick = 3
    u.drawFrame()
    check u.scr.renderFull() != a

  test "a completed dry run says nothing was executed":
    var u = installUi(started = true)
    var guard = 0
    while u.runner.step() and guard < 1000: inc guard
    u.drawFrame()
    check "none executed" in u.scr.renderFull()

  test "the install page renders at every size while running":
    for (w, h) in [(60, 20), (80, 24), (100, 30), (200, 50)]:
      var u = installUi(started = true)
      u.scr = newScreen(Caps(depth: cdTrue, unicode: true, width: w, height: h))
      u.layout = computeLayout(w, h)
      discard u.runner.step()
      u.drawFrame()
      check u.scr.renderFull().len > 0

  test "it renders on the VT with no unicode":
    # The fallback console is the surface with the least margin, and the one a
    # user only reaches because something already went wrong.
    var u = installUi(started = true)
    u.scr = newScreen(Caps(depth: cd16, unicode: false, width: 80, height: 24))
    u.layout = computeLayout(80, 24)
    discard u.runner.step()
    u.drawFrame()
    let f = u.scr.renderFull()
    check "Partitioning the disk" in f
    check "\u2588" notin f
    check "\u2713" notin f

suite "welcome page":
  test "the wordmark and the pitch both appear":
    var u = Ui(scr: newScreen(Caps(depth: cdTrue, unicode: true, width: 100,
                                   height: 30)),
               wiz: initWizard(true), status: "")
    u.layout = computeLayout(100, 30)
    u.drawFrame()
    let f = u.scr.renderFull()
    check "A declarative Linux distribution" in f
    check "Seven steps" in f

  test "a real session invites you to begin; a dry run says it writes nothing":
    var dry = Ui(scr: newScreen(Caps(depth: cdTrue, unicode: true, width: 100,
                                     height: 30)),
                 wiz: initWizard(true), status: "")
    dry.layout = computeLayout(100, 30)
    dry.drawFrame()
    check "will not write anything" in dry.scr.renderFull()

    var real = Ui(scr: newScreen(Caps(depth: cdTrue, unicode: true, width: 100,
                                      height: 30)),
                  wiz: initWizard(false), status: "")
    real.layout = computeLayout(100, 30)
    real.drawFrame()
    check "Press enter to begin" in real.scr.renderFull()
