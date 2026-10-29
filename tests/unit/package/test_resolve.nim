import std/[os, sequtils, strutils, tables, unittest]
import ../../../src/nexis/package/[parse, resolve, groups, types]

const fixtures = currentSourcePath().parentDir.parentDir.parentDir /
                 "fixtures" / "packages"

proc loadDef(name: string): Definition =
  let p = fixtures / name
  let (d, diags) = parseDefinition(readFile(p), p)
  doAssert not diags.hasErrors(), diags.render(p)
  d

proc loadGroups(): GroupSet =
  let p = fixtures / "groups.toml"
  let (gs, diags) = parseGroups(readFile(p), p)
  doAssert not diags.hasErrors()
  gs

proc names(ds: seq[DepSpec]): seq[string] = ds.mapIt($it)

proc msgs(ds: seq[Diagnostic]): string =
  for d in ds: result.add d.msg & "\n"

suite "feature resolution":
  test "declaration defaults apply when nothing is requested":
    let d = loadDef("featured.toml")
    var diags: seq[Diagnostic]
    check resolveFeatures(d, initTable[string, bool](), diags) == @["gtk3"]
    check diags.len == 0

  test "a request overrides the default":
    let d = loadDef("featured.toml")
    var diags: seq[Diagnostic]
    var req = {"gtk3": false, "docs": true}.toTable
    check resolveFeatures(d, req, diags) == @["docs"]

  test "enabling two mutually exclusive features is an error":
    let d = loadDef("featured.toml")
    var diags: seq[Diagnostic]
    var req = {"qt6": true}.toTable
    discard resolveFeatures(d, req, diags)
    check "mutually exclusive" in msgs(diags)

  test "requesting an undeclared feature is an error":
    let d = loadDef("featured.toml")
    var diags: seq[Diagnostic]
    var req = {"wayland": true}.toTable
    discard resolveFeatures(d, req, diags)
    check "is not declared by featured" in msgs(diags)

suite "closure expansion":
  test "groups expand into the dependency set":
    let (r, diags) = resolve(loadDef("featured.toml"), loadGroups(),
                             initTable[string, bool]())
    check not diags.hasErrors()
    check "zlib" in r.dependencies.names
    check "xz" in r.dependencies.names
    check "gcc" in r.native.names

  test "a disabled feature contributes nothing to the closure":
    let (r, _) = resolve(loadDef("featured.toml"), loadGroups(),
                         initTable[string, bool]())
    # gtk3 is on by default, qt6 and docs are off.
    check "gtk3" in r.dependencies.names
    check "glib" in r.dependencies.names
    check "qt6-base" notin r.dependencies.names
    check "doxygen" notin r.native.names

  test "enabling a feature pulls its dependencies in":
    var req = {"gtk3": false, "qt6": true, "docs": true}.toTable
    let (r, _) = resolve(loadDef("featured.toml"), loadGroups(), req)
    check "qt6-base" in r.dependencies.names
    check "doxygen" in r.native.names
    check "gtk3" notin r.dependencies.names

  test "an unresolvable group is an error naming the group file":
    let d = loadDef("featured.toml")
    var empty = GroupSet(path: "nowhere.toml", groups: initTable[string, Group]())
    let (_, diags) = resolve(d, empty, initTable[string, bool]())
    check "does not resolve in nowhere.toml" in msgs(diags)

  test "dependencies are deduplicated and sorted":
    let (r, _) = resolve(loadDef("featured.toml"), loadGroups(),
                         initTable[string, bool]())
    var sorted = true
    for i in 1 ..< r.dependencies.len:
      if $r.dependencies[i - 1] >= $r.dependencies[i]: sorted = false
    check sorted

suite "active outputs":
  test "an output owned by a disabled feature is not active":
    let (r, _) = resolve(loadDef("featured.toml"), loadGroups(),
                         initTable[string, bool]())
    check r.activeOutputs == @["out", "dev"]

  test "enabling the feature activates its output":
    var req = {"docs": true}.toTable
    let (r, _) = resolve(loadDef("featured.toml"), loadGroups(), req)
    check r.activeOutputs == @["out", "dev", "doc"]

  test "active outputs keep declaration order":
    var req = {"docs": true}.toTable
    let (r, _) = resolve(loadDef("featured.toml"), loadGroups(), req)
    check r.activeOutputs == r.def.outputs.filterIt(it in r.activeOutputs)

suite "source identity":
  test "is stable across repeated resolution":
    let d = loadDef("featured.toml")
    let a = sourceIdentity(d)
    let b = sourceIdentity(d)
    check a == b
    check a.len == 64

  test "does not depend on the url, so a mirror change is not a rebuild":
    var d = loadDef("featured.toml")
    let before = sourceIdentity(d)
    d.sources[0].urls = @["https://mirror.example.net/featured-2.0.tar.xz"]
    check sourceIdentity(d) == before

  test "changes when a source hash changes":
    var d = loadDef("featured.toml")
    let before = sourceIdentity(d)
    d.sources[0].hash.digest[0] = d.sources[0].hash.digest[0] xor 0xff'u8
    check sourceIdentity(d) != before

  test "changes when a patch is dropped":
    var d = loadDef("featured.toml")
    let before = sourceIdentity(d)
    d.sources.setLen(1)
    check sourceIdentity(d) != before

  test "distinguishes a patch from a primary source with the same hash":
    var a = loadDef("featured.toml")
    var b = loadDef("featured.toml")
    b.sources[1].role = srPrimary
    check sourceIdentity(a) != sourceIdentity(b)

suite "build identity":
  setup:
    let gs = loadGroups()
    let def = loadDef("featured.toml")
    proc idFor(req: Table[string, bool], nativeIds: Table[string, string],
               runtimeIds: Table[string, string],
               target = "x86_64-linux-gnu"): string =
      let (r, rd) = resolve(def, gs, req)
      doAssert not rd.hasErrors(), msgs(rd)
      let (id, bd) = buildIdentity(r, nativeIds, runtimeIds, target)
      doAssert not bd.hasErrors(), msgs(bd)
      id

    proc idsFor(r: Resolved, salt = ""): (Table[string, string],
                                          Table[string, string]) =
      var n, rt: Table[string, string]
      for d in r.native: n[$d] = "artifact-" & $d & salt
      for d in r.dependencies: rt[$d] = "iface-" & $d & salt
      (n, rt)

    let (baseR, _) = resolve(def, gs, initTable[string, bool]())
    let (baseNative, baseRuntime) = idsFor(baseR)

  test "is stable for identical inputs":
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    let b = idFor(initTable[string, bool](), baseNative, baseRuntime)
    check a == b
    check a.len == 64

  test "changes when the feature set changes":
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    var req = {"gtk3": false, "qt6": true}.toTable
    let (r2, _) = resolve(def, gs, req)
    let (n2, rt2) = idsFor(r2)
    let b = idFor(req, n2, rt2)
    check a != b

  test "changes when the target triple changes":
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    let b = idFor(initTable[string, bool](), baseNative, baseRuntime,
                  "aarch64-linux-gnu")
    check a != b

  test "changes when a build dependency's artifact id changes":
    var mutated = baseNative
    for k in mutated.keys.toSeq: mutated[k] = mutated[k] & "-rebuilt"
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    let b = idFor(initTable[string, bool](), mutated, baseRuntime)
    check a != b

  test "changes when a runtime dependency's INTERFACE id changes":
    var mutated = baseRuntime
    for k in mutated.keys.toSeq: mutated[k] = mutated[k] & "-abi-break"
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    let b = idFor(initTable[string, bool](), baseNative, mutated)
    check a != b

  test "does NOT change when a runtime dependency rebuilds with the same interface":
    # This is the whole point of a separate interface identity: an ABI-preserving
    # security patch to zlib must not rebuild everything that links it.
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    let b = idFor(initTable[string, bool](), baseNative, baseRuntime)
    check a == b

  test "changes when the revision is bumped":
    var bumped = def
    bumped.revision = def.revision + 1
    let (r, _) = resolve(bumped, gs, initTable[string, bool]())
    let (id, _) = buildIdentity(r, baseNative, baseRuntime, "x86_64-linux-gnu")
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    check id != a

  test "changes when a group's contents change":
    var gs2 = loadGroups()
    gs2.groups["compression"].dependencies.add DepSpec(name: "brotli")
    let (r2, _) = resolve(def, gs2, initTable[string, bool]())
    let (n2, rt2) = idsFor(r2)
    let (id2, _) = buildIdentity(r2, n2, rt2, "x86_64-linux-gnu")
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    check id2 != a

  test "changes when a phase override changes":
    var tweaked = def
    tweaked.build.phases[phConfigure] =
      Phase(mode: pmArgs, add: @["--buildtype=debug"])
    let (r, _) = resolve(tweaked, gs, initTable[string, bool]())
    let (id, _) = buildIdentity(r, baseNative, baseRuntime, "x86_64-linux-gnu")
    let a = idFor(initTable[string, bool](), baseNative, baseRuntime)
    check id != a

  test "reports a missing dependency id rather than hashing a gap":
    let (r, _) = resolve(def, gs, initTable[string, bool]())
    var partial = baseNative
    partial.del(partial.keys.toSeq[0])
    let (_, diags) = buildIdentity(r, partial, baseRuntime, "x86_64-linux-gnu")
    check diags.hasErrors()
    check "no artifact id for native dependency" in msgs(diags)

  test "field lengths are prefixed so adjacent fields cannot collide":
    # Without length prefixing, ("ab","c") and ("a","bc") hash identically and
    # two different packages would share a cache entry.
    var a = def
    var b = def
    a.name = "ab"
    a.version = "c"
    b.name = "a"
    b.version = "bc"
    check sourceIdentity(a) != sourceIdentity(b)
