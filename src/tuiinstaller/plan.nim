## Turning an InstallConfig into an ordered list of commands.
##
## The plan is built in full before anything runs. `--dry-run` renders this
## same list; a real install executes it. There is no second code path, so a
## dry run cannot lie about what an install would do.

import std/[strutils]
import ./command, ./disk, ./state

const
  MountRoot = "/mnt"
  MountBoot = "/mnt/boot"

func mkfsProg(fs: RootFs): string =
  case fs
  of rfExt4: "mkfs.ext4"
  of rfBtrfs: "mkfs.btrfs"
  of rfXfs: "mkfs.xfs"

func mkfsArgs(fs: RootFs): seq[string] =
  ## `verity` on ext4 is not optional and cannot be added later without a
  ## rewrite: it is an on-disk feature flag set at mkfs time. Generation images
  ## are sealed with fs-verity, so a root formatted without it can hold a
  ## NexisOS install that never gets runtime integrity checking — and the user
  ## would have no indication anything was missing.
  ##
  ## Enabling it costs nothing on a filesystem that never uses it.
  case fs
  of rfExt4: @["-O", "verity"]
  of rfBtrfs, rfXfs: @[]

func partitionCmds*(cfg: InstallConfig): seq[Command] =
  ## Always starts by wiping the partition table. A half-overwritten table is
  ## the worst outcome available, so the plan commits to a clean slate first.
  result.add cmd("wipe", "sgdisk", "--zap-all", cfg.disk)

  case cfg.scheme
  of psEfiGpt:
    let esp = partName(cfg.disk, 1)
    let root = partName(cfg.disk, 2)
    result.add cmd("esp", "sgdisk", "--new=1:0:+512M", "--typecode=1:ef00",
                   "--change-name=1:ESP", cfg.disk)
    result.add cmd("root", "sgdisk", "--new=2:0:0", "--typecode=2:8300",
                   "--change-name=2:nexis-root", cfg.disk)
    result.add cmd("settle", "udevadm", "settle")
    result.add cmd("mkfs-esp", "mkfs.vfat", "-F", "32", "-n", "ESP", esp)
    var rootArgs = mkfsArgs(cfg.rootFs)
    rootArgs.add ["-L", "nexis-root", root]
    result.add Command(name: "mkfs-root", prog: mkfsProg(cfg.rootFs),
                       args: rootArgs)
  of psBiosGpt:
    # A BIOS boot partition holds the bootloader's stage 1.5. It carries no
    # filesystem, so there is deliberately no mkfs for it.
    let root = partName(cfg.disk, 2)
    result.add cmd("biosboot", "sgdisk", "--new=1:0:+1M", "--typecode=1:ef02",
                   "--change-name=1:BIOSBOOT", cfg.disk)
    result.add cmd("root", "sgdisk", "--new=2:0:0", "--typecode=2:8300",
                   "--change-name=2:nexis-root", cfg.disk)
    result.add cmd("settle", "udevadm", "settle")
    var rootArgs = mkfsArgs(cfg.rootFs)
    rootArgs.add ["-L", "nexis-root", root]
    result.add Command(name: "mkfs-root", prog: mkfsProg(cfg.rootFs),
                       args: rootArgs)

func mountCmds(cfg: InstallConfig): seq[Command] =
  let root = partName(cfg.disk, 2)
  result.add cmd("mount-root", "mount", root, MountRoot)
  if cfg.scheme == psEfiGpt:
    result.add cmd("mkdir-boot", "mkdir", "-p", MountBoot)
    result.add cmd("mount-boot", "mount", partName(cfg.disk, 1), MountBoot)

func unmountCmds(cfg: InstallConfig): seq[Command] =
  ## Reverse order of mountCmds. Unmounting a parent before its child fails.
  if cfg.scheme == psEfiGpt:
    result.add cmd("umount-boot", "umount", MountBoot)
  result.add cmd("umount-root", "umount", MountRoot)

func configCmds(cfg: InstallConfig): seq[Command] =
  result.add cmd("mkdir-etc", "mkdir", "-p", MountRoot & "/etc/nexis")
  result.add cmd("write-config", "nexis-config", "write",
                 "--root", MountRoot,
                 "--hostname", cfg.hostname,
                 "--timezone", cfg.timezone,
                 "--locale", cfg.locale,
                 "--profile", $cfg.profile)
  result.add cmd("user", "useradd", "--root", MountRoot,
                 "--create-home", "--groups", "wheel", cfg.username)

func buildCmds(cfg: InstallConfig): seq[Command] =
  ## Generation 1 is built by the same builder a later `nexis rebuild` uses.
  ## An installer with its own bespoke path produces systems that differ from
  ## rebuilt ones in ways nobody notices until a rebuild breaks them.
  ##
  ## **Generation 1 contains exactly two packages: `nexis` and `nexis-init`.**
  ## Nothing from the installation medium is copied onto the target — not the
  ## compositor, not the shell, not the partitioning tools. The medium is
  ## scaffolding and is discarded; the installed system is what the declaration
  ## says and nothing else.
  ##
  ## That is why there is no cleanup pass. A system assembled by copying the
  ## medium would need one, and would also no longer be a pure function of its
  ## declaration — which is the property the whole project exists to hold.
  result.add cmd("generation", "nexis", "rebuild", "boot",
                 "--root", MountRoot, "--config", MountRoot & "/etc/nexis")
  result.add cmd("bootloader", "nexis", "bootloader", "install",
                 "--root", MountRoot, "--disk", cfg.disk)

func buildPlan*(cfg: InstallConfig): seq[Command] =
  result.add partitionCmds(cfg)
  result.add mountCmds(cfg)
  result.add configCmds(cfg)
  result.add buildCmds(cfg)
  result.add unmountCmds(cfg)

func renderPlan*(cfg: InstallConfig): string =
  let plan = buildPlan(cfg)
  result.add(if cfg.dryRun:
               "DRY RUN - " & $plan.len & " commands, none will be executed\n"
             else:
               "INSTALL - " & $plan.len & " commands will be executed\n")
  result.add "Target: " & cfg.disk & "\n\n"
  for i, c in plan:
    result.add align($(i + 1), 2) & ". " & c.name & "\n"
    result.add "    $ " & c.render() & "\n"
