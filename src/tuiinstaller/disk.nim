## Block device discovery and partition naming.

import std/[strutils]

type
  Disk* = object
    device*: string
    size*: string
    model*: string

func parseLsblk*(text: string): seq[Disk] =
  ## Parses `lsblk -dno NAME,SIZE,TYPE,MODEL`. Only whole disks are kept:
  ## partitions, optical drives and loop devices are never install targets and
  ## offering them is how someone installs onto their ISO.
  for raw in text.splitLines():
    let line = raw.strip()
    if line.len == 0: continue
    let parts = line.splitWhitespace()
    if parts.len < 3: continue
    if parts[2] != "disk": continue
    var d = Disk(device: "/dev/" & parts[0], size: parts[1])
    if parts.len > 3:
      d.model = parts[3 .. ^1].join(" ")
    result.add d

func partName*(disk: string, n: int): string =
  ## `/dev/sda` + 1 -> `/dev/sda1`, but `/dev/nvme0n1` + 1 -> `/dev/nvme0n1p1`.
  ## Getting this wrong targets `/dev/nvme0n11`, which may well exist.
  if disk.len > 0 and disk[^1] in {'0'..'9'}:
    disk & "p" & $n
  else:
    disk & $n

func sampleDisks*(): seq[Disk] =
  ## Fallback targets so the wizard is navigable without root or real
  ## hardware, which is how it gets developed and tested.
  @[
    Disk(device: "/dev/vda", size: "20G", model: "QEMU HARDDISK"),
    Disk(device: "/dev/nvme0n1", size: "1.8T", model: "WD_BLACK SN850X"),
  ]
