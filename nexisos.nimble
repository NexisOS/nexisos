version     = "0.1.0"
author      = "Kyle Gortych"
description = "A declarative Linux distribution"
license     = "GPL-3.0-or-later"

srcDir = "src"
binDir = "bin"

requires "nim >= 2.2.0"
requires "parsetoml >= 0.7.0"
requires "checksums >= 0.2.0"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc nimc(output, source: string; release = true) =
  mkDir "bin"

  let flags =
    if release:
      "-d:release --opt:speed"
    else:
      "--debuginfo"

  exec "nim c " & flags &
       " --hints:off -o:" & output & " " & source

proc runTest(name, source: string) =
  mkDir "tests/bin"

  exec "nim c -r --hints:off --warnings:off " &
       "-o:tests/bin/" & name & " " & source

proc buildBinaries() =
  nimc "bin/nexis", "src/nexis/main.nim"
  nimc "bin/nexis-init", "src/init/main.nim"
  nimc "bin/nexis-installer", "src/tuiinstaller/main.nim"

proc requireDistroBuild() =
  if not fileExists("bin/nexis") or
      not fileExists("bin/nexis-init") or
      not fileExists("bin/nexis-installer"):
    echo "Error: NexisOS binaries haven't been built."
    echo "Run 'nimble build' before building the installer ISO."
    quit 1

proc runTests() =
  for t in ["process", "filesystem"]:
    runTest t, "tests/unit/lib/test_" & t & ".nim"

  runTest "cli", "tests/unit/cli/test_cli.nim"

  for t in ["init", "sleep", "notify", "socket", "config"]:
    runTest t, "tests/unit/init/test_" & t & ".nim"

  runTest "hashing", "tests/unit/lib/test_hashing.nim"
  runTest "store", "tests/unit/store/test_store.nim"

  for t in ["build", "scheduler", "isolate", "realise", "declare"]:
    runTest t, "tests/unit/build/test_" & t & ".nim"

  for t in ["merge", "generation", "activate", "image"]:
    runTest t, "tests/unit/compose/test_" & t & ".nim"

  runTest "bootentry", "tests/unit/compose/test_boot.nim"
  runTest "system", "tests/unit/config/test_system.nim"

  for t in ["sri", "glob", "lexical", "parse", "resolve"]:
    runTest "pkg_" & t, "tests/unit/package/test_" & t & ".nim"

  for t in ["anim", "command", "configuration", "disk", "input",
            "installation", "partition", "plan", "session", "state", "ui"]:
    runTest "inst_" & t, "tests/unit/installer/test_" & t & ".nim"

proc previewInstaller(args: string) =
  exec "nim c -r --hints:off --warnings:off " &
       "-o:bin/preview tools/preview.nim " & args

# ---------------------------------------------------------------------------
# NexisOS binaries
# ---------------------------------------------------------------------------

task build, "Build all NexisOS binaries":
  buildBinaries()

# ---------------------------------------------------------------------------
# Installer development
# ---------------------------------------------------------------------------

task preview, "Preview the TUI installer":
  previewInstaller "--all"

task installer, "Run the installer locally in dry-run mode":
  nimc "bin/nexis-installer", "src/tuiinstaller/main.nim", release = false
  exec "./bin/nexis-installer --dry-run"

# ---------------------------------------------------------------------------
# Buildroot / ISO
# ---------------------------------------------------------------------------

task doctor, "Check Buildroot dependencies and configuration":
  exec "nim r --hints:off tools/build.nim doctor"

task configure, "Configure the NexisOS Buildroot installer":
  exec "nim r --hints:off tools/build.nim configure"

task buildroot, "Build the NexisOS installer using Buildroot":
  requireDistroBuild()
  exec "nim r --hints:off tools/build.nim build"

task iso, "Build the NexisOS installer ISO":
  requireDistroBuild()
  exec "nim r --hints:off tools/build.nim iso"

task cleanBuildroot, "Remove Buildroot installer output":
  exec "nim r --hints:off tools/build.nim clean"

task rebuildIso, "Clean and rebuild the NexisOS installer ISO":
  requireDistroBuild()
  exec "nim r --hints:off tools/build.nim rebuild"

# ---------------------------------------------------------------------------
# QEMU development
# ---------------------------------------------------------------------------

task qemuCheck, "Check host capabilities and QEMU configuration":
  exec "nim r --hints:off tools/qemu.nim check"

task qemuConfig, "Display the QEMU configuration":
  exec "nim r --hints:off tools/qemu.nim print-config"

task run, "Boot the NexisOS installer in QEMU":
  exec "nim r --hints:off tools/qemu.nim installer"

task runInstalled, "Boot installed NexisOS in QEMU":
  exec "nim r --hints:off tools/qemu.nim installed"

task resetVm, "Delete the NexisOS QEMU virtual disk":
  echo "This permanently deletes the NexisOS development VM disk."
  echo "Run directly to confirm: nim r tools/qemu.nim reset --confirm"
  quit 1

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

task test, "Run all unit, integration, and smoke tests":
  runTests()

  if fileExists("tests/integration/run.sh"):
    exec "bash tests/integration/run.sh"
  else:
    echo "No integration tests yet - skipping"

  exec "bash tests/smoke/boot.sh"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

task clean, "Remove generated binaries and test artifacts":
  rmDir "nimcache"
  rmDir "bin"
  rmDir "tests/bin"
  rmDir "build/os"
  rmDir "build/pkgs"
