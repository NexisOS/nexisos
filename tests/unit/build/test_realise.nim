import std/[os, strutils, tables, unittest]
import ../../../src/nexis/build/[realise, scheduler, sandbox]
import ../../../src/nexis/package/[types, resolve]
import ../../../src/nexis/store/store
import ../../../src/lib/paths

const Root = "/tmp/nexis-realise-tests"

proc pkg(name: string, deps: seq[string] = @[], id = ""): Resolved =
  var d = Definition(name: name, version: "1.0")
  for dep in deps:
    d.build.dependencies.add DepSpec(name: dep)
  result = Resolved(def: d, buildId: (if id.len > 0: id else: "id-" & name))
  for dep in deps:
    result.dependencies.add DepSpec(name: dep)

proc freshStore(sub: string): Store =
  let path = Root / sub
  removeDir(path)
  createDir(path)
  initStore(path)

proc opts(dir: string): RealiseOptions =
  result = defaultOptions()
  result.storeRoot = Root / dir
  result.stagingRoot = Root / dir & "-staging"
  result.dryRun = true

suite "planning":
  test "dependencies are ordered before their dependants":
    var s = freshStore("order")
    let p = plan(@[pkg("app", @["lib"]), pkg("lib")], s, opts("order"))
    check p.diagnostics.len == 0
    check p.toBuild.find("id-lib") < p.toBuild.find("id-app")

  test "a package with no buildId is a diagnostic, not a silent skip":
    # It means the package was never resolved against its inputs, and building
    # it would produce an artifact nothing could refer to.
    var s = freshStore("noid")
    let d = Definition(name: "x", version: "1")
    let q = plan(@[Resolved(def: d)], s, opts("noid"))
    check q.diagnostics.len == 1
    check "buildId" in q.diagnostics[0]
    check q.toBuild.len == 0

  test "the same buildId twice builds once":
    # This is why a diamond dependency does not build its shared base twice.
    var s = freshStore("dedup")
    let p = plan(@[pkg("a", @[], "same"), pkg("b", @[], "same")], s,
                 opts("dedup"))
    check p.resolved.len == 1
    check p.toBuild.len == 1

  test "a cycle is reported as its path, and nothing is planned":
    var s = freshStore("cycle")
    let p = plan(@[pkg("a", @["b"]), pkg("b", @["a"])], s, opts("cycle"))
    check p.diagnostics.len == 1
    check "cycle" in p.diagnostics[0]
    check p.toBuild.len == 0

  test "the plan is identical across runs over the same set":
    # A dry run that predicts a different order than the real run predicts
    # nothing. Determinism here is what makes the two agree.
    var s = freshStore("stable")
    let a = plan(@[pkg("c"), pkg("a", @["b"]), pkg("b")], s, opts("stable"))
    for _ in 0 .. 4:
      let b = plan(@[pkg("c"), pkg("a", @["b"]), pkg("b")], s, opts("stable"))
      check b.toBuild == a.toBuild

  test "insertion order does not change the plan":
    var s = freshStore("insert")
    let a = plan(@[pkg("a", @["b"]), pkg("b"), pkg("c")], s, opts("insert"))
    let b = plan(@[pkg("c"), pkg("b"), pkg("a", @["b"])], s, opts("insert"))
    check a.toBuild == b.toBuild

  test "a dependency outside the set is left to the resolver":
    # If the resolver was wrong the build fails on a missing input, rather
    # than silently linking something else.
    var s = freshStore("external")
    let p = plan(@[pkg("app", @["not-in-this-set"])], s, opts("external"))
    check p.diagnostics.len == 0
    check p.toBuild == @["id-app"]

  test "an empty set plans nothing and is not an error":
    var s = freshStore("empty")
    let p = plan(@[], s, opts("empty"))
    check p.diagnostics.len == 0
    check p.toBuild.len == 0

suite "weight":
  test "more dependencies means more weight, as a scheduling hint":
    check weightOf(pkg("a", @["x", "y"])) > weightOf(pkg("b"))

  test "weight is never zero, so every node is dispatchable":
    check weightOf(pkg("bare")) >= 1

suite "rendering a plan":
  test "the counts are stated before the list":
    var s = freshStore("render")
    let p = plan(@[pkg("app", @["lib"]), pkg("lib")], s, opts("render"))
    let text = p.renderPlan()
    check "2 to build" in text
    check "build order:" in text
    check "lib" in text

  test "nothing to do says so rather than printing an empty list":
    var s = freshStore("nothing")
    check "nothing to do" in plan(@[], s, opts("nothing")).renderPlan()

  test "diagnostics replace the plan rather than accompanying it":
    var s = freshStore("diag")
    let p = plan(@[pkg("a", @["b"]), pkg("b", @["a"])], s, opts("diag"))
    let text = p.renderPlan()
    check text.startsWith("error:")
    check "build order" notin text

suite "realising, dry":
  test "a dry run walks the whole graph and builds everything":
    let o = opts("dry")
    let r = realise(@[pkg("app", @["lib"]), pkg("lib")], o)
    check r.report.failed.len == 0
    check r.report.built.len == 2

  test "a dry run produces a log for every package":
    # The identical sequence with an executor that runs nothing; if the log is
    # empty the dry run took a different path and is predicting nothing.
    let r = realise(@[pkg("solo")], opts("drylog"))
    check r.logs.len == 1
    for _, log in r.logs:
      check log.len > 0

  test "the log records the sandbox the build would have used":
    let r = realise(@[pkg("solo")], opts("drysandbox"))
    for _, log in r.logs:
      check "namespaces:" in log
      check "SOURCE_DATE_EPOCH" in log

  test "a plan error aborts before anything is dispatched":
    let r = realise(@[pkg("a", @["b"]), pkg("b", @["a"])], opts("dryabort"))
    check r.report.aborted
    check r.report.built.len == 0
    check r.failures.len == 0        ## nothing ran, so nothing failed

  test "a dry run writes nothing into the store":
    let o = opts("drystore")
    discard realise(@[pkg("app")], o)
    var count = 0
    if dirExists(o.storeRoot / "objects"):
      for kind, path in walkDir(o.storeRoot / "objects"): inc count
    check count == 0

suite "the sandbox a build would enter":
  test "only declared dependencies are bind-mounted":
    # A build needing something undeclared must fail on a missing header
    # rather than succeed against the host's copy and produce an artifact
    # nobody can rebuild.
    var s = freshStore("inputs")
    var artifacts = {"id-lib": "deadbeef"}.toTable
    var byName = {"lib": "id-lib", "other": "id-other"}.toTable
    let paths = inputPaths(s, pkg("app", @["lib"]), artifacts, byName)
    check paths.len == 1
    check "deadbeef" in paths[0]

  test "a dependency with no artifact yet contributes no path":
    var s = freshStore("noart")
    let paths = inputPaths(s, pkg("app", @["lib"]),
                           initTable[string, string](),
                           {"lib": "id-lib"}.toTable)
    check paths.len == 0

  test "input paths are sorted, so the sandbox spec is reproducible":
    var s = freshStore("sortinputs")
    let artifacts = {"id-a": "aaa", "id-b": "bbb", "id-c": "ccc"}.toTable
    let byName = {"a": "id-a", "b": "id-b", "c": "id-c"}.toTable
    let paths = inputPaths(s, pkg("app", @["c", "a", "b"]), artifacts, byName)
    check paths.len == 3
    for i in 1 ..< paths.len:
      check paths[i - 1] <= paths[i]
