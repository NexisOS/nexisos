## Dependency groups are authoring sugar. They expand before hashing, so a
## change to a group changes the build identity of every package that uses it
## and triggers a rebuild. That is why groups need no version numbers — and
## why the group file is a build input, not configuration.

import std/[strutils, tables]
import parsetoml
import ./types

type
  Group* = object
    name*: string
    native*: seq[DepSpec]
    dependencies*: seq[DepSpec]

  GroupSet* = object
    groups*: Table[string, Group]
    path*: string

proc strSeq(v: TomlValueRef): seq[string] =
  if v.isNil or v.kind != TomlValueKind.Array: return @[]
  for item in v.arrayVal:
    if item.kind == TomlValueKind.String: result.add item.stringVal

proc splitDep(s: string): DepSpec =
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

proc parseGroups*(src, path: string): (GroupSet, seq[Diagnostic]) =
  var gs = GroupSet(path: path, groups: initTable[string, Group]())
  var diags: seq[Diagnostic]
  var root: TomlValueRef
  try:
    root = parsetoml.parseString(src)
  except CatchableError as e:
    diags.add err(0, "TOML syntax error: " & e.msg)
    return (gs, diags)

  if not root.tableVal.hasKey("schema"):
    diags.add err(0, "group file has no `schema` key")
  if not root.tableVal.hasKey("group"):
    diags.add err(0, "group file declares no [group.*] tables")
    return (gs, diags)

  let g = root.tableVal["group"]
  if g.kind != TomlValueKind.Table:
    diags.add err(0, "`group` must be a table")
    return (gs, diags)

  for name, val in g.tableVal:
    var grp = Group(name: name)
    for s in strSeq(val.tableVal.getOrDefault("native")):
      grp.native.add splitDep(s)
    for s in strSeq(val.tableVal.getOrDefault("dependencies")):
      grp.dependencies.add splitDep(s)
    if grp.native.len == 0 and grp.dependencies.len == 0:
      diags.add warn(0, "group '" & name & "' is empty")
    gs.groups[name] = grp

  (gs, diags)
