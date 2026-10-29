## The content-addressed store.
##
## Insert is atomic and idempotent: content is staged in `tmp/` under a unique
## name, hashed, then renamed into place. A crash mid-insert leaves a stray
## temp file and nothing else — never a half-written object under a name that
## claims to be complete, which would poison every later lookup and be
## invisible until the artifact was used.
##
## Objects are immutable once written. Two packages containing byte-identical
## files converge on one object, which is where the disk saving over a
## conventional distribution comes from, and why a generation's metadata image
## can be a few megabytes rather than a copy of /usr.

import std/[algorithm, os, strutils, tables, sets]
import ../../lib/[hashing, paths, errors]
import ./index

export Store, objectPath, manifestPath
export index

type
  Manifest* = object
    id*: Digest
    entries*: seq[TreeEntry]

  InsertStats* = object
    objectsWritten*: int      ## new to the store
    objectsDeduped*: int      ## already present
    bytesWritten*: int64

proc initStore*(root = DefaultStoreRoot): Store =
  result = Store(root: root)
  for d in [result.objectsDir, result.manifestsDir, result.tmpDir,
            result.buildDir]:
    try:
      createDir(d)
    except OSError as e:
      raiseNexis(ekStore, "cannot create store directory " & d & ": " & e.msg)

proc hasObject*(s: Store, d: Digest): bool =
  fileExists(s.objectPath(d))

proc hasManifest*(s: Store, d: Digest): bool =
  fileExists(s.manifestPath(d))

var tmpCounter = 0

proc stagePath(s: Store): string =
  inc tmpCounter
  s.tmpDir / ("stage-" & $getCurrentProcessId() & "-" & $tmpCounter)

proc commit(s: Store, staged, final: string) =
  ## Rename into place. If the destination already exists another process won
  ## the race and its copy is byte-identical by construction, so the staged
  ## copy is simply dropped.
  createDir(final.parentDir)
  if fileExists(final):
    removeFile(staged)
    return
  try:
    moveFile(staged, final)
  except OSError:
    if fileExists(final):
      removeFile(staged)
    else:
      raiseNexis(ekStore, "cannot commit object to " & final)
  try:
    setFilePermissions(final, {fpUserRead, fpGroupRead, fpOthersRead})
  except OSError:
    discard

proc insertData*(s: Store, data: string): tuple[digest: Digest, isNew: bool] =
  let d = sha256(data)
  if s.hasObject(d): return (d, false)
  let staged = s.stagePath()
  writeFile(staged, data)
  s.commit(staged, s.objectPath(d))
  (d, true)

proc insertFile*(s: Store, path: string): tuple[digest: Digest, isNew: bool] =
  let d = hashFile(path)
  if s.hasObject(d): return (d, false)
  let staged = s.stagePath()
  copyFile(path, staged)
  s.commit(staged, s.objectPath(d))
  (d, true)

proc readObject*(s: Store, d: Digest): string =
  let p = s.objectPath(d)
  if not fileExists(p):
    raiseNexis(ekStore, "object not in store: " & d.string)
  readFile(p)

proc parseManifest*(id: Digest, text: string): Manifest =
  result.id = id
  var lineNo = 0
  for raw in text.splitLines():
    inc lineNo
    if raw.len == 0: continue
    let parts = raw.split(' ')
    if parts.len < 3:
      raiseNexis(ekStore, "malformed manifest line " & $lineNo & ": " & raw)
    case parts[0]
    of "f":
      if parts.len != 4:
        raiseNexis(ekStore, "file entry needs 4 fields on line " & $lineNo)
      let dg = Digest(parts[2])
      if not dg.isValid:
        raiseNexis(ekStore, "bad digest on line " & $lineNo & ": " & parts[2])
      result.entries.add TreeEntry(path: decodeField(parts[3]), kind: ekFile,
                                   executable: parts[1] == "755", digest: dg)
    of "d":
      if parts.len != 3:
        raiseNexis(ekStore, "dir entry needs 3 fields on line " & $lineNo)
      result.entries.add TreeEntry(path: decodeField(parts[2]), kind: ekDir)
    of "l":
      if parts.len != 3:
        raiseNexis(ekStore, "symlink entry needs 3 fields on line " & $lineNo)
      result.entries.add TreeEntry(path: decodeField(parts[2]), kind: ekSymlink,
                                   target: decodeField(parts[1]))
    else:
      raiseNexis(ekStore, "unknown manifest entry type on line " & $lineNo &
                 ": " & parts[0])

proc validate*(m: Manifest) =
  ## Manifests describe trees that will be materialised into a generation, and
  ## they come from build outputs and (once import tooling lands) from foreign
  ## packaging. Path escapes are checked here, at the trust boundary, rather
  ## than at materialisation time when the damage is already possible.
  var seen = initHashSet[string]()
  for e in m.entries:
    if not isSafeRelPath(e.path):
      raiseNexis(ekStore, "unsafe path in manifest: " & e.path,
                 hint = "Paths must be relative and must not contain '..'.")
    if e.path in seen:
      raiseNexis(ekStore, "duplicate path in manifest: " & e.path)
    seen.incl e.path
    if e.kind == ekSymlink and not isSafeSymlinkTarget(e.target, e.path):
      raiseNexis(ekStore, "symlink escapes the artifact: " & e.path &
                 " -> " & e.target)

proc insertTree*(s: Store, root: string): tuple[id: Digest, stats: InsertStats] =
  ## Walks a build output, inserts every file as an object, and stores the
  ## manifest describing how they compose. The manifest's own digest is the
  ## artifact identity.
  if not dirExists(root):
    raiseNexis(ekStore, "no such directory: " & root)

  var entries = walkTree(root)
  var stats: InsertStats

  for e in entries.mitems:
    if e.kind != ekFile: continue
    let full = root / e.path
    let (d, isNew) = s.insertFile(full)
    e.digest = d
    if isNew:
      inc stats.objectsWritten
      stats.bytesWritten += getFileSize(full)
    else:
      inc stats.objectsDeduped

  let m = Manifest(entries: entries)
  m.validate()

  let text = renderManifest(entries)
  let id = sha256(text)
  if not s.hasManifest(id):
    let staged = s.stagePath()
    writeFile(staged, text)
    s.commit(staged, s.manifestPath(id))
  (id, stats)

proc readManifest*(s: Store, id: Digest): Manifest =
  let p = s.manifestPath(id)
  if not fileExists(p):
    raiseNexis(ekStore, "manifest not in store: " & id.string)
  parseManifest(id, readFile(p))

proc materialise*(s: Store, id: Digest, dest: string) =
  ## Reconstructs a tree from a manifest. Used for build inputs and for
  ## inspection; generation assembly does not go through this, since composefs
  ## points at the objects in place rather than copying them.
  let m = s.readManifest(id)
  m.validate()
  createDir(dest)
  for e in m.entries:
    let target = dest / e.path
    case e.kind
    of ekDir:
      createDir(target)
    of ekFile:
      createDir(target.parentDir)
      copyFile(s.objectPath(e.digest), target)
      if e.executable:
        setFilePermissions(target, {fpUserRead, fpUserExec, fpGroupRead,
                                    fpGroupExec, fpOthersRead, fpOthersExec})
    of ekSymlink:
      createDir(target.parentDir)
      createSymlink(e.target, target)

## --- References and garbage collection ------------------------------------
##
## Refcounted, not mark-and-sweep. Retiring a generation costs what that
## generation uniquely held; a store with millions of objects and ten
## generations does not get slower to collect as it grows. See ADR 0003.

proc indexPath*(s: Store): string = s.root / "index" / "log"
proc rootsPath*(s: Store): string = s.root / "index" / "roots"

proc openStoreIndex*(s: Store): Index =
  openIndex(s.indexPath, s.rootsPath)

proc retain*(s: Store, ix: var Index, id: Digest) =
  ## Registers an artifact and increments the refcount of every object it
  ## uses. Called when a generation or environment is created.
  let m = s.readManifest(id)
  m.validate()
  ix.addRef(id)
  for e in m.entries:
    if e.kind != ekFile: continue
    var size: int64 = 0
    try: size = getFileSize(s.objectPath(e.digest))
    except OSError: discard
    ix.addRef(e.digest, size)

proc collect*(s: Store, ix: var Index, id: Digest, dryRun = false):
    tuple[removed: int, freed: int64] =
  ## Releases an artifact. Objects whose refcount reaches zero are unlinked.
  ## Deletions are batched and sorted by shard so the unlinks hit each
  ## directory together rather than seeking across the store.
  if not s.hasManifest(id): return
  let m = s.readManifest(id)

  var doomed: seq[tuple[path: string, size: int64]]
  for e in m.entries:
    if e.kind != ekFile: continue
    let size = ix.get(e.digest).size
    if ix.release(e.digest):
      doomed.add (s.objectPath(e.digest), size)

  if ix.release(id):
    doomed.add (s.manifestPath(id), 0'i64)

  doomed.sort(proc (a, b: auto): int = cmp(a.path, b.path))
  for (path, size) in doomed:
    if not dryRun:
      try: removeFile(path)
      except OSError: continue
    inc result.removed
    result.freed += size

proc verify*(s: Store, ix: Index): seq[string] =
  ## Cross-checks the index against the filesystem. The index is a cache, so
  ## disagreement is repairable rather than fatal — but it should be reported
  ## rather than silently tolerated.
  for d, info in ix.objects:
    # Manifests are refcounted in the same table as objects, since both need
    # releasing, but they live under manifests/ rather than objects/.
    if fileExists(s.objectPath(Digest(d))): continue
    if fileExists(s.manifestPath(Digest(d))): continue
    result.add "indexed but missing from disk: " & d
  # The digest is the shard directory plus the filename, not the filename
  # alone: objects are stored as <2 hex>/<remaining 62>, matching the layout
  # composefs expects. Reading only the filename here reported every object as
  # unindexed, which is exactly the sort of false alarm that teaches people to
  # ignore `nexis store verify`.
  for shardDir in walkDirs(s.objectsDir / "*"):
    let prefix = shardDir.lastPathPart
    for path in walkFiles(shardDir / "*"):
      let digest = prefix & path.extractFilename
      if not ix.objects.hasKey(digest):
        result.add "on disk but unindexed: " & digest

proc rebuildIndex*(s: Store): Index =
  ## Reconstructs the index from the manifests reachable from registered
  ## roots. This is the repair path and the only O(store) operation in the
  ## design; it exists so that losing the index costs one slow pass, never
  ## data.
  removeFile(s.indexPath)
  var ix = s.openStoreIndex()      # roots survive: they are a separate file
  let savedRoots = ix.roots()
  for r in savedRoots:
    if s.hasManifest(r.artifact):
      s.retain(ix, r.artifact)
  ix
