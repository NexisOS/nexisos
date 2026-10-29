# Installer interface

Molokai, a step sidebar, and animated install progress — rendered so that the
same code works under a Wayland compositor and on a bare kernel console.

## Terminal choice

**foot on the ISO. wezterm as an installed-system package.**

`cage` runs one Wayland client fullscreen, and a TUI is not a Wayland client, so
a terminal emulator sits between them (see [installer.md](installer.md)). The
choice matters more than it looks because installation media has to run on
hardware nobody tested:

| | Size on ISO | GPU requirement | Verdict |
| --- | --- | --- | --- |
| **foot** | ~1 MB + fcft/freetype/harfbuzz | none beyond wlroots | **ISO** |
| alacritty | ~10 MB | OpenGL 3.3 | no |
| wezterm | ~100 MB + Rust/wgpu stack | Vulkan or OpenGL | installed systems |

wezterm is an excellent daily driver and should absolutely be packaged. It is
the wrong choice for an installer: it pulls a GPU stack onto media that may boot
with `nomodeset`, into a VM without virtio-gpu, or over a serial console. foot
is Wayland-native, has no GL requirement of its own, and starts instantly.

This is not the whole answer, because the graphical path can fail outright — and
on installation media, a failure the user cannot get past is fatal. So the
installer renders identically on:

```
cage + foot          truecolor, any font, hidpi
tty1 (kernel console) 16 colours, fixed 8x16 font, 80x24
serial console        whatever TERM says, often 16 colours
```

The VT is not hypothetical. It is what you get when KMS init fails, and it
constrains every visual decision below.

## Colour

Molokai is defined once in RGB (`theme.nim`) and quantised down at render time —
truecolor → 256 → 16 → mono. Screens reference semantic roles (`clAccent`,
`clError`, `clDim`) rather than raw hues, so retheming is one block.

Quantisation uses a luminance-weighted distance (green weighted 4, red 2,
blue 3). An unweighted metric picks visibly wrong greys for Molokai's olive-ish
`#272822` background. The 256-colour path considers both the 6×6×6 cube and the
greyscale ramp and takes whichever is nearer, which matters for exactly that
background.

**Colour alone never carries meaning.** At 16 colours the difference between
"current step" and "completed step" is not reliably distinguishable — different
terminals map the palette differently, and some VTs render bright colours as
bold. So the current step is drawn as a **filled row**, and every step carries a
marker glyph (`✓ ▸ ○ ✗`, degrading to `* > - !`). The highlight survives being
rendered in one colour.

## Layout

```
+------------------------+---------------------------------------------+
|  sidebar: steps        |  logo panel (animated)                      |
|  current highlighted   +---------------------------------------------+
|                        |  content for the current step               |
+------------------------+---------------------------------------------+
| status / keys                                                        |
+----------------------------------------------------------------------+
```

Two degradation stages, both tested:

- **below 100 columns** — the logo panel is dropped. 80×24 is the kernel
  console's fixed size, so this is the case that has to look deliberate rather
  than cramped. The sidebar stays, because knowing where you are in a nine-step
  install matters more than decoration.
- **below 70 columns** — the sidebar collapses to a `Step 4/7  Partitioning`
  indicator on the top line.

## The title

Static, drawn once, on the welcome page only.

An earlier draft had an extruded 3D wordmark oscillating about the Y axis with
a travelling shimmer. It was dropped: a moving logo competes for attention on
the one screen where a first-time user is trying to read carefully, and it
occupied panel space on every page that the hints needed more.

The banner is built from per-letter glyph arrays rather than pre-joined rows,
so the mixed case is right — "NexisOS", not "NEXISOS" — and a letter can be
fixed without re-aligning six other lines by hand. There is a test asserting
the lowercase glyphs leave their top rows empty, which is what would silently
regress if someone rebuilt the banner from a figlet dump.

Colour runs left to right across Molokai's cyan-to-green range so the wordmark
reads as one object rather than as seven letters. Below the banner width it
degrades to plain bold text.

## Hints

Every step carries a permanent hint panel, not a help key. Someone installing a
declarative distribution for the first time does not know what a generation is
and will not press F1 to find out — so the welcome page says, in plain words,
that there is no install command and that rebuilds produce rollback points.

Hints live in `state.nim` next to the step enum rather than in the rendering
code, so they cannot drift out of sync with the steps they describe. A test
asserts every step has one.

Validation messages appear in the content area where the user is looking, not
in the status bar. `stepValid` returns the offending field and a sentence
explaining the rule, because an installer that refuses to advance without
saying why is the most common way a first-time user gives up.

## Dry run

`--dry-run` is not a separate code path. `buildPlan` produces an ordered list of
`Command` values; a dry run renders that list and a real install executes it.
Because there is only one list, a dry run cannot diverge from what an install
would actually do.

```
$ nimble plan
DRY RUN - 14 commands, none will be executed
Target: /dev/nvme0n1

 1. wipe
    $ sgdisk --zap-all /dev/nvme0n1
 ...
```

The mode is visible in three places — the sidebar, the review summary, and the
install page — because the single most dangerous confusion available is
believing you are in dry run when you are not.

Commands are executed with arguments passed directly to the process, never
through a shell. `render()` produces shell-equivalent text with quoting for
*display only*, so a device name containing a space can never become two
arguments.

## Rendering

Cells are diffed against the previous frame and only changed cells are emitted,
with runs sharing escape sequences. The install page animates continuously — a
spinner per stage, a progress bar, and a travelling wave during the generation
build — so a full 80×24 repaint every frame would be visibly slow over a serial
console at 115200 baud and would flicker on a VT. A test asserts that a one-cell
change costs the same on an 80×24 screen as on a 200×50 one.

## Animation

Every animation is a pure function of a tick counter: `spinnerFrame(unicode, 7)`
is a value, not a side effect of a timer. Two things follow. They are testable
without a terminal, and the render loop cannot drift — a dropped frame skips
ahead rather than falling behind and accumulating lag.

The animation budget goes on the pages where something is actually happening,
which is why the title above stays static. On the install page:

The console's limit is the **font**, not the colour depth. It does 16 colours
and the theme quantises to them cleanly; what it lacks is glyphs — the kernel
font holds 256 or 512, so box drawing and braille are frequently absent.
`detectCaps` turns unicode off there and the ASCII twins take over, so the UI
stays correct and gets plainer. That is why cage + foot is an improvement
rather than a requirement.

| Element | Unicode | VT | Says |
| --- | --- | --- | --- |
| Stage spinner | braille cycle | `- \ | /` | this stage is running |
| Progress bar | eighth blocks | `#` and `-` | how far through the plan |
| Build wave | block heights | `.:-=+*#%` | working, with no completion estimate |

The wave exists because the generation build has no honest percentage to
report: it is a dependency graph being drained, not a file being copied. A
progress bar there would be a number the installer cannot stand behind.

Every unicode frame set has an ASCII twin of the same width. A spinner that
renders as `?` on the console someone fell back to *because something already
went wrong* is worse than no spinner, and there is a test asserting the VT
rendering contains no codepoint above U+007F.

Stage state is carried by the glyph as well as the colour — pending, running,
done and failed are four distinct characters — because at 16 colours running
and done are not reliably distinguishable, and the fallback console is exactly
where a stalled step most needs to be visible.

## Preview

```
nimble preview        every screen as plain text
nimble previewVt      the same, as the kernel console renders it
nimble animate        run the install animation live in this terminal
nimble frames         install animation frames as plain text
nimble plan           the dry-run command list
nimble genconfig      the generation-zero TOML
nimble installer      build and run the installer here, in dry-run mode
```

`--vt` is the one to check before changing anything. It is the surface with the
least margin and the one a user only sees when something has already gone wrong.
