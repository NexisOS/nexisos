#!/usr/bin/env -S nim r
#
# NexisOS Buildroot installer build tool.
#
# Usage:
#   nim r tools/build.nim doctor
#   nim r tools/build.nim configure
#   nim r tools/build.nim build
#   nim r tools/build.nim iso
#   nim r tools/build.nim clean
#   nim r tools/build.nim rebuild
#
# Or through Nimble:
#   nimble doctor
#   nimble configure
#   nimble build
#   nimble iso
#   nimble clean
#   nimble rebuild

import std/[os, osproc, strutils, sequtils]

const
  Defconfig = "nexis_installer_x86_64_defconfig"

  RequiredCommands = [
    "make",
    "gcc",
    "g++",
    "git",
    "cpio",
    "rsync",
    "file",
    "bc",
    "bison",
    "flex",
    "perl",
    "python3",
    "sed",
    "awk",
    "tar",
    "gzip",
    "bzip2",
    "xz",
    "patch",
    "wget"
  ]

type
  BuildPaths = object
    root: string
    buildroot: string
    external: string
    output: string
    defconfig: string

proc die(message: string; code = 1) {.noreturn.} =
  stderr.writeLine("error: " & message)
  quit(code)

proc info(message: string) =
  echo "==> " & message

proc paths(): BuildPaths =
  ## tools/build.nim -> tools/ -> repository root.
  let source = currentSourcePath().absolutePath()
  let toolsDir = parentDir(source)
  let root = parentDir(toolsDir)

  result.root = root
  result.buildroot = root / "tools" / "buildroot"
  result.external = root / "tools" / "buildroot-external"
  result.output = root / "build" / "installer"
  result.defconfig = result.external / "configs" / Defconfig

proc commandExists(name: string): bool =
  findExe(name).len > 0

proc runCommand(
  executable: string,
  args: seq[string],
  workingDir = ""
) =
  ## Execute a program directly, without a shell.
  ## Inherit stdin/stdout/stderr and propagate failures.
  if findExe(executable).len == 0:
    die("required executable not found: " & executable)

  let process = startProcess(
    executable,
    workingDir = workingDir,
    args = args,
    options = {poParentStreams}
  )

  let exitCode = process.waitForExit()
  process.close()

  if exitCode != 0:
    die(
      executable & " failed with exit code " & $exitCode,
      exitCode
    )

proc buildrootArgs(p: BuildPaths): seq[string] =
  @[
    "-C", p.buildroot,
    "O=" & p.output,
    "BR2_EXTERNAL=" & p.external
  ]

proc runBuildroot(p: BuildPaths; targets: seq[string] = @[]) =
  var args = buildrootArgs(p)
  args.add(targets)
  runCommand("make", args)

proc usage() =
  echo """
NexisOS Buildroot installer builder

Usage:
  build.nim <command>

Commands:
  doctor       Check build dependencies and project configuration
  configure    Configure Buildroot
  build        Configure and build the installer image
  iso          Build the installer and locate its ISO
  clean        Remove Buildroot output
  rebuild      Clean and rebuild the installer
  help         Show this help

Examples:
  nim r tools/build.nim doctor
  nim r tools/build.nim configure
  nim r tools/build.nim build
  nim r tools/build.nim iso
  nim r tools/build.nim clean
  nim r tools/build.nim rebuild
"""

proc checkDirectory(
  label, path: string,
  missing: var seq[string]
) =
  if dirExists(path):
    echo "  ", label.alignLeft(12), " OK"
  else:
    echo "  ", label.alignLeft(12), " MISSING"
    missing.add(label & ": " & path)

proc checkFile(
  label, path: string,
  missing: var seq[string]
) =
  if fileExists(path):
    echo "  ", label.alignLeft(12), " OK"
  else:
    echo "  ", label.alignLeft(12), " MISSING"
    missing.add(label & ": " & path)

proc doctor(p: BuildPaths) =
  echo "NexisOS installer build environment"
  echo ""
  echo "Root:       ", p.root
  echo "Buildroot:  ", p.buildroot
  echo "External:   ", p.external
  echo "Output:     ", p.output
  echo ""

  var missing: seq[string] = @[]

  for command in RequiredCommands:
    if commandExists(command):
      echo "  ", command.alignLeft(12), " OK"
    else:
      echo "  ", command.alignLeft(12), " MISSING"
      missing.add("command: " & command)

  echo ""

  checkDirectory("Buildroot", p.buildroot, missing)
  checkDirectory("External", p.external, missing)
  checkFile("Defconfig", p.defconfig, missing)

  echo ""

  if missing.len > 0:
    stderr.writeLine("Missing requirements:")

    for item in missing:
      stderr.writeLine("  - " & item)

    die("build environment is incomplete")

  echo "Build environment looks good."

proc configure(p: BuildPaths) =
  if not dirExists(p.buildroot):
    die("Buildroot directory not found: " & p.buildroot)

  if not dirExists(p.external):
    die("Buildroot external tree not found: " & p.external)

  if not fileExists(p.defconfig):
    die("Buildroot defconfig not found: " & p.defconfig)

  if not commandExists("make"):
    die("required command not found: make")

  createDir(p.output)

  info("Configuring NexisOS installer")
  runBuildroot(p, @[Defconfig])

  echo ""
  echo "Configuration written to:"
  echo "  ", p.output / ".config"

proc listArtifacts(p: BuildPaths) =
  let imagesDir = p.output / "images"

  echo ""
  echo "Artifacts:"

  if not dirExists(imagesDir):
    echo "  No images directory exists yet."
    return

  var artifacts: seq[string] = @[]

  for kind, path in walkDir(imagesDir):
    if kind == pcFile:
      artifacts.add(extractFilename(path))

  artifacts.sort()

  if artifacts.len == 0:
    echo "  No artifacts found."
    return

  for artifact in artifacts:
    echo "  ", artifact

proc build(p: BuildPaths) =
  configure(p)

  echo ""
  info("Building NexisOS installer")

  runBuildroot(p)

  echo ""
  echo "Build complete."

  listArtifacts(p)

proc findIso(p: BuildPaths): string =
  let imagesDir = p.output / "images"

  if not dirExists(imagesDir):
    return ""

  var candidates: seq[string] = @[]

  for kind, path in walkDir(imagesDir):
    if kind == pcFile and path.toLowerAscii().endsWith(".iso"):
      candidates.add(path)

  candidates.sort()

  if candidates.len > 0:
    result = candidates[0]

proc iso(p: BuildPaths) =
  build(p)

  echo ""
  info("Installer ISO")

  let image = findIso(p)

  if image.len == 0:
    die(
      "Buildroot completed, but no ISO was produced.\n\n" &
      "Expected an ISO under:\n  " &
      p.output / "images" & "\n\n" &
      "Check your Buildroot configuration for ISO/image generation."
    )

  echo ""
  echo "ISO:"
  echo "  ", image

proc clean(p: BuildPaths) =
  ## Restrict cleanup to the exact expected build output directory.
  ## Do not follow a symlink if the output directory itself is one.
  let expected = (p.root / "build" / "installer").absolutePath()
  let target = p.output.absolutePath()

  if target != expected:
    die("refusing cleanup: output path does not match expected path")

  if symlinkExists(target):
    die("refusing cleanup: installer output directory is a symlink")

  if not dirExists(target):
    info("Build output does not exist; nothing to clean")
    return

  # Keep the repository build directory intact.
  if target == p.root.absolutePath() or
     target == (p.root / "build").absolutePath():
    die("refusing cleanup: target is too broad")

  info("Removing Buildroot output")
  removeDir(target)

  echo "Build output removed."

proc rebuild(p: BuildPaths) =
  clean(p)
  iso(p)

proc main() =
  let p = paths()
  let args = commandLineParams()
  let command = if args.len > 0: args[0] else: "help"

  case command
  of "doctor":
    doctor(p)
  of "configure":
    configure(p)
  of "build":
    build(p)
  of "iso":
    iso(p)
  of "clean":
    clean(p)
  of "rebuild":
    rebuild(p)
  of "help", "-h", "--help":
    usage()
  else:
    stderr.writeLine("error: unknown command: " & command)
    echo ""
    usage()
    quit(2)

when isMainModule:
  main()
