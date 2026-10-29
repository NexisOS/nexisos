## Network state.
##
## There is no network *step*, deliberately. A NexisOS install does not need
## one: the ISO carries a store with everything generation 1 needs, so the
## machine can be installed on a bench with no cable in it. Adding a step that
## most users would page past teaches them to page past steps.
##
## What the installer does need is to *know* the link state, so it can say so
## on the review page and warn honestly before a build that will try to fetch
## sources it does not have.

import std/[os, strutils, algorithm]

type
  LinkState* = enum
    lsUnknown
    lsDown
    lsUp

  Link* = object
    name*: string
    state*: LinkState
    wireless*: bool

const SysClassNet = "/sys/class/net"

func parseOperstate*(s: string): LinkState =
  case s.strip().toLowerAscii()
  of "up": lsUp
  of "down", "lowerlayerdown": lsDown
  else: lsUnknown

func isLoopback*(name: string): bool = name == "lo"

proc readLinks*(root = SysClassNet): seq[Link] =
  ## Read straight from sysfs rather than shelling out to `ip`. One fewer
  ## binary the ISO has to carry on the fallback path, and no output format to
  ## parse that changes between iproute2 versions.
  if not dirExists(root): return @[]
  var names: seq[string]
  for kind, path in walkDir(root):
    let n = path.extractFilename
    if isLoopback(n): continue
    names.add n
  names.sort()
  for n in names:
    var l = Link(name: n, state: lsUnknown)
    try:
      l.state = parseOperstate(readFile(root / n / "operstate"))
    except IOError, OSError:
      discard
    l.wireless = dirExists(root / n / "wireless") or
                 dirExists(root / n / "phy80211")
    result.add l

func anyUp*(links: seq[Link]): bool =
  for l in links:
    if l.state == lsUp: return true
  false

func summary*(links: seq[Link]): string =
  ## One line for the review page.
  if links.len == 0: return "no interfaces detected"
  var up: seq[string]
  for l in links:
    if l.state == lsUp: up.add l.name
  if up.len == 0:
    return $links.len & " interface(s), none up - offline install"
  "up: " & up.join(", ")

func offlineWarning*(links: seq[Link]): seq[string] =
  ## Shown on the review page only when it applies. A warning that is always
  ## present is furniture, and gets read as furniture.
  if anyUp(links): return @[]
  @[
    "No network link is up. The install itself does not need one: everything",
    "generation 1 requires is on this medium. Anything you add afterwards",
    "that must be fetched will fail until the machine is connected.",
  ]
