## Realisation: from resolved packages to artifacts in the store.
##
## This is the piece that was missing. The resolver produces a `Resolved` with a
## `buildId`; the scheduler drains a dependency graph; the runner executes
## phases inside a sandbox; the store holds content-addressed trees. Each half
## worked and nothing joined them, so no artifact had ever been produced.
##
## Two decisions shape everything here.
##
## **The store is consulted before the graph is built, not while draining it.**
## A package whose `buildId` is already present is marked cached up front, and
## its dependants become buildable immediately. Deciding this during the drain
## would mean the plan a user sees in `dry-run` differs from what actually runs
## — and a dry run that does not predict the real run is worse than no dry run.
##
## **A build commits to the store only after it succeeds, and a failure leaves
## nothing behind.** The staging tree is removed, no reference is taken, and the
## index never learns the buildId existed. That is what makes a failed build
## indistinguishable from one that never started, which in turn is what lets a
## rebuild after a fix be a clean operation rather than a repair.

import std/[algorithm, os, strutils, tables]
import ../../lib/[filesystem, paths, process]
import ../../lib/hashing except Digest

# `resolve.Digest` is `string`; `lib/hashing.Digest` is a distinct string. Two
# types, one name. Aliased here so the conversion at the store boundary reads
# as deliberate rather than as a cast someone forgot to remove.
type StoreDigest = hashing.Digest
import ../package/[types, resolve]
import ../store/store
import ./sandbox, ./phases, ./runner, ./scheduler, ./isolate

type
  Plan* = object
    ## Everything decidable before a single build runs.
    graph*: Graph
    resolved*: Table[string, Resolved]   ## buildId -> package
    cached*: seq[string]                 ## buildIds already in the store
    toBuild*: seq[string]                ## buildIds that must run, in order
    diagnostics*: seq[string]

  RealiseOptions* = object
    storeRoot*: string
    stagingRoot*: string
    maxParallel*: int
    failFast*: bool
    dryRun*: bool
    timeoutMs*: int
    target*: string

  Realisation* = object
    report*: RunReport
    artifacts*: Table[string, string]    ## buildId -> artifact digest
    logs*: Table[string, string]         ## buildId -> build log
    failures*: Table[string, BuildResult]

func defaultOptions*(): RealiseOptions =
  RealiseOptions(storeRoot: DefaultStoreRoot, stagingRoot: "/var/tmp/nexis",
                 maxParallel: 1, failFast: false, dryRun: false,
                 timeoutMs: 6 * 3600 * 1000, target: "x86_64-linux")

# --- Planning ----------------------------------------------------------------

func weightOf*(r: Resolved): int =
  ## A scheduling hint, not an estimate. The only signal available before a
  ## build has ever run is the shape of the definition, so it is used honestly:
  ## more phases and more dependencies means start it earlier, because it is
  ## more likely to be on the critical path.
  result = 1 + r.dependencies.len
  for name in PhaseName:
    if r.def.build.phases.hasKey(name): inc result

proc plan*(packages: seq[Resolved], s: Store, opts: RealiseOptions): Plan =
  ## Build the graph, and decide what is already done.
  result.graph = newGraph(opts.maxParallel, opts.failFast)
  result.resolved = initTable[string, Resolved]()

  # Sorted so two runs over the same set produce the same plan. The graph
  # already breaks ties deterministically, but the insertion order feeds the
  # tie-break, so it has to be stable too.
  var sorted = packages
  sorted.sort(proc (a, b: Resolved): int = cmp(a.buildId, b.buildId))

  var byName = initTable[string, string]()      ## package name -> buildId
  for r in sorted:
    if r.buildId.len == 0:
      result.diagnostics.add r.def.name &
        " has no buildId; it was not resolved against its inputs"
      continue
    if r.buildId in result.resolved:
      # The same buildId twice is not an error: it is the same build, and
      # deduplicating here is why a diamond dependency builds once.
      continue
    result.resolved[r.buildId] = r
    byName[r.def.name] = r.buildId

  for id, r in result.resolved:
    var deps: seq[string]
    for d in r.dependencies:
      if d.name in byName:
        deps.add byName[d.name]
      else:
        # A dependency outside this set is assumed already realised. The
        # resolver is what guarantees that; if it is wrong, the build fails on
        # a missing input rather than silently linking something else.
        discard
    deps.sort()
    result.graph.add newNode(id, r.def.name, deps, weightOf(r))

  let order = result.graph.prepare()
  if order.cycle.len > 0:
    result.diagnostics.add "dependency cycle: " & order.cycle.join(" -> ")
    return

  # The store lookup happens here, once, so `dry-run` and the real run agree.
  #
  # NOTE: `resolve.Digest` is `string` while `lib/hashing.Digest` is a distinct
  # string. Two types, one name — converting at this boundary is the honest
  # thing to do until one of them is renamed (see TODO.md).
  for id in result.graph.order:
    if s.hasManifest(StoreDigest(id)):
      result.cached.add id
      result.graph.complete(id, ocCached, "already in the store")
    else:
      result.toBuild.add id
  result.graph.refreshReady()

func renderPlan*(p: Plan): string =
  ## What `nexis rebuild dry-run` prints.
  if p.diagnostics.len > 0:
    for d in p.diagnostics: result.add "error: " & d & "\n"
    return
  result.add $p.cached.len & " cached, " & $p.toBuild.len & " to build\n"
  if p.toBuild.len == 0:
    result.add "\nnothing to do.\n"
    return
  result.add "\nbuild order:\n"
  for i, id in p.toBuild:
    let r = p.resolved[id]
    result.add "  " & align($(i + 1), 3) & ". " & r.def.name
    if r.features.len > 0:
      result.add "  [" & r.features.join(" ") & "]"
    result.add "\n       " & id[0 ..< min(16, id.len)] & "\n"

# --- Realising ---------------------------------------------------------------

proc inputPaths*(s: Store, r: Resolved, artifacts: Table[string, string],
                 byName: Table[string, string]): seq[string] =
  ## The store paths bind-mounted into the sandbox. Only declared dependencies,
  ## which is the whole point: a build that needs something undeclared fails on
  ## a missing header rather than silently succeeding against the host's copy
  ## and producing an artifact that cannot be rebuilt elsewhere.
  for d in r.dependencies:
    if d.name notin byName: continue
    let depId = byName[d.name]
    if depId in artifacts:
      result.add s.root / "objects" / artifacts[depId]
  result.sort()

proc buildOne*(s: var Store, r: Resolved, inputs: seq[string],
               opts: RealiseOptions,
               exec: proc (prog: string, args: seq[string],
                           o: ExecOpts): ExecResult): (BuildResult, string) =
  ## One package: resolve phases, enter the sandbox, run, commit.
  ##
  ## Returns the artifact digest on success and the empty string otherwise.
  ## Nothing partial is ever returned: a caller cannot accidentally treat a
  ## failed build's staging tree as an artifact.
  # The paths are the sandbox's, not the host's: phases are substituted with
  # the locations they will see *inside* the namespaces, which is why these
  # come from sandbox.nim rather than from opts.
  var vars = defaultVars()
  vars.destDir = DestDir
  vars.srcDir = SrcDir
  vars.buildDir = BuildTmp
  vars.jobs = max(opts.maxParallel, 1)

  let phases = resolvePhases(r.def, vars, r.configureFlags)
  let staging = makeStagingDir(opts.stagingRoot, r.def.name)

  var req = BuildRequest(name: r.def.name,
                         spec: newSandbox(inputs, allowNetwork = false,
                                          jobs = opts.maxParallel),
                         phases: phases, staging: staging,
                         timeoutMs: opts.timeoutMs)

  let res = runBuild(req, exec)
  if res.outcome != boSuccess:
    # Nothing is kept. A failed build must be indistinguishable from one that
    # never started, or the next attempt begins from a state nobody chose.
    discardStaging(staging)
    return (res, "")

  let (ok, why) = commitReady(staging)
  if not ok:
    discardStaging(staging)
    var failed = res
    failed.outcome = boPhaseFailed
    failed.log.add "\n" & why & "\n"
    return (failed, "")

  let (id, _) = s.insertTree(staging / "dest")
  discardStaging(staging)
  (res, string(id))

proc realise*(packages: seq[Resolved], opts = defaultOptions()): Realisation =
  ## Plan, then drain. The scheduler owns readiness and cancellation; this owns
  ## the store and the sandbox.
  var s = initStore(opts.storeRoot)
  var p = plan(packages, s, opts)

  # A local rather than `result`, deliberately. Inside the `BuildFn` closure
  # below, `result` binds to *that closure's* return tuple, not to this proc's
  # — so writing `result.artifacts[id] = ...` there is a compile error at best
  # and a silent write to the wrong thing at worst. Naming it removes the
  # shadowing entirely.
  var realised = Realisation(artifacts: initTable[string, string](),
                        logs: initTable[string, string](),
                        failures: initTable[string, BuildResult]())

  if p.diagnostics.len > 0:
    realised.report.aborted = true
    for d in p.diagnostics: realised.report.failed.add ("plan", d)
    return realised

  var byName = initTable[string, string]()
  for id, r in p.resolved: byName[r.def.name] = id

  # A cached package's artifact is its buildId: the manifest is already in the
  # store under that id, so a dependant can bind-mount it without rebuilding.
  for id in p.cached:
    realised.artifacts[id] = id

  let build: BuildFn = proc (id, name: string): (Outcome, string) =
    let r = p.resolved[id]
    let inputs = inputPaths(s, r, realised.artifacts, byName)

    if opts.dryRun:
      # The identical sequence with an executor that runs nothing. A dry run
      # taking a different path through this function would not be predicting
      # anything.
      let (res, _) = buildOne(s, r, inputs, opts,
        proc (prog: string, args: seq[string], o: ExecOpts): ExecResult =
          ExecResult(code: 0, output: ""))
      realised.logs[id] = res.log
      return (ocBuilt, "")

    let (res, artifact) = buildOne(s, r, inputs, opts,
                                   sandboxedExec(newSandbox(inputs)))
    realised.logs[id] = res.log
    case res.outcome
    of boSuccess:
      realised.artifacts[id] = artifact
      (ocBuilt, "")
    of boSandboxRefused:
      realised.failures[id] = res
      (ocFailed, "sandbox: " & res.violations.join("; "))
    of boTimedOut:
      realised.failures[id] = res
      (ocFailed, "timed out in " & $res.failedPhase)
    of boPhaseFailed:
      realised.failures[id] = res
      (ocFailed, $res.failedPhase & " exited " & $res.exitCode)

  realised.report = p.graph.run(build)
  realised

func summary*(r: Realisation): string =
  result = r.report.summary()
  if r.failures.len > 0:
    result.add "\n\nBuild logs are attached to each failure; the last phase " &
               "that ran is named above.\n"
