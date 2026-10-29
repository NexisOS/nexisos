## Molokai, with honest degradation.
##
## The installer has to render on three very different surfaces:
##
##   foot / wezterm      24-bit colour, any font, hidpi
##   xterm-256color      256-colour palette
##   the kernel console  16 colours, fixed 8x16 font, 80x25
##
## The VT is not a hypothetical: it is the fallback when KMS fails, when a VM
## has no virtio-gpu, and when installing over serial. Molokai is defined once
## in RGB and quantised down, so the same code renders everywhere and the
## installer never depends on a colour it cannot get.

type
  Rgb* = object
    r*, g*, b*: int

  ColorDepth* = enum
    cdMono      ## no colour at all
    cd16        ## kernel console
    cd256       ## xterm-256color
    cdTrue      ## 24-bit

func rgb*(r, g, b: int): Rgb = Rgb(r: r, g: g, b: b)

## --- Molokai ---------------------------------------------------------------

const
  mkBackground* = rgb(0x27, 0x28, 0x22)
  mkForeground* = rgb(0xF8, 0xF8, 0xF2)
  mkSelection*  = rgb(0x49, 0x48, 0x3E)
  mkComment*    = rgb(0x75, 0x71, 0x5E)

  mkPink*       = rgb(0xF9, 0x26, 0x72)
  mkGreen*      = rgb(0xA6, 0xE2, 0x2E)
  mkYellow*     = rgb(0xE6, 0xDB, 0x74)
  mkOrange*     = rgb(0xFD, 0x97, 0x1F)
  mkPurple*     = rgb(0xAE, 0x81, 0xFF)
  mkCyan*       = rgb(0x66, 0xD9, 0xEF)
  mkWhite*      = rgb(0xFF, 0xFF, 0xFF)

## Semantic roles. Screens reference these, never raw colours, so retheming is
## a change to this block alone.
const
  clBg*         = mkBackground
  clFg*         = mkForeground
  clDim*        = mkComment
  clPanel*      = mkSelection
  clAccent*     = mkGreen      ## current step, focus
  clDone*       = mkCyan       ## completed step
  clPending*    = mkComment
  clError*      = mkPink
  clWarn*       = mkOrange
  clHint*       = mkYellow
  clTitle*      = mkPurple

## --- Quantisation ----------------------------------------------------------

const cubeLevels = [0, 95, 135, 175, 215, 255]

func nearestCubeIndex(v: int): int =
  var best = 0
  var bestD = high(int)
  for i, level in cubeLevels:
    let d = abs(level - v)
    if d < bestD:
      bestD = d
      best = i
  best

func dist(a, b: Rgb): int =
  ## Weighted squared distance. Green is weighted highest because human
  ## luminance perception is dominated by it, and an unweighted metric picks
  ## visibly wrong greys for Molokai's olive-ish background.
  let dr = a.r - b.r
  let dg = a.g - b.g
  let db = a.b - b.b
  2 * dr * dr + 4 * dg * dg + 3 * db * db

func to256*(c: Rgb): int =
  ## Nearest of the 6x6x6 cube (16-231) or the greyscale ramp (232-255).
  let
    ri = nearestCubeIndex(c.r)
    gi = nearestCubeIndex(c.g)
    bi = nearestCubeIndex(c.b)
    cube = rgb(cubeLevels[ri], cubeLevels[gi], cubeLevels[bi])
    cubeIdx = 16 + 36 * ri + 6 * gi + bi

  # Greyscale ramp: 8, 18, 28 ... 238
  let avg = (c.r + c.g + c.b) div 3
  var gray = (avg - 8) div 10
  if gray < 0: gray = 0
  if gray > 23: gray = 23
  let grayVal = 8 + gray * 10
  let grayRgb = rgb(grayVal, grayVal, grayVal)

  if dist(c, grayRgb) < dist(c, cube): 232 + gray else: cubeIdx

const ansi16 = [
  rgb(0, 0, 0),       rgb(170, 0, 0),     rgb(0, 170, 0),     rgb(170, 85, 0),
  rgb(0, 0, 170),     rgb(170, 0, 170),   rgb(0, 170, 170),   rgb(170, 170, 170),
  rgb(85, 85, 85),    rgb(255, 85, 85),   rgb(85, 255, 85),   rgb(255, 255, 85),
  rgb(85, 85, 255),   rgb(255, 85, 255),  rgb(85, 255, 255),  rgb(255, 255, 255),
]

func to16*(c: Rgb): int =
  var best = 0
  var bestD = high(int)
  for i, p in ansi16:
    let d = dist(c, p)
    if d < bestD:
      bestD = d
      best = i
  best

func luminance*(c: Rgb): int =
  (c.r * 299 + c.g * 587 + c.b * 114) div 1000

func blend*(a, b: Rgb, t: float): Rgb =
  ## Linear blend; t = 0 gives a, t = 1 gives b.
  let tc = if t < 0.0: 0.0 elif t > 1.0: 1.0 else: t
  rgb(a.r + int(float(b.r - a.r) * tc),
      a.g + int(float(b.g - a.g) * tc),
      a.b + int(float(b.b - a.b) * tc))
