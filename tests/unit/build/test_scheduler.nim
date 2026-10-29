import std/[strutils, tables, unittest]
import ../../../src/nexis/build/scheduler

proc chain(): Graph =
  ## a <- b <- c
  result = newGraph()
  result.add newNode("a", "libc")
  result.add newNode("b", "openssl", @["a"])
  result.add newNode("c", "curl", @["b"])
  discard result.prepare()

proc diamond(): Graph =
  ## base <- (left, right) <- top
  result = newGraph(maxParallel = 4)
  result.add newNode("base", "base")
  result.add newNode("left", "left", @["base"])
  result.add newNode("right", "right", @["base"])
  result.add newNode("top", "top", @["left", "right"])
  discard result.prepare()

proc alwaysBuilds(): BuildFn =
  proc (id, name: string): (Outcome, string) = (ocBuilt, "")

proc failsOn(target: string): BuildFn =
  proc (id, name: string): (Outcome, string) =
    if name == target: (ocFailed, "compiler exited 1") else: (ocBuilt, "")

suite "ordering":
  test "dependencies come before dependants":
    let r = chain().topoOrder()
    check r.cycle.len == 0
    check r.order == @["a", "b", "c"]

  test "the order is identical across runs":
    # A build order that varies between runs turns a race in a package's own
    # build system into a failure that appears and vanishes.
    let first = diamond().topoOrder().order
    for _ in 0 .. 5:
      check diamond().topoOrder().order == first

  test "a cycle is reported as its path, not just as a fact":
    var g = newGraph()
    g.add newNode("a", "a", @["b"])
    g.add newNode("b", "b", @["a"])
    let r = g.topoOrder()
    check r.cycle.len > 0
    check r.cycle[0] == r.cycle[^1]

  test "a dependency that is not in the graph is caught before anything runs":
    # Discovering this partway through a 200-package build wastes everything
    # already done.
    var g = newGraph()
    g.add newNode("a", "a", @["nowhere"])
    check "nowhere" in g.topoOrder().missing

  test "prepare refuses to set an order for a broken graph":
    var g = newGraph()
    g.add newNode("a", "a", @["b"])
    g.add newNode("b", "b", @["a"])
    discard g.prepare()
    check g.order.len == 0

  test "an empty graph is done, not stuck":
    var g = newGraph()
    discard g.prepare()
    check g.isDone()

suite "readiness":
  test "only leaves are ready at the start":
    let g = chain()
    check g.nodes["a"].state == nsReady
    check g.nodes["b"].state == nsPending

  test "completing a node releases its dependants":
    var g = chain()
    g.dispatch("a")
    g.complete("a", ocBuilt)
    check g.nodes["b"].state == nsReady
    check g.nodes["c"].state == nsPending

  test "a cached dependency satisfies just as a built one does":
    var g = chain()
    g.dispatch("a")
    g.complete("a", ocCached)
    check g.nodes["b"].state == nsReady

  test "a node with several dependencies waits for all of them":
    var g = diamond()
    g.dispatch("base"); g.complete("base", ocBuilt)
    g.dispatch("left"); g.complete("left", ocBuilt)
    check g.nodes["top"].state == nsPending
    g.dispatch("right"); g.complete("right", ocBuilt)
    check g.nodes["top"].state == nsReady

suite "parallelism":
  test "dispatch is capped":
    var g = diamond()
    g.dispatch("base"); g.complete("base", ocBuilt)
    g.maxParallel = 1
    let first = g.nextReady()
    g.dispatch(first)
    check g.nextReady() == ""      ## the slot is taken
    check not g.canDispatch()

  test "the heaviest ready node goes first":
    # A long build started last becomes the tail everything waits on.
    var g = newGraph(maxParallel = 1)
    g.add newNode("a", "quick", @[], weight = 1)
    g.add newNode("b", "llvm", @[], weight = 100)
    g.add newNode("c", "medium", @[], weight = 10)
    discard g.prepare()
    check g.nodes[g.nextReady()].name == "llvm"

  test "a single slot still drains the whole graph":
    var g = chain()
    g.maxParallel = 1
    let r = g.run(alwaysBuilds())
    check r.built.len == 3
    check g.isDone()

suite "failure containment":
  test "a failure cancels only what depends on it":
    # One broken package in a rebuild of two hundred should produce one
    # failure, not a wall of noise.
    var g = newGraph(maxParallel = 4)
    g.add newNode("bad", "bad")
    g.add newNode("dependant", "dependant", @["bad"])
    g.add newNode("unrelated", "unrelated")
    discard g.prepare()
    let r = g.run(failsOn("bad"))
    check r.failed.len == 1
    check r.cancelled.len == 1
    check r.built == @["unrelated"]

  test "cancellation is distinct from failure":
    # One real failure and forty cancellations reads very differently from
    # forty-one failures.
    var g = chain()
    let r = g.run(failsOn("libc"))
    check r.failed.len == 1
    check r.cancelled.len == 2
    check g.nodes["c"].state == nsCancelled

  test "a cancellation says which dependency caused it":
    var g = chain()
    discard g.run(failsOn("libc"))
    check "libc" in g.nodes["b"].reason

  test "the failure reason is carried through to the report":
    var g = chain()
    let r = g.run(failsOn("libc"))
    check r.failed[0][1] == "compiler exited 1"

  test "fail-fast stops early; the default does not":
    var fast = diamond()
    fast.failFast = true
    let a = fast.run(failsOn("base"))
    check a.aborted

    var slow = diamond()
    let b = slow.run(failsOn("left"))
    check not b.aborted
    check "right" in b.built      ## independent work still ran

  test "the graph is done even when everything failed":
    var g = chain()
    discard g.run(failsOn("libc"))
    check g.isDone()
    check g.anyFailed()

suite "progress":
  test "counts add up to the total at every point":
    var g = diamond()
    for _ in 0 .. 3:
      let id = g.nextReady()
      if id.len == 0: break
      g.dispatch(id)
      let p = g.progress()
      check p.built + p.cached + p.failed + p.cancelled + p.running +
            p.pending == p.total
      g.complete(id, ocBuilt)

  test "a fresh graph is at zero and a drained one at one":
    var g = diamond()
    check g.fraction() == 0.0
    discard g.run(alwaysBuilds())
    check g.fraction() == 1.0

  test "cancelled work counts as resolved, not as pending forever":
    # Otherwise a run that stopped early shows a progress bar that never fills.
    var g = chain()
    discard g.run(failsOn("libc"))
    check g.fraction() == 1.0

  test "cached nodes are counted separately from built ones":
    var g = chain()
    let r = g.run(proc (id, name: string): (Outcome, string) =
      if name == "libc": (ocCached, "") else: (ocBuilt, ""))
    check r.cached == @["libc"]
    check r.built.len == 2

suite "the summary":
  test "failures come first, because that is what the reader needs":
    var g = chain()
    let s = g.run(failsOn("libc")).summary()
    check s.find("failed") < s.find("built")

  test "a clean run says so without ambiguity":
    var g = chain()
    let s = g.run(alwaysBuilds()).summary()
    check "3 built" in s
    check "0 failed" in s

  test "not-attempted work is named, not just counted":
    var g = chain()
    let s = g.run(failsOn("libc")).summary()
    check "not attempted" in s
    check "openssl" in s
