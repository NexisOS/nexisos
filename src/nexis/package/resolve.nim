## Stage 3: settle features, expand groups, compute identities.
##
## The identity model is the reason this stage exists as a separate type. An
## unresolved Definition has no meaningful hash: its dependency set is still
## conditional on features that the host config has not weighed in on yet.

import std/[algorithm, sequtils, strutils, tables]
import checksums/sha2
import ./types, ./sri, ./groups

type
  FeatureRequest* = Table[string, bool]
    ## Overrides from a profile or host config, layered over the declaration
    ## defaults.

  Resolved* = object
    def*: Definition
    features*: seq[string]        ## enabled, sorted
    dependencies*: seq[DepSpec]   ## expanded, deduplicated, sorted
    native*: seq[DepSpec]
    configureFlags*: seq[string]  ## contributed by features, in declaration order
    activeOutputs*: seq[string]
    sourceId*: string
    buildId*: string

  Digest* = string

proc hex(s: ShaDigest_256): string =
  for c in s: result.add toHex(c.ord, 2).toLowerAscii()

proc h(parts: varargs[string]): Digest =
  ## Length-prefixed field joining. Concatenating raw strings would let
  ## ("ab", "c") and ("a", "bc") collide, which for a build identity means two
  ## different packages sharing a cache entry.
  var ctx = initSha_256()
  for p in parts:
    let prefix = $p.len & ":"
    ctx.update(prefix.toOpenArray(0, prefix.high))
    if p.len > 0: ctx.update(p.toOpenArray(0, p.high))
  hex(ctx.digest())

proc cmpDep(a, b: DepSpec): int = cmp($a, $b)

proc dedupSorted(xs: seq[DepSpec]): seq[DepSpec] =
  var s = xs
  s.sort(cmpDep)
  for d in s:
    if result.len == 0 or $result[^1] != $d: result.add d

## ---------------------------------------------------------------------------
## Source identity
##
## Deliberately excludes URLs: two mirrors of the same tarball are the same
## source, and changing a mirror must not force a rebuild.
## ---------------------------------------------------------------------------

proc sourceIdentity*(d: Definition): Digest =
  var fields = @["nexis-source-v1", d.name, d.version]
  var entries: seq[string]
  for s in d.sources:
    entries.add $s.role & "\x1f" & $s.hash & "\x1f" & $s.unpack & "\x1f" & $s.strip
  entries.sort()
  fields.add entries
  h(fields)

## ---------------------------------------------------------------------------
## Feature resolution
## ---------------------------------------------------------------------------

proc resolveFeatures*(d: Definition, req: FeatureRequest,
                      diags: var seq[Diagnostic]): seq[string] =
  var enabled = initTable[string, bool]()
  for name, f in d.features:
    enabled[name] = f.default
  for name, want in req:
    if name notin d.features:
      diags.add err(0, "requested feature '" & name & "' is not declared by " &
                    d.name)
      continue
    enabled[name] = want

  for group in d.featureConflicts:
    var on: seq[string]
    for name in group:
      if enabled.getOrDefault(name, false): on.add name
    if on.len > 1:
      on.sort()
      diags.add err(0, "features " & on.join(" and ") &
                    " are declared mutually exclusive but both are enabled")

  for name, f in d.features:
    if enabled.getOrDefault(name, false): result.add name
  result.sort()

## ---------------------------------------------------------------------------
## Closure expansion
## ---------------------------------------------------------------------------

proc expand(specs: seq[string], gs: GroupSet, wantNative: bool,
            diags: var seq[Diagnostic]): seq[DepSpec] =
  for name in specs:
    if name notin gs.groups:
      diags.add err(0, "dependency group '" & name &
                    "' does not resolve in " & gs.path)
      continue
    let g = gs.groups[name]
    result.add(if wantNative: g.native else: g.dependencies)

proc resolve*(d: Definition, gs: GroupSet, req: FeatureRequest):
    (Resolved, seq[Diagnostic]) =
  var diags: seq[Diagnostic]
  var r = Resolved(def: d)

  r.features = resolveFeatures(d, req, diags)
  let on = r.features

  var deps = d.build.dependencies
  var nat = d.build.native
  deps.add expand(d.build.dependencyGroups, gs, false, diags)
  nat.add expand(d.build.nativeGroups, gs, true, diags)

  # Only enabled features contribute. This is the whole point: a dependency
  # reachable only through a disabled feature is not in the closure.
  r.activeOutputs = @[]
  for name, f in d.features:
    if name in on:
      deps.add f.dependencies
      nat.add f.native
      r.configureFlags.add f.configure
      for o in f.outputs:
        if o notin r.activeOutputs: r.activeOutputs.add o
    else:
      r.configureFlags.add f.configureOff

  # Outputs a feature owns are dropped when the feature is off; everything not
  # claimed by any feature is always active.
  var claimed: seq[string]
  for _, f in d.features:
    for o in f.outputs:
      if o notin claimed: claimed.add o
  for o in d.outputs:
    if o notin claimed and o notin r.activeOutputs:
      r.activeOutputs.add o
  r.activeOutputs = d.outputs.filterIt(it in r.activeOutputs)

  r.dependencies = dedupSorted(deps)
  r.native = dedupSorted(nat)
  r.sourceId = sourceIdentity(d)
  (r, diags)

## ---------------------------------------------------------------------------
## Build identity
##
## Build dependencies enter by artifact id, runtime dependencies by interface
## id. That asymmetry is the payoff of a separate interface identity: a
## toolchain change rebuilds, an ABI-preserving library rebuild does not.
## ---------------------------------------------------------------------------

proc buildIdentity*(r: Resolved,
                    nativeArtifactIds: Table[string, string],
                    runtimeInterfaceIds: Table[string, string],
                    target: string): (Digest, seq[Diagnostic]) =
  var diags: seq[Diagnostic]
  let d = r.def
  var fields = @[
    "nexis-build-v1",
    r.sourceId,
    $d.revision,
    d.slot,
    target,
    $d.build.builder,
  ]

  var phases: seq[string]
  for name in PhaseName:
    if d.build.phases.hasKey(name):
      let p = d.build.phases[name]
      var s = $name & "=" & $p.mode
      if p.add.len > 0: s.add "|args:" & p.add.join("\x1f")
      for row in p.argv: s.add "|argv:" & row.join("\x1f")
      phases.add s
    else:
      phases.add $name & "=default"
  fields.add phases

  fields.add r.features.join(",")
  fields.add r.configureFlags.join("\x1f")

  var envKeys = toSeq(d.build.environment.keys)
  envKeys.sort()
  for k in envKeys:
    fields.add k & "=" & d.build.environment[k]

  for dep in r.native:
    if $dep notin nativeArtifactIds:
      diags.add err(0, "no artifact id for native dependency " & $dep &
                    "; build identity cannot be computed until it is built")
      continue
    fields.add "native:" & $dep & "@" & nativeArtifactIds[$dep]
  for dep in r.dependencies:
    if $dep notin runtimeInterfaceIds:
      diags.add err(0, "no interface id for runtime dependency " & $dep &
                    "; build identity cannot be computed until it is built")
      continue
    fields.add "runtime:" & $dep & "@" & runtimeInterfaceIds[$dep]

  fields.add r.activeOutputs.join(",")
  (h(fields), diags)
