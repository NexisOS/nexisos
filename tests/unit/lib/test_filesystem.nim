import std/[algorithm, os, sequtils, strutils, unittest]
import ../../../src/lib/[filesystem, errors]

const Root = "/tmp/nexis-fs-tests"

proc fresh(sub: string): string =
  result = Root / sub
  removeDir(result)
  createDir(result)

suite "atomic writes":
  test "content arrives under the final name":
    let d = fresh("atomic")
    writeAtomic(d / "f.txt", "hello")
    check readFile(d / "f.txt") == "hello"

  test "parent directories are created":
    let d = fresh("mkparent")
    writeAtomic(d / "a" / "b" / "c.txt", "deep")
    check readFile(d / "a" / "b" / "c.txt") == "deep"

  test "no temp file survives a successful write":
    # A stray temp file is tolerable after a crash; after a success it means
    # the rename did not happen and something else is going on.
    let d = fresh("notmp")
    writeAtomic(d / "f.txt", "x")
    var count = 0
    for kind, path in walkDir(d): inc count
    check count == 1

  test "overwriting replaces rather than appending":
    let d = fresh("overwrite")
    writeAtomic(d / "f.txt", "first")
    writeAtomic(d / "f.txt", "second")
    check readFile(d / "f.txt") == "second"

  test "permissions are applied when asked for":
    let d = fresh("perms")
    writeAtomic(d / "run", "#!/bin/sh", {fpUserRead, fpUserWrite, fpUserExec})
    check fpUserExec in getFilePermissions(d / "run")

  test "an unwritable destination raises rather than failing silently":
    var raised = false
    try:
      writeAtomic("/proc/nexis-cannot-write-here/f.txt", "x")
    except NexisError as e:
      raised = true
      check e.kind == ekIo
    check raised

suite "append-only log":
  test "lines accumulate in order":
    let d = fresh("log")
    appendSync(d / "log", "one")
    appendSync(d / "log", "two")
    check readFile(d / "log") == "one\ntwo\n"

  test "a line that already ends in a newline is not doubled":
    let d = fresh("log2")
    appendSync(d / "log", "one\n")
    check readFile(d / "log") == "one\n"

suite "walking a tree":
  proc sample(): string =
    result = fresh("walk")
    createDir(result / "dir" / "sub")
    writeFile(result / "b.txt", "b")
    writeFile(result / "a.txt", "a")
    writeFile(result / "dir" / "run", "#!/bin/sh")
    setFilePermissions(result / "dir" / "run",
                       {fpUserRead, fpUserWrite, fpUserExec})
    createSymlink("a.txt", result / "link")

  test "paths are relative to the root and slash-separated":
    for e in sample().walkTree():
      check not e.path.startsWith("/")
      check not e.path.startsWith(".")

  test "the order is sorted, not directory order":
    # A manifest whose order depends on readdir order is not reproducible:
    # two machines with the same files would compute different digests.
    let paths = sample().walkTree().mapIt(it.path)
    check paths == paths.sorted()

  test "the same tree walks identically twice":
    check sample().walkTree() == sample().walkTree()

  test "kinds are distinguished":
    var kinds: seq[EntryKind]
    for e in sample().walkTree(): kinds.add e.kind
    check ekFile in kinds
    check ekDir in kinds
    check ekSymlink in kinds

  test "the executable bit is recorded":
    for e in sample().walkTree():
      if e.path == "dir/run": check e.executable
      if e.path == "a.txt": check not e.executable

  test "symlinks are recorded by target, never followed":
    # Following them would let a build output smuggle in host files, and would
    # loop on a cycle.
    let d = fresh("symloop")
    createSymlink(d, d / "self")
    let entries = d.walkTree()
    check entries.len == 1
    check entries[0].kind == ekSymlink

  test "a missing root raises rather than returning nothing":
    var raised = false
    try: discard walkTree(Root / "does-not-exist")
    except NexisError: raised = true
    check raised

suite "copying":
  test "structure, symlinks and the executable bit survive":
    let src = fresh("copysrc")
    createDir(src / "d")
    writeFile(src / "d" / "run", "x")
    setFilePermissions(src / "d" / "run",
                       {fpUserRead, fpUserWrite, fpUserExec})
    createSymlink("run", src / "d" / "alias")
    let dst = Root / "copydst"
    removeDir(dst)
    copyTree(src, dst)
    check walkTree(src).len == walkTree(dst).len
    check fpUserExec in getFilePermissions(dst / "d" / "run")
    check symlinkExists(dst / "d" / "alias")

suite "removal":
  test "removing something absent is not an error":
    # Cleanup runs after failures, where the thing being cleaned up may never
    # have been created.
    removeTree(Root / "never-existed")

  test "a directory and its contents go":
    let d = fresh("rm")
    writeFile(d / "f", "x")
    removeTree(d)
    check not dirExists(d)

  test "a dangling symlink is removed, not chased":
    let d = fresh("rmlink")
    createSymlink(d / "missing", d / "dangling")
    removeTree(d / "dangling")
    check not symlinkExists(d / "dangling")

suite "space and staging":
  test "free space on a real filesystem is positive":
    check freeBytes("/tmp") > 0

  test "an unknown path reports -1 rather than zero":
    # Zero would read as "full" and refuse every build.
    check freeBytes("/no/such/path/at/all") == -1

  test "a plausible requirement passes and an absurd one raises":
    requireSpace("/tmp", 1024)
    var raised = false
    try: requireSpace("/tmp", high(int64) div 2)
    except NexisError: raised = true
    check raised

  test "staging directories are unique and real":
    let parent = fresh("staging")
    let a = makeStagingDir(parent, "build")
    let b = makeStagingDir(parent, "build")
    check a != b
    check dirExists(a) and dirExists(b)

  test "same-filesystem detection":
    # The store stages inside itself so a rename is never a cross-device copy.
    # This exists so that can be asserted rather than assumed.
    check isSameFilesystem("/tmp", "/tmp")
    check not isSameFilesystem("/tmp", "/proc")
