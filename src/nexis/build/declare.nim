## From a declaration to a set of buildable packages.
##
## This is the last link in the chain. `/etc/nexis/system.toml` names packages;
## definitions live in files; the resolver turns a definition plus a feature
## request into a `Resolved` with a `buildId`; `realise.nim` takes a
## `seq[Resolved]`. Nothing walked from one end to the other, so the whole
## pipeline had never been run.
##
## Two properties this has to hold, both of which are the point of the project
## rather than implementation details:
##
## **The closure is complete before anything builds.** Every transitive
## dependency is located and resolved during this walk. A package whose
## definition is missing is an error *here*, not a build that fails forty
## minutes in on a missing header — and not a build that silently succeeds
## against something the host happened to have.
##
## **A definition is found by search path, not by a central index.** The
## repository model is decentralised (ADR 0005), so "where does `openssl` come
## from" is answered by an ordered list of directories the user controls. The
## first match wins and the origin is recorded, so `nexis why` can say which
## file a package came from.

import std/[algorithm, os, sets, strutils, tables]
import ../package/[types, parse, groups, resolve]

type
  Origin* = object
    name*: string
    path*: string           ## the definition file it was read from
    source*: string         ## which search-path entry provided it

  Problem* = object
    package*: string
    msg*: string
    requiredBy*: string     ## empty when it was named by the declaration

  Closure* = object
    packages*: seq[Resolved]
    origins*: Table[string, Origin]
    problems*: seq[Problem]

  SearchPath* = seq[string]

func format*(p: Problem): string =
  result = p.package & ": " & p.msg
  if p.requiredBy.len > 0:
    result.add " (required by " & p.requiredBy & ")"

func hasErrors*(c: Closure): bool = c.problems.len > 0

func defaultSearchPath*(configRoot = "/etc/nexis"): SearchPath =
  ## Ordered, first match wins. The local overlay comes first so a machine can
  ## override a definition without editing anything it does not own — the
  ## decentralised equivalent of a Nix overlay, and the reason there is no
  ## `nexis edit --patch`.
  @[configRoot / "packages",
    configRoot / "overlay",
    "/var/lib/nexis/definitions",
    "/usr/share/nexis/definitions"]

# --- Locating ----------------------------------------------------------------

proc locate*(name: string, path: SearchPath): (string, string) =
  ## Returns (file, which search entry matched), or two empty strings.
  ##
  ## `<dir>/<name>.toml` then `<dir>/<name>/package.toml`. The second form is
  ## for definitions that ship patches alongside them; both are checked because
  ## forcing a directory for a one-file package is noise, and forcing a single
  ## file for a package with patches is a lie.
  for entry in path:
    for candidate in [entry / (name & ".toml"),
                      entry / name / "package.toml"]:
      if fileExists(candidate):
        return (candidate, entry)
  ("", "")

proc loadDefinition*(name: string, path: SearchPath):
    (Definition, string, string, seq[Diagnostic]) =
  ## Definition, file, search entry, diagnostics.
  let (file, entry) = locate(name, path)
  if file.len == 0:
    return (Definition(), "", "", @[])
  var src = ""
  try:
    src = readFile(file)
  except IOError, OSError:
    return (Definition(), file, entry,
            @[Diagnostic(severity: sevError, line: 0,
                         msg: "cannot read " & file)])
  let (d, diags) = parseDefinition(src, file)
  (d, file, entry, diags)

proc loadGroups*(path: SearchPath): GroupSet =
  ## Groups are merged across the search path, earlier entries winning. A group
  ## is a name for a set of dependencies, so an overlay redefining one is how a
  ## machine substitutes an implementation without touching every consumer.
  result.groups = initTable[string, Group]()
  var entries = path
  entries.reverse()          ## later entries first, so earlier ones overwrite
  for entry in entries:
    let file = entry / "groups.toml"
    if not fileExists(file): continue
    try:
      let (gs, _) = parseGroups(readFile(file), file)
      for name, g in gs.groups: result.groups[name] = g
    except IOError, OSError:
      discard

# --- Walking the closure -----------------------------------------------------

proc assignBuildIds*(c: var Closure, target: string) =
  ## Compute every `buildId`, in dependency order.
  ##
  ## A build identity depends on its inputs' identities, so it cannot be known
  ## until they are — which is why `resolve()` does not set it and why this is
  ## a second pass rather than part of the walk.
  ##
  ## BOOTSTRAP: a dependency's *interface* id is what should feed a dependant's
  ## build hash, so that an ABI-preserving rebuild of a library does not
  ## rebuild everything linking it (architecture.md, "Four identities"). An
  ## interface id is computed from a built output, and nothing has been built,
  ## so each dependency's `buildId` stands in for it. The consequence is real
  ## and should not be forgotten: today a library rebuild rebuilds its
  ## dependants. Correct, just wasteful. See TODO.md.
  var byName = initTable[string, Resolved]()
  for r in c.packages: byName[r.def.name] = r

  var ids = initTable[string, string]()
  var settled = initHashSet[string]()

  # Repeat until nothing new settles: a package settles once every dependency
  # it has inside the closure has an id. A cycle never settles, and is reported
  # rather than looping forever.
  while true:
    var progressed = false
    for r in c.packages:
      if r.def.name in settled: continue
      var ready = true
      var native = initTable[string, string]()
      var runtime = initTable[string, string]()
      for d in r.dependencies:
        if d.name notin byName: continue      ## outside the closure
        if d.name notin ids: ready = false; break
        runtime[d.name] = ids[d.name]
      if not ready: continue
      for d in r.native:
        if d.name notin byName: continue
        if d.name notin ids: ready = false; break
        native[d.name] = ids[d.name]
      if not ready: continue

      let (id, diags) = buildIdentity(r, native, runtime, target)
      for d in diags:
        if d.severity == sevError:
          c.problems.add Problem(package: r.def.name, msg: d.msg)
      ids[r.def.name] = id
      settled.incl r.def.name
      progressed = true
    if not progressed: break

  for i in 0 ..< c.packages.len:
    let name = c.packages[i].def.name
    if name in ids:
      c.packages[i].buildId = ids[name]
    else:
      c.problems.add Problem(package: name,
        msg: "build identity could not be computed; a dependency cycle " &
             "inside the closure is the usual cause")

proc buildClosure*(wanted: seq[string], path: SearchPath,
                   features = initTable[string, bool](),
                   target = "x86_64-linux"): Closure =
  ## Breadth-first from the declared set, resolving every transitive
  ## dependency.
  ##
  ## Breadth-first rather than depth-first so that a missing definition three
  ## levels down is reported alongside its siblings rather than aborting the
  ## walk — the same "report everything at once" rule the rest of the codebase
  ## follows, applied to the dependency graph.
  result.origins = initTable[string, Origin]()
  let gs = loadGroups(path)

  var queue: seq[(string, string)] = @[]     ## (name, requiredBy)
  var seen = initHashSet[string]()

  # Sorted so the closure is identical across runs regardless of the order the
  # declaration happened to list packages in.
  var start = wanted
  start.sort()
  for name in start:
    queue.add (name, "")

  var head = 0
  while head < queue.len:
    let (name, requiredBy) = queue[head]
    inc head
    if name in seen: continue
    seen.incl name

    let (def, file, entry, diags) = loadDefinition(name, path)
    if file.len == 0:
      result.problems.add Problem(package: name, requiredBy: requiredBy,
        msg: "no definition found on the search path")
      continue

    var fatal = false
    for d in diags:
      if d.severity == sevError:
        fatal = true
        result.problems.add Problem(package: name, requiredBy: requiredBy,
          msg: file & ":" & $d.line & ": " & d.msg)
    if fatal: continue

    if def.name.len > 0 and def.name != name:
      # A file claiming a different name than the one it was found under means
      # one of the two is wrong, and guessing which produces a closure that
      # does not match the declaration.
      result.problems.add Problem(package: name, requiredBy: requiredBy,
        msg: file & " declares itself as `" & def.name & "`")
      continue

    let (r, rdiags) = resolve(def, gs, features)
    var resolveFailed = false
    for d in rdiags:
      if d.severity == sevError:
        resolveFailed = true
        result.problems.add Problem(package: name, requiredBy: requiredBy,
                                    msg: d.msg)
    if resolveFailed: continue

    result.origins[name] = Origin(name: name, path: file, source: entry)
    result.packages.add r

    var deps: seq[string]
    for d in r.dependencies: deps.add d.name
    for d in r.native: deps.add d.name
    deps.sort()
    for d in deps:
      if d notin seen: queue.add (d, name)

  # Deterministic output order. `realise` sorts by buildId anyway, but a
  # closure that reorders between runs makes every diff of `nexis why` noise.
  result.packages.sort(proc (a, b: Resolved): int = cmp(a.def.name, b.def.name))
  result.assignBuildIds(target)

proc closureFor*(configPackages: seq[string], configRoot: string,
                 features = initTable[string, bool](),
                 target = "x86_64-linux"): Closure =
  buildClosure(configPackages, defaultSearchPath(configRoot), features, target)

# --- Reporting ---------------------------------------------------------------

func renderClosure*(c: Closure): string =
  if c.problems.len > 0:
    result.add $c.problems.len & " problem(s):\n"
    for p in c.problems:
      result.add "  " & p.format() & "\n"
    return
  result.add $c.packages.len & " package(s) in the closure\n"
  for r in c.packages:
    result.add "  " & r.def.name
    if r.def.version.len > 0: result.add " " & r.def.version
    if r.features.len > 0: result.add "  [" & r.features.join(" ") & "]"
    result.add "\n"

func missingDefinitions*(c: Closure): seq[string] =
  for p in c.problems:
    if "no definition found" in p.msg: result.add p.package
