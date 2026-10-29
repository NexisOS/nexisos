## Writing the generation image.
##
## The one place that knows about EROFS, deliberately — see ADR 0007. Today it
## generates a composefs dump and hands it to `mkcomposefs`; when a Nim EROFS
## writer exists, only `writeImage` changes and every test below still applies,
## because they assert what the dump *says* rather than what the tool does with
## it.
##
## The dump is built as data first, exactly as `isolate.nim` plans mounts before
## performing them. That split is what makes the part encoding NexisOS's intent
## testable on a machine with no composefs tooling installed, which is most
## machines.
##
## **The dump format is a compatibility surface with a tool NexisOS does not
## control.** `mkcomposefs` is checked for at startup and its version recorded
## in the generation, so a format change surfaces as a refusal naming the
## version rather than as an image that mounts and is subtly wrong.

import std/[algorithm, os, strutils, tables]
import ../../lib/hashing
import ../../lib/process
import ../../lib/filesystem except EntryKind, ekFile, ekDir, ekSymlink
import ./merge

const
  MkComposefs* = "mkcomposefs"
  KnownGoodVersions* = ["1.0", "1.1"]

type
  DumpLine* = object
    ## One entry in the composefs dump. Kept as a record rather than a string
    ## so the fields can be asserted individually; rendering happens once, at
    ## the end.
    path*: string
    size*: int64
    mode*: int
    kind*: EntryKind
    payload*: string        ## symlink target, or the store object path
    digest*: string         ## content digest, files only
    xattrs*: seq[(string, string)]

  ImageSpec* = object
    lines*: seq[DumpLine]
    objectStore*: string

  ImageResult* = object
    ok*: bool
    digest*: string
    path*: string
    error*: string
    toolVersion*: string

func modeFor*(e: TreeEntry): int =
  ## Permissions are derived, not carried.
  ##
  ## A build output's permission bits are mostly noise — whatever the build
  ## system happened to leave. What matters is the executable bit and the file
  ## type; everything else is a policy decision that belongs in the definition.
  ## Deriving them here means two builds of the same package cannot differ by a
  ## umask.
  case e.kind
  of ekDir: 0o755
  of ekSymlink: 0o777
  of ekFile: (if e.executable: 0o755 else: 0o644)

func objectPathFor*(digest: string): string =
  ## Where composefs finds the content, relative to the object store. Must
  ## match `lib/paths.objectPath` — the two-hex shard and the remainder as
  ## filename — or the image references objects that are not there.
  if digest.len < 3: return digest
  digest[0 .. 1] / digest[2 .. ^1]

func selinuxLabel*(path: string): string =
  ## The label a path carries in the image.
  ##
  ## This is the property composefs was chosen for: xattrs live in the metadata
  ## image, not on the shared inode, so two generations can label the same
  ## object differently. A hardlink farm cannot do this at all.
  ##
  ## The mapping is a placeholder until refpolicy file contexts are compiled in
  ## (Phase 5); it is here so the plumbing carries labels from the start rather
  ## than being retrofitted through every layer later.
  if path.startsWith("usr/bin/") or path.startsWith("usr/sbin/"):
    "system_u:object_r:bin_t:s0"
  elif path.startsWith("usr/lib/"):
    "system_u:object_r:lib_t:s0"
  elif path.startsWith("etc/"):
    "system_u:object_r:etc_t:s0"
  else:
    "system_u:object_r:usr_t:s0"

proc specFor*(m: Merged, objectStore: string): ImageSpec =
  ## Turn a merged tree into the image description.
  ##
  ## Refuses a tree with collisions. `generationFrom` refuses too; both check
  ## because this is the function that produces bytes, and a guard only at the
  ## call site is one the next call site will not have.
  if m.hasCollisions():
    raise newException(ValueError,
      "cannot build an image from a tree with " & $m.collisions.len &
      " unresolved collision(s)")

  result.objectStore = objectStore
  for me in m.entries:
    let e = me.entry
    var line = DumpLine(path: "/" & e.path, mode: modeFor(e), kind: e.kind)
    case e.kind
    of ekDir: discard
    of ekSymlink:
      line.payload = e.target
    of ekFile:
      line.digest = string(e.digest)
      line.payload = objectPathFor(string(e.digest))
    line.xattrs.add ("security.selinux", selinuxLabel(e.path))
    result.lines.add line

  # Sorted by path so the dump — and therefore the image, and therefore the
  # generation seal — is a function of the tree rather than of iteration order.
  result.lines.sort(proc (a, b: DumpLine): int = cmp(a.path, b.path))

func escapeField*(s: string): string =
  ## The dump format is whitespace-separated, so anything that could be
  ## mistaken for a field separator is escaped. A path containing a space is
  ## unusual and entirely legal, and silently splitting it would produce an
  ## image with two wrong entries instead of one right one.
  for c in s:
    case c
    of ' ': result.add "\\x20"
    of '\t': result.add "\\x09"
    of '\n': result.add "\\x0a"
    of '\\': result.add "\\\\"
    else: result.add c

func renderLine*(l: DumpLine): string =
  var fields = @[escapeField(l.path), $l.size, $l.mode]
  case l.kind
  of ekDir: fields.add "dir"
  of ekFile: fields.add "file"
  of ekSymlink: fields.add "symlink"
  fields.add (if l.payload.len > 0: escapeField(l.payload) else: "-")
  fields.add (if l.digest.len > 0: l.digest else: "-")
  for (k, v) in l.xattrs:
    fields.add escapeField(k) & "=" & escapeField(v)
  fields.join(" ")

func render*(spec: ImageSpec): string =
  for l in spec.lines: result.add l.renderLine() & "\n"

func specDigest*(spec: ImageSpec): string =
  ## A digest of the description, not of the resulting image.
  ##
  ## Useful on its own: two machines producing the same spec will produce the
  ## same image, so a mismatch here localises the fault to composition rather
  ## than to the writer.
  string(sha256(spec.render()))

# --- Invoking the writer -----------------------------------------------------

proc toolVersion*(): string =
  let r = exec(MkComposefs, ["--version"])
  if r.code != 0: return ""
  for token in r.output.splitWhitespace():
    if token.len > 0 and token[0] in {'0'..'9'}: return token
  r.output.strip()

proc toolAvailable*(): (bool, string) =
  if which(MkComposefs).len == 0:
    return (false, MkComposefs & " is not installed; see ADR 0007")
  let v = toolVersion()
  if v.len == 0:
    return (false, MkComposefs & " did not report a version")
  var known = false
  for k in KnownGoodVersions:
    if v.startsWith(k): known = true
  if not known:
    # A warning, not a refusal. Refusing on an unrecognised version would make
    # every upgrade of the tool a broken build; proceeding silently would make
    # a format change look like corruption. Naming it is the middle path.
    return (true, MkComposefs & " " & v & " is untested with NexisOS (known: " &
                  KnownGoodVersions.join(", ") & ")")
  (true, "")

proc writeImage*(spec: ImageSpec, output: string): ImageResult =
  ## Generate the dump and run the writer.
  ##
  ## The dump goes to a file rather than a pipe so it survives a failure and
  ## can be read: "mkcomposefs exited 1" is not debuggable, and the dump is
  ## the only artifact that says what NexisOS asked for.
  let (available, note) = toolAvailable()
  result.toolVersion = toolVersion()
  if not available:
    result.error = note
    return

  let dumpPath = output & ".dump"
  try:
    writeAtomic(dumpPath, spec.render())
  except CatchableError as e:
    result.error = "cannot write " & dumpPath & ": " & e.msg
    return

  let r = exec(MkComposefs, ["--from-file", dumpPath,
                             "--digest-store", spec.objectStore, output])
  if r.code != 0:
    result.error = MkComposefs & " exited " & $r.code & "\n" & r.output &
                   "\nThe dump it was given is at " & dumpPath
    return

  removeFile(dumpPath)
  result.ok = true
  result.path = output
  try:
    result.digest = string(hashFile(output))
  except CatchableError:
    result.error = "image written but could not be hashed"
    result.ok = false
