import std/[os, strutils, unittest]
import ../../../src/nexis/compose/[activate, generation]

const Root = "/tmp/nexis-activate-tests"

proc good(id = 1): Generation =
  result = Generation(id: id, configDigest: "cfg", imageDigest: "img",
                      policyDigest: "pol", bootDigest: "boot",
                      kernel: "vmlinuz-6.12", initramfs: "initramfs.img",
                      packages: @[newPackageRef("base", "1", "b", "a")],
                      created: 1000)
  result.seal = computeSeal(result)

proc withImage(sub: string, g: Generation): string =
  ## A generation directory containing an image, so the presence gate passes.
  let root = Root / sub
  removeDir(root)
  createDir(generationDir(g.id, root))
  writeFile(imagePath(g.id, root), "not really an erofs image")
  root

suite "validation gates":
  test "a complete generation passes every gate":
    let root = withImage("ok", good())
    check validate(good(), root).passed()

  test "a broken seal is caught":
    let root = withImage("seal", good())
    var g = good()
    g.imageDigest = "tampered"      ## seal no longer matches
    check not validate(g, root).passed()

  test "a missing image is caught before anything is mounted":
    let root = Root / "noimage"
    removeDir(root)
    createDir(root)
    check not validate(good(), root).passed()

  test "a generation with no kernel is refused":
    let root = withImage("nokernel", good())
    var g = good()
    g.kernel = ""
    g.seal = computeSeal(g)
    let gates = validate(g, root)
    check not gates.passed()
    check "would not boot" in gates.failures()[0].detail

  test "a generation with no packages is refused":
    let root = withImage("nopkgs", good())
    var g = good()
    g.packages = @[]
    g.seal = computeSeal(g)
    check not validate(g, root).passed()

  test "every failing gate is reported, not just the first":
    # A user about to reboot may only get one look at the screen.
    let root = Root / "manyfail"
    removeDir(root)
    createDir(root)
    var g = good()
    g.kernel = ""
    g.policyDigest = ""
    g.packages = @[]
    g.seal = computeSeal(g)
    check validate(g, root).failures().len >= 4

  test "the report says the running system was not touched":
    let root = Root / "untouched"
    removeDir(root)
    createDir(root)
    check "running system is untouched" in validate(good(), root).report()

suite "modes":
  test "switch does everything":
    let s = stepsFor(amSwitch)
    check stMountImage in s
    check stSwitchDefault in s
    check stWriteBootEntry in s

  test "boot does not touch the running system":
    let s = stepsFor(amBoot)
    check stMountImage notin s
    check stSwitchDefault in s
    check not amBoot.affectsRunningSystem()
    check amBoot.survivesReboot()

  test "test does not survive a reboot":
    let s = stepsFor(amTest)
    check stMountImage in s
    check stSwitchDefault notin s
    check amTest.affectsRunningSystem()
    check not amTest.survivesReboot()

  test "build changes nothing at all":
    let s = stepsFor(amBuild)
    check stMountImage notin s
    check stSwitchDefault notin s
    check not amBuild.affectsRunningSystem()
    check not amBuild.survivesReboot()

  test "every mode validates before it acts":
    for m in Mode:
      let s = stepsFor(m)
      check s[0] == stPrepare
      check s[1] == stValidate

  test "the boot entry is written before the image is mounted":
    # A crash between them must leave a boot entry that describes something
    # real, rather than a running system nothing points at.
    let s = stepsFor(amSwitch)
    check s.find(stWriteBootEntry) < s.find(stMountImage)

  test "the default is switched after the image is mounted":
    # Otherwise a crash leaves a machine booting a generation that was never
    # verified.
    let s = stepsFor(amSwitch)
    check s.find(stMountImage) < s.find(stSwitchDefault)

suite "planning":
  test "a sound plan lists its steps":
    let root = withImage("plan", good())
    let p = planActivation(good(), 0, amSwitch, root)
    check p.canProceed()
    check "mounting the new /usr" in p.renderPlan()

  test "a failing plan shows the gates instead of the steps":
    let root = Root / "planbad"
    removeDir(root)
    createDir(root)
    let p = planActivation(good(), 0, amSwitch, root)
    check not p.canProceed()
    check "steps:" notin p.renderPlan()

  test "test mode warns that it does not survive a reboot":
    let root = withImage("plantest", good())
    let p = planActivation(good(), 7, amTest, root)
    check "returns to generation 7" in p.renderPlan()

  test "boot mode says the running system is unchanged":
    let root = withImage("planboot", good())
    let p = planActivation(good(), 7, amBoot, root)
    check "next boot" in p.renderPlan()

suite "the generation list":
  proc entries(ids: seq[int], currentId: int): seq[Entry] =
    for id in ids: result.add Entry(id: id, current: id == currentId)

  test "ids are allocated one past the highest, never reused":
    # Reuse would make generation 12 ambiguous across a collection, breaking
    # every log line and boot entry that already named it.
    check nextId(entries(@[1, 2, 3], 3)) == 4
    check nextId(@[]) == 1

  test "a gap does not cause reuse":
    check nextId(entries(@[1, 5], 5)) == 6

  test "rollback targets the generation before the current one":
    check rollbackTarget(entries(@[1, 2, 3], 3)) == 2
    check rollbackTarget(entries(@[1, 2, 3], 2)) == 1

  test "rolling back from the oldest is refused, not a silent no-op":
    # Silently doing nothing is how someone reboots expecting a fix.
    check rollbackTarget(entries(@[1, 2, 3], 1)) == -1
    check not canRollback(entries(@[1], 1))

  test "generations sort numerically, not lexically":
    # A string sort puts 10 before 9, and a rollback list in the wrong order
    # is a rollback to the wrong generation.
    let root = Root / "sorting"
    removeDir(root)
    for id in [1, 2, 9, 10, 11]:
      createDir(root / $id)
    let listed = listGenerations(root)
    check listed.len == 5
    check listed[2].id == 9
    check listed[3].id == 10

  test "an absent generations directory lists nothing rather than failing":
    check listGenerations(Root / "does-not-exist").len == 0

suite "executing":
  test "a dry run performs no filesystem changes":
    let root = withImage("dryrun", good())
    let p = planActivation(good(), 0, amSwitch, root)
    let (ok, log) = p.activate(dryRun = true)
    check ok
    check log.len > 0
    for line in log:
      check line.startsWith("[dry-run] ")

  test "a plan whose gates failed refuses before the first step":
    # The guard is here as well as in the caller, because a guard that only
    # exists at the call site is one the next call site will not have.
    let root = Root / "refuse"
    removeDir(root)
    createDir(root)
    let p = planActivation(good(), 0, amSwitch, root)
    let (ok, log) = p.activate(dryRun = true)
    check not ok
    check "gate failed" in log[0]

  test "the log names each step in order":
    let root = withImage("logorder", good())
    let (_, log) = planActivation(good(), 0, amSwitch, root)
                     .activate(dryRun = true)
    let joined = log.join("\n")
    check joined.find("boot entry") < joined.find("mount")
    check joined.find("mount") < joined.find("point")

  test "the manifest records the seal and every package":
    let root = withImage("manifest", good())
    var e = Executor(dryRun: false)
    e.writeManifest(good(), root)
    let text = readFile(manifestPath(1, root))
    check "seal = " in text
    check "[[package]]" in text
    check "name = \"base\"" in text
    check "Do not edit" in text
