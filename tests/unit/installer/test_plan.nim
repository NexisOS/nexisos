import std/[sequtils, strutils, unittest]
import ../../../src/tuiinstaller/command
import ../../../src/tuiinstaller/plan
import ../../../src/tuiinstaller/state

proc cfgFor(scheme: PartScheme, fs = rfExt4,
            disk = "/dev/vda"): InstallConfig =
  result = defaultConfig(dryRun = true)
  result.disk = disk
  result.scheme = scheme
  result.rootFs = fs

suite "partition plan":
  test "efi scheme creates esp + root and formats both":
    let cmds = partitionCmds(cfgFor(psEfiGpt))
    let rendered = cmds.mapIt(it.render())
    check rendered[0] == "sgdisk --zap-all /dev/vda"
    check rendered.anyIt("ef00" in it)          # ESP type code
    check rendered.anyIt(it.startsWith("mkfs.vfat"))
    check rendered.anyIt("mkfs.ext4" in it and "/dev/vda2" in it)

  test "bios scheme has no esp, still formats root":
    let cmds = partitionCmds(cfgFor(psBiosGpt))
    let rendered = cmds.mapIt(it.render())
    check rendered.anyIt("ef02" in it)          # BIOS boot type code
    check not rendered.anyIt("mkfs.vfat" in it)
    check rendered.anyIt("mkfs.ext4" in it)

  test "filesystem choice changes the mkfs program":
    let cmds = partitionCmds(cfgFor(psEfiGpt, fs = rfBtrfs))
    check cmds.mapIt(it.render()).anyIt(it.startsWith("mkfs.btrfs"))

  test "nvme disks get p-separated partition names":
    let cmds = partitionCmds(cfgFor(psEfiGpt, disk = "/dev/nvme0n1"))
    check cmds.mapIt(it.render()).anyIt("/dev/nvme0n1p2" in it)

suite "full plan":
  test "plan ends by unmounting what it mounted":
    let cmds = buildPlan(cfgFor(psEfiGpt))
    let rendered = cmds.mapIt(it.render())
    check rendered[^1].startsWith("umount")
    let mounts = rendered.filterIt(it.startsWith("mount "))
    let umounts = rendered.filterIt(it.startsWith("umount "))
    check mounts.len == umounts.len

  test "config values reach the plan":
    var cfg = cfgFor(psEfiGpt)
    cfg.hostname = "webbox"
    cfg.username = "kyle"
    let rendered = buildPlan(cfg).mapIt(it.render())
    check rendered.anyIt("--hostname webbox" in it)
    check rendered.anyIt("useradd" in it and "kyle" in it)

  test "dry-running the full plan executes nothing and succeeds":
    var ex = initExecutor(dryRun = true)
    check ex.runAll(buildPlan(cfgFor(psEfiGpt)))
    check ex.history.allIt(it.skipped)

suite "rendered plan":
  test "renderPlan is numbered and shows dry-run mode":
    let text = renderPlan(cfgFor(psEfiGpt))
    check "DRY RUN" in text
    check " 1. " in text
    check "$ sgdisk --zap-all /dev/vda" in text
