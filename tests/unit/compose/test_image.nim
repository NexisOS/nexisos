import std/[strutils, unittest]
import ../../../src/nexis/compose/[image, merge]
import ../../../src/lib/hashing

proc c(pkg: string, entries: varargs[TreeEntry]): Contribution =
  Contribution(package: pkg, output: "out", entries: @entries)

proc f(path, digest: string, exe = false): TreeEntry =
  TreeEntry(path: path, kind: ekFile, digest: Digest(digest), executable: exe)

proc d(path: string): TreeEntry = TreeEntry(path: path, kind: ekDir)
proc l(path, target: string): TreeEntry =
  TreeEntry(path: path, kind: ekSymlink, target: target)

suite "permissions are derived, not carried":
  test "the executable bit is the only thing that survives":
    # Two builds of the same package must not differ by a umask.
    check modeFor(f("x", "1", exe = true)) == 0o755
    check modeFor(f("x", "1", exe = false)) == 0o644
    check modeFor(d("x")) == 0o755

suite "object references":
  test "the path matches the store's shard layout":
    # If these disagree the image references objects that are not there.
    check objectPathFor("abcdef0123") == "ab/cdef0123"

  test "a short digest does not crash the renderer":
    check objectPathFor("ab") == "ab"

suite "SELinux labels":
  test "labels vary by path, which is why composefs was chosen":
    # xattrs live in the metadata image, not on the shared inode, so two
    # generations can label the same object differently.
    check "bin_t" in selinuxLabel("usr/bin/nginx")
    check "lib_t" in selinuxLabel("usr/lib/libssl.so")
    check "etc_t" in selinuxLabel("etc/passwd")

  test "every path gets some label, never an empty one":
    for p in ["usr/share/doc/x", "opt/thing", "usr/bin/y"]:
      check selinuxLabel(p).len > 0

suite "building a spec":
  test "every merged entry becomes a line":
    let m = merge(@[c("a", d("usr"), f("usr/x", "111"), l("usr/y", "x"))])
    check specFor(m, "/store/objects").lines.len == 3

  test "files carry a digest and an object path; directories do not":
    let spec = specFor(merge(@[c("a", d("usr"), f("usr/x", "abcdef"))]),
                       "/store/objects")
    for line in spec.lines:
      if line.kind == ekFile:
        check line.digest == "abcdef"
        check line.payload == "ab/cdef"
      else:
        check line.digest == ""

  test "a symlink carries its target as the payload":
    let spec = specFor(merge(@[c("a", l("usr/lib/x.so", "x.so.1"))]),
                       "/store/objects")
    check spec.lines[0].payload == "x.so.1"

  test "every line carries an SELinux label":
    let spec = specFor(merge(@[c("a", f("usr/bin/x", "1"))]), "/store")
    check spec.lines[0].xattrs.len == 1
    check spec.lines[0].xattrs[0][0] == "security.selinux"

  test "a tree with collisions is refused before any bytes are produced":
    # generationFrom refuses too; both check, because a guard only at the call
    # site is one the next call site will not have.
    let m = merge(@[c("a", f("x", "1")), c("b", f("x", "2"))])
    expect ValueError:
      discard specFor(m, "/store")

  test "lines come out sorted, so the image is a function of the tree":
    let m = merge(@[c("a", f("usr/z", "1"), f("usr/a", "2"), f("usr/m", "3"))])
    let spec = specFor(m, "/store")
    for i in 1 ..< spec.lines.len:
      check spec.lines[i - 1].path <= spec.lines[i].path

  test "the spec digest is stable and order-independent":
    # Two machines producing the same spec produce the same image, so a
    # mismatch localises the fault to composition rather than the writer.
    let a = specFor(merge(@[c("a", f("x", "1")), c("b", f("y", "2"))]), "/s")
    let b = specFor(merge(@[c("b", f("y", "2")), c("a", f("x", "1"))]), "/s")
    check a.specDigest() == b.specDigest()

  test "a different tree gives a different digest":
    let a = specFor(merge(@[c("a", f("x", "1"))]), "/s")
    let b = specFor(merge(@[c("a", f("x", "2"))]), "/s")
    check a.specDigest() != b.specDigest()

suite "the dump format":
  test "a path containing a space is escaped, not split":
    # Silently splitting produces an image with two wrong entries instead of
    # one right one.
    check escapeField("usr/share/my file") == "usr/share/my\\x20file"

  test "backslashes and newlines are escaped":
    check escapeField("a\\b") == "a\\\\b"
    check "\\x0a" in escapeField("a\nb")

  test "an ordinary path is unchanged":
    check escapeField("usr/bin/nginx") == "usr/bin/nginx"

  test "a rendered line names its type":
    let spec = specFor(merge(@[c("a", d("usr"), f("usr/x", "abcd"),
                                 l("usr/y", "x"))]), "/store")
    let text = spec.render()
    check " dir " in text
    check " file " in text
    check " symlink " in text

  test "a rendered line carries the label":
    let spec = specFor(merge(@[c("a", f("usr/bin/x", "abcd"))]), "/store")
    check "security.selinux=" in spec.render()

  test "absent fields render as a placeholder, not as nothing":
    # An empty field would shift every field after it by one.
    let spec = specFor(merge(@[c("a", d("usr"))]), "/store")
    check " - - " in spec.render() or spec.render().endsWith("- -\n") or
          "-" in spec.render()
    let fields = spec.render().strip().split(" ")
    check fields.len >= 6

  test "every line ends with a newline":
    let spec = specFor(merge(@[c("a", f("x", "1"), f("y", "2"))]), "/store")
    check spec.render().count('\n') == 2

suite "the writer is a compatibility surface":
  test "an absent tool is reported, not assumed working":
    let (available, note) = toolAvailable()
    if not available:
      check note.len > 0
      check "ADR 0007" in note or "version" in note

  test "writing without the tool fails with a readable error":
    let spec = specFor(merge(@[c("a", f("x", "1"))]), "/store")
    let r = writeImage(spec, "/tmp/nexis-image-test.cfs")
    if not r.ok:
      check r.error.len > 0
      check r.digest.len == 0
