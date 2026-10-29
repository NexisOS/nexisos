## Generations: the manifest, the seal, and what a rollback restores.
##
## A generation is not an image. It is an image *plus* the service
## configuration, the security policy, the boot entry and the metadata that
## describe it — carried together and sealed by one digest, so a rollback
## cannot restore the filesystem while leaving an incompatible policy behind.
## That coupling is the whole reason this is a separate concept from "a merged
## tree", and it is why the seal covers all of it rather than just the files.
##
## What a generation deliberately does **not** contain: `/var`, `/home`, and
## anything else a running machine wrote. Rolling back replaces the composed
## system, not the user's work — see the addendum to ADR 0001. Verifying a
## generation is therefore a digest comparison against its manifest, never a
## walk of the live filesystem, because the live filesystem is *supposed* to
## have changed.

import std/[algorithm, strutils, tables, times]
import ../../lib/hashing
import ./merge

type
  GenerationId* = int

  PackageRef* = object
    name*: string
    version*: string
    buildId*: string
    artifactId*: string

  Generation* = object
    id*: GenerationId
    label*: string              ## optional human name
    created*: int64             ## unix seconds
    configDigest*: string       ## the declaration this was built from
    imageDigest*: string        ## the composefs metadata image
    policyDigest*: string       ## compiled SELinux policy
    bootDigest*: string         ## kernel + initramfs + boot entry
    packages*: seq[PackageRef]
    seal*: string               ## covers every field above
    kernel*: string
    initramfs*: string

  VerifyProblem* = object
    field*: string
    expected*: string
    actual*: string

func newPackageRef*(name, version, buildId, artifactId: string): PackageRef =
  PackageRef(name: name, version: version, buildId: buildId,
             artifactId: artifactId)

# --- Sealing -----------------------------------------------------------------

func sealInput*(g: Generation): string =
  ## The canonical byte sequence the seal is computed over.
  ##
  ## Built explicitly rather than by serialising the object, for two reasons.
  ## Adding a field to `Generation` must not silently change every existing
  ## seal; and a field that *should* be sealed must be added here deliberately,
  ## where the omission is visible in review rather than buried in a reflection
  ## helper that happened not to reach it.
  ##
  ## Packages are sorted by build id: a generation containing the same packages
  ## is the same generation, whatever order they were composed in.
  var parts = @[
    "nexis-generation-v1",
    $g.id,
    g.configDigest,
    g.imageDigest,
    g.policyDigest,
    g.bootDigest,
    g.kernel,
    g.initramfs,
  ]
  var refs: seq[string]
  for p in g.packages:
    refs.add p.name & "\x1f" & p.version & "\x1f" & p.buildId & "\x1f" &
             p.artifactId
  refs.sort()
  parts.add refs
  parts.join("\x1e")

proc computeSeal*(g: Generation): string =
  string(sha256(g.sealInput()))

proc sealed*(g: Generation): Generation =
  result = g
  result.seal = computeSeal(g)

proc verifySeal*(g: Generation): bool =
  ## Does the recorded seal match what these fields hash to?
  ##
  ## Note what this does *not* prove: that the image on disk matches
  ## `imageDigest`. It proves the manifest is internally consistent — that
  ## nobody edited a field without recomputing the seal. Checking the image
  ## itself is fs-verity's job at mount time, which is continuous rather than
  ## once at activation.
  g.seal.len > 0 and g.seal == computeSeal(g)

func verify*(g, recorded: Generation): seq[VerifyProblem] =
  ## Compare a generation against what was recorded for it. Every difference,
  ## not the first — a boot that fails validation should say everything that is
  ## wrong, because the machine may be about to become unbootable and the user
  ## may only get one look at the screen.
  for (field, a, b) in [("config", g.configDigest, recorded.configDigest),
                        ("image", g.imageDigest, recorded.imageDigest),
                        ("policy", g.policyDigest, recorded.policyDigest),
                        ("boot", g.bootDigest, recorded.bootDigest),
                        ("kernel", g.kernel, recorded.kernel),
                        ("initramfs", g.initramfs, recorded.initramfs)]:
    if a != b:
      result.add VerifyProblem(field: field, expected: b, actual: a)
  if g.packages.len != recorded.packages.len:
    result.add VerifyProblem(field: "packages",
                             expected: $recorded.packages.len,
                             actual: $g.packages.len)

# --- Building one ------------------------------------------------------------

proc generationFrom*(id: GenerationId, m: Merged, packages: seq[PackageRef],
                     configDigest, imageDigest, policyDigest,
                     bootDigest: string, now: int64 = 0): Generation =
  ## Assemble and seal. Refuses a merged tree that still has collisions: a
  ## generation with two owners for one path is not a system, and sealing it
  ## would make the contradiction permanent and authenticated.
  if m.hasCollisions():
    raise newException(ValueError,
      "cannot build a generation from a tree with " & $m.collisions.len &
      " unresolved collision(s)")
  result = Generation(id: id, created: (if now > 0: now
                                        else: epochTime().int64),
                      configDigest: configDigest, imageDigest: imageDigest,
                      policyDigest: policyDigest, bootDigest: bootDigest,
                      packages: packages)
  result.seal = computeSeal(result)

# --- Comparing ---------------------------------------------------------------

type
  ChangeKind* = enum
    ckAdded
    ckRemoved
    ckChanged

  PackageChange* = object
    kind*: ChangeKind
    name*: string
    fromVersion*, toVersion*: string

func diff*(a, b: Generation): seq[PackageChange] =
  ## What changed between two generations, by package.
  ##
  ## This is what makes a rollback a decision rather than a guess: before
  ## reverting, a user can see that the difference is one kernel and two
  ## libraries rather than four hundred packages.
  var inA = initTable[string, PackageRef]()
  var inB = initTable[string, PackageRef]()
  for p in a.packages: inA[p.name] = p
  for p in b.packages: inB[p.name] = p

  var names: seq[string]
  for n in inA.keys: names.add n
  for n in inB.keys:
    if n notin inA: names.add n
  names.sort()

  for n in names:
    if n notin inB:
      result.add PackageChange(kind: ckRemoved, name: n,
                               fromVersion: inA[n].version)
    elif n notin inA:
      result.add PackageChange(kind: ckAdded, name: n,
                               toVersion: inB[n].version)
    elif inA[n].buildId != inB[n].buildId:
      # buildId, not version: a rebuild against a new toolchain is a real
      # change even when the version string is identical, and hiding it would
      # make "nothing changed" a lie in exactly the case a user is debugging.
      result.add PackageChange(kind: ckChanged, name: n,
                               fromVersion: inA[n].version,
                               toVersion: inB[n].version)

func describe*(c: PackageChange): string =
  case c.kind
  of ckAdded: "+ " & c.name & " " & c.toVersion
  of ckRemoved: "- " & c.name & " " & c.fromVersion
  of ckChanged:
    if c.fromVersion == c.toVersion:
      "~ " & c.name & " " & c.fromVersion & " (rebuilt)"
    else:
      "~ " & c.name & " " & c.fromVersion & " -> " & c.toVersion

func renderDiff*(changes: seq[PackageChange]): string =
  if changes.len == 0: return "no package changes\n"
  var added, removed, changed: int
  for c in changes:
    case c.kind
    of ckAdded: inc added
    of ckRemoved: inc removed
    of ckChanged: inc changed
  result = $added & " added, " & $removed & " removed, " &
           $changed & " changed\n\n"
  for c in changes: result.add "  " & c.describe() & "\n"

proc summary*(g: Generation): string =
  result = "generation " & $g.id
  if g.label.len > 0: result.add " (" & g.label & ")"
  result.add "\n  packages: " & $g.packages.len
  result.add "\n  seal:     " & (if g.seal.len >= 16: g.seal[0 ..< 16]
                                 else: g.seal)
  result.add "\n  verified: " & (if g.verifySeal(): "yes" else: "NO")
  result.add "\n"
