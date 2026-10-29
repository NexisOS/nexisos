## The NexisOS wordmark, drawn once on the welcome page.
##
## Static. An earlier draft rotated and shimmered; it was dropped because a
## moving logo competes for attention on the one screen where a first-time
## user is trying to read carefully.
##
## Built from per-letter glyphs rather than as pre-joined rows, so the mixed
## case is right ("NexisOS", not "NEXISOS") and a letter can be fixed without
## re-aligning six other lines by hand.

import ./theme, ./term

const
  Rows = 7

  GlyphN = ["#    #", "##   #", "# #  #", "#  # #", "#   ##", "#    #", "#    #"]
  GlyphE = ["     ", "     ", " ### ", "#   #", "#####", "#    ", " ### "]
  GlyphX = ["     ", "     ", "#   #", " # # ", "  #  ", " # # ", "#   #"]
  GlyphI = [" # ", "   ", "## ", " # ", " # ", " # ", "###"]
  GlyphS = ["     ", "     ", " ####", "#    ", " ### ", "    #", "#### "]
  GlyphO = [" #### ", "#    #", "#    #", "#    #", "#    #", "#    #", " #### "]
  GlyphS2 = [" #####", "#     ", "#     ", " #### ", "     #", "     #", "##### "]

  Gap = "  "

func banner(): array[Rows, string] =
  for r in 0 ..< Rows:
    result[r] = GlyphN[r] & Gap & GlyphE[r] & Gap & GlyphX[r] & Gap &
                GlyphI[r] & Gap & GlyphS[r] & Gap & GlyphO[r] & Gap &
                GlyphS2[r]

const Banner = banner()

func titleWidth*(): int = Banner[0].len
func titleHeight*(): int = Rows

proc drawTitle*(scr: var Screen, x, y: int) =
  ## Colour runs left to right across Molokai's cyan-to-green range, so the
  ## wordmark reads as one object rather than as seven letters.
  let w = Banner[0].len
  for row in 0 ..< Rows:
    let line = Banner[row]
    for col in 0 ..< line.len:
      if line[col] != '#': continue
      scr.put(x + col, y + row, toRune32("#"),
              blend(mkCyan, mkGreen, float(col) / float(w - 1)),
              clBg, bold = true)

proc drawTitleCompact*(scr: var Screen, x, y: int) =
  ## For terminals too narrow for the banner.
  scr.putStr(x, y, "NexisOS", mkGreen, clBg, bold = true)
