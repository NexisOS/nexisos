## Screen composition: sidebar, content area, hint panel, status line.
##
##  +------------------------+---------------------------------------------+
##  |  sidebar: steps        |  content for the current step                |
##  |  current highlighted   |                                             |
##  |                        +---------------------------------------------+
##  |                        |  hints: what this step means, in plain words |
##  +------------------------+---------------------------------------------+
##  | status / keys                                                        |
##  +----------------------------------------------------------------------+
##
## The hint panel is permanent, not a help key. Someone installing a
## declarative distribution for the first time does not know what a generation
## is, and will not press F1 to find out.
##
## Layout degrades in one stage: below 70 columns the sidebar collapses to a
## "Step 4/7" indicator. 80x24 is the kernel console's fixed size and is the
## case that has to look deliberate rather than cramped.

import std/strutils
import ./theme, ./term, ./title, ./state, ./anim, ./partition,
       ./configuration, ./network, ./installation

type
  Layout* = object
    sidebarW*: int
    showSidebar*: bool
    contentX*, contentY*, contentW*, contentH*: int
    hintY*, hintH*: int

  Ui* = object
    scr*: Screen
    wiz*: Wizard
    status*: string
    layout*: Layout
    tick*: int              ## frame counter; every animation derives from it
    runner*: Runner         ## populated once the install page starts
    links*: seq[Link]
    efiBooted*: bool

const
  SidebarWide = 26
  MinSidebarCols = 70
  HintLines = 6

proc computeLayout*(w, h: int): Layout =
  result.showSidebar = w >= MinSidebarCols
  result.sidebarW = if result.showSidebar: SidebarWide else: 0
  result.contentX = result.sidebarW + (if result.showSidebar: 1 else: 0)
  result.contentY = 1
  result.contentW = w - result.contentX - 1
  result.hintH = min(HintLines, max(0, h - 10))
  result.hintY = h - 2 - result.hintH
  result.contentH = result.hintY - result.contentY - 1

proc newUi*(dryRun = false): Ui =
  result.scr = newScreen(detectCaps())
  result.wiz = initWizard(dryRun)
  result.status = "arrows move   enter select   D dry-run plan   Q quit"
  result.layout = computeLayout(result.scr.width, result.scr.height)
  result.tick = 0
  result.efiBooted = firmwareIsEfi()
  result.links = readLinks()
  result.wiz.cfg.scheme = detectScheme()

type Glyphs = object
  v, h, done, cur, pend: string

proc glyphs(u: Ui): Glyphs =
  if u.scr.caps.unicode:
    Glyphs(v: "\u2502", h: "\u2500", done: "\u2713", cur: "\u25b8",
           pend: "\u25cb")
  else:
    Glyphs(v: "|", h: "-", done: "*", cur: ">", pend: "-")

proc hline(u: var Ui, x, y, w: int, col: Rgb) =
  let g = u.glyphs()
  for i in 0 ..< w:
    u.scr.put(x + i, y, toRune32(g.h), col)

proc drawSidebar(u: var Ui) =
  if not u.layout.showSidebar: return
  let g = u.glyphs()
  let w = u.layout.sidebarW
  let h = u.scr.height

  for i in 0 ..< h - 2:
    u.scr.put(w, i, toRune32(g.v), clPanel)

  u.scr.putStr(2, 1, "NexisOS", clTitle, clBg, bold = true)
  u.scr.putStr(2, 2, "installer", clDim)
  u.hline(1, 3, w - 2, clPanel)

  var y = 5
  for s in Step:
    if y >= h - 3: break
    var marker = g.pend
    var col = clPending
    if s in u.wiz.done:
      marker = g.done
      col = clDone
    if s == u.wiz.step:
      # A filled row, not just a coloured label. At 16 colours the hue
      # difference between current and done is not reliably distinguishable,
      # so the highlight cannot rest on colour alone.
      for x in 1 ..< w:
        u.scr.put(x, y, uint32(' '), clFg, clPanel)
      u.scr.putStr(2, y, g.cur, clAccent, clPanel, bold = true)
      u.scr.putStr(4, y, $s, clAccent, clPanel, bold = true)
    else:
      u.scr.putStr(2, y, marker, col)
      u.scr.putStr(4, y, $s, col)
    inc y

  if u.wiz.cfg.dryRun:
    u.scr.putStr(2, h - 4, "DRY RUN", clWarn, clBg, bold = true)

proc drawCompactStep(u: var Ui) =
  if u.layout.showSidebar: return
  let label = "Step " & $(ord(u.wiz.step) + 1) & "/" & $StepCount & "  " &
              $u.wiz.step & (if u.wiz.cfg.dryRun: "   [DRY RUN]" else: "")
  u.scr.putStr(1, 0, label, clAccent, clBg, bold = true)

func wrapHint*(lines: seq[string], width: int): seq[string] =
  ## Hints are authored at a comfortable reading width, but the kernel console
  ## leaves about 52 columns once the sidebar is drawn. Clipping mid-word there
  ## is the difference between guidance and noise, so they re-wrap — and blank
  ## lines survive, because they are the paragraph breaks.
  if width <= 8: return lines
  for line in lines:
    if line.len == 0:
      result.add ""
      continue
    var cur = ""
    for word in line.split(' '):
      if word.len == 0: continue
      if cur.len == 0:
        cur = word
      elif cur.len + 1 + word.len <= width:
        cur.add " " & word
      else:
        result.add cur
        cur = word
    if cur.len > 0: result.add cur

proc drawHints(u: var Ui) =
  if u.layout.hintH <= 0: return
  let x = u.layout.contentX
  let w = u.scr.width - x - 1
  u.hline(x, u.layout.hintY - 1, w, clPanel)
  var y = u.layout.hintY
  let wrapped = wrapHint(stepHint(u.wiz.step), max(w - 4, 8))
  for line in wrapped:
    if y >= u.layout.hintY + u.layout.hintH: break
    u.scr.putStr(x + 2, y, line, clDim)
    inc y

proc drawStatus(u: var Ui) =
  let y = u.scr.height - 1
  for x in 0 ..< u.scr.width:
    u.scr.put(x, y, uint32(' '), clFg, clPanel)
  u.scr.putStr(1, y, u.status, clDim, clPanel)

proc putContent*(u: var Ui, dx, dy: int, text: string, col = clFg,
                 bold = false) =
  u.scr.putStr(u.layout.contentX + 2 + dx, u.layout.contentY + dy, text, col,
               clBg, bold)

proc drawWelcome(u: var Ui) =
  let x = u.layout.contentX + 2
  var y = u.layout.contentY

  if u.layout.contentW >= titleWidth() + 2 and
     u.layout.contentH > titleHeight() + 6:
    drawTitle(u.scr, x, y)
    y += titleHeight()
  else:
    drawTitleCompact(u.scr, x, y)
    inc y

  # A rule under the wordmark in the same cyan-to-green gradient, so the
  # welcome page reads as one composed thing rather than a banner with text
  # under it. Static, like the title: the animation budget belongs on the
  # pages where something is actually happening.
  inc y
  let ruleW = min(u.layout.contentW - 2, titleWidth())
  let g = u.glyphs()
  for i in 0 ..< ruleW:
    u.scr.put(x + i, y, toRune32(g.h),
              blend(mkCyan, mkGreen, float(i) / float(max(ruleW - 1, 1))))
  inc y
  inc y

  u.scr.putStr(x, y, "A declarative Linux distribution", clFg, clBg,
               bold = true)
  inc y
  u.scr.putStr(x, y, "reproducible builds, a real FHS, and SELinux that works",
               clDim)
  y += 2

  for line in [
      "Seven steps. Nothing is written to any disk until the last one,",
      "and the last one shows you every command before it runs.",
  ]:
    u.scr.putStr(x, y, line, clFg)
    inc y

  y += 1
  if u.wiz.cfg.dryRun:
    u.scr.putStr(x, y, "Dry run: this session will not write anything.",
                 clWarn, clBg, bold = true)
  else:
    u.scr.putStr(x, y, "Press enter to begin.", clAccent, clBg, bold = true)

proc drawRow(u: var Ui, dy: int, focused: bool, label, value, note: string) =
  ## One selectable row. The cursor is a glyph *and* a colour change, for the
  ## same reason the sidebar highlight is a fill: at 16 colours a hue shift
  ## alone is not reliably visible, and this is the fallback surface.
  let g = u.glyphs()
  let mark = if focused: g.cur else: " "
  let col = if focused: clAccent else: clFg
  u.putContent(0, dy, mark, col, focused)
  u.putContent(2, dy, label.alignLeft(12), (if focused: clAccent else: clDim))
  u.putContent(14, dy, value, col, focused)
  if note.len > 0 and u.layout.contentW > 46:
    u.putContent(14 + max(value.len + 2, 18), dy, note, clDim)

proc drawEditRow(u: var Ui, dy: int, focused, editing: bool,
                 label, value: string) =
  let g = u.glyphs()
  let mark = if focused: g.cur else: " "
  let col = if focused: clAccent else: clFg
  u.putContent(0, dy, mark, col, focused)
  u.putContent(2, dy, label.alignLeft(12), (if focused: clAccent else: clDim))
  u.putContent(14, dy, value, col, focused)
  if focused and editing:
    # A block cursor after the text, so it is obvious which field the next
    # keystroke lands in. Without it, typing on the wrong row is silent.
    u.putContent(14 + value.len, dy, "_", clAccent, true)

proc drawDisk(u: var Ui) =
  u.putContent(0, 0, "Select a target disk", clTitle, true)
  var y = 2
  if u.wiz.disks.len == 0:
    u.putContent(0, y, "No disks found.", clError, true)
    u.putContent(0, y + 2,
                 "The installer needs a whole block device. If this is a VM,",
                 clDim)
    u.putContent(0, y + 3, "check that a virtio or SATA disk is attached.",
                 clDim)
    return
  let g = u.glyphs()
  for i, d in u.wiz.disks:
    let focused = i == u.wiz.sel
    let chosen = d.device == u.wiz.cfg.disk
    let mark =
      if focused: g.cur
      elif chosen: g.done
      else: " "
    let col = if focused: clAccent elif chosen: clDone else: clFg
    u.putContent(0, y, mark, col, focused)
    u.putContent(2, y, d.device.alignLeft(16), col, focused)
    u.putContent(18, y, d.size.alignLeft(9), col)
    u.putContent(27, y, d.model, (if focused: col else: clDim))
    inc y
  u.putContent(0, y + 1, "Everything on the selected disk is erased.", clWarn)

proc drawPartition(u: var Ui) =
  u.putContent(0, 0, "Disk layout", clTitle, true)
  u.drawRow(2, u.wiz.sel == 0, "Scheme", $u.wiz.cfg.scheme,
            schemeNote(u.wiz.cfg.scheme, u.efiBooted))
  u.drawRow(3, u.wiz.sel == 1, "Filesystem", $u.wiz.cfg.rootFs,
            fsNote(u.wiz.cfg.rootFs))

  u.putContent(0, 5, "Resulting layout", clDim)
  var y = 6
  for line in layoutLines(u.wiz.cfg):
    u.putContent(2, y, line, clFg)
    inc y

proc drawSystem(u: var Ui) =
  u.putContent(0, 0, "System", clTitle, true)
  u.drawEditRow(2, u.wiz.sel == 0, u.wiz.editing, "Hostname",
                u.wiz.cfg.hostname)
  u.drawEditRow(3, u.wiz.sel == 1, u.wiz.editing, "Timezone",
                u.wiz.cfg.timezone)
  u.drawEditRow(4, u.wiz.sel == 2, u.wiz.editing, "Locale", u.wiz.cfg.locale)
  u.putContent(0, 6, "Network     " & summary(u.links), clDim)

proc drawUser(u: var Ui) =
  u.putContent(0, 0, "User account", clTitle, true)
  u.drawEditRow(2, u.wiz.sel == 0, u.wiz.editing, "Username",
                u.wiz.cfg.username)
  u.drawRow(3, u.wiz.sel == 1, "Profile", $u.wiz.cfg.profile, "")
  u.putContent(2, 5, "Groups      wheel  (sudo access)", clDim)

proc drawReview(u: var Ui) =
  u.putContent(0, 0, "Review", clTitle, true)
  var y = 2
  for line in summaryLines(u.wiz.cfg):
    let warn = "erased" in line or "DRY RUN" in line
    u.putContent(0, y, line, (if warn: clWarn else: clFg), warn)
    inc y

  for line in offlineWarning(u.links):
    if y >= u.layout.contentH - 1: break
    inc y
    u.putContent(0, y, line, clWarn)

  # The declaration itself, because "I answered five questions" and "this file
  # now defines my machine" are the same fact and the user should see it.
  if u.layout.contentW >= 60 and y + 4 < u.layout.contentH:
    y += 2
    u.putContent(0, y, "/etc/nexis/system.toml", clDim)
    inc y
    for line in configPreviewLines(u.wiz.cfg):
      if y >= u.layout.contentH - 1: break
      u.putContent(2, y, line, (if line.startsWith("["): clTitle else: clDim))
      inc y

proc drawInstall(u: var Ui) =
  u.putContent(0, 0, "Install", clTitle, true)

  if not u.runner.started:
    u.putContent(0, 2, (if u.wiz.cfg.dryRun:
                          "Press enter to print the plan without running it."
                        else:
                          "Press enter to erase " & u.wiz.cfg.disk &
                          " and install."),
                 (if u.wiz.cfg.dryRun: clFg else: clError), true)
    u.putContent(0, 4, $u.runner.total() & " commands are planned. Press D to " &
                 "read them all first.", clDim)
    return

  var y = 2
  for st in u.runner.stages():
    if y >= u.layout.contentH - 4: break
    drawStepLine(u.scr, u.layout.contentX + 2, u.layout.contentY + y,
                 u.runner.stageState(st), u.tick, $st)
    inc y

  inc y
  let barW = min(u.layout.contentW - 16, 40)
  if barW > 4:
    drawProgress(u.scr, u.layout.contentX + 2, u.layout.contentY + y, barW,
                 u.runner.fraction())
    inc y

  # No percentage exists for a graph being drained, so the wave says "working"
  # without implying an estimate the installer cannot honestly make.
  if u.runner.currentStage() == sgGenerate and not u.runner.finished and
     not u.runner.failed:
    inc y
    drawWave(u.scr, u.layout.contentX + 2, u.layout.contentY + y,
             min(u.layout.contentW - 4, 46), u.tick)

  inc y
  inc y
  let st = u.runner.statusLine()
  u.putContent(0, y, st,
               (if u.runner.failed: clError
                elif u.runner.finished: clDone
                else: clFg), true)

proc drawStep(u: var Ui) =
  case u.wiz.step
  of stWelcome: u.drawWelcome()
  of stDisk: u.drawDisk()
  of stPartition: u.drawPartition()
  of stSystem: u.drawSystem()
  of stUser: u.drawUser()
  of stReview: u.drawReview()
  of stInstall: u.drawInstall()

  # Validation is shown where the user is looking, not buried in a status bar.
  let v = u.wiz.stepValid()
  if not v.ok and u.layout.contentH > 3:
    u.putContent(0, u.layout.contentH - 2, v.msg, clWarn)

proc drawFrame*(u: var Ui) =
  u.scr.clear()
  u.layout = computeLayout(u.scr.width, u.scr.height)
  u.drawSidebar()
  u.drawCompactStep()
  u.drawStep()
  u.drawHints()
  u.drawStatus()
