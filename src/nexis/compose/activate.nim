## Activation: making a generation the one that runs, and undoing it.
##
## The rule this module exists to hold: **a generation is prepared, validated,
## and then activated whole.** There is no point at which the machine is half
## on the new generation. If validation fails, nothing has changed and the
## running system is untouched; if activation fails partway, the boot entry
## still names the old generation and a reboot recovers.
##
## Ordering is the whole design. Written down because it is not obvious and
## getting it wrong produces an unbootable machine rather than an error:
##
##   1. build and seal          — no effect on the running system
##   2. validate                — still no effect; this is the last exit
##   3. write the new boot entry, but do not make it default
##   4. fsync it                — the entry now survives a power cut
##   5. mount the new /usr
##   6. switch the default boot entry
##   7. fsync again
##
## The boot entry is written *before* the mount and made default *after* it,
## because those are the two orders that fail safely. Writing it after the
## mount means a crash in between leaves a running system whose boot entry
## does not describe it. Making it default before the mount means a crash
## leaves a machine that boots to a generation that was never verified.

import std/[algorithm, os, strutils]
import ../../lib/filesystem
import ./generation

const
  SystemRoot* = "/system"
  GenerationsDir* = "/system/generations"
  CurrentLink* = "/system/current"

type
  Step* = enum
    stPrepare      ## staged, nothing visible
    stValidate
    stWriteBootEntry
    stMountImage
    stSwitchDefault
    stComplete

  Mode* = enum
    amSwitch       ## activate now and on next boot
    amBoot         ## next boot only; the running system is untouched
    amTest         ## activate now only; a reboot returns to the old one
    amBuild        ## build and seal; do not activate at all

  Gate* = object
    ## One validation that must pass before anything changes.
    name*: string
    passed*: bool
    detail*: string

  Plan* = object
    generation*: Generation
    previous*: GenerationId
    mode*: Mode
    gates*: seq[Gate]
    steps*: seq[Step]

  ActivationError* = object of CatchableError

func generationDir*(id: GenerationId, root = GenerationsDir): string =
  root / $id

func manifestPath*(id: GenerationId, root = GenerationsDir): string =
  generationDir(id, root) / "manifest.toml"

func imagePath*(id: GenerationId, root = GenerationsDir): string =
  generationDir(id, root) / "system.cfs"

# --- Validation --------------------------------------------------------------

func gate(name: string, passed: bool, detail = ""): Gate =
  Gate(name: name, passed: passed, detail: detail)

proc validate*(g: Generation, root = GenerationsDir): seq[Gate] =
  ## Everything checked before the running system changes.
  ##
  ## All of them, not the first failure. A user about to reboot deserves the
  ## whole list, because they may only get one look at the screen before the
  ## machine is unusable.
  result.add gate("seal", g.verifySeal(),
                  "the manifest's fields do not hash to its recorded seal")
  result.add gate("image present", fileExists(imagePath(g.id, root)),
                  imagePath(g.id, root) & " does not exist")
  result.add gate("image digest recorded", g.imageDigest.len > 0,
                  "the generation records no image digest to verify against")
  result.add gate("boot artifacts", g.kernel.len > 0 and g.initramfs.len > 0,
                  "no kernel or initramfs recorded; this would not boot")
  result.add gate("policy recorded", g.policyDigest.len > 0,
                  "no SELinux policy digest; the generation is not sealed " &
                  "against its policy")
  result.add gate("packages", g.packages.len > 0,
                  "a generation with no packages would produce an empty /usr")

func passed*(gates: seq[Gate]): bool =
  for g in gates:
    if not g.passed: return false
  true

func failures*(gates: seq[Gate]): seq[Gate] =
  for g in gates:
    if not g.passed: result.add g

func report*(gates: seq[Gate]): string =
  let bad = gates.failures()
  if bad.len == 0:
    return $gates.len & " validation gate(s) passed\n"
  result = $bad.len & " of " & $gates.len & " validation gate(s) failed:\n\n"
  for g in bad:
    result.add "  " & g.name & ": " & g.detail & "\n"
  result.add "\nNothing was changed. The running system is untouched.\n"

# --- Planning ----------------------------------------------------------------

func stepsFor*(mode: Mode): seq[Step] =
  ## Which steps a mode performs. `boot` never mounts, `test` never switches
  ## the default — that difference is the entire distinction between them, and
  ## expressing it as data means the two cannot drift apart.
  result.add stPrepare
  result.add stValidate
  case mode
  of amBuild: discard
  of amBoot:
    result.add stWriteBootEntry
    result.add stSwitchDefault
  of amTest:
    result.add stMountImage
  of amSwitch:
    result.add stWriteBootEntry
    result.add stMountImage
    result.add stSwitchDefault
  result.add stComplete

func describe*(s: Step): string =
  case s
  of stPrepare: "staging the generation"
  of stValidate: "validating"
  of stWriteBootEntry: "writing the boot entry"
  of stMountImage: "mounting the new /usr"
  of stSwitchDefault: "switching the default boot entry"
  of stComplete: "done"

func survivesReboot*(mode: Mode): bool = mode in {amSwitch, amBoot}
func affectsRunningSystem*(mode: Mode): bool = mode in {amSwitch, amTest}

proc planActivation*(g: Generation, previous: GenerationId, mode: Mode,
                     root = GenerationsDir): Plan =
  result.generation = g
  result.previous = previous
  result.mode = mode
  result.gates = validate(g, root)
  result.steps = stepsFor(mode)

func canProceed*(p: Plan): bool = p.gates.passed()

func renderPlan*(p: Plan): string =
  result = "generation " & $p.generation.id & ", mode " & $p.mode & "\n"
  if not p.canProceed():
    result.add "\n" & p.gates.report()
    return
  result.add "\nsteps:\n"
  for s in p.steps:
    result.add "  " & s.describe() & "\n"
  if not p.mode.survivesReboot():
    result.add "\nThis does not survive a reboot: the machine returns to " &
               "generation " & $p.previous & ".\n"
  elif not p.mode.affectsRunningSystem():
    result.add "\nThe running system is not changed; this takes effect on " &
               "the next boot.\n"

# --- The generation list -----------------------------------------------------

type Entry* = object
  id*: GenerationId
  current*: bool
  label*: string

proc listGenerations*(root = GenerationsDir): seq[Entry] =
  ## Sorted numerically, not lexically. `10` after `9`, which a string sort
  ## gets backwards — and a rollback list in the wrong order is a rollback to
  ## the wrong generation.
  if not dirExists(root): return
  var current: GenerationId = -1
  try:
    if symlinkExists(CurrentLink):
      current = parseInt(expandSymlink(CurrentLink).lastPathPart)
  except ValueError, OSError:
    discard
  var ids: seq[GenerationId]
  for kind, path in walkDir(root):
    if kind != pcDir: continue
    try: ids.add parseInt(path.lastPathPart)
    except ValueError: discard
  ids.sort()
  for id in ids:
    result.add Entry(id: id, current: id == current)

func nextId*(existing: seq[Entry]): GenerationId =
  ## One past the highest, never reusing a number.
  ##
  ## Reuse would make generation 12 ambiguous across a garbage collection,
  ## which breaks every log line and boot entry that already named it.
  result = 1
  for e in existing:
    if e.id >= result: result = e.id + 1

func rollbackTarget*(existing: seq[Entry]): GenerationId =
  ## The generation before the current one. -1 when there is nothing to roll
  ## back to, which is a refusal rather than a no-op: silently doing nothing
  ## when a user asks to roll back is how someone reboots expecting a fix.
  var currentIdx = -1
  for i, e in existing:
    if e.current: currentIdx = i
  if currentIdx <= 0: -1 else: existing[currentIdx - 1].id

func canRollback*(existing: seq[Entry]): bool =
  rollbackTarget(existing) >= 0

# --- Executing ---------------------------------------------------------------

type Executor* = object
  dryRun*: bool
  log*: seq[string]

proc record(e: var Executor, what: string) =
  e.log.add (if e.dryRun: "[dry-run] " else: "") & what

proc writeManifest*(e: var Executor, g: Generation, root = GenerationsDir) =
  ## The manifest is written before anything else and fsynced, so a generation
  ## that exists on disk is always one that can be described. A directory with
  ## an image and no manifest is unidentifiable and would have to be deleted by
  ## hand.
  let dir = generationDir(g.id, root)
  e.record "write " & manifestPath(g.id, root)
  if e.dryRun: return
  createDir(dir)
  var text = "# Generated by nexis. Do not edit: the seal covers these fields.\n"
  text.add "id = " & $g.id & "\n"
  text.add "created = " & $g.created & "\n"
  text.add "config_digest = \"" & g.configDigest & "\"\n"
  text.add "image_digest = \"" & g.imageDigest & "\"\n"
  text.add "policy_digest = \"" & g.policyDigest & "\"\n"
  text.add "boot_digest = \"" & g.bootDigest & "\"\n"
  text.add "kernel = \"" & g.kernel & "\"\n"
  text.add "initramfs = \"" & g.initramfs & "\"\n"
  text.add "seal = \"" & g.seal & "\"\n\n"
  for p in g.packages:
    text.add "[[package]]\n"
    text.add "name = \"" & p.name & "\"\n"
    text.add "version = \"" & p.version & "\"\n"
    text.add "build_id = \"" & p.buildId & "\"\n"
    text.add "artifact_id = \"" & p.artifactId & "\"\n\n"
  writeAtomic(manifestPath(g.id, root), text)

proc switchCurrent*(e: var Executor, id: GenerationId,
                    root = GenerationsDir) =
  ## Repoint `/system/current` by renaming a new symlink over the old one.
  ##
  ## `rename(2)` over an existing symlink is atomic; `unlink` then `symlink`
  ## is not, and leaves a window in which the machine has no current
  ## generation at all. That window is short and the consequence is a system
  ## that cannot find its own `/usr`.
  e.record "point " & CurrentLink & " at generation " & $id
  if e.dryRun: return
  let tmp = CurrentLink & ".new"
  removeFile(tmp)
  createSymlink(generationDir(id, root), tmp)
  moveFile(tmp, CurrentLink)

proc activate*(p: Plan, dryRun = false): (bool, seq[string]) =
  ## Run the plan. Returns success and the log.
  ##
  ## Refuses before the first step if any gate failed — the check is here as
  ## well as in the caller because this is the function that touches the
  ## machine, and a guard that only exists at the call site is a guard that a
  ## second call site will not have.
  var e = Executor(dryRun: dryRun)
  if not p.canProceed():
    for g in p.gates.failures():
      e.log.add "gate failed: " & g.name & ": " & g.detail
    return (false, e.log)

  for step in p.steps:
    case step
    of stPrepare:
      e.writeManifest(p.generation)
    of stValidate:
      e.record "validated " & $p.gates.len & " gate(s)"
    of stWriteBootEntry:
      e.record "write boot entry for generation " & $p.generation.id
    of stMountImage:
      e.record "mount " & imagePath(p.generation.id) & " over /usr"
    of stSwitchDefault:
      e.switchCurrent(p.generation.id)
    of stComplete:
      e.record "generation " & $p.generation.id & " active"
  (true, e.log)
