import std/[os, sequtils, strutils, unittest]
import ../../../src/lib/[hashing, paths, errors]
import ../../../src/nexis/store/store

const root = "/tmp/nexis-store-test"

proc freshStore(): Store =
  removeDir(root)
  initStore(root)

proc buildTree(dir: string) =
  removeDir(dir)
  createDir(dir / "bin")
  createDir(dir / "share")
  writeFile(dir / "bin" / "tool", "#!/bin/sh\necho hi\n")
  setFilePermissions(dir / "bin" / "tool",
                     {fpUserRead, fpUserWrite, fpUserExec})
  writeFile(dir / "share" / "readme", "docs\n")
  createSymlink("tool", dir / "bin" / "tool2")

suite "path safety":
  test "relative paths inside the tree are accepted":
    check isSafeRelPath("bin/tool")
    check isSafeRelPath("a")

  test "escapes and absolutes are rejected":
    check not isSafeRelPath("")
    check not isSafeRelPath("/etc/passwd")
    check not isSafeRelPath("../outside")
    check not isSafeRelPath("bin/../../etc/shadow")
    check not isSafeRelPath("bin//tool")
    check not isSafeRelPath("./tool")

  test "symlinks may stay inside or point at an absolute FHS path":
    check isSafeSymlinkTarget("tool", "bin/tool2")
    check isSafeSymlinkTarget("/usr/bin/env", "bin/env")
    check isSafeSymlinkTarget("../share/readme", "bin/link")

  test "a symlink climbing out of the artifact is rejected":
    check not isSafeSymlinkTarget("../../etc/shadow", "bin/link")
    check not isSafeSymlinkTarget("../..", "bin/link")

suite "object insertion":
  setup:
    var s = freshStore()

  test "inserting data returns a valid digest and reports it as new":
    let (d, isNew) = s.insertData("hello")
    check d.isValid
    check isNew
    check s.hasObject(d)
    check s.readObject(d) == "hello"

  test "inserting the same content twice deduplicates":
    let (d1, new1) = s.insertData("same")
    let (d2, new2) = s.insertData("same")
    check d1 == d2
    check new1
    check not new2

  test "objects land under a sharded path":
    let (d, _) = s.insertData("shard me")
    check s.objectPath(d).contains("/objects/" & d.string[0 .. 1] & "/")
    check fileExists(s.objectPath(d))

  test "reading an absent object raises a store error":
    expect NexisError:
      discard s.readObject(sha256("never inserted"))

  test "stored objects are left read-only":
    let (d, _) = s.insertData("immutable")
    check fpUserWrite notin getFilePermissions(s.objectPath(d))

  test "no staging files are left behind":
    discard s.insertData("a")
    discard s.insertData("b")
    var leftovers = 0
    for _ in walkFiles(s.tmpDir / "*"): inc leftovers
    check leftovers == 0

suite "trees and manifests":
  setup:
    var s = freshStore()
    buildTree("/tmp/nexis-tree-a")

  test "inserting a tree returns a stable artifact id":
    let (id1, _) = s.insertTree("/tmp/nexis-tree-a")
    let (id2, _) = s.insertTree("/tmp/nexis-tree-a")
    check id1 == id2
    check s.hasManifest(id1)

  test "the artifact id is the hash of the manifest, not of the directory":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    check id == sha256(renderManifest(s.readManifest(id).entries))

  test "the manifest round-trips through parsing":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    let m = s.readManifest(id)
    check m.entries.len == 5      # 2 dirs, 2 files, 1 symlink
    check renderManifest(m.entries) == readFile(s.manifestPath(id))

  test "the executable bit survives a round trip":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    for e in s.readManifest(id).entries:
      if e.path == "bin/tool": check e.executable
      if e.path == "share/readme": check not e.executable

  test "symlink targets survive a round trip":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    var found = false
    for e in s.readManifest(id).entries:
      if e.path == "bin/tool2":
        check e.kind == ekSymlink
        check e.target == "tool"
        found = true
    check found

  test "a second tree sharing a file deduplicates the object":
    discard s.insertTree("/tmp/nexis-tree-a")
    buildTree("/tmp/nexis-tree-b")
    writeFile("/tmp/nexis-tree-b/share/extra", "new content\n")
    let (_, stats) = s.insertTree("/tmp/nexis-tree-b")
    # Two file objects (bin/tool, share/readme) are already present; the
    # symlink is not an object, so it is not counted.
    check stats.objectsDeduped == 2
    check stats.objectsWritten == 1

  test "materialise reconstructs the tree":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    removeDir("/tmp/nexis-out")
    s.materialise(id, "/tmp/nexis-out")
    check readFile("/tmp/nexis-out/share/readme") == "docs\n"
    check fpUserExec in getFilePermissions("/tmp/nexis-out/bin/tool")
    check expandSymlink("/tmp/nexis-out/bin/tool2") == "tool"
    check hashTree("/tmp/nexis-out") == hashTree("/tmp/nexis-tree-a")

  test "a missing directory raises rather than storing an empty tree":
    expect NexisError:
      discard s.insertTree("/tmp/definitely-not-here")

suite "manifest validation":
  test "an escaping path is rejected at parse-and-validate time":
    let text = "f 644 " & sha256("x").string & " ../../etc/shadow\n"
    let m = parseManifest(sha256(text), text)
    expect NexisError:
      m.validate()

  test "an escaping symlink is rejected":
    let text = "l ../../../etc/shadow bin/evil\n"
    let m = parseManifest(sha256(text), text)
    expect NexisError:
      m.validate()

  test "a duplicate path is rejected":
    let d = sha256("x").string
    let text = "f 644 " & d & " a\nf 644 " & d & " a\n"
    let m = parseManifest(sha256(text), text)
    expect NexisError:
      m.validate()

  test "a corrupt digest is rejected":
    expect NexisError:
      discard parseManifest(sha256("x"), "f 644 notahash a\n")

  test "an unknown entry type is rejected":
    expect NexisError:
      discard parseManifest(sha256("x"), "z 644 whatever a\n")

suite "manifest field encoding":
  setup:
    var s = freshStore()

  test "a path containing a space round-trips":
    removeDir("/tmp/nexis-spaces")
    createDir("/tmp/nexis-spaces/share")
    writeFile("/tmp/nexis-spaces/share/Some Font.ttf", "font\n")
    let (id, _) = s.insertTree("/tmp/nexis-spaces")
    var found = false
    for e in s.readManifest(id).entries:
      if e.path == "share/Some Font.ttf": found = true
    check found

  test "a symlink target containing a space round-trips":
    # Three-field symlink lines are only unambiguous because both fields are
    # encoded; without it "l a b c" cannot be split correctly.
    removeDir("/tmp/nexis-spacelink")
    createDir("/tmp/nexis-spacelink")
    writeFile("/tmp/nexis-spacelink/a b", "x\n")
    createSymlink("a b", "/tmp/nexis-spacelink/link name")
    let (id, _) = s.insertTree("/tmp/nexis-spacelink")
    var ok = false
    for e in s.readManifest(id).entries:
      if e.kind == ekSymlink:
        check e.path == "link name"
        check e.target == "a b"
        ok = true
    check ok

  test "every manifest line has a fixed field count":
    removeDir("/tmp/nexis-spaces2")
    createDir("/tmp/nexis-spaces2/d ir")
    writeFile("/tmp/nexis-spaces2/d ir/f ile", "x")
    let (id, _) = s.insertTree("/tmp/nexis-spaces2")
    for line in readFile(s.manifestPath(id)).splitLines():
      if line.len == 0: continue
      let n = line.split(' ').len
      case line[0]
      of 'f': check n == 4
      of 'd', 'l': check n == 3
      else: check false

suite "index":
  setup:
    var s = freshStore()
    var ix = s.openStoreIndex()

  test "refcounts rise and fall":
    let d = sha256("payload")
    check not ix.has(d)
    ix.addRef(d, 100)
    check ix.get(d).refs == 1
    ix.addRef(d, 100)
    check ix.get(d).refs == 2
    check not ix.release(d)
    check ix.release(d)
    check not ix.has(d)

  test "releasing an unknown object is a no-op, not a negative count":
    check not ix.release(sha256("never seen"))

  test "state survives reopening":
    let d = sha256("persisted")
    ix.addRef(d, 42)
    ix.addRoot(rkGeneration, "1", sha256("gen1"))
    var reopened = openIndex(s.indexPath)
    check reopened.get(d).refs == 1
    check reopened.get(d).size == 42
    check reopened.hasRoot(rkGeneration, "1")

  test "a torn trailing record is discarded rather than misread":
    ix.addRef(sha256("good"), 1)
    let f = open(s.indexPath, fmAppend)
    f.write("o deadbeef 3 999")     # no newline, no crc
    f.close()
    var reopened = openIndex(s.indexPath)
    check reopened.get(sha256("good")).refs == 1
    check not reopened.has(Digest("deadbeef"))

  test "a corrupted record is rejected by its checksum":
    ix.addRef(sha256("intact"), 1)
    var text = readFile(s.indexPath)
    text = text.replace(" 1 1 ", " 9 1 ")
    writeFile(s.indexPath, text)
    var reopened = openIndex(s.indexPath)
    check reopened.objectCount == 0

  test "roots can be removed":
    ix.addRoot(rkEnvironment, "proj-a", sha256("envA"))
    check ix.hasRoot(rkEnvironment, "proj-a")
    ix.removeRoot(rkEnvironment, "proj-a")
    check not ix.hasRoot(rkEnvironment, "proj-a")
    var reopened = openIndex(s.indexPath)
    check not reopened.hasRoot(rkEnvironment, "proj-a")

  test "root kinds are namespaced from each other":
    ix.addRoot(rkGeneration, "1", sha256("a"))
    ix.addRoot(rkPin, "1", sha256("b"))
    check ix.roots().len == 2

  test "compaction preserves state and drops dead records":
    let d = sha256("churn")
    for _ in 0 .. 200: ix.addRef(d, 8)
    for _ in 0 .. 199: discard ix.release(d)
    ix.addRoot(rkGeneration, "7", sha256("gen7"))
    let before = ix.get(d).refs
    ix.compact()
    var reopened = openIndex(s.indexPath)
    check reopened.get(d).refs == before
    check reopened.hasRoot(rkGeneration, "7")
    check readFile(s.indexPath).splitLines().len <= 4

  test "sizes come from the index, not from walking the store":
    ix.addRef(sha256("a"), 100)
    ix.addRef(sha256("b"), 250)
    check ix.totalSize == 350

suite "refcounted collection":
  setup:
    var s = freshStore()
    var ix = s.openStoreIndex()
    buildTree("/tmp/nexis-tree-a")

  test "retaining an artifact refcounts every object it uses":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, id)
    for e in s.readManifest(id).entries:
      if e.kind == ekFile:
        check ix.get(e.digest).refs == 1

  test "collecting the only holder frees its objects":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, id)
    let (removed, _) = s.collect(ix, id)
    check removed > 0
    check not s.hasManifest(id)
    check not s.hasObject(sha256("docs\n"))

  test "an object held by two generations survives the first collection":
    # The property that makes rollback safe: retiring one generation must not
    # touch files another still redirects into.
    let (idA, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, idA)
    buildTree("/tmp/nexis-tree-b")
    writeFile("/tmp/nexis-tree-b/share/unique", "only in b\n")
    let (idB, _) = s.insertTree("/tmp/nexis-tree-b")
    s.retain(ix, idB)

    discard s.collect(ix, idB)
    check not s.hasManifest(idB)
    check not s.hasObject(sha256("only in b\n"))
    # Shared content is still held by A.
    check s.hasObject(sha256("docs\n"))
    check ix.get(sha256("docs\n")).refs == 1
    check s.hasManifest(idA)

  test "collection cost is proportional to what is retired, not to the store":
    # Ten artifacts retained; retiring one must touch only its unique object.
    var ids: seq[Digest]
    for i in 0 .. 9:
      let dir = "/tmp/nexis-many-" & $i
      buildTree(dir)
      writeFile(dir / "share" / "unique", "content " & $i & "\n")
      let (id, _) = s.insertTree(dir)
      s.retain(ix, id)
      ids.add id
    let before = ix.objectCount
    let (removed, _) = s.collect(ix, ids[3])
    check removed == 2          # the unique object plus the manifest
    check ix.objectCount == before - 2

  test "a dry run reports without unlinking":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, id)
    let (removed, _) = s.collect(ix, id, dryRun = true)
    check removed > 0
    check s.hasObject(sha256("docs\n"))

  test "verify notices an object deleted behind the index's back":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, id)
    check s.verify(ix).len == 0
    removeFile(s.objectPath(sha256("docs\n")))
    let problems = s.verify(ix)
    check problems.len == 1
    check "missing from disk" in problems[0]

  test "verify notices an unindexed object":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, id)
    discard s.insertData("snuck in")
    check s.verify(ix).anyIt("unindexed" in it)

  test "roots survive losing the refcount log":
    # The log is a cache; the root set is not. If roots lived in the log,
    # losing it would delete a running system on the next collection.
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    ix.addRoot(rkGeneration, "1", id)
    removeFile(s.indexPath)
    var reopened = s.openStoreIndex()
    check reopened.hasRoot(rkGeneration, "1")

  test "rebuildIndex reconstructs refcounts from the roots":
    let (id, _) = s.insertTree("/tmp/nexis-tree-a")
    s.retain(ix, id)
    ix.addRoot(rkGeneration, "1", id)
    removeFile(s.indexPath)
    var rebuilt = s.rebuildIndex()
    check rebuilt.hasRoot(rkGeneration, "1")
    for e in s.readManifest(id).entries:
      if e.kind == ekFile:
        check rebuilt.get(e.digest).refs == 1
