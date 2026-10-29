import std/unittest
import ../../../src/tuiinstaller/disk

const SampleLsblk = """
sda    465.8G disk Samsung SSD 870
sda1   512M   part
sr0    1024M  rom  QEMU DVD-ROM
loop0  4K     loop
nvme0n1 1.8T  disk WD_BLACK SN850X
vda    20G    disk
"""

suite "lsblk parsing":
  test "keeps disks, drops partitions, roms and loops":
    let disks = parseLsblk(SampleLsblk)
    check disks.len == 3
    check disks[0].device == "/dev/sda"
    check disks[1].device == "/dev/nvme0n1"
    check disks[2].device == "/dev/vda"

  test "multi-word models survive":
    let disks = parseLsblk(SampleLsblk)
    check disks[0].model == "Samsung SSD 870"

  test "model is optional":
    let disks = parseLsblk(SampleLsblk)
    check disks[2].model == ""

  test "garbage input yields nothing":
    check parseLsblk("").len == 0
    check parseLsblk("not a table at all").len == 0

suite "partition naming":
  test "plain devices append the number":
    check partName("/dev/sda", 1) == "/dev/sda1"
    check partName("/dev/vdb", 2) == "/dev/vdb2"

  test "devices ending in a digit get a p separator":
    check partName("/dev/nvme0n1", 1) == "/dev/nvme0n1p1"
    check partName("/dev/mmcblk0", 2) == "/dev/mmcblk0p2"

suite "sample disks":
  test "dry-run fallback provides selectable targets":
    check sampleDisks().len >= 1
