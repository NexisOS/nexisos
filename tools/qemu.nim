#!/usr/bin/env -S nim r
#
# NexisOS QEMU launcher
#
# Usage:
#   nim r tools/qemu.nim
#   nim r tools/qemu.nim installer
#   nim r tools/qemu.nim installed
#   nim r tools/qemu.nim check
#   nim r tools/qemu.nim print-config
#   nim r tools/qemu.nim reset --confirm
#
# Optional environment overrides:
#   NEXIS_QEMU_ARCH=x86_64|aarch64
#   NEXIS_QEMU_RAM=4G
#   NEXIS_QEMU_CPUS=4
#   NEXIS_QEMU_DISK_SIZE=32G
#   NEXIS_QEMU_GRAPHICS=auto|gtk|none
#   NEXIS_QEMU_ACCEL=auto|kvm|tcg
#
# Requires Linux and the appropriate QEMU system emulator.

import std/[
  os,
  osproc,
  strutils,
  parseutils,
  sequtils,
  terminal,
  times
]

type
  GuestArch = enum
    gaX86_64
    gaAarch64

  BootMode = enum
    bmInstaller
    bmInstalled

  GraphicsMode = enum
    gmAuto
    gmGtk
    gmNone

  AccelMode = enum
    amAuto
    amKvm
    amTcg

  HostInfo = object
    arch: string
    cpus: int
    memoryMiB: int
    kvmAvailable: bool
    graphicalSession: bool
    gtkAvailable: bool

  Config = object
    arch: GuestArch
    bootMode: BootMode
    memoryMiB: int
    cpus: int
    diskSizeGiB: int
    graphics: GraphicsMode
    acceleration: AccelMode
    confirmReset: bool
    printOnly: bool

const
  DefaultDiskSizeGiB = 32
  MinMemoryMiB = 512
  MinCpus = 1

proc die(message: string; code = 1) {.noreturn.} =
  stderr.writeLine("error: " & message)
  quit(code)

proc info(message: string) =
  stdout.writeLine("==> " & message)

proc readTextFile(path: string): string =
  ## Read a small host-system information file.
  ## Return an empty string if it is missing or inaccessible.
  try:
    if fileExists(path):
      return readFile(path).strip()
  except CatchableError:
    discard

  return ""

proc parsePositiveInt(value, label: string): int =
  var parsed = 0

  if value.len == 0 or parseInt(value, parsed) != value.len:
    die(label & " must be a positive integer")

  if parsed <= 0:
    die(label & " must be greater than zero")

  return parsed

proc detectCpuCount(): int =
  ## Nim's countProcessors reports logical processors.
  result = countProcessors()

  if result < 1:
    result = 1

  # Respect Linux cgroup v2 CPU quotas when available.
  let quota = readTextFile("/sys/fs/cgroup/cpu.max")

  if quota.len > 0:
    let fields = quota.splitWhitespace()

    if fields.len >= 2 and fields[0] != "max":
      try:
        let quotaMicros = parseBiggestInt(fields[0])
        let periodMicros = parseBiggestInt(fields[1])

        if quotaMicros > 0 and periodMicros > 0:
          let allowed = int(
            (quotaMicros + periodMicros - 1) div periodMicros
          )

          if allowed > 0:
            result = min(result, allowed)
      except ValueError:
        discard

proc detectMemoryMiB(): int =
  ## Determine the host memory limit, preferring cgroup limits
  ## where applicable, rather than blindly using physical RAM.
  let meminfo = readTextFile("/proc/meminfo")

  for line in meminfo.splitLines():
    if line.startsWith("MemTotal:"):
      let fields = line.splitWhitespace()

      if fields.len >= 2:
        try:
          result = int(parseBiggestInt(fields[1]) div 1024)
        except ValueError:
          discard

      break

  if result <= 0:
    result = 4096

  # cgroup v2 memory limit.
  let limitText = readTextFile("/sys/fs/cgroup/memory.max")

  if limitText.len > 0 and limitText != "max":
    try:
      let limitBytes = parseBiggestInt(limitText)

      if limitBytes > 0:
        let limitMiB = int(limitBytes div (1024 * 1024))

        # Ignore implausibly large sentinel limits.
        if limitMiB > 0 and limitMiB < result:
          result = limitMiB
    except ValueError:
      discard

  # Leave host memory available for the desktop and build tools.
  result = max(MinMemoryMiB, result div 2)

proc detectHost(): HostInfo =
  result.arch = hostCPU.toLowerAscii()
  result.cpus = detectCpuCount()
  result.memoryMiB = detectMemoryMiB()

  # /dev/kvm existing does not guarantee it can be opened.
  result.kvmAvailable =
    fileExists("/dev/kvm") and
    dirExists("/sys/module/kvm")

  let sessionType = getEnv("XDG_SESSION_TYPE").toLowerAscii()

  result.graphicalSession =
    getEnv("DISPLAY").len > 0 or
    getEnv("WAYLAND_DISPLAY").len > 0

  result.gtkAvailable =
    result.graphicalSession and
    findExe("qemu-system-x86_64").len > 0 and
    (sessionType == "x11" or sessionType == "wayland" or
     getEnv("DISPLAY").len > 0)

proc parseGuestArch(value: string): GuestArch =
  case value.toLowerAscii()
  of "x86_64", "x86-64", "amd64":
    gaX86_64
  of "aarch64", "arm64":
    gaAarch64
  else:
    die("unsupported guest architecture: " & value &
        " (supported: x86_64, aarch64)")

proc parseGraphics(value: string): GraphicsMode =
  case value.toLowerAscii()
  of "auto":
    gmAuto
  of "gtk":
    gmGtk
  of "none":
    gmNone
  else:
    die("NEXIS_QEMU_GRAPHICS must be auto, gtk, or none")

proc parseAcceleration(value: string): AccelMode =
  case value.toLowerAscii()
  of "auto":
    amAuto
  of "kvm":
    amKvm
  of "tcg":
    amTcg
  else:
    die("NEXIS_QEMU_ACCEL must be auto, kvm, or tcg")

proc parseDiskSizeGiB(value: string): int =
  ## Deliberately accept only integer sizes with an optional G suffix.
  ## This prevents malformed QEMU size strings.
  var normalized = value.strip().toLowerAscii()

  if normalized.endsWith("g"):
    normalized.setLen(normalized.len - 1)

  let size = parsePositiveInt(normalized, "disk size")

  if size < 4 or size > 1024:
    die("disk size must be between 4 and 1024 GiB")

  return size

proc projectRoot(): string =
  ## Resolve the repository root from this source file.
  parentDir(parentDir(currentSourcePath()).absolutePath())

proc parseConfig(host: HostInfo; args: seq[string]): Config =
  result.arch =
    parseGuestArch(getEnv("NEXIS_QEMU_ARCH",
      if host.arch in ["aarch64", "arm64"]: "aarch64"
      else: "x86_64"))

  result.bootMode = bmInstaller
  result.memoryMiB = min(4096, max(MinMemoryMiB, host.memoryMiB))
  result.cpus = min(4, host.cpus)
  result.diskSizeGiB = DefaultDiskSizeGiB
  result.graphics = parseGraphics(
    getEnv("NEXIS_QEMU_GRAPHICS", "auto"))
  result.acceleration = parseAcceleration(
    getEnv("NEXIS_QEMU_ACCEL", "auto"))
  result.confirmReset = false
  result.printOnly = false

  let ram = getEnv("NEXIS_QEMU_RAM")

  if ram.len > 0:
    var normalized = ram.toLowerAscii()

    if normalized.endsWith("g"):
      normalized.setLen(normalized.len - 1)
      result.memoryMiB =
        parsePositiveInt(normalized, "NEXIS_QEMU_RAM") * 1024
    elif normalized.endsWith("m"):
      normalized.setLen(normalized.len - 1)
      result.memoryMiB =
        parsePositiveInt(normalized, "NEXIS_QEMU_RAM")
    else:
      die("NEXIS_QEMU_RAM must use an M or G suffix, e.g. 4096M or 4G")

  let cpuOverride = getEnv("NEXIS_QEMU_CPUS")

  if cpuOverride.len > 0:
    result.cpus = parsePositiveInt(cpuOverride, "NEXIS_QEMU_CPUS")

  let diskOverride = getEnv("NEXIS_QEMU_DISK_SIZE")

  if diskOverride.len > 0:
    result.diskSizeGiB = parseDiskSizeGiB(diskOverride)

  var positionalSeen = false

  for arg in args:
    case arg
    of "installer":
      result.bootMode = bmInstaller
      positionalSeen = true
    of "installed":
      result.bootMode = bmInstalled
      positionalSeen = true
    of "check":
      result.printOnly = true
    of "print-config":
      result.printOnly = true
    of "--confirm":
      result.confirmReset = true
    of "reset":
      # Reset is handled before launch validation in main().
      discard
    of "--help", "-h":
      echo """
NexisOS QEMU launcher

Usage:
  qemu.nim [installer|installed|check|print-config|reset] [--confirm]

Environment:
  NEXIS_QEMU_ARCH=x86_64|aarch64
  NEXIS_QEMU_RAM=4G
  NEXIS_QEMU_CPUS=4
  NEXIS_QEMU_DISK_SIZE=32G
  NEXIS_QEMU_GRAPHICS=auto|gtk|none
  NEXIS_QEMU_ACCEL=auto|kvm|tcg
"""
      quit(0)
    else:
      die("unknown argument: " & arg)

proc qemuExecutable(arch: GuestArch): string =
  case arch
  of gaX86_64: "qemu-system-x86_64"
  of gaAarch64: "qemu-system-aarch64"

proc isoPath(root: string; arch: GuestArch): string =
  case arch
  of gaX86_64:
    root / "build" / "installer" / "images" /
      "nexisos-installer-x86_64.iso"
  of gaAarch64:
    root / "build" / "installer" / "images" /
      "nexisos-installer-aarch64.iso"

proc vmDirectory(root: string): string =
  root / "build" / "qemu"

proc diskPath(root: string): string =
  vmDirectory(root) / "disk.qcow2"

proc validateConfig(host: HostInfo; cfg: Config) =
  if cfg.memoryMiB < MinMemoryMiB:
    die("guest memory must be at least " &
        $MinMemoryMiB & " MiB")

  if cfg.memoryMiB > host.memoryMiB:
    die("guest memory exceeds the detected host/cgroup memory budget (" &
        $host.memoryMiB & " MiB)")

  if cfg.cpus < MinCpus:
    die("CPU count must be positive")

  if cfg.cpus > host.cpus:
    die("requested CPU count exceeds the detected host/cgroup CPU budget (" &
        $host.cpus & ")")

  if cfg.acceleration == amKvm and not host.kvmAvailable:
    die("KVM was requested but /dev/kvm or the KVM module is unavailable")

  if cfg.graphics == gmGtk and not host.graphicalSession:
    die("GTK display was requested, but no graphical session was detected")

proc printConfig(host: HostInfo; cfg: Config; root: string) =
  echo "NexisOS QEMU preflight"
  echo "  Host architecture: " & host.arch
  echo "  Guest architecture: " & $cfg.arch
  echo "  Emulator:          " & qemuExecutable(cfg.arch)
  echo "  Host CPUs:         " & $host.cpus
  echo "  Host memory:       " & $host.memoryMiB & " MiB"
  echo "  Guest CPUs:        " & $cfg.cpus
  echo "  Guest memory:      " & $cfg.memoryMiB & " MiB"
  echo "  KVM available:     " & $host.kvmAvailable
  echo "  Graphics session:  " & $host.graphicalSession
  echo "  Disk size:         " & $cfg.diskSizeGiB & " GiB"
  echo "  Disk:              " & diskPath(root)

  if cfg.bootMode == bmInstaller:
    echo "  Installer ISO:     " & isoPath(root, cfg.arch)

proc ensureExecutable(name: string): string =
  result = findExe(name)

  if result.len == 0:
    die("required executable not found: " & name)

proc ensureDisk(root: string; cfg: Config) =
  let vmDir = vmDirectory(root)
  let disk = diskPath(root)

  if not dirExists(vmDir):
    createDir(vmDir)

  if fileExists(disk):
    return

  let qemuImg = ensureExecutable("qemu-img")

  info("Creating virtual disk (" & $cfg.diskSizeGiB & " GiB)")

  let command = @[qemuImg, "create", "-f", "qcow2",
                  disk, $cfg.diskSizeGiB & "G"]

  let exitCode = execCmdEx(command.mapIt(quoteShell(it)).join(" ")).exitCode

  if exitCode != 0:
    die("qemu-img failed to create the virtual disk")

proc resetDisk(root: string; confirmed: bool) =
  let rootPath = root.absolutePath()
  let vmDir = vmDirectory(root).absolutePath()
  let disk = diskPath(root).absolutePath()

  if not vmDir.startsWith(rootPath & DirSep):
    die("refusing reset: VM directory escapes repository root")

  if not confirmed:
    die("reset deletes the NexisOS VM disk; rerun with reset --confirm")

  if not fileExists(disk):
    info("No virtual disk exists; nothing to reset")
    return

  # Refuse symlinks to avoid deleting an unexpected target.
  if symlinkExists(disk):
    die("refusing to reset a symlinked virtual disk")

  stdout.writeLine("About to delete: " & disk)
  removeFile(disk)
  info("Virtual disk removed")

proc buildQemuArgs(host: HostInfo; cfg: Config;
                   root: string): seq[string] =
  let iso = isoPath(root, cfg.arch)
  let disk = diskPath(root)

  result = @[
    qemuExecutable(cfg.arch),
    "-machine", "q35",
    "-smp", $cfg.cpus,
    "-m", $cfg.memoryMiB & "M",
    "-drive", "file=" & disk & ",format=qcow2,if=virtio",
    "-device", "virtio-rng-pci",
    "-nic", "user,model=virtio-net-pci"
  ]

  if cfg.arch == gaX86_64:
    result.add(@["-cpu",
      if cfg.acceleration == amTcg: "qemu64" else: "host"])
  else:
    result.add(@["-cpu",
      if cfg.acceleration == amTcg: "cortex-a72" else: "host"])

  case cfg.acceleration
  of amAuto:
    if host.kvmAvailable:
      result.add("-enable-kvm")
  of amKvm:
    result.add("-enable-kvm")
  of amTcg:
    discard

  case cfg.graphics
  of gmNone:
    result.add("-display")
    result.add("none")
  of gmGtk:
    result.add("-display")
    result.add("gtk")
  of gmAuto:
    if host.graphicalSession:
      result.add("-display")
      result.add("gtk")
    else:
      result.add("-display")
      result.add("none")

  result.add("-device")
  result.add("virtio-vga")

  if cfg.bootMode == bmInstaller:
    result.add("-cdrom")
    result.add(iso)
    result.add("-boot")
    result.add("order=d")
  else:
    result.add("-boot")
    result.add("order=c")

proc main() =
  let root = projectRoot()
  let args = commandLineParams()
  let host = detectHost()

  # Handle reset independently; it must not create a new disk.
  if args.len > 0 and args[0] == "reset":
    let confirmed = args.len > 1 and args[1] == "--confirm"
    resetDisk(root, confirmed)
    return

  let cfg = parseConfig(host, args)

  validateConfig(host, cfg)

  let emulator = ensureExecutable(qemuExecutable(cfg.arch))

  if cfg.bootMode == bmInstaller:
    let iso = isoPath(root, cfg.arch)

    if not fileExists(iso):
      die("installer ISO not found: " & iso &
          "\nBuild it with your NexisOS ISO build task first.")

  if cfg.printOnly:
    printConfig(host, cfg, root)
    return

  ensureDisk(root, cfg)

  var command = buildQemuArgs(host, cfg, root)
  command[0] = emulator

  info("Launching NexisOS")
  info("Guest: " & $cfg.arch)
  info("Memory: " & $cfg.memoryMiB & " MiB")
  info("CPUs: " & $cfg.cpus)

  let process = startProcess(
    command[0],
    args = command[1 .. ^1],
    options = {poParentStreams}
  )

  let exitCode = process.waitForExit()
  process.close()

  if exitCode != 0:
    quit(exitCode)

when isMainModule:
  main()
