## Boot entries.
##
## One entry per generation, so the bootloader menu *is* the generation list.
## That is the property worth having: a machine that will not boot can be
## recovered from the boot menu without a rescue USB, by someone who does not
## know what NexisOS is.
##
## Boot Loader Specification (BLS) type 1 entries, because they are plain files
## in a directory that every modern bootloader reads — systemd-boot, GRUB with
## blscfg, and rEFInd. Writing a GRUB config instead would mean regenerating
## one file on every change, and a partially-written `grub.cfg` is an
## unbootable machine. A directory of independent files has no such state: a
## half-written entry is one bad menu item next to the good ones.
##
## The ordering rule from `activate.nim` applies here concretely: entries are
## written and fsynced *before* the default is changed, so a power cut between
## the two leaves a bootable machine on the old generation.

import std/[algorithm, os, strutils]
import ../../lib/[filesystem, errors]
import ./generation

const
  EntriesDir* = "/boot/loader/entries"
  LoaderConf* = "/boot/loader/loader.conf"
  MaxEntries* = 20

type
  BootEntry* = object
    id*: GenerationId
    title*: string
    version*: string
    linux*: string           ## path relative to the ESP
    initrd*: string
    options*: seq[string]
    machineId*: string

func entryFileName*(id: GenerationId, machineId: string): string =
  ## `<machine-id>-nexis-<n>.conf`. The machine id prefix is the BLS
  ## convention and it matters on a shared ESP: two installations otherwise
  ## overwrite each other's entries, and the second one silently wins.
  (if machineId.len > 0: machineId else: "nexis") & "-nexis-" & $id & ".conf"

func kernelOptions*(g: Generation, root: string, extra: seq[string] = @[]):
    seq[string] =
  ## The command line for a generation.
  ##
  ## `nexis.generation=` is what the initramfs reads to know which image to
  ## mount, and it is why every entry can point at the same kernel and still
  ## boot a different system. Without it the entries would be indistinguishable
  ## and a rollback would have nothing to select.
  result.add "root=" & root
  result.add "nexis.generation=" & $g.id
  result.add "rw"
  # Both consoles, for the same reason the ISO lists both: a headless machine
  # has no other path, and a serial log is the only way to debug a boot that
  # fails before userspace.
  result.add "console=tty1"
  result.add "console=ttyS0,115200n8"
  for e in extra: result.add e

func entryFor*(g: Generation, root, machineId: string,
               extra: seq[string] = @[]): BootEntry =
  BootEntry(id: g.id, machineId: machineId,
            title: "NexisOS generation " & $g.id &
                   (if g.label.len > 0: " (" & g.label & ")" else: ""),
            version: $g.id,
            linux: "/" & g.kernel.lastPathPart,
            initrd: "/" & g.initramfs.lastPathPart,
            options: kernelOptions(g, root, extra))

func render*(e: BootEntry): string =
  ## BLS is key-value, one per line. `sort-key` is what orders the menu; it is
  ## zero-padded so entry 10 does not sort before entry 9 — the same numeric
  ## sorting bug that would put a rollback list in the wrong order.
  result.add "title      " & e.title & "\n"
  result.add "version    " & e.version & "\n"
  result.add "sort-key   nexis-" & align($e.id, 6, '0') & "\n"
  result.add "linux      " & e.linux & "\n"
  result.add "initrd     " & e.initrd & "\n"
  result.add "options    " & e.options.join(" ") & "\n"

# --- Writing -----------------------------------------------------------------

proc writeEntry*(e: BootEntry, dir = EntriesDir) =
  ## Written atomically and fsynced. An entry that exists must be complete:
  ## the bootloader reads this directory with no way to tell a truncated file
  ## from a valid one, and a truncated entry is a menu item that fails at the
  ## worst possible moment.
  try:
    createDir(dir)
    writeAtomic(dir / entryFileName(e.id, e.machineId), e.render())
  except CatchableError as err:
    raiseNexis(ekIo, "cannot write the boot entry for generation " & $e.id,
               hint = err.msg)

proc listEntries*(machineId: string, dir = EntriesDir): seq[GenerationId] =
  ## Generations that have a boot entry, sorted numerically.
  if not dirExists(dir): return
  let prefix = (if machineId.len > 0: machineId else: "nexis") & "-nexis-"
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.lastPathPart
    if not name.startsWith(prefix) or not name.endsWith(".conf"): continue
    let mid = name[prefix.len ..< name.len - 5]
    try: result.add parseInt(mid)
    except ValueError: discard
  result.sort()

proc setDefault*(id: GenerationId, machineId: string,
                 conf = LoaderConf) =
  ## Point the bootloader at a generation.
  ##
  ## This is the last step of an activation and the first step of a rollback,
  ## and it is the only one that changes what happens on the next boot. Every
  ## entry is already on disk before this runs, so the worst outcome of a
  ## failure here is that the machine boots the previous generation — which is
  ## a working system, not a broken one.
  var lines: seq[string]
  if fileExists(conf):
    try:
      for line in readFile(conf).splitLines():
        if not line.strip().startsWith("default"): lines.add line
    except CatchableError: discard
  else:
    lines.add "timeout 5"
  lines.add "default " & entryFileName(id, machineId)
  var text = ""
  for l in lines:
    if l.len > 0 or text.len > 0: text.add l & "\n"
  writeAtomic(conf, text)

proc pruneEntries*(keep: seq[GenerationId], machineId: string,
                   dir = EntriesDir): int =
  ## Remove entries for generations that no longer exist.
  ##
  ## A menu item pointing at a collected generation boots to a kernel panic,
  ## which looks to a user like the machine is broken rather than like a stale
  ## menu entry. Pruning is therefore part of collection, not housekeeping.
  for id in listEntries(machineId, dir):
    if id in keep: continue
    try:
      removeFile(dir / entryFileName(id, machineId))
      inc result
    except CatchableError: discard

func entriesOverLimit*(existing: seq[GenerationId], limit = MaxEntries):
    seq[GenerationId] =
  ## Which entries to drop when the menu grows past the limit, oldest first.
  ##
  ## A bootloader menu with two hundred entries is not a feature — the newest
  ## and the last-known-good are what anyone uses, and everything between them
  ## makes those two harder to find.
  if existing.len <= limit: return
  var sorted = existing
  sorted.sort()
  sorted[0 ..< existing.len - limit]
