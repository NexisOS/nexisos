## System configuration: `/etc/nexis/*.toml`.
##
## This is the *only* input to system state. There is no imperative path that
## can add a package, so anything not reachable from here does not exist on the
## machine. See docs/cli.md.
##
## Home configuration is part of this, not a separate evaluation: `[users.*]`
## carries packages, dotfiles and environment together. See docs/home.md.

import std/[strutils, tables]
import parsetoml
import ../package/types

const ConfigSchema* = 1

type
  HomeMode* = enum
    hmManaged = "managed"  ## NexisOS owns it; read-only; reverts on rebuild
    hmSeeded = "seeded"    ## written once if absent, then the user's forever
    hmMerged = "merged"    ## declared base layer, user writes overlay above

  HomeEntry* = object
    path*: string          ## relative to the user's home directory
    source*: string        ## path within the configuration tree
    mode*: HomeMode
    line*: int

  User* = object
    name*: string
    uid*: int
    groups*: seq[string]
    shell*: string
    packages*: seq[string]
    shadows*: seq[string]  ## system packages this user deliberately overrides
    home*: seq[HomeEntry]
    environment*: Table[string, string]
    line*: int

  SystemConfig* = object
    schema*: int
    hostname*: string
    timezone*: string
    locale*: string
    packages*: seq[string]
    users*: OrderedTable[string, User]
    services*: Table[string, bool]
    path*: string

proc get(t: TomlValueRef, key: string): TomlValueRef =
  if t.isNil or t.kind != TomlValueKind.Table: return nil
  if t.tableVal.hasKey(key): return t.tableVal[key]
  nil

proc getStr(t: TomlValueRef, key: string, dflt = ""): string =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.String: dflt else: v.stringVal

proc getInt(t: TomlValueRef, key: string, dflt = 0): int =
  let v = t.get(key)
  if v.isNil or v.kind != TomlValueKind.Int: dflt else: int(v.intVal)

proc strSeq(v: TomlValueRef): seq[string] =
  if v.isNil or v.kind != TomlValueKind.Array: return @[]
  for item in v.arrayVal:
    if item.kind == TomlValueKind.String: result.add item.stringVal

proc checkHomePath(p: string, line: int, diags: var seq[Diagnostic]) =
  if p.len == 0:
    diags.add err(line, "home entry has an empty path")
    return
  if p.startsWith("/"):
    diags.add err(line, "home path must be relative to the user's home " &
                  "directory, not absolute: " & p.escape())
  if p.startsWith("~"):
    diags.add err(line, "home path must not start with ~; it is already " &
                  "relative to the home directory: " & p.escape())
  for part in p.split('/'):
    if part == "..":
      diags.add err(line, "home path must not escape the home directory: " &
                    p.escape())
      break

proc parseHome(val: TomlValueRef, line: int,
               diags: var seq[Diagnostic]): seq[HomeEntry] =
  let home = val.get("home")
  if home.isNil: return
  if home.kind != TomlValueKind.Table:
    diags.add err(line, "home must be a table of managed/seeded/merged lists")
    return

  for mode in HomeMode:
    let arr = home.get($mode)
    if arr.isNil: continue
    if arr.kind != TomlValueKind.Array:
      diags.add err(line, "home." & $mode & " must be an array of " &
                    "{ path, source } tables")
      continue
    for item in arr.arrayVal:
      if item.kind != TomlValueKind.Table:
        diags.add err(line, "home." & $mode &
                      " entries must be { path = \"...\", source = \"...\" }")
        continue
      var e = HomeEntry(mode: mode, line: line)
      e.path = item.getStr("path")
      e.source = item.getStr("source")
      checkHomePath(e.path, line, diags)
      if e.source.len == 0:
        diags.add err(line, "home." & $mode & " entry for " & e.path.escape() &
                      " has no source")
      result.add e

proc checkHomeOverlap(entries: seq[HomeEntry], user: string,
                      diags: var seq[Diagnostic]) =
  var seen: Table[string, HomeMode]
  for e in entries:
    if e.path.len == 0: continue
    if seen.hasKey(e.path):
      diags.add err(e.line, "users." & user & " declares " & e.path.escape() &
                    " twice (" & $seen[e.path] & " and " & $e.mode & ")")
    else:
      seen[e.path] = e.mode

  # A managed file inside a merged directory is fine and useful: the merged
  # directory supplies a writable overlay, the managed file within it stays
  # authoritative. A managed file inside a *seeded* directory is a
  # contradiction, because seeded means NexisOS never touches the tree again.
  for a in entries:
    for b in entries:
      if a.path == b.path or a.path.len == 0 or b.path.len == 0: continue
      if not b.path.startsWith(a.path & "/"): continue
      if a.mode == hmSeeded and b.mode == hmManaged:
        diags.add err(b.line, "users." & user & ": " & b.path.escape() &
                      " is managed but sits inside " & a.path.escape() &
                      ", which is seeded. A seeded tree is handed to the user " &
                      "and never revisited, so the managed file inside it " &
                      "would not stay authoritative.")

proc parseUsers(root: TomlValueRef, diags: var seq[Diagnostic]):
    OrderedTable[string, User] =
  result = initOrderedTable[string, User]()
  let users = root.get("users")
  if users.isNil or users.kind != TomlValueKind.Table: return

  var byUid: Table[int, string]
  for name, val in users.tableVal:
    if val.kind != TomlValueKind.Table:
      diags.add err(0, "users." & name & " must be a table")
      continue
    var u = User(name: name)
    u.uid = val.getInt("uid", 0)
    u.shell = val.getStr("shell")
    u.groups = strSeq(val.get("groups"))
    u.packages = strSeq(val.get("packages"))
    u.shadows = strSeq(val.get("shadows"))
    u.environment = initTable[string, string]()

    let env = val.get("environment")
    if not env.isNil and env.kind == TomlValueKind.Table:
      for k, v in env.tableVal:
        if v.kind == TomlValueKind.String: u.environment[k] = v.stringVal

    if u.uid == 0:
      diags.add err(0, "users." & name & " has no uid")
    elif u.uid < 1000:
      diags.add warn(0, "users." & name & " has uid " & $u.uid &
                     ", below the usual 1000 floor for human accounts")
    if byUid.hasKey(u.uid):
      diags.add err(0, "users." & name & " and users." & byUid[u.uid] &
                    " share uid " & $u.uid)
    else:
      byUid[u.uid] = name

    u.home = parseHome(val, 0, diags)
    checkHomeOverlap(u.home, name, diags)

    # `shadows` names system packages this user deliberately overrides. An
    # entry that the user does not actually provide is a no-op and almost
    # certainly a mistake.
    for s in u.shadows:
      if s notin u.packages:
        diags.add err(0, "users." & name & " shadows '" & s &
                      "' but does not declare it in packages, so there is " &
                      "nothing to shadow the system package with")

    result[name] = u

proc parseSystemConfig*(src, path: string):
    (SystemConfig, seq[Diagnostic]) =
  var cfg = SystemConfig(path: path)
  var diags: seq[Diagnostic]
  cfg.users = initOrderedTable[string, User]()
  cfg.services = initTable[string, bool]()

  var root: TomlValueRef
  try:
    root = parsetoml.parseString(src)
  except CatchableError as e:
    diags.add err(0, "TOML syntax error: " & e.msg)
    return (cfg, diags)

  cfg.schema = root.getInt("schema", 0)

  # These live under [system], which is what docs/configuration.md documents
  # and what the installer writes. They were read from the document root here,
  # so every configuration the installer generated failed validation with
  # "no hostname" — found by running the whole chain end to end for the first
  # time. The root is still accepted, because a config written against the old
  # behaviour should not break on upgrade.
  let sys = root.get("system")
  cfg.hostname = sys.getStr("hostname", root.getStr("hostname"))
  cfg.timezone = sys.getStr("timezone", root.getStr("timezone"))
  cfg.locale = sys.getStr("locale", root.getStr("locale"))

  if cfg.hostname.len == 0:
    diags.add err(0, "no hostname (expected [system] hostname = \"...\")")
  if root.get("local") != nil and root.get("locale") == nil:
    diags.add err(0, "found key 'local'; the key is 'locale'")

  if not sys.isNil:
    cfg.packages = strSeq(sys.get("packages"))
    let pkgTable = sys.get("packages")
    # `[system.packages] include = [...]` is the shape the installer writes;
    # `packages = [...]` is the shorter one. Both are accepted because both
    # appear in the documentation.
    if not pkgTable.isNil and pkgTable.kind == TomlValueKind.Table:
      cfg.packages = strSeq(pkgTable.get("include"))

  let svc = root.get("services")
  if not svc.isNil and svc.kind == TomlValueKind.Table:
    for k, v in svc.tableVal:
      if v.kind == TomlValueKind.Bool: cfg.services[k] = v.boolVal

  cfg.users = parseUsers(root, diags)
  (cfg, diags)
