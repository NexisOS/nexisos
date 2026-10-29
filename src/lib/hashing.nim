## Hashing primitives. Every identity in NexisOS bottoms out here.
##
## Three levels:
##   sha256      raw bytes
##   hashFields  a tuple of strings, length-prefixed
##   hashTree    a directory tree, canonicalised
##
## `hashFields` is length-prefixed rather than separator-joined because
## concatenating raw strings lets ("ab", "c") and ("a", "bc") collide, and for
## a build identity that means two different packages sharing a cache entry. A
## separator character only moves the problem to inputs containing it.

import std/[algorithm, os, strutils]
import checksums/sha2

type
  Digest* = distinct string   ## lowercase hex

func `$`*(d: Digest): string {.borrow.}
func `==`*(a, b: Digest): bool {.borrow.}
func len*(d: Digest): int {.borrow.}

func isValid*(d: Digest): bool =
  d.string.len == 64 and d.string.allCharsInSet({'0'..'9', 'a'..'f'})

func toHex(s: ShaDigest_256): string =
  for c in s: result.add toHex(c.ord, 2).toLowerAscii()

proc sha256*(data: string): Digest =
  var ctx = initSha_256()
  if data.len > 0: ctx.update(data.toOpenArray(0, data.high))
  Digest(toHex(ctx.digest()))

proc hashFields*(parts: varargs[string]): Digest =
  var ctx = initSha_256()
  for p in parts:
    let prefix = $p.len & ":"
    ctx.update(prefix.toOpenArray(0, prefix.high))
    if p.len > 0: ctx.update(p.toOpenArray(0, p.high))
  Digest(toHex(ctx.digest()))

proc hashFile*(path: string): Digest =
  ## Streamed, because artifacts include things like a 400 MB Firefox binary
  ## and reading those whole is a needless resident-memory spike.
  var ctx = initSha_256()
  var f: File
  if not f.open(path, fmRead):
    raise newException(IOError, "cannot open " & path)
  defer: f.close()
  var buf = newString(64 * 1024)
  while true:
    let n = f.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    ctx.update(buf.toOpenArray(0, n - 1))
  Digest(toHex(ctx.digest()))

type
  EntryKind* = enum
    ekFile, ekDir, ekSymlink

  TreeEntry* = object
    path*: string        ## relative to the tree root, forward slashes
    kind*: EntryKind
    executable*: bool
    target*: string      ## symlink target
    digest*: Digest      ## content digest, files only

proc modeOf(path: string): bool =
  ## Only the executable bit is preserved. Everything else about a build
  ## output's permissions is either derivable or noise: read bits are always
  ## set, setuid is a security decision that belongs in the definition rather
  ## than in whatever the build system happened to do, and group/other write
  ## is never wanted.
  try:
    fpUserExec in getFilePermissions(path)
  except OSError:
    false

proc walkTree*(root: string): seq[TreeEntry] =
  ## Deterministic depth-first walk, sorted by path at every level. Directory
  ## order from the filesystem is arbitrary and varies between filesystems, so
  ## sorting is what makes the tree hash reproducible at all.
  var stack = @[""]
  var entries: seq[TreeEntry]

  while stack.len > 0:
    let rel = stack.pop()
    let abs = if rel.len == 0: root else: root / rel
    var kids: seq[tuple[kind: PathComponent, path: string]]
    for kind, path in walkDir(abs, relative = true):
      kids.add (kind, path)
    kids.sort(proc (a, b: auto): int = cmp(a.path, b.path))

    for (kind, name) in kids:
      let childRel = if rel.len == 0: name else: rel & "/" & name
      let childAbs = root / childRel
      case kind
      of pcFile:
        entries.add TreeEntry(path: childRel, kind: ekFile,
                              executable: modeOf(childAbs),
                              digest: hashFile(childAbs))
      of pcDir:
        entries.add TreeEntry(path: childRel, kind: ekDir)
        stack.add childRel
      of pcLinkToFile, pcLinkToDir:
        var target = ""
        try: target = expandSymlink(childAbs)
        except OSError: target = ""
        entries.add TreeEntry(path: childRel, kind: ekSymlink, target: target)

  entries.sort(proc (a, b: TreeEntry): int = cmp(a.path, b.path))
  entries

const NeedsEscape = {' ', '%', '\n', '\r', '\t'}

func encodeField*(s: string): string =
  ## Percent-encodes the characters that would make a manifest line ambiguous.
  ## Artifact paths legitimately contain spaces (`/usr/share/fonts/Some
  ## Font.ttf`), and a symlink line has both a target and a path, so a
  ## space-separated format without escaping cannot be parsed back reliably.
  ## Everything else is left alone, so the common line stays readable.
  for c in s:
    if c in NeedsEscape or c.ord < 0x20:
      result.add "%" & toHex(c.ord, 2).toUpperAscii()
    else:
      result.add c

func decodeField*(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add char(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError:
        discard
    result.add s[i]
    inc i

func manifestLine*(e: TreeEntry): string =
  ## One canonical line per entry. Text rather than a binary format so a
  ## corrupt artifact can be diffed by a human at 3am.
  ##
  ##   f <mode> <digest> <path>
  ##   d <mode> <path>
  ##   l <target> <path>
  ##
  ## Paths and targets are percent-encoded, so every line splits on spaces
  ## into a fixed number of fields.
  case e.kind
  of ekFile: "f " & (if e.executable: "755" else: "644") & " " &
             e.digest.string & " " & encodeField(e.path)
  of ekDir: "d 755 " & encodeField(e.path)
  of ekSymlink: "l " & encodeField(e.target) & " " & encodeField(e.path)

func renderManifest*(entries: seq[TreeEntry]): string =
  for e in entries:
    result.add manifestLine(e) & "\n"

proc hashTree*(root: string): Digest =
  ## The artifact identity: a hash of the canonical manifest, which carries no
  ## timestamps, no uid/gid and no permission bits beyond executable. Two
  ## builds that differ only in when they ran hash identically, which is the
  ## entire point.
  sha256(renderManifest(walkTree(root)))
