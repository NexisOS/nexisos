## Glob matching for output path assignment.
##
## `**` is special only as a complete path segment, where it matches zero or
## more segments. Within a segment, `*` matches any run of non-`/` characters
## and `?` matches exactly one.
##
## `intersects` decides whether two patterns can ever match the same path. It
## is an exact emptiness test on the intersection, not an approximation, which
## is what makes the overlap diagnostic trustworthy enough to show a user.

import std/strutils

proc segIntersects(a, b: string): bool =
  ## Can a single path segment match both patterns?
  if a.len == 0 and b.len == 0: return true
  if a.len == 0: return b.allCharsInSet({'*'})
  if b.len == 0: return a.allCharsInSet({'*'})
  if a[0] == '*':
    return segIntersects(a[1 .. ^1], b) or segIntersects(a, b[1 .. ^1])
  if b[0] == '*':
    return segIntersects(a, b[1 .. ^1]) or segIntersects(a[1 .. ^1], b)
  if a[0] == '?' or b[0] == '?':
    return segIntersects(a[1 .. ^1], b[1 .. ^1])
  return a[0] == b[0] and segIntersects(a[1 .. ^1], b[1 .. ^1])

proc segMatches(pat, s: string): bool =
  if pat.len == 0: return s.len == 0
  if pat[0] == '*':
    return segMatches(pat[1 .. ^1], s) or
           (s.len > 0 and segMatches(pat, s[1 .. ^1]))
  if s.len == 0: return false
  if pat[0] == '?': return segMatches(pat[1 .. ^1], s[1 .. ^1])
  return pat[0] == s[0] and segMatches(pat[1 .. ^1], s[1 .. ^1])

proc split*(path: string): seq[string] =
  result = @[]
  for part in path.split('/'):
    if part.len > 0: result.add part

proc matchSegs(pat, s: seq[string]): bool =
  if pat.len == 0: return s.len == 0
  if pat[0] == "**":
    # zero or more segments
    if matchSegs(pat[1 .. ^1], s): return true
    return s.len > 0 and matchSegs(pat, s[1 .. ^1])
  if s.len == 0: return false
  return segMatches(pat[0], s[0]) and matchSegs(pat[1 .. ^1], s[1 .. ^1])

proc matches*(pattern, path: string): bool =
  ## Does `path` match `pattern`?
  matchSegs(split(pattern), split(path))

proc intersectSegs(a, b: seq[string]): bool =
  if a.len == 0 and b.len == 0: return true
  if a.len == 0:
    for s in b:
      if s != "**": return false
    return true
  if b.len == 0:
    for s in a:
      if s != "**": return false
    return true
  if a[0] == "**":
    return intersectSegs(a[1 .. ^1], b) or intersectSegs(a, b[1 .. ^1])
  if b[0] == "**":
    return intersectSegs(a, b[1 .. ^1]) or intersectSegs(a[1 .. ^1], b)
  return segIntersects(a[0], b[0]) and intersectSegs(a[1 .. ^1], b[1 .. ^1])

proc intersects*(a, b: string): bool =
  ## Is there any path matched by both patterns?
  intersectSegs(split(a), split(b))
