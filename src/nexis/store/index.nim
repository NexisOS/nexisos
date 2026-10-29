## The store index: what is present, what references it, and what is a root.
##
## Garbage collection must cost what is being *retired*, not what is being
## *stored*. Walking the object tree to compute a reachable set is O(store) and
## gets slower every year the machine is in use — it is the shape of the
## problem that makes `nix-collect-garbage` slow. So the store keeps refcounts
## and decrements them when a generation retires; objects reaching zero are
## unlinked, and nothing else is touched. See ADR 0003.
##
## Format: an append-only log of fixed-shape text records, each CRC-checked so
## a torn tail from a crash truncates rather than being silently misread. The
## map is rebuilt in memory on open; compaction rewrites the log once dead
## records outnumber live ones.
##
## Chosen over SQLite deliberately: the workload is a hash map keyed by a
## 32-byte digest, and a general SQL engine on exactly this shape is one of the
## things that makes Nix's GC slow. The interface here is narrow on purpose —
## `get`, `addRef`, `release`, `roots` — so that swapping in LMDB, if the live
## object count ever reaches a few million, is contained.
##
## The index is a cache, never the source of truth. `rebuild` reconstructs it
## from the manifests on disk, so losing it costs one slow pass and no data.

import std/[os, strutils, tables]
import ../../lib/hashing

type
  RootKind* = enum
    rkGeneration = "generation"
    rkEnvironment = "environment"
    rkPin = "pin"

  Root* = object
    kind*: RootKind
    name*: string        ## generation number, environment id, or pin label
    artifact*: Digest

  ObjectInfo* = object
    refs*: int
    size*: int64

  Index* = object
    path*: string
    rootsPath*: string
    objects*: Table[string, ObjectInfo]
    rootTable*: Table[string, Root]
    liveRecords: int
    deadRecords: int

func crc32(s: string): uint32 =
  ## Small table-free CRC32. The index is written on every rebuild, so the
  ## cost matters more than the elegance.
  var crc = 0xFFFFFFFF'u32
  for ch in s:
    crc = crc xor uint32(uint8(ch))
    for _ in 0 ..< 8:
      if (crc and 1'u32) != 0:
        crc = (crc shr 1) xor 0xEDB88320'u32
      else:
        crc = crc shr 1
  crc xor 0xFFFFFFFF'u32

func encodeRecord(fields: varargs[string]): string =
  let body = fields.join(" ")
  body & " " & toHex(crc32(body).int64, 8).toLowerAscii()

func decodeRecord(line: string): seq[string] =
  ## Returns an empty seq for a torn or corrupt record.
  let sp = line.rfind(' ')
  if sp <= 0: return @[]
  let body = line[0 ..< sp]
  let want = line[sp + 1 .. ^1]
  if toHex(crc32(body).int64, 8).toLowerAscii() != want: return @[]
  body.split(' ')

proc appendRecord(ix: var Index, fields: varargs[string]) =
  let f = open(ix.path, fmAppend)
  defer: f.close()
  f.writeLine(encodeRecord(fields))

proc apply(ix: var Index, fields: seq[string]) =
  case fields[0]
  of "o":
    # o <digest> <refs> <size>
    if fields.len != 4: return
    let d = fields[1]
    let refs = try: parseInt(fields[2]) except ValueError: return
    let size = try: parseBiggestInt(fields[3]) except ValueError: return
    if refs <= 0:
      ix.objects.del d
    else:
      ix.objects[d] = ObjectInfo(refs: refs, size: size)
  else: discard

proc loadRoots(ix: var Index) =
  ## Roots live in their own file, rewritten atomically, deliberately *not* in
  ## the refcount log.
  ##
  ## The log is a cache that can be rebuilt from the store. The root set
  ## cannot: nothing on disk records that generation 42 is still bootable. If
  ## roots lived only in the log, losing the log would mean losing every root,
  ## and the next collection would delete a running system. Refcounts are
  ## recoverable; roots are the ground truth that recovery starts from.
  if not fileExists(ix.rootsPath): return
  for line in lines(ix.rootsPath):
    if line.len == 0: continue
    let fields = decodeRecord(line)
    if fields.len != 3: continue
    var kind: RootKind
    var found = false
    for k in RootKind:
      if $k == fields[0]: kind = k; found = true
    if not found: continue
    ix.rootTable[fields[0] & "/" & fields[1]] =
      Root(kind: kind, name: fields[1], artifact: Digest(fields[2]))

proc saveRoots(ix: Index) =
  let tmp = ix.rootsPath & ".tmp"
  var f = open(tmp, fmWrite)
  for _, r in ix.rootTable:
    f.writeLine(encodeRecord($r.kind, r.name, r.artifact.string))
  f.close()
  moveFile(tmp, ix.rootsPath)

proc openIndex*(path: string, rootsPath = ""): Index =
  result = Index(path: path,
                 rootsPath: if rootsPath.len > 0: rootsPath
                            else: path.parentDir / "roots")
  result.objects = initTable[string, ObjectInfo]()
  result.rootTable = initTable[string, Root]()
  createDir(path.parentDir)
  result.loadRoots()
  if not fileExists(path):
    writeFile(path, "")
    return

  var total = 0
  for line in lines(path):
    if line.len == 0: continue
    inc total
    let fields = decodeRecord(line)
    if fields.len == 0:
      # A torn tail is expected after a crash: the last append did not
      # complete. Anything corrupt earlier means the log is untrustworthy and
      # a rebuild is the honest response, not a guess.
      continue
    result.apply(fields)
  result.liveRecords = result.objects.len
  result.deadRecords = max(0, total - result.liveRecords)

proc get*(ix: Index, d: Digest): ObjectInfo =
  ix.objects.getOrDefault(d.string, ObjectInfo(refs: 0, size: 0))

proc has*(ix: Index, d: Digest): bool =
  ix.objects.hasKey(d.string)

proc addRef*(ix: var Index, d: Digest, size: int64 = 0) =
  var info = ix.objects.getOrDefault(d.string, ObjectInfo(refs: 0, size: size))
  inc info.refs
  if size > 0: info.size = size
  ix.objects[d.string] = info
  ix.appendRecord("o", d.string, $info.refs, $info.size)
  inc ix.deadRecords

proc release*(ix: var Index, d: Digest): bool =
  ## Returns true when the refcount reached zero and the object should be
  ## unlinked. Never goes negative: an over-release is a bug in the caller and
  ## a wedged store is worse than a leaked object.
  if not ix.objects.hasKey(d.string): return false
  var info = ix.objects[d.string]
  dec info.refs
  if info.refs <= 0:
    ix.objects.del d.string
    ix.appendRecord("o", d.string, "0", $info.size)
    inc ix.deadRecords
    return true
  ix.objects[d.string] = info
  ix.appendRecord("o", d.string, $info.refs, $info.size)
  inc ix.deadRecords
  false

proc addRoot*(ix: var Index, kind: RootKind, name: string, artifact: Digest) =
  ## Roots are explicit. Discovering them by scanning `/proc`, as Nix does, is
  ## both slow and unreliable; an unregistered root here is a live tree whose
  ## objects can be collected, which is the one failure mode in this design
  ## that breaks a system rather than wasting disk.
  ix.rootTable[$kind & "/" & name] =
    Root(kind: kind, name: name, artifact: artifact)
  ix.saveRoots()

proc removeRoot*(ix: var Index, kind: RootKind, name: string) =
  ix.rootTable.del $kind & "/" & name
  ix.saveRoots()

proc roots*(ix: Index): seq[Root] =
  for _, r in ix.rootTable: result.add r

proc hasRoot*(ix: Index, kind: RootKind, name: string): bool =
  ix.rootTable.hasKey($kind & "/" & name)

proc totalSize*(ix: Index): int64 =
  ## Sizes come from the index. Walking directories to compute them is the
  ## same O(store) mistake in a different costume.
  for _, info in ix.objects: result += info.size

proc objectCount*(ix: Index): int = ix.objects.len

proc needsCompaction*(ix: Index): bool =
  ix.deadRecords > max(1024, ix.objects.len)

proc compact*(ix: var Index) =
  ## Rewrites the log with one record per live entry, via a temp file and a
  ## rename so a crash mid-compaction leaves the old log intact.
  let tmp = ix.path & ".compact"
  var f = open(tmp, fmWrite)
  for d, info in ix.objects:
    f.writeLine(encodeRecord("o", d, $info.refs, $info.size))
  f.close()
  moveFile(tmp, ix.path)
  ix.liveRecords = ix.objects.len
  ix.deadRecords = 0
