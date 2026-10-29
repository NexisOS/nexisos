## Filesystem operations, with the atomicity the store depends on.
##
## The store's central promise is that an object under its final name is
## complete. A crash mid-write must leave a stray temp file and nothing else —
## never a half-written object under a name claiming to be finished, which
## would poison every later lookup and stay invisible until the artifact was
## used. That promise is `writeAtomic` here, and everything else in the store
## rests on it.
##
## The subtlety is that `rename(2)` being atomic is not sufficient. Rename
## makes the *name* appear atomically; it says nothing about the data having
## reached the disk. After a power loss the name can exist pointing at a file
## of zeros. So the sequence is: write, fsync the file, rename, fsync the
## directory.

import std/[os, posix, algorithm, strutils]
import ./errors

# --- Atomic writes -----------------------------------------------------------

proc fsyncPath(path: string, isDir = false) =
  let flags = if isDir: O_RDONLY else: O_WRONLY
  let fd = open(path.cstring, flags)
  if fd < 0: return          ## best effort; the rename already happened
  discard fsync(fd)
  discard close(fd)

proc writeAtomic*(path, content: string, permissions: set[FilePermission] = {}) =
  ## Write via a temp file in the *same directory*, so the rename cannot cross
  ## a filesystem boundary and silently degrade into a copy.
  let dir = path.parentDir
  let tmp = dir / ("." & path.extractFilename & ".tmp." & $getCurrentProcessId())
  try:
    # Inside the try: creating the parent is as likely to fail as writing, and
    # letting a raw OSError escape from here would bypass the error kind the
    # CLI maps to an exit code.
    if dir.len > 0: createDir(dir)
    writeFile(tmp, content)
    if permissions.len > 0: setFilePermissions(tmp, permissions)
    fsyncPath(tmp)
    moveFile(tmp, path)
    if dir.len > 0: fsyncPath(dir, isDir = true)
  except OSError, IOError:
    try: removeFile(tmp)
    except CatchableError: discard
    raiseNexis(ekIo, "cannot write " & path,
               hint = "check permissions and free space on " & dir)

proc appendSync*(path, line: string) =
  ## Append and flush. The store index is an append-only log, so a torn tail
  ## from a crash must truncate rather than be silently misread — the CRC in
  ## the record catches that, but only if the bytes actually reached the disk.
  let dir = path.parentDir
  var f: File
  try:
    if dir.len > 0: createDir(dir)
  except OSError as e:
    raiseNexis(ekIo, "cannot create " & dir & ": " & e.msg)
  if not f.open(path, fmAppend):
    raiseNexis(ekIo, "cannot append to " & path)
  try:
    f.write(line)
    if not line.endsWith("\n"): f.write("\n")
    f.flushFile()
    discard fsync(f.getFileHandle())
  finally:
    f.close()

# --- Trees -------------------------------------------------------------------

type
  EntryKind* = enum
    ekFile
    ekDir
    ekSymlink

  WalkEntry* = object
    path*: string          ## relative to the walk root, always '/'-separated
    kind*: EntryKind
    executable*: bool
    target*: string        ## symlink target, when kind is ekSymlink
    size*: int64

proc walkTree*(root: string): seq[WalkEntry] =
  ## Every entry under `root`, sorted, with paths relative to it.
  ##
  ## Sorted because the result feeds a manifest, and a manifest whose order
  ## depends on directory iteration order is not reproducible — two machines
  ## with the same files would compute different digests. Symlinks are recorded
  ## by target and never followed: following them would let a build output
  ## smuggle in host files, and would loop.
  var out0: seq[WalkEntry]

  proc rec(dir, prefix: string) =
    var names: seq[string]
    for kind, path in walkDir(dir):
      names.add path.extractFilename
    names.sort()
    for name in names:
      let full = dir / name
      let rel = if prefix.len == 0: name else: prefix & "/" & name
      var st: Stat
      if lstat(full.cstring, st) != 0: continue
      if S_ISLNK(st.st_mode):
        out0.add WalkEntry(path: rel, kind: ekSymlink,
                           target: expandSymlink(full))
      elif S_ISDIR(st.st_mode):
        out0.add WalkEntry(path: rel, kind: ekDir)
        rec(full, rel)
      elif S_ISREG(st.st_mode):
        out0.add WalkEntry(path: rel, kind: ekFile,
                           executable: (st.st_mode.uint32 and 0o111) != 0,
                           size: st.st_size.int64)
      # Sockets, fifos and devices are skipped deliberately. A build that
      # produces one has produced something unreproducible, and copying it
      # into an artifact would be worse than dropping it.

  if not dirExists(root):
    raiseNexis(ekIo, "not a directory: " & root)
  rec(root, "")
  out0

proc copyTree*(src, dst: string) =
  ## Copy preserving symlinks and the executable bit. Used to stage build
  ## outputs; the store itself never copies, it links.
  createDir(dst)
  for e in walkTree(src):
    let target = dst / e.path
    case e.kind
    of ekDir: createDir(target)
    of ekSymlink:
      createDir(target.parentDir)
      createSymlink(e.target, target)
    of ekFile:
      createDir(target.parentDir)
      copyFile(src / e.path, target)
      if e.executable:
        setFilePermissions(target, {fpUserRead, fpUserWrite, fpUserExec,
                                    fpGroupRead, fpGroupExec,
                                    fpOthersRead, fpOthersExec})

proc removeTree*(path: string) =
  ## Remove, tolerating absence. Cleanup paths run after failures, where the
  ## thing being cleaned up may never have been created.
  if not (dirExists(path) or fileExists(path) or symlinkExists(path)): return
  try:
    if dirExists(path) and not symlinkExists(path): removeDir(path)
    else: removeFile(path)
  except OSError as e:
    raiseNexis(ekIo, "cannot remove " & path & ": " & e.msg)

# --- Space and staging -------------------------------------------------------

proc freeBytes*(path: string): int64 =
  ## Free space on the filesystem holding `path`, or -1 if it cannot be
  ## determined. Checked before a build rather than discovered halfway through
  ## one: ENOSPC partway into a generation leaves a mess that costs more to
  ## clean up than the check costs to run.
  var s: Statvfs
  if statvfs(path.cstring, s) != 0: return -1
  int64(s.f_bavail) * int64(s.f_frsize)

proc requireSpace*(path: string, needed: int64) =
  let free = freeBytes(path)
  if free >= 0 and free < needed:
    raiseNexis(ekIo,
               "not enough space on " & path & ": need " & $needed &
               " bytes, have " & $free)

proc makeStagingDir*(parent, prefix: string): string =
  ## A uniquely named directory under `parent`. Unique by pid and a counter
  ## rather than by time, because two processes starting in the same
  ## millisecond is exactly the case a store has to survive.
  createDir(parent)
  var n = 0
  while true:
    let candidate = parent / (prefix & "-" & $getCurrentProcessId() & "-" & $n)
    if not dirExists(candidate):
      createDir(candidate)
      return candidate
    inc n
    if n > 10000:
      raiseNexis(ekIo, "cannot create a staging directory under " & parent)

proc isSameFilesystem*(a, b: string): bool =
  ## Whether a rename between these two would be atomic or a copy. The store
  ## stages inside itself precisely so this is always true; this exists so the
  ## assumption can be asserted rather than assumed.
  var sa, sb: Stat
  if stat(a.cstring, sa) != 0: return false
  if stat(b.cstring, sb) != 0: return false
  sa.st_dev == sb.st_dev
