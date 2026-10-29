## Partition scheme selection.
##
## The scheme is not really a preference — it is a fact about the firmware the
## machine booted with, and offering it as a free choice is how someone ends up
## with an ESP on a BIOS box that will never boot. So the default is *detected*
## and the wrong answer is *labelled*, while still being selectable, because a
## detection that cannot be overridden is worse than one that can.

import std/[os, strutils]
import ./state, ./disk

const EfiVarsPath = "/sys/firmware/efi"

proc firmwareIsEfi*(): bool =
  ## The kernel only creates this when it booted via EFI. Present on a real
  ## UEFI boot, absent under BIOS/CSM, and absent in the installer's own
  ## development environment — where the fallback is the modern answer anyway.
  dirExists(EfiVarsPath)

proc detectScheme*(): PartScheme =
  if firmwareIsEfi(): psEfiGpt else: psBiosGpt

func schemeNote*(s: PartScheme, efiBooted: bool): string =
  ## Shown next to the option. Empty when the choice agrees with the firmware.
  if efiBooted and s == psBiosGpt:
    "this machine booted UEFI - BIOS mode will not boot"
  elif not efiBooted and s == psEfiGpt:
    "this machine did not boot UEFI - an ESP may not be usable"
  else:
    ""

func fsNote*(fs: RootFs): string =
  case fs
  of rfExt4:  "safe default, boring on purpose"
  of rfBtrfs: "snapshots and compression, overlapping with generations"
  of rfXfs:   "large files, cannot be shrunk"

func schemes*(): seq[PartScheme] = @[psEfiGpt, psBiosGpt]
func filesystems*(): seq[RootFs] = @[rfExt4, rfBtrfs, rfXfs]

func cycleScheme*(v: PartScheme, delta: int): PartScheme =
  let span = ord(high(PartScheme)) + 1
  PartScheme((((ord(v) + delta) mod span) + span) mod span)

func cycleFs*(v: RootFs, delta: int): RootFs =
  let span = ord(high(RootFs)) + 1
  RootFs((((ord(v) + delta) mod span) + span) mod span)

func cycleProfile*(v: Profile, delta: int): Profile =
  let span = ord(high(Profile)) + 1
  Profile((((ord(v) + delta) mod span) + span) mod span)

# --- Layout preview ----------------------------------------------------------

func layoutLines*(cfg: InstallConfig): seq[string] =
  ## What the disk will look like afterwards. Shown on the partition page
  ## because "GPT + ESP" means nothing to someone who has not partitioned a
  ## disk before, and two labelled rows do.
  if cfg.disk.len == 0:
    return @["(no disk selected)"]
  case cfg.scheme
  of psEfiGpt: @[
    partName(cfg.disk, 1).alignLeft(16) & "512M".alignLeft(8) &
      "vfat".alignLeft(8) & "EFI system partition",
    partName(cfg.disk, 2).alignLeft(16) & "rest".alignLeft(8) &
      ($cfg.rootFs).alignLeft(8) & "root, /store and generations",
  ]
  of psBiosGpt: @[
    partName(cfg.disk, 1).alignLeft(16) & "1M".alignLeft(8) &
      "none".alignLeft(8) & "BIOS boot, bootloader stage 1.5",
    partName(cfg.disk, 2).alignLeft(16) & "rest".alignLeft(8) &
      ($cfg.rootFs).alignLeft(8) & "root, /store and generations",
  ]
