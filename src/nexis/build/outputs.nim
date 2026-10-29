## Assigning built files to package outputs.
##
## Patterns are matched in `outputs` declaration order and the first match
## wins, so overlap is legal and ordering carries the intent. A file matching
## no pattern is a build error rather than a silent drop: that is how an
## upstream which started installing somewhere new gets noticed, instead of
## the file quietly vanishing from the package.

import std/[strutils, tables]
import ../package/[types, glob]
import ../../lib/hashing

type
  Assignment* = object
    output*: string
    entries*: seq[TreeEntry]

  SplitResult* = object
    assignments*: OrderedTable[string, seq[TreeEntry]]
    unmatched*: seq[string]
    empty*: seq[string]      ## declared outputs that received nothing

proc splitOutputs*(d: Definition, entries: seq[TreeEntry],
                   activeOutputs: seq[string]): SplitResult =
  result.assignments = initOrderedTable[string, seq[TreeEntry]]()
  for name in activeOutputs:
    result.assignments[name] = @[]

  for e in entries:
    # Directories are recreated by whichever output owns their contents, so
    # they are not assigned on their own. A directory that ends up empty in
    # every output simply does not appear, which is correct.
    if e.kind == ekDir: continue

    let absolute = if e.path.startsWith("/"): e.path else: "/" & e.path
    var placed = false
    for name in activeOutputs:
      if name notin d.output: continue
      for pat in d.output[name].paths:
        if matches(pat, absolute):
          result.assignments[name].add e
          placed = true
          break
      if placed: break
    if not placed:
      result.unmatched.add absolute

  for name in activeOutputs:
    if result.assignments.getOrDefault(name, @[]).len == 0:
      result.empty.add name

proc explain*(d: Definition, path: string,
              activeOutputs: seq[string]): tuple[output, pattern: string] =
  ## Which output claims a path, and which pattern put it there. Backs
  ## `nexis owns`, and is what makes an overlap warning actionable.
  let absolute = if path.startsWith("/"): path else: "/" & path
  for name in activeOutputs:
    if name notin d.output: continue
    for pat in d.output[name].paths:
      if matches(pat, absolute):
        return (name, pat)
  ("", "")

proc renderSplit*(r: SplitResult): string =
  for name, entries in r.assignments:
    var bytes = 0
    result.add name & ": " & $entries.len & " files\n"
    discard bytes
  if r.unmatched.len > 0:
    result.add "unmatched: " & $r.unmatched.len & " files\n"
