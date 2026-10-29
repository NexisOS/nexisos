import std/[strutils, unittest]
import ../../../src/nexis/compose/merge
import ../../../src/lib/hashing

proc f(path: string, digest = "aaa", exe = false): TreeEntry =
  TreeEntry(path: path, kind: ekFile, digest: Digest(digest), executable: exe)

proc d(path: string): TreeEntry = TreeEntry(path: path, kind: ekDir)

proc l(path, target: string): TreeEntry =
  TreeEntry(path: path, kind: ekSymlink, target: target)

proc c(pkg: string, entries: varargs[TreeEntry]): Contribution =
  Contribution(package: pkg, output: "out", entries: @entries)

suite "merging":
  test "disjoint packages merge cleanly":
    let m = merge(@[c("a", d("usr"), f("usr/a")),
                    c("b", d("usr"), f("usr/b"))])
    check not m.hasCollisions()
    check m.files == 2
    check m.directories == 1

  test "a shared directory is not a collision":
    # Every package shipping /usr/bin/x needs /usr/bin to exist. Calling that a
    # conflict would make merging any two packages impossible.
    let m = merge(@[c("a", d("usr/bin"), f("usr/bin/a")),
                    c("b", d("usr/bin"), f("usr/bin/b"))])
    check not m.hasCollisions()

  test "two packages claiming one file collide":
    let m = merge(@[c("a", f("usr/bin/foo", "111")),
                    c("b", f("usr/bin/foo", "222"))])
    check m.hasCollisions()
    check m.collisions[0].path == "usr/bin/foo"
    check m.collisions[0].claimants.len == 2

  test "the message names both packages and the path":
    # "Path conflict detected" without saying which packages is the message
    # that sends someone grepping the whole store.
    let m = merge(@[c("nginx", f("usr/bin/foo", "111")),
                    c("apache", f("usr/bin/foo", "222"))])
    let text = m.report()
    check "usr/bin/foo" in text
    check "nginx" in text
    check "apache" in text

  test "byte-identical claims are still reported":
    # Nothing would break today, but nobody declared which package owns the
    # path — and "identical today" is not "identical after the next update".
    let m = merge(@[c("a", f("usr/share/x", "same")),
                    c("b", f("usr/share/x", "same"))])
    check m.hasCollisions()
    check m.collisions[0].identical
    check "identical content" in m.collisions[0].describe()

  test "differing content is not marked identical":
    let m = merge(@[c("a", f("usr/share/x", "one")),
                    c("b", f("usr/share/x", "two"))])
    check not m.collisions[0].identical

  test "a file where a directory is, is always a conflict":
    let m = merge(@[c("a", d("usr/lib")), c("b", f("usr/lib"))])
    check m.hasCollisions()

  test "symlinks to the same target are identical; to different ones are not":
    let same = merge(@[c("a", l("usr/lib/libx.so", "libx.so.1")),
                       c("b", l("usr/lib/libx.so", "libx.so.1"))])
    check same.collisions[0].identical
    let diff = merge(@[c("a", l("usr/lib/libx.so", "libx.so.1")),
                       c("b", l("usr/lib/libx.so", "libx.so.2"))])
    check not diff.collisions[0].identical

  test "the same file differing only in its executable bit collides":
    let m = merge(@[c("a", f("usr/bin/x", "same", exe = true)),
                    c("b", f("usr/bin/x", "same", exe = false))])
    check m.hasCollisions()
    check not m.collisions[0].identical

  test "three packages claiming one path name all three":
    let m = merge(@[c("a", f("x", "1")), c("b", f("x", "2")),
                    c("c", f("x", "3"))])
    check m.collisions[0].claimants.len == 3

suite "determinism":
  test "the merged tree does not depend on contribution order":
    # Two machines composing the same generation must produce the same bytes.
    let x = merge(@[c("a", f("usr/a")), c("b", f("usr/b")),
                    c("c", f("usr/c"))])
    let y = merge(@[c("c", f("usr/c")), c("a", f("usr/a")),
                    c("b", f("usr/b"))])
    check x.entries.len == y.entries.len
    for i in 0 ..< x.entries.len:
      check x.entries[i].entry.path == y.entries[i].entry.path
      check $x.entries[i].provider == $y.entries[i].provider

  test "entries come out sorted":
    let m = merge(@[c("a", f("usr/z"), f("usr/a"), f("usr/m"))])
    for i in 1 ..< m.entries.len:
      check m.entries[i - 1].entry.path <= m.entries[i].entry.path

  test "collisions come out sorted, so a report can be diffed":
    let m = merge(@[c("a", f("z", "1"), f("a", "1")),
                    c("b", f("z", "2"), f("a", "2"))])
    check m.collisions.len == 2
    check m.collisions[0].path == "a"

  test "which package wins a collision is stable, not iteration order":
    for _ in 0 .. 5:
      let m = merge(@[c("b", f("x", "2")), c("a", f("x", "1"))])
      check m.entries[0].provider.package == "a"

suite "ownership":
  test "every path reports the package that provided it":
    # This is what `nexis owns` answers when something on a system is behaving
    # oddly and the user needs to know what put it there.
    let m = merge(@[c("nginx", f("usr/bin/nginx")),
                    c("openssl", f("usr/lib/libssl.so"))])
    check m.ownerOf("usr/bin/nginx") == "nginx"
    check m.ownerOf("usr/lib/libssl.so") == "openssl"
    check m.ownerOf("usr/bin/nothing") == ""

  test "a non-default output is named in the provenance":
    var contrib = c("openssl", f("usr/include/ssl.h"))
    contrib.output = "dev"
    let m = merge(@[contrib])
    check m.ownerOf("usr/include/ssl.h") == "openssl:dev"

  test "everything a package contributed can be listed":
    let m = merge(@[c("a", f("x"), f("y")), c("b", f("z"))])
    check m.pathsFrom("a") == @["x", "y"]
    check m.pathsFrom("b") == @["z"]

suite "reporting":
  test "a clean merge reports its counts":
    let m = merge(@[c("a", d("usr"), f("usr/x"), l("usr/y", "x"))])
    let text = m.report()
    check "1 files" in text
    check "1 directories" in text
    check "1 symlinks" in text

  test "a collision report says how to resolve it":
    let m = merge(@[c("a", f("x", "1")), c("b", f("x", "2"))])
    let text = m.report()
    check "exactly one owner" in text
    check "slot" in text

  test "an empty merge is valid and empty":
    let m = merge(@[])
    check not m.hasCollisions()
    check m.total() == 0
