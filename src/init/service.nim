## The service model, and ordering.
##
## Services are declared, never scripted. A unit that runs a shell script to
## decide what to do is a unit whose behaviour is not knowable from the
## configuration — which defeats the point of a declarative system, and is why
## `ExecStartPre=/bin/sh -c ...` is not reproduced here.
##
## The ordering rules are deliberately smaller than systemd's. systemd separates
## `Requires`/`Wants`/`BindsTo`/`PartOf`/`Requisite` from `After`/`Before`, and
## the fact that a dependency does *not* imply an ordering is the single most
## common source of confusion in systemd units. Here there are two axes and one
## rule connecting them:
##
##   requires  — must be running, and must start first
##   wants     — start it too, but do not fail if it fails, and still order
##   after     — ordering only, no dependency
##
## A `requires` implies an `after`. Making that automatic removes the failure
## mode where a unit declares a dependency, omits the ordering, and works on the
## developer's machine because the race usually resolves the right way.

import std/[algorithm, sets, tables]

type
  RestartPolicy* = enum
    rpNever = "never"
    rpOnFailure = "on-failure"
    rpAlways = "always"

  ReadinessKind* = enum
    rdImmediate = "immediate"   ## running as soon as it is spawned
    rdNotify = "notify"         ## sd_notify READY=1
    rdSocket = "socket"         ## the socket is listening before the process
    rdExit = "exit"             ## a oneshot: ready when it exits cleanly

  Service* = object
    name*: string
    exec*: seq[string]          ## argv, never a shell string
    requires*: seq[string]
    wants*: seq[string]
    after*: seq[string]
    restart*: RestartPolicy
    readiness*: ReadinessKind
    restartSec*: int            ## ms between restarts
    startTimeout*: int          ## ms to become ready before it is a failure
    stopTimeout*: int           ## ms after SIGTERM before SIGKILL
    maxRestarts*: int           ## within restartWindow, before giving up
    restartWindow*: int         ## ms
    oneshot*: bool
    watchdogSec*: int           ## ms between required pings; 0 disables
    tty*: string                ## controlling terminal, e.g. "/dev/tty1"
    selinuxDomain*: string
    cgroup*: string

func defaultService*(name: string): Service =
  Service(name: name, restart: rpOnFailure, readiness: rdImmediate,
          restartSec: 200, startTimeout: 30_000, stopTimeout: 30_000,
          maxRestarts: 5, restartWindow: 60_000)

func orderingDeps*(s: Service): seq[string] =
  ## Everything that must start before this. `requires` implies `after`, so a
  ## unit cannot declare a dependency and accidentally omit the ordering.
  var seen = initHashSet[string]()
  for d in s.requires & s.wants & s.after:
    if d.len > 0 and d notin seen:
      seen.incl d
      result.add d

# --- Dependency resolution ---------------------------------------------------

type
  OrderResult* = object
    order*: seq[string]         ## start order; stop order is its reverse
    cycle*: seq[string]         ## non-empty if the graph has one
    missing*: seq[string]       ## required names with no service

func findMissing*(services: Table[string, Service]): seq[string] =
  ## A `requires` naming a service that does not exist is a configuration
  ## error, caught before anything starts. `wants` and `after` on an absent
  ## name are not: they are how an optional component is expressed.
  var missing: seq[string]
  for name, s in services:
    for dep in s.requires:
      if dep notin services and dep notin missing:
        missing.add dep
  missing.sort()
  missing

func resolveOrder*(services: Table[string, Service]): OrderResult =
  ## Deterministic topological order.
  ##
  ## Ties are broken by name rather than by hash-table order, so the same
  ## configuration produces the same start order on every boot. Without that,
  ## a race that only fires in one ordering appears and disappears across
  ## reboots of an identical machine — which is precisely the kind of bug a
  ## reproducible system exists to eliminate.
  result.missing = findMissing(services)

  var names: seq[string]
  for n in services.keys: names.add n
  names.sort()

  var state = initTable[string, int]()    ## 0 unvisited, 1 in progress, 2 done
  for n in names: state[n] = 0
  var order: seq[string]
  var cycle: seq[string]
  var stack: seq[string]

  proc visit(n: string) =
    if cycle.len > 0: return
    if state.getOrDefault(n, 2) == 2: return
    if state[n] == 1:
      # Report the cycle itself, not just its existence. "there is a cycle"
      # sends the reader hunting; "a -> b -> a" is a fix.
      let at = stack.find(n)
      cycle = stack[(if at >= 0: at else: 0) .. ^1] & n
      return
    state[n] = 1
    stack.add n
    var deps = services[n].orderingDeps()
    deps.sort()
    for d in deps:
      if d in services: visit(d)
    discard stack.pop()
    state[n] = 2
    order.add n

  for n in names: visit(n)

  if cycle.len > 0: result.cycle = cycle
  else: result.order = order

func stopOrder*(startOrder: seq[string]): seq[string] =
  ## The reverse. Stopping in start order tears down a dependency while its
  ## dependants are still using it, which is how a clean shutdown turns into a
  ## cascade of error logs.
  result = startOrder
  result.reverse()

func wouldOrphan*(services: Table[string, Service], stopping: string):
    seq[string] =
  ## Which running services require the one about to stop. Stopping a service
  ## that others require is allowed, but it must be a stated consequence
  ## rather than a discovery.
  var affected: seq[string]
  for name, s in services:
    if stopping in s.requires: affected.add name
  affected.sort()
  affected
