## Stage 1 and 2: parse a definition file and validate it in isolation.
##
## Closure-level checks (does this dependency's output exist, does this group
## resolve) live in resolve.nim, because they need the whole set loaded.

import std/[strutils, tables]
import parsetoml
import ./types, ./sri, ./glob, ./lexical

type
  Parser = object
    scan: Scan
    diags: seq[Diagnostic]
    path: string

proc add(p: var Parser, d: Diagnostic) = p.diags.add d

proc lineOf(p: Parser, key: string): int = p.scan.lineOf(key)

proc parseDep*(s: string, line: int, p: var Parser): DepSpec =
  ## `name[@slot][:output]`. The two sigils are distinct so a package can carry
  ## both, e.g. `llvm@18:dev`.
  var rest = s
  let colon = rest.rfind(':')
  if colon >= 0:
    result.output = rest[colon + 1 .. ^1]
    rest = rest[0 ..< colon]
  let at = rest.find('@')
  if at >= 0:
    result.slot = rest[at + 1 .. ^1]
    rest = rest[0 ..< at]
  result.name = rest
  if result.name.len == 0:
    p.add err(line, "empty dependency name in " & s.escape())

proc strSeq(v: TomlValueRef): seq[string] =
  if v.isNil or v.kind != TomlValueKind.Array: return @[]
  for item in v.arrayVal:
    if item.kind == TomlValueKind.String: result.add item.stringVal

proc depSeq(v: TomlValueRef, line: int, p: var Parser): seq[DepSpec] =
  for s in strSeq(v):
    result.add parseDep(s, line, p)

proc get(t: TomlValueRef, key: string): TomlValueRef =
  if t.isNil or t.kind != TomlValueKind.Table: return nil
  if t.tableVal.hasKey(key): return t.tableVal[key]
  nil

proc getStr(t: TomlValueRef, key: string, dflt = ""): string =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.String: dflt else: v.stringVal

proc getBool(t: TomlValueRef, key: string, dflt = false): bool =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.Bool: dflt else: v.boolVal

proc getInt(t: TomlValueRef, key: string, dflt = 0): int =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.Int: dflt else: int(v.intVal)

proc parseEnum[T: enum](p: var Parser, s: string, line: int, what: string,
                        dflt: T): T =
  if s.len == 0: return dflt
  for e in T:
    if $e == s: return e
  var opts: seq[string]
  for e in T: opts.add $e
  p.add err(line, "unknown " & what & ": " & s.escape() &
            " (expected one of " & opts.join(", ") & ")")
  dflt

proc parseSources(p: var Parser, root: TomlValueRef): seq[Source] =
  let arr = root.get("source")
  if arr.isNil or arr.kind != TomlValueKind.Array:
    p.add err(0, "no [[source]] declared; a definition needs at least one")
    return
  for i, item in arr.arrayVal:
    let ln = p.lineOf("source[" & $i & "]")
    var s = Source(line: ln)
    s.role = parseEnum(p, item.getStr("role", "primary"), ln, "source role",
                       srPrimary)
    s.unpack = parseEnum(p, item.getStr("unpack", "auto"), ln, "unpack mode",
                         upAuto)
    s.strip = item.getInt("strip", 1)
    s.urls = strSeq(item.get("urls"))
    if s.urls.len == 0:
      p.add err(ln, "source has no urls")
    let h = item.getStr("hash")
    if h.len == 0:
      p.add err(ln, "source has no hash")
    else:
      try:
        s.hash = parseSri(h)
        if not s.hash.isPinned:
          p.add warn(ln, "source hash is unpinned (" & h &
                     "); the package cannot be built reproducibly until it is set")
      except SriError as e:
        p.add err(ln, e.msg)
    result.add s

proc parsePhases(p: var Parser, build: TomlValueRef): Table[PhaseName, Phase] =
  result = initTable[PhaseName, Phase]()
  let ph = build.get("phases")
  if ph.isNil or ph.kind != TomlValueKind.Table: return
  for key, val in ph.tableVal:
    let ln = p.lineOf("build.phases." & key)
    var found = false
    var name: PhaseName
    for pn in PhaseName:
      if $pn == key:
        name = pn
        found = true
        break
    if not found:
      p.add err(ln, "unknown build phase: " & key.escape())
      continue
    var phase = Phase(line: ln)
    phase.mode = parseEnum(p, val.getStr("mode", "default"), ln, "phase mode",
                           pmDefault)
    phase.add = strSeq(val.get("add"))
    let argv = val.get("argv")
    if not argv.isNil and argv.kind == TomlValueKind.Array:
      for row in argv.arrayVal:
        phase.argv.add strSeq(row)
    case phase.mode
    of pmArgs:
      if phase.add.len == 0:
        p.add warn(ln, "phase '" & key & "' uses mode 'args' but adds nothing")
      if phase.argv.len > 0:
        p.add err(ln, "phase '" & key &
                  "' uses mode 'args'; argv is only valid for prepend/append/replace")
    of pmPrepend, pmAppend, pmReplace:
      if phase.argv.len == 0:
        p.add err(ln, "phase '" & key & "' uses mode '" & $phase.mode &
                  "' but declares no argv")
      for row in phase.argv:
        if row.len == 0:
          p.add err(ln, "phase '" & key & "' has an empty argv entry")
    of pmDefault, pmSkip:
      if phase.add.len > 0 or phase.argv.len > 0:
        p.add warn(ln, "phase '" & key & "' is '" & $phase.mode &
                   "'; add/argv are ignored")
    result[name] = phase

const ToolchainVars = ["CC", "CXX", "LD", "AR", "RANLIB", "NM", "STRIP",
                       "OBJCOPY", "OBJDUMP", "CFLAGS", "CXXFLAGS", "LDFLAGS",
                       "PATH"]

proc parseBuild(p: var Parser, root: TomlValueRef): Build =
  let b = root.get("build")
  if b.isNil:
    p.add err(0, "no [build] table")
    return
  let ln = p.lineOf("build")
  result.builder = parseEnum(p, b.getStr("builder"), ln, "builder", bAutotools)
  if b.getStr("builder").len == 0:
    p.add err(ln, "[build] has no builder")
  result.target = b.getStr("target")
  result.nativeGroups = strSeq(b.get("native-groups"))
  result.dependencyGroups = strSeq(b.get("dependency-groups"))
  result.native = depSeq(b.get("native"), ln, p)
  result.dependencies = depSeq(b.get("dependencies"), ln, p)
  result.environment = initTable[string, string]()

  let env = b.get("environment")
  if not env.isNil:
    if env.kind != TomlValueKind.Table:
      p.add err(p.lineOf("build.environment"),
        "environment must be a table of KEY = \"value\", not an array of " &
        "\"KEY=value\" strings")
    else:
      for k, v in env.tableVal:
        if v.kind != TomlValueKind.String:
          p.add err(p.lineOf("build.environment"),
                    "environment value for " & k & " must be a string")
          continue
        if k in ToolchainVars:
          p.add err(p.lineOf("build.environment"),
            "environment sets " & k & ", which the toolchain owns. Pin the " &
            "toolchain through a native dependency instead so it enters the " &
            "build identity.")
        result.environment[k] = v.stringVal

  result.phases = parsePhases(p, b)
  if result.builder == bScript:
    for name, phase in result.phases:
      if phase.mode notin {pmReplace, pmSkip}:
        p.add err(phase.line, "builder 'script' has no defaults, so phase '" &
                  $name & "' must use mode 'replace' or 'skip'")

proc parseFeatures(p: var Parser, root: TomlValueRef,
                   conflicts: var seq[seq[string]]): OrderedTable[string, Feature] =
  result = initOrderedTable[string, Feature]()
  let f = root.get("features")
  if f.isNil or f.kind != TomlValueKind.Table: return
  for key, val in f.tableVal:
    if key == "conflicts":
      if val.kind == TomlValueKind.Array:
        for row in val.arrayVal:
          conflicts.add strSeq(row)
      continue
    if val.kind != TomlValueKind.Table:
      p.add err(p.lineOf("features." & key),
                "features." & key & " must be a table")
      continue
    let ln = p.lineOf("features." & key)
    var feat = Feature(name: key, line: ln)
    feat.default = val.getBool("default", false)
    feat.dependencies = depSeq(val.get("dependencies"), ln, p)
    feat.native = depSeq(val.get("native"), ln, p)
    feat.configure = strSeq(val.get("configure"))
    feat.configureOff = strSeq(val.get("configure-off"))
    feat.outputs = strSeq(val.get("outputs"))
    result[key] = feat

proc parseOutputs(p: var Parser, root: TomlValueRef,
                  declared: seq[string]): OrderedTable[string, Output] =
  result = initOrderedTable[string, Output]()
  let o = root.get("output")
  if o.isNil or o.kind != TomlValueKind.Table:
    p.add err(0, "no [output.*] tables declared")
    return
  for key, val in o.tableVal:
    let ln = p.lineOf("output." & key)
    var outp = Output(name: key, line: ln)
    outp.paths = strSeq(val.get("paths"))
    if outp.paths.len == 0:
      p.add err(ln, "output '" & key & "' declares no paths")
    for pat in outp.paths:
      if not pat.startsWith("/"):
        p.add err(ln, "output pattern must be absolute: " & pat.escape())
    result[key] = outp

  for name in declared:
    if name notin result:
      p.add err(p.lineOf("outputs"),
                "output '" & name & "' is listed in `outputs` but has no " &
                "[output." & name & "] table")
  for name in result.keys:
    if name notin declared:
      p.add err(result[name].line,
                "[output." & name & "] is defined but not listed in `outputs`, " &
                "so nothing will be assigned to it")

proc checkOutputOverlap(p: var Parser, outs: OrderedTable[string, Output],
                        order: seq[string]) =
  ## Patterns are matched in `outputs` declaration order, first match wins, so
  ## overlap is legal. Identical patterns in two outputs are not: the later one
  ## is unreachable and the author plainly meant something else.
  var seen: Table[string, string]
  for name in order:
    if name notin outs: continue
    for pat in outs[name].paths:
      if seen.hasKey(pat):
        p.add err(outs[name].line,
          "output '" & name & "' repeats the pattern " & pat.escape() &
          " already claimed by output '" & seen[pat] &
          "'; the later one can never match")
      else:
        seen[pat] = name
  for i in 0 ..< order.len:
    for j in i + 1 ..< order.len:
      if order[i] notin outs or order[j] notin outs: continue
      for a in outs[order[i]].paths:
        for b in outs[order[j]].paths:
          if a != b and intersects(a, b):
            p.add warn(outs[order[j]].line,
              "pattern " & b.escape() & " in output '" & order[j] &
              "' overlaps " & a.escape() & " in output '" & order[i] &
              "'; earlier outputs win, so files matching both go to '" &
              order[i] & "'")

proc parseProvides(p: var Parser, root: TomlValueRef): seq[Provide] =
  let arr = root.get("provides")
  if arr.isNil or arr.kind != TomlValueKind.Array: return
  var byName: Table[string, int]
  for i, item in arr.arrayVal:
    let ln = p.lineOf("provides[" & $i & "]")
    var pr = Provide(line: ln)
    pr.name = item.getStr("name")
    pr.path = item.getStr("path")
    pr.priority = item.getInt("priority", 0)
    if pr.name.len == 0: p.add err(ln, "provides entry has no name")
    if pr.path.len == 0: p.add err(ln, "provides entry has no path")
    elif not pr.path.startsWith("/"):
      p.add err(ln, "provides path must be absolute: " & pr.path.escape())
    if byName.hasKey(pr.name):
      p.add err(ln, "provides '" & pr.name &
                "' is declared twice in the same definition")
    byName[pr.name] = i
    result.add pr

proc parseSecurity(p: var Parser, root: TomlValueRef): Security =
  let s = root.get("security")
  if s.isNil: return
  result.needsNetwork = s.getBool("needs-network")
  result.needsMount = s.getBool("needs-mount")
  result.needsPtrace = s.getBool("needs-ptrace")
  let caps = s.get("capabilities")
  if not caps.isNil:
    result.capabilities = strSeq(caps.get("allow"))
    for c in result.capabilities:
      if not c.startsWith("CAP_"):
        p.add err(p.lineOf("security.capabilities"),
                  "capability should be a CAP_* constant: " & c.escape())
  let sel = s.get("selinux")
  if not sel.isNil:
    result.selinux.domain = sel.getStr("domain")
    result.selinux.executableType = sel.getStr("executable-type")

proc parseDefinition*(src, path: string): (Definition, seq[Diagnostic]) =
  ## Parses and validates a single definition file. Diagnostics may contain
  ## warnings even on success; check `hasErrors`.
  var p = Parser(path: path)
  p.scan = scan(src)
  p.diags = p.scan.diagnostics

  var root: TomlValueRef
  try:
    root = parsetoml.parseString(src)
  except CatchableError as e:
    # parsetoml embeds "(line:col)" in the message; keep it verbatim rather
    # than reformatting it into something less precise.
    p.add err(0, "TOML syntax error: " & e.msg)
    return (Definition(path: path), p.diags)

  var d = Definition(path: path)
  d.schema = root.getInt("schema", 0)
  if d.schema == 0:
    p.add err(p.lineOf("schema"), "no `schema` key")
  elif d.schema != SchemaVersion:
    p.add err(p.lineOf("schema"), "unsupported schema version " & $d.schema &
              " (this build understands " & $SchemaVersion & ")")

  d.name = root.getStr("name")
  d.version = root.getStr("version")
  d.revision = root.getInt("revision", 0)
  d.slot = root.getStr("slot")
  d.description = root.getStr("description")
  d.homepage = root.getStr("homepage")
  d.license = root.getStr("license")
  if d.name.len == 0: p.add err(p.lineOf("name"), "no `name`")
  if d.version.len == 0: p.add err(p.lineOf("version"), "no `version`")

  d.outputs = strSeq(root.get("outputs"))
  if d.outputs.len == 0:
    d.outputs = @["out"]
  d.conflicts = strSeq(root.get("conflicts"))
  d.replaces = strSeq(root.get("replaces"))

  d.sources = parseSources(p, root)
  d.build = parseBuild(p, root)
  d.features = parseFeatures(p, root, d.featureConflicts)
  d.output = parseOutputs(p, root, d.outputs)
  checkOutputOverlap(p, d.output, d.outputs)
  d.provides = parseProvides(p, root)
  d.security = parseSecurity(p, root)

  # Feature conflict groups must name declared features.
  for group in d.featureConflicts:
    for name in group:
      if name notin d.features:
        p.add err(p.lineOf("features.conflicts"),
                  "features.conflicts names '" & name &
                  "', which is not a declared feature")

  # A feature may only claim an output the package declares.
  for name, feat in d.features:
    for o in feat.outputs:
      if o notin d.outputs:
        p.add err(feat.line, "feature '" & name & "' claims output '" & o &
                  "', which is not in `outputs`")

  # Slots must be self-qualifying: if a package declares a slot, at least one
  # output pattern has to mention it, or two slots of the package will collide
  # on identical paths at generation build time.
  if d.slot.len > 0:
    var qualified = false
    for _, o in d.output:
      for pat in o.paths:
        if d.slot in pat: qualified = true
    if not qualified:
      p.add err(p.lineOf("slot"),
        "slot '" & d.slot & "' is declared but no output pattern is " &
        "slot-qualified, so two slots of " & d.name &
        " would claim the same paths. Qualify the paths (e.g. " &
        "/usr/lib/" & d.name & "-" & d.slot & "/**) and expose the " &
        "unqualified name through `provides`.")

  (d, p.diags)
