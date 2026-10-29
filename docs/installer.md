# The installer

NexisOS ships a TUI installer (`nexis-installer`) that runs automatically when
the ISO is booted from removable media. It is a text interface presented inside
a Wayland kiosk compositor.

## Boot path

```
UEFI firmware
     │
     ▼
Unified Kernel Image  (kernel + initramfs + cmdline, signed)
     │
     ▼
initramfs
     │  find the ISO by label, mount the squashed root read-only
     │  mount the content store
     ▼
switch_root
     │
     ▼
nexis-init  (PID 1)
     │
     ├── uevent manager      populate /dev, coldplug
     ├── seatd               device arbitration for the compositor
     ├── dbus-daemon         (only if the profile needs it)
     └── installer.target
             │
             ▼
        cage ── foot ── nexis-installer
```

## Why there are three processes to show a text UI

This is the part worth being explicit about, because it is easy to under-count.

`cage` is a kiosk compositor: it runs **one Wayland client fullscreen**. A TUI is
not a Wayland client — it is a program that writes escape sequences to a
terminal. So the chain needs a Wayland terminal emulator in the middle. `foot`
is the right choice: small, fast, no toolkit dependency.

The resulting ISO dependency set for the graphical path is:

```
cage → wlroots → libdrm, mesa, libinput, libxkbcommon, pixman, libseat
foot → fcft, freetype, harfbuzz, fontconfig, wayland
```

That is real weight for displaying text. It buys:

- correct font rendering and hidpi scaling, instead of the kernel console's
  fixed-size bitmap font on a 4K panel;
- working touch and trackpad input;
- one presentation path that a future graphical installer can reuse unchanged;
- no VT-switching or console-blanking surprises mid-install.

Those are legitimate reasons, and the decision stands. But the cost should be a
decision rather than a discovery, and it has one important consequence.

### seatd is not needed

libseat has a `builtin` backend that opens DRM and input devices directly, and
the installer runs as root, so it works. `LIBSEAT_BACKEND=builtin` therefore
removes a daemon, a socket and a startup ordering problem from the medium.

seatd earns its place on an installed multi-user system, where unprivileged
sessions need device access arbitrated. An installation medium has exactly one
session and it is root's.

### Two things the ISO build has to copy explicitly

**Mesa's DRI drivers**, because they are `dlopen`'d and `ldd` cannot see them.
Missing, cage starts and renders nothing — a black screen rather than an error.

**A font with the glyphs the TUI uses.** Box drawing, braille spinners, block
progress bars. A Latin-only font gives a screen of empty rectangles, which
looks like a broken installer rather than a missing font.

## The installer must not depend on cage

Because the graphical path can fail, and on installation media that failure is
terminal for the user.

It fails when: the GPU has no working KMS driver (a `nomodeset` fallback, an
unsupported new card), the VM has no virtio-gpu, the install is over a serial
console, or `seatd` cannot arbitrate the DRM device.

So `nexis-installer` is a plain TUI that reads a terminal and writes escape
sequences. It has no idea what is hosting it. `installer.target` tries the
graphical path and falls back:

```
cage + foot            preferred
      │ fails
      ▼
nexis-installer on tty1 directly     kernel console, always available
      │ no console at all
      ▼
serial console via console= on the kernel cmdline
```

`nexis-installer --surface` reports which path a running machine chose and
why, so a fallback is never a silent one.

The fallback path needs nothing beyond the kernel — no wlroots, no Mesa, no
seatd. Keeping the installer host-agnostic is what makes that free. It also
means the installer can be developed and tested in a terminal without booting
an ISO, which matters more day to day than any of the above.

## Module structure

Under `src/tuiinstaller/`:

| Module | Responsibility |
| --- | --- |
| `main.nim` | entry point, raw mode, the event loop, fallback detection |
| `ui.nim` | layout, sidebar, hint panel, per-step rendering |
| `state.nim` | wizard state machine, validation, navigation, cursor |
| `term.nim` | cell grid, capability detection, frame diffing |
| `theme.nim` | Molokai in RGB, quantised to 256 and 16 colours |
| `title.nim` | the wordmark, static, welcome page only |
| `anim.nim` | spinners, progress bars, the build wave — all pure functions of a tick |
| `input.nim` | key decoding, including CSI and SS3 escape sequences |
| `disk.nim` | block device enumeration |
| `partition.nim` | scheme detection and selection, layout preview |
| `network.nim` | link state, for reporting — not a step |
| `configuration.nim` | rendering generation zero as TOML |
| `command.nim` | a command value with `render()`, inspectable before execution |
| `plan.nim` | `buildPlan()` — an `InstallConfig` becomes an ordered command list |
| `installation.nim` | running the plan, one command per frame, with stage progress |

**The installer builds a complete, inspectable plan before executing
anything.** A dry run renders the plan; a real run executes the same list.
That is the same "prepare, validate, then activate" shape as generation
activation, and it is what makes an installer testable without a disk.

### Why there is no network step

An install does not need one. The medium carries a store with everything
generation 1 requires, so a machine can be installed on a bench with nothing
plugged into it. A step that most users would page past teaches them to page
past steps, and the one before it is the disk selection.

`network.nim` reads link state from sysfs and the review page reports it. When
nothing is up, it says so and explains that the install still works — a warning
that is always present is furniture, and gets read as furniture.

### The plan, from the tests

- starts with `sgdisk --zap-all <disk>`;
- emits an ESP with type code `ef00` for `psEfiGpt`, a `ef02` BIOS boot
  partition for `psBiosGpt` and no ESP;
- chooses `mkfs.vfat` / `mkfs.ext4` / `mkfs.btrfs` from the filesystem
  selection;
- uses `p`-separated partition names for NVMe devices (`/dev/nvme0n1p2`);
- unmounts everything it mounted, in reverse order, at the end.

## What gets installed

**Two packages: `nexis` and `nexis-init`.** That is the whole installed system
at first boot.

Nothing from the medium is copied to the target. The compositor, the terminal,
the shell, `iwd`, the partitioning tools — all of it exists to run the
installer and is discarded with the medium. A user who wants a shell on their
new machine declares one and rebuilds.

This is why the installer is small and why it stays small. It has no package
selection screen, no desktop-environment chooser, and no task list, because
those are declarations the user makes afterwards in a file they can read.

## Installation as generation zero

The installer's output is not a set of files copied onto a disk. It is a
**generation**: the same artifact `nexis rebuild` produces, built by the same
generation builder, from a configuration the installer assembled.

```
installer wizard
      │
      ▼
/etc/nexis/*.toml       written to the target
      │
      ▼
generation builder      same code path as a rebuild
      │
      ▼
generation 1 + bootloader entry
```

This means the first boot of an installed system is a rollback target like any
other, and it means the installer cannot drift from the rebuild path — there is
only one path.
