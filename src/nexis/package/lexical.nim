## A source-level pass over the definition text, run before the TOML parser.
##
## It exists because two things cannot be recovered from a parsed TOML tree:
##
## 1. **Rule 0.** TOML binds a bare key to the most recently opened table, so
##    `outputs = [...]` written below `[features.translations]` becomes
##    `features.translations.outputs`. The parsed tree cannot distinguish that
##    from an intentional key of the same name — both are just a string at a
##    path. The mistake is only visible in the source, as a *reserved
##    top-level key name appearing after the first table header*.
##
## 2. **Line numbers for semantic errors.** parsetoml reports line and column
##    for syntax errors but the value tree it produces carries no locations, so
##    "hash is missing its algorithm prefix" would otherwise have nowhere to
##    point. This pass records a line for every table header and key path.

import std/[strutils, tables]
import ./types

const ReservedTopLevel* = [
  "schema", "name", "version", "revision", "slot", "description",
  "homepage", "license", "outputs", "conflicts", "replaces",
]

## Legal keys per table context. Contexts are normalised: array indices become
## `[]`, and the user-named component of `features.X` / `output.X` /
## `build.phases.X` becomes `*`.
##
## This doubles as typo detection. A key that is legal nowhere in its table is
## reported regardless of whether it collides with a top-level name; a key that
## happens to *be* a top-level name gets the more specific rule-0 message,
## because that is the mistake the author almost certainly made.
const ContextKeys*: seq[(string, seq[string])] = @[
  ("", @["schema", "name", "version", "revision", "slot", "description",
         "homepage", "license", "outputs", "conflicts", "replaces"]),
  ("source[]", @["role", "urls", "hash", "unpack", "strip"]),
  ("build", @["builder", "target", "native-groups", "dependency-groups",
              "native", "dependencies", "environment"]),
  ("build.phases", @["unpack", "patch", "configure", "build", "check",
                     "install"]),
  ("build.phases.*", @["mode", "add", "argv"]),
  ("features", @["conflicts"]),
  ("features.*", @["default", "dependencies", "native", "configure",
                   "configure-off", "outputs"]),
  ("output.*", @["paths"]),
  ("provides[]", @["name", "path", "priority"]),
  ("security", @["needs-network", "needs-mount", "needs-ptrace"]),
  ("security.capabilities", @["allow"]),
  ("security.selinux", @["domain", "executable-type"]),
]

## Tables whose keys are free-form and must not be checked.
const OpaqueContexts* = ["build.environment"]

proc normalise*(path: string): string =
  ## `source[3]` -> `source[]`, `features.gtk3` -> `features.*`.
  var parts: seq[string] = @[]
  for part in path.split('.'):
    let br = part.find('[')
    parts.add(if br >= 0: part[0 ..< br] & "[]" else: part)
  result = parts.join(".")
  # Collapse the user-named component of the known parameterised tables.
  for prefix in ["features", "output", "build.phases"]:
    if result.startsWith(prefix & ".") and result.len > prefix.len + 1:
      let tail = result[prefix.len + 1 .. ^1]
      if "." notin tail:
        # features.conflicts is a real key of [features], not a subtable name;
        # only collapse when the name is not itself a declared key.
        var isKey = false
        for (ctx, keys) in ContextKeys:
          if ctx == prefix and tail in keys: isKey = true
        if not isKey: return prefix & ".*"

proc legalKeys*(context: string): seq[string] =
  for (ctx, keys) in ContextKeys:
    if ctx == context: return keys
  @[]

proc isOpaque*(context: string): bool =
  context in OpaqueContexts

type
  Scan* = object
    lines*: Table[string, int]   ## dotted path -> 1-based line number
    diagnostics*: seq[Diagnostic]

proc keyName(line: string): string =
  ## Returns the bare key of a `key = value` line, or "".
  let eq = line.find('=')
  if eq <= 0: return ""
  var k = line[0 ..< eq].strip()
  if k.len == 0: return ""
  # Reject anything that isn't a plain bare key: quoted or dotted keys are
  # never reserved top-level names, so they are out of scope for rule 0.
  for c in k:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return ""
  k

proc scan*(src: string): Scan =
  var
    inMultiline = false
    multiDelim = ""
    depth = 0
    firstTable = 0
    curPath = ""
    aotCount = initTable[string, int]()

  var lineNo = 0
  for raw in src.splitLines():
    inc lineNo
    var line = raw

    if inMultiline:
      if line.contains(multiDelim):
        inMultiline = false
        line = line[line.find(multiDelim) + 3 .. ^1]
      else:
        continue

    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      continue

    # Opening a multi-line string?
    for delim in ["\"\"\"", "'''"]:
      let a = line.find(delim)
      if a >= 0 and line.find(delim, a + 3) < 0:
        inMultiline = true
        multiDelim = delim
        line = line[0 ..< a]
        break

    if depth == 0 and stripped.startsWith("["):
      # Table header, possibly [[array of tables]]
      let isAot = stripped.startsWith("[[")
      let close = stripped.find(if isAot: "]]" else: "]")
      if close > 0:
        let name = stripped[(if isAot: 2 else: 1) ..< close].strip()
        if firstTable == 0: firstTable = lineNo
        if isAot:
          let n = aotCount.getOrDefault(name, 0)
          aotCount[name] = n + 1
          curPath = name & "[" & $n & "]"
        else:
          curPath = name
        result.lines[curPath] = lineNo
        continue

    if depth == 0:
      let k = keyName(line)
      if k.len > 0:
        let path = if curPath.len > 0: curPath & "." & k else: k
        if path notin result.lines:
          result.lines[path] = lineNo
        let ctx = normalise(curPath)
        if not isOpaque(ctx):
          let legal = legalKeys(ctx)
          if legal.len > 0 and k notin legal:
            if k in ReservedTopLevel and firstTable > 0:
              result.diagnostics.add err(lineNo,
                "top-level key '" & k & "' appears after the table header on " &
                "line " & $firstTable & ", so TOML binds it to [" & curPath &
                "] as '" & curPath & "." & k &
                "'. Move all top-level keys above the first table header.")
            else:
              result.diagnostics.add err(lineNo,
                "unknown key '" & k & "' in [" & curPath & "] (expected one " &
                "of " & legal.join(", ") & ")")

    # Track bracket depth so multi-line arrays don't look like keys or headers.
    var inStr = false
    var quote = ' '
    for c in line:
      if inStr:
        if c == quote: inStr = false
      elif c in {'"', '\''}:
        inStr = true
        quote = c
      elif c == '#':
        break
      elif c == '[':
        inc depth
      elif c == ']':
        dec depth
    if depth < 0: depth = 0

proc lineOf*(s: Scan, path: string): int =
  s.lines.getOrDefault(path, 0)
