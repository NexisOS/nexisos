## Draining the realisation graph.
##
## The scheduler decides *what to build next and how many at once*. It does not
## build anything itself — the executor is passed in — which is what makes the
## whole policy testable without a toolchain, and what lets `rebuild dry-run`
## walk the identical decision sequence with a no-op executor.
##
## Three properties matter more than throughput:
##
## **Determinism.** Ready nodes are dispatched in a stable order, so the same
## graph produces the same build sequence every run. A build order that varies
## between runs turns a race in a package's own build system into a failure
## that appears and vanishes, which is the single worst class of bug to inherit
## in a system whose selling point is reproducibility.
##
## **Failure containment.** A failed build cancels only what depends on it.
## Everything independent still runs, so one broken package in a rebuild of two
## hundred produces one failure and one hundred and ninety-nine artifacts —
## not a wall of noise where the real cause has to be found by inspection.
##
## **Nothing half-committed.** A build that fails must leave no live reference
## in the store. The scheduler reports outcomes; committing them is the
## caller's job, and the split exists so that rule has one place to live.

import std/[algorithm, sets, strutils, tables]

type
  NodeState* = enum
    nsPending      ## waiting on dependencies
    nsReady        ## dependencies satisfied, not yet started
    nsBuilding
    nsBuilt
    nsCached       ## already in the store; never ran
    nsFailed
    nsCancelled    ## a dependency failed, so this can never run

  Node* = object
    id*: string                 ## buildId
    name*: string               ## human-readable, for logs
    deps*: seq[string]          ## buildIds this needs
    weight*: int                ## relative cost; scheduling hint only
    state*: NodeState
    reason*: string

  Outcome* = enum
    ocBuilt
    ocCached
    ocFailed

  Graph* = object
    nodes*: Table[string, Node]
    order*: seq[string]         ## deterministic dispatch order
    running*: HashSet[string]
    maxParallel*: int
    failFast*: bool

  Progress* = object
    total*, built*, cached*, failed*, cancelled*, running*, pending*: int

func newNode*(id, name: string, deps: seq[string] = @[], weight = 1): Node =
  Node(id: id, name: name, deps: deps, weight: weight, state: nsPending)

func newGraph*(maxParallel = 1, failFast = false): Graph =
  Graph(nodes: initTable[string, Node](), running: initHashSet[string](),
        maxParallel: max(maxParallel, 1), failFast: failFast)

proc add*(g: var Graph, n: Node) =
  g.nodes[n.id] = n

# --- Ordering ----------------------------------------------------------------

type OrderResult* = object
  order*: seq[string]
  cycle*: seq[string]
  missing*: seq[string]

func topoOrder*(g: Graph): OrderResult =
  ## Deterministic topological order. Ties break by name, then by id — never
  ## by hash-table iteration order, which varies between runs and between Nim
  ## versions.
  var ids: seq[string]
  for id in g.nodes.keys: ids.add id
  ids.sort(proc (a, b: string): int =
    let c = cmp(g.nodes[a].name, g.nodes[b].name)
    if c != 0: c else: cmp(a, b))

  var missing: seq[string]
  for id in ids:
    for d in g.nodes[id].deps:
      if d notin g.nodes and d notin missing: missing.add d
  missing.sort()
  result.missing = missing

  var state = initTable[string, int]()
  var order: seq[string]
  var cycle: seq[string]
  var stack: seq[string]

  proc visit(id: string) =
    if cycle.len > 0: return
    let st = state.getOrDefault(id, 0)
    if st == 2: return
    if st == 1:
      let at = stack.find(id)
      cycle = stack[(if at >= 0: at else: 0) .. ^1] & id
      return
    state[id] = 1
    stack.add id
    var deps = g.nodes[id].deps
    deps.sort()
    for d in deps:
      if d in g.nodes: visit(d)
    discard stack.pop()
    state[id] = 2
    order.add id

  for id in ids: visit(id)
  if cycle.len > 0: result.cycle = cycle
  else: result.order = order

proc prepare*(g: var Graph): OrderResult =
  ## Compute the order and mark the initially-ready nodes. Must succeed before
  ## anything runs: a graph with a cycle or a missing dependency is a
  ## resolution bug, and discovering it partway through a two-hundred-package
  ## build wastes everything already done.
  result = g.topoOrder()
  if result.cycle.len > 0 or result.missing.len > 0: return
  g.order = result.order
  for id in g.order:
    if g.nodes[id].deps.len == 0:
      g.nodes[id].state = nsReady

# --- Readiness ---------------------------------------------------------------

func depsSatisfied*(g: Graph, id: string): bool =
  for d in g.nodes[id].deps:
    if d notin g.nodes: return false
    if g.nodes[d].state notin {nsBuilt, nsCached}: return false
  true

func failedDeps*(g: Graph, id: string): seq[string] =
  for d in g.nodes[id].deps:
    if d in g.nodes and g.nodes[d].state in {nsFailed, nsCancelled}:
      result.add g.nodes[d].name

proc refreshReady*(g: var Graph) =
  for id in g.order:
    if g.nodes[id].state != nsPending: continue
    let failed = g.failedDeps(id)
    if failed.len > 0:
      # Cancelled, not failed. The distinction is the whole point of the
      # summary at the end: one real failure and forty cancellations reads
      # very differently from forty-one failures.
      g.nodes[id].state = nsCancelled
      g.nodes[id].reason = "depends on " & failed.join(", ")
    elif g.depsSatisfied(id):
      g.nodes[id].state = nsReady

func canDispatch*(g: Graph): bool =
  g.running.len < g.maxParallel

proc nextReady*(g: var Graph): string =
  ## The next node to build, or "" if none can start right now.
  ##
  ## Heaviest-first among ready nodes. A long build started last becomes the
  ## tail everything waits on, and the whole graph finishes no sooner than its
  ## longest remaining chain — so the expensive work goes first while there is
  ## still other work to overlap it with.
  if not g.canDispatch(): return ""
  var best = ""
  var bestWeight = -1
  for id in g.order:
    if g.nodes[id].state != nsReady: continue
    if g.nodes[id].weight > bestWeight:
      bestWeight = g.nodes[id].weight
      best = id
  best

proc dispatch*(g: var Graph, id: string) =
  g.nodes[id].state = nsBuilding
  g.running.incl id

proc complete*(g: var Graph, id: string, outcome: Outcome, reason = "") =
  g.running.excl id
  case outcome
  of ocBuilt: g.nodes[id].state = nsBuilt
  of ocCached: g.nodes[id].state = nsCached
  of ocFailed:
    g.nodes[id].state = nsFailed
    g.nodes[id].reason = reason
  g.refreshReady()

func isDone*(g: Graph): bool =
  if g.running.len > 0: return false
  for id in g.order:
    if g.nodes[id].state in {nsPending, nsReady}: return false
  true

func anyFailed*(g: Graph): bool =
  for id in g.order:
    if g.nodes[id].state == nsFailed: return true
  false

func progress*(g: Graph): Progress =
  result.total = g.order.len
  for id in g.order:
    case g.nodes[id].state
    of nsBuilt: inc result.built
    of nsCached: inc result.cached
    of nsFailed: inc result.failed
    of nsCancelled: inc result.cancelled
    of nsBuilding: inc result.running
    of nsPending, nsReady: inc result.pending

func fraction*(g: Graph): float =
  if g.order.len == 0: return 1.0
  let p = g.progress()
  float(p.built + p.cached + p.failed + p.cancelled) / float(g.order.len)

# --- Driving -----------------------------------------------------------------

type
  BuildFn* = proc (id, name: string): (Outcome, string) {.closure.}

  RunReport* = object
    built*, cached*: seq[string]
    failed*: seq[(string, string)]      ## name, reason
    cancelled*: seq[(string, string)]
    aborted*: bool                      ## stopped early under failFast

proc run*(g: var Graph, build: BuildFn): RunReport =
  ## Drain the graph, one dispatch at a time.
  ##
  ## Sequential here even when `maxParallel` is higher: the readiness and
  ## cancellation policy is what this module owns, and it is identical either
  ## way. Actual concurrency belongs to the caller, which owns the process
  ## handles — keeping it out means the policy stays a pure decision sequence
  ## that a test can step through.
  while not g.isDone():
    let id = g.nextReady()
    if id.len == 0: break

    let name = g.nodes[id].name
    g.dispatch(id)
    let (outcome, reason) = build(id, name)
    g.complete(id, outcome, reason)

    if outcome == ocFailed and g.failFast:
      # Off by default. A rebuild is usually an overnight or CI operation, and
      # learning about all six broken packages in one run beats learning about
      # them one run at a time.
      result.aborted = true
      break

  for id in g.order:
    let n = g.nodes[id]
    case n.state
    of nsBuilt: result.built.add n.name
    of nsCached: result.cached.add n.name
    of nsFailed: result.failed.add (n.name, n.reason)
    of nsCancelled: result.cancelled.add (n.name, n.reason)
    else: discard

func summary*(r: RunReport): string =
  ## What the user reads at the end. Failures first: that is what they need,
  ## and a summary that leads with successes buries it.
  if r.failed.len > 0:
    result.add $r.failed.len & " failed:\n"
    for (name, reason) in r.failed:
      result.add "  " & name & ": " & reason & "\n"
  if r.cancelled.len > 0:
    result.add $r.cancelled.len & " not attempted:\n"
    for (name, reason) in r.cancelled:
      result.add "  " & name & " (" & reason & ")\n"
  if r.aborted:
    result.add "stopped at the first failure (--fail-fast)\n"
  result.add $r.built.len & " built, " & $r.cached.len & " cached"
  if r.failed.len == 0 and r.cancelled.len == 0: result.add ", 0 failed"
