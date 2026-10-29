import std/[strutils, unittest]
import ../../../src/nexis/compose/[generation, merge]
import ../../../src/lib/hashing

proc gen(id: int, pkgs: seq[PackageRef] = @[]): Generation =
  result = Generation(id: id, configDigest: "cfg", imageDigest: "img",
                      policyDigest: "pol", bootDigest: "boot",
                      kernel: "6.12", initramfs: "init", packages: pkgs,
                      created: 1000)
  result.seal = computeSeal(result)

proc p(name, version, buildId: string): PackageRef =
  newPackageRef(name, version, buildId, "art-" & buildId)

suite "sealing":
  test "a sealed generation verifies":
    check gen(1).verifySeal()

  test "an unsealed generation does not":
    var g = gen(1)
    g.seal = ""
    check not g.verifySeal()

  test "editing any sealed field invalidates the seal":
    # The seal exists so nobody can change what a generation claims to be
    # without it being obvious.
    for mutate in [proc (g: var Generation) = g.imageDigest = "tampered",
                   proc (g: var Generation) = g.policyDigest = "tampered",
                   proc (g: var Generation) = g.bootDigest = "tampered",
                   proc (g: var Generation) = g.configDigest = "tampered",
                   proc (g: var Generation) = g.kernel = "tampered",
                   proc (g: var Generation) = g.id = 99]:
      var g = gen(1)
      mutate(g)
      check not g.verifySeal()

  test "the seal covers the policy, so a rollback cannot mismatch it":
    # This is the coupling the whole design rests on: a generation carries its
    # filesystem, services, policy and boot entry together.
    var a = gen(1)
    var b = gen(1)
    b.policyDigest = "different"
    b.seal = computeSeal(b)
    check a.seal != b.seal

  test "the label is not sealed, so renaming does not invalidate":
    # A label is a human convenience with no effect on what boots.
    var g = gen(1)
    let before = g.seal
    g.label = "before the kernel upgrade"
    check computeSeal(g) == before

  test "package order does not change the seal":
    # The same packages are the same generation, whatever order they composed
    # in.
    let a = gen(1, @[p("a", "1", "ida"), p("b", "2", "idb")])
    let b = gen(1, @[p("b", "2", "idb"), p("a", "1", "ida")])
    check a.seal == b.seal

  test "a different package set changes the seal":
    let a = gen(1, @[p("a", "1", "ida")])
    let b = gen(1, @[p("a", "1", "idb")])
    check a.seal != b.seal

  test "sealing is deterministic across runs":
    for _ in 0 .. 5:
      check gen(1, @[p("a", "1", "x")]).seal == gen(1, @[p("a", "1", "x")]).seal

suite "building from a merged tree":
  proc contrib(pkg, path: string, digest: string): Contribution =
    Contribution(package: pkg, output: "out",
                 entries: @[TreeEntry(path: path, kind: ekFile,
                                      digest: Digest(digest))])

  test "a clean tree builds a sealed generation":
    let m = merge(@[contrib("a", "usr/bin/a", "1"),
                    contrib("b", "usr/bin/b", "2")])
    let g = generationFrom(1, m, @[p("a", "1", "ida")], "cfg", "img", "pol",
                           "boot", now = 1000)
    check g.verifySeal()

  test "a tree with collisions is refused, not sealed":
    # Sealing a contradiction would make it permanent and authenticated.
    let m = merge(@[contrib("a", "usr/bin/x", "1"),
                    contrib("b", "usr/bin/x", "2")])
    expect ValueError:
      discard generationFrom(1, m, @[], "cfg", "img", "pol", "boot")

suite "verification against a record":
  test "an identical pair reports nothing":
    check verify(gen(1), gen(1)).len == 0

  test "every difference is reported, not just the first":
    # A boot failing validation should say everything that is wrong: the
    # machine may be about to become unbootable and the user may get one look.
    var a = gen(1)
    var b = gen(1)
    b.imageDigest = "x"
    b.policyDigest = "y"
    b.kernel = "z"
    check verify(a, b).len == 3

  test "a problem names the field and both values":
    var b = gen(1)
    b.imageDigest = "expected-one"
    let problems = verify(gen(1), b)
    check problems[0].field == "image"
    check problems[0].expected == "expected-one"
    check problems[0].actual == "img"

suite "diffing generations":
  test "added, removed and changed are distinguished":
    let a = gen(1, @[p("keep", "1", "k1"), p("gone", "1", "g1"),
                     p("bump", "1", "b1")])
    let b = gen(2, @[p("keep", "1", "k1"), p("new", "1", "n1"),
                     p("bump", "2", "b2")])
    let changes = diff(a, b)
    check changes.len == 3
    var kinds: seq[ChangeKind]
    for c in changes: kinds.add c.kind
    check ckAdded in kinds
    check ckRemoved in kinds
    check ckChanged in kinds

  test "an unchanged package is not reported":
    let a = gen(1, @[p("same", "1", "id")])
    check diff(a, gen(2, @[p("same", "1", "id")])).len == 0

  test "a rebuild at the same version is still a change":
    # Hiding it would make "nothing changed" a lie in exactly the case someone
    # is debugging.
    let a = gen(1, @[p("x", "1.0", "old")])
    let b = gen(2, @[p("x", "1.0", "new")])
    let changes = diff(a, b)
    check changes.len == 1
    check "rebuilt" in changes[0].describe()

  test "the diff is sorted, so it can be read and compared":
    let a = gen(1, @[p("z", "1", "z"), p("a", "1", "a")])
    let b = gen(2, @[])
    let changes = diff(a, b)
    check changes[0].name == "a"

  test "the rendering counts before it lists":
    # Before reverting, a user should see that the difference is one kernel and
    # two libraries rather than four hundred packages.
    let a = gen(1, @[p("x", "1", "1")])
    let b = gen(2, @[p("x", "2", "2"), p("y", "1", "y")])
    let text = renderDiff(diff(a, b))
    check "1 added" in text
    check "1 changed" in text

  test "no changes says so plainly":
    check "no package changes" in renderDiff(@[])

suite "summary":
  test "a summary states whether the seal verified":
    check "verified: yes" in gen(1).summary()
    var g = gen(1)
    g.seal = "bogus"
    check "verified: NO" in g.summary()
