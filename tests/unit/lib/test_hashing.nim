import std/[os, strutils, times, unittest]
import ../../../src/lib/hashing

const tmp = "/tmp/nexis-hash-test"

proc reset() =
  removeDir(tmp)
  createDir(tmp)

suite "digests":
  test "sha256 is stable and well-formed":
    let a = sha256("hello")
    check a == sha256("hello")
    check a.isValid
    check a != sha256("hello ")

  test "an empty input still hashes":
    check sha256("").isValid

  test "a digest of the wrong shape is not valid":
    check not Digest("nope").isValid
    check not Digest("A".repeat(64)).isValid   # uppercase

suite "field hashing":
  test "length prefixing prevents adjacent-field collisions":
    # Without it, ("ab","c") and ("a","bc") hash identically, and for a build
    # identity that means two different packages sharing a cache entry.
    check hashFields("ab", "c") != hashFields("a", "bc")
    check hashFields("a", "") != hashFields("", "a")

  test "field order matters":
    check hashFields("x", "y") != hashFields("y", "x")

  test "a separator character in the input cannot forge a boundary":
    check hashFields("a:b") != hashFields("a", "b")

suite "file hashing":
  setup:
    reset()

  test "matches the in-memory hash of the same bytes":
    writeFile(tmp / "f", "contents")
    check hashFile(tmp / "f") == sha256("contents")

  test "handles a file larger than the read buffer":
    let big = "x".repeat(200_000)
    writeFile(tmp / "big", big)
    check hashFile(tmp / "big") == sha256(big)

  test "a missing file raises rather than returning a digest":
    expect IOError:
      discard hashFile(tmp / "absent")

suite "tree hashing":
  setup:
    reset()
    createDir(tmp / "a" / "b")
    writeFile(tmp / "a" / "one", "1")
    writeFile(tmp / "a" / "b" / "two", "2")
    createSymlink("one", tmp / "a" / "link")

  test "is deterministic":
    check hashTree(tmp / "a") == hashTree(tmp / "a")

  test "ignores modification time":
    let before = hashTree(tmp / "a")
    setLastModificationTime(tmp / "a" / "one",
                            getLastModificationTime(tmp / "a" / "one") +
                            initDuration(hours = 100))
    check hashTree(tmp / "a") == before

  test "detects a content change":
    let before = hashTree(tmp / "a")
    writeFile(tmp / "a" / "one", "changed")
    check hashTree(tmp / "a") != before

  test "detects the executable bit":
    let before = hashTree(tmp / "a")
    setFilePermissions(tmp / "a" / "one", {fpUserRead, fpUserWrite, fpUserExec})
    check hashTree(tmp / "a") != before

  test "detects a retargeted symlink":
    let before = hashTree(tmp / "a")
    removeFile(tmp / "a" / "link")
    createSymlink("b/two", tmp / "a" / "link")
    check hashTree(tmp / "a") != before

  test "detects a renamed file even with identical content":
    let before = hashTree(tmp / "a")
    moveFile(tmp / "a" / "one", tmp / "a" / "uno")
    check hashTree(tmp / "a") != before

  test "two identical trees built separately hash the same":
    createDir(tmp / "c" / "b")
    writeFile(tmp / "c" / "one", "1")
    writeFile(tmp / "c" / "b" / "two", "2")
    createSymlink("one", tmp / "c" / "link")
    check hashTree(tmp / "a") == hashTree(tmp / "c")

  test "the manifest is sorted, so filesystem order cannot leak in":
    let entries = walkTree(tmp / "a")
    for i in 1 ..< entries.len:
      check entries[i - 1].path < entries[i].path
