## Store layout and path safety.
##
## /store/
##   objects/<ab>/<digest>        individual file contents, deduplicated
##   manifests/<ab>/<digest>      canonical tree descriptions
##   tmp/                         staging for atomic inserts
##   build/                       build sandboxes, never referenced after
##
## Two levels rather than one because composefs needs *files* content-
## addressed — a generation's metadata image redirects per-file into
## `objects/` — while packages produce *trees*. A manifest names a tree by
## listing the objects it is made of, so two packages containing an identical
## file share one object, and two generations containing an identical package
## share every object in it.
##
## Sharding by the first two hex characters keeps directory sizes reasonable;
## a flat objects/ with a million entries is slow to list on every filesystem
## worth supporting.

import std/[os, strutils]
import ./hashing

const DefaultStoreRoot* = "/store"

type Store* = object
  root*: string

func objectsDir*(s: Store): string = s.root / "objects"
func manifestsDir*(s: Store): string = s.root / "manifests"
func tmpDir*(s: Store): string = s.root / "tmp"
func buildDir*(s: Store): string = s.root / "build"

## Two hex characters of shard, and the *remainder* as the filename.
##
## Two rather than one or three: 256 buckets keeps a million-object store at
## roughly four thousand entries per directory, which every filesystem handles
## without a linear scan. One bucket level of 16 would be sixteen times worse;
## three would be 4096 mostly-empty directories and a wasted inode each.
##
## The remainder rather than the full digest is not cosmetic. It is the layout
## composefs expects for a `--digest-store`, so a generation image can use the
## object store directly as its data-only lower layer instead of NexisOS
## maintaining a second parallel tree. Getting this right costs nothing now and
## would be a migration later.
func shard*(d: Digest): string = d.string[0 .. 1]
func shardRest*(d: Digest): string = d.string[2 .. ^1]

func objectPath*(s: Store, d: Digest): string =
  s.objectsDir / shard(d) / shardRest(d)

func manifestPath*(s: Store, d: Digest): string =
  s.manifestsDir / shard(d) / shardRest(d)

func isSafeRelPath*(p: string): bool =
  ## Rejects anything that could escape a tree root when a manifest is
  ## materialised. Manifests come from build outputs and, once import tooling
  ## exists, from foreign packaging, so this is a trust boundary rather than a
  ## sanity check.
  if p.len == 0: return false
  if p.startsWith("/") or p.startsWith("\\"): return false
  if p.len >= 2 and p[1] == ':': return false
  for part in p.split('/'):
    if part.len == 0: return false
    if part == "." or part == "..": return false
  true

func isSafeSymlinkTarget*(target, fromPath: string): bool =
  ## A symlink inside an artifact may point within the artifact or at an
  ## absolute FHS path (which resolves inside the generation once merged). It
  ## may not climb out of the artifact with `..`.
  if target.len == 0: return false
  if target.startsWith("/"): return true
  var depth = fromPath.count('/')
  for part in target.split('/'):
    if part == "..":
      dec depth
      if depth < 0: return false
    elif part.len > 0 and part != ".":
      inc depth
  true
