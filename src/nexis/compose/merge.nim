## Merging artifacts into one tree, and refusing when they disagree.
##
## This is the step NixOS never has to take. A Nix profile is a symlink farm
## where a collision can be resolved by priority, and the system closure simply
## holds both versions of a library because nothing merges them into a shared
## namespace. NexisOS composes a real `/usr`, so every path in a generation must
## map to exactly one output — and when two packages both claim `/usr/bin/foo`,
## something has to give.
##
## **What gives is the build, not the tree.** A collision is a hard failure
## naming both packages and the contested path. The alternatives are all worse:
##
## - *Last writer wins* makes the result depend on iteration order, which means
##   the same declaration produces different systems on different machines.
## - *Priority* (Nix's `buildenv`) makes it depend on a number somebody set
##   months ago in an unrelated file, and silently drops the loser.
## - *Both, renamed* produces a `/usr/bin/foo` nobody declared.
##
## Failing is the only option where the system that boots is the system the
## declaration describes. Deliberate parallel versions have their own spelling
## — slots and virtual provides — which is a declaration the user made rather
## than an accident the composer papered over.

import std/[algorithm, sets, strutils, tables]
import ../../lib/hashing

type
  Provenance* = object
    package*: string        ## which package output claims this path
    output*: string         ## "out", "lib", "dev" …

  MergedEntry* = object
    entry*: TreeEntry
    provider*: Provenance

  Collision* = object
    path*: string
    claimants*: seq[Provenance]
    identical*: bool        ## same content digest from every claimant

  Merged* = object
    entries*: seq[MergedEntry]
    collisions*: seq[Collision]
    directories*: int
    files*: int
    symlinks*: int

  Contribution* = object
    ## One package output's contribution to the tree.
    package*: string
    output*: string
    entries*: seq[TreeEntry]

func provenanceOf*(c: Contribution): Provenance =
  Provenance(package: c.package, output: c.output)

func `$`*(p: Provenance): string =
  if p.output.len == 0 or p.output == "out": p.package
  else: p.package & ":" & p.output

func describe*(c: Collision): string =
  var names: seq[string]
  for p in c.claimants: names.add $p
  result = c.path & " is claimed by " & names.join(" and ")
  if c.identical:
    result.add " (identical content — declare one as the provider, or split " &
               "the shared file into its own package)"

# --- Merging -----------------------------------------------------------------

func isDirectory(e: TreeEntry): bool = e.kind == ekDir

func sameContent(a, b: TreeEntry): bool =
  ## Two entries are interchangeable when a caller could not tell which one it
  ## got. Directories always are — every package that ships `/usr/bin/x` needs
  ## `/usr/bin` to exist, and calling that a collision would make merging any
  ## two packages impossible.
  if a.kind != b.kind: return false
  case a.kind
  of ekDir: true
  of ekSymlink: a.target == b.target
  of ekFile: a.digest == b.digest and a.executable == b.executable

proc merge*(contributions: seq[Contribution]): Merged =
  ## Merge every contribution into one tree.
  ##
  ## Contributions are processed in sorted order and the result is sorted, so
  ## the merged tree — and therefore the generation digest — is a function of
  ## the input set rather than of the order it happened to arrive in. Two
  ## machines composing the same generation must produce the same bytes.
  var byPath = initTable[string, MergedEntry]()
  var claims = initTable[string, seq[Provenance]]()
  var conflicting = initHashSet[string]()

  var sorted = contributions
  sorted.sort(proc (a, b: Contribution): int =
    let n = cmp(a.package, b.package)
    if n != 0: n else: cmp(a.output, b.output))

  for c in sorted:
    let who = c.provenanceOf()
    for e in c.entries:
      if e.path notin byPath:
        byPath[e.path] = MergedEntry(entry: e, provider: who)
        claims[e.path] = @[who]
        continue

      let existing = byPath[e.path]

      # A directory claimed by several packages is normal and expected.
      if isDirectory(e) and isDirectory(existing.entry):
        claims[e.path].add who
        continue

      # A file where a directory already is, or the reverse, is always a
      # conflict — one of them cannot exist.
      if isDirectory(e) != isDirectory(existing.entry):
        claims[e.path].add who
        conflicting.incl e.path
        continue

      if sameContent(e, existing.entry):
        # Byte-identical is still a collision, but a different kind: nothing
        # would break, yet nobody declared which package owns the path. Left
        # to the caller's policy rather than silently allowed, because
        # "identical today" is not "identical after the next update".
        claims[e.path].add who
        conflicting.incl e.path
        continue

      claims[e.path].add who
      conflicting.incl e.path

  var paths: seq[string]
  for p in byPath.keys: paths.add p
  paths.sort()

  for p in paths:
    let m = byPath[p]
    result.entries.add m
    case m.entry.kind
    of ekDir: inc result.directories
    of ekFile: inc result.files
    of ekSymlink: inc result.symlinks

  var conflicted: seq[string]
  for p in conflicting: conflicted.add p
  conflicted.sort()
  for p in conflicted:
    var identical = true
    var first = true
    var ref0: TreeEntry
    for c in sorted:
      for e in c.entries:
        if e.path != p: continue
        if first:
          ref0 = e
          first = false
        elif not sameContent(e, ref0):
          identical = false
    result.collisions.add Collision(path: p, claimants: claims[p],
                                    identical: identical)

func hasCollisions*(m: Merged): bool = m.collisions.len > 0

func total*(m: Merged): int = m.entries.len

func report*(m: Merged): string =
  ## What the user sees when a generation refuses to compose.
  ##
  ## Every collision at once, and the packages named on each line. "Path
  ## conflict detected" without saying which packages is the message that sends
  ## someone grepping the whole store.
  if m.collisions.len == 0:
    return $m.total() & " paths (" & $m.files & " files, " &
           $m.directories & " directories, " & $m.symlinks & " symlinks)\n"
  result = $m.collisions.len & " path collision(s):\n\n"
  for c in m.collisions:
    result.add "  " & c.describe() & "\n"
  result.add "\nA generation gives every path exactly one owner. Resolve this " &
             "by\nremoving one package, or by declaring a slot if both are " &
             "wanted.\n"

# --- Ownership ---------------------------------------------------------------

func ownerOf*(m: Merged, path: string): string =
  ## Which package provides this path. Backs `nexis owns`, which is the
  ## question a user asks when something on their system is behaving oddly and
  ## they need to know what put it there.
  for e in m.entries:
    if e.entry.path == path: return $e.provider
  ""

func pathsFrom*(m: Merged, package: string): seq[string] =
  for e in m.entries:
    if e.provider.package == package: result.add e.entry.path
