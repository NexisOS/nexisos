## Turning a builder plus its overrides into concrete argv lists.
##
## Phases are argv arrays, never shell strings. Substitution uses `@name@`
## rather than `$name` deliberately: `$` invites the assumption that a shell
## is expanding it, and there is no shell here. An unsubstituted `@...@` left
## in a resolved phase is an error rather than a literal, because silently
## passing `@out@` to `make install` produces a directory with that name.
##
## The resolved argv — not the declared overrides — is what enters the build
## identity. That distinction matters: if the default flags for `autotools`
## change in a NexisOS release, every autotools package must rebuild, and
## hashing only the *declared* overrides would miss that entirely and serve
## stale artifacts from cache.

import std/[strutils, tables]
import ../package/types

# PhaseName and Builder are part of this module's public interface — a caller
# holding a ResolvedPhase needs them. Re-exported so importing ./phases is
# sufficient, rather than every consumer also importing ../package/types and
# discovering that only when it fails to compile.
export types

type
  BuildVars* = object
    destDir*: string     ## staging root that `make install` writes into
    prefix*: string      ## install prefix inside the destdir, normally /usr
    srcDir*: string      ## unpacked source root
    buildDir*: string    ## out-of-tree build directory
    jobs*: int

  ResolvedPhase* = object
    name*: PhaseName
    argv*: seq[seq[string]]
    skipped*: bool

  PhaseError* = object of CatchableError

func defaultVars*(): BuildVars =
  BuildVars(destDir: "/build/dest", prefix: "/usr", srcDir: "/build/src",
            buildDir: "/build/build", jobs: 1)

## ---------------------------------------------------------------------------
## Builder defaults
##
## Flags here are chosen for reproducibility as much as for correctness:
## `--offline` and `--locked` for cargo so a build cannot reach the network or
## silently resolve a different dependency; `-trimpath` for go so absolute
## build paths do not end up embedded in the binary.
## ---------------------------------------------------------------------------

func defaultPhases*(b: Builder): Table[PhaseName, seq[seq[string]]] =
  result = initTable[PhaseName, seq[seq[string]]]()
  case b
  of bAutotools:
    result[phConfigure] = @[@["./configure", "--prefix=@prefix@"]]
    result[phBuild] = @[@["make", "-j@jobs@"]]
    result[phCheck] = @[@["make", "check"]]
    result[phInstall] = @[@["make", "DESTDIR=@dest@", "install"]]
  of bCMake:
    result[phConfigure] = @[@["cmake", "-S", "@src@", "-B", "@build@",
                              "-DCMAKE_INSTALL_PREFIX=@prefix@",
                              "-DCMAKE_BUILD_TYPE=Release"]]
    result[phBuild] = @[@["cmake", "--build", "@build@", "-j", "@jobs@"]]
    result[phCheck] = @[@["ctest", "--test-dir", "@build@"]]
    result[phInstall] = @[@["cmake", "--install", "@build@"]]
  of bMeson:
    result[phConfigure] = @[@["meson", "setup", "@build@", "@src@",
                              "--prefix=@prefix@", "--buildtype=release"]]
    result[phBuild] = @[@["meson", "compile", "-C", "@build@", "-j", "@jobs@"]]
    result[phCheck] = @[@["meson", "test", "-C", "@build@"]]
    result[phInstall] = @[@["meson", "install", "-C", "@build@",
                            "--destdir", "@dest@"]]
  of bMake:
    result[phBuild] = @[@["make", "-j@jobs@"]]
    result[phCheck] = @[@["make", "check"]]
    result[phInstall] = @[@["make", "DESTDIR=@dest@", "PREFIX=@prefix@",
                            "install"]]
  of bCargo:
    result[phBuild] = @[@["cargo", "build", "--release", "--offline",
                          "--locked"]]
    result[phCheck] = @[@["cargo", "test", "--release", "--offline",
                          "--locked"]]
    result[phInstall] = @[@["cargo", "install", "--path", ".", "--offline",
                            "--locked", "--root", "@dest@@prefix@"]]
  of bGo:
    result[phBuild] = @[@["go", "build", "-trimpath", "-mod=readonly",
                          "./..."]]
    result[phCheck] = @[@["go", "test", "-mod=readonly", "./..."]]
  of bScript:
    discard   ## no defaults; every phase must be replaced or skipped

## ---------------------------------------------------------------------------
## Substitution
## ---------------------------------------------------------------------------

func substitute*(arg: string, v: BuildVars): string =
  result = arg
  result = result.replace("@dest@", v.destDir)
  result = result.replace("@prefix@", v.prefix)
  result = result.replace("@src@", v.srcDir)
  result = result.replace("@build@", v.buildDir)
  result = result.replace("@jobs@", $v.jobs)

func unresolvedPlaceholder*(arg: string): string =
  ## Returns the first `@name@` left in an argument, or "".
  var i = 0
  while i < arg.len:
    if arg[i] == '@':
      let close = arg.find('@', i + 1)
      if close > i + 1:
        let name = arg[i + 1 ..< close]
        var bare = true
        for c in name:
          if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}: bare = false
        if bare and name.len > 0: return "@" & name & "@"
        i = close
        continue
    inc i
  ""

## ---------------------------------------------------------------------------
## Resolution
## ---------------------------------------------------------------------------

func applyOverride(defaults: seq[seq[string]], p: Phase): seq[seq[string]] =
  case p.mode
  of pmDefault:
    result = defaults
  of pmSkip:
    result = @[]
  of pmArgs:
    # Flags append to the *last* argv of the default. A default that runs two
    # commands means the flags belong to the second (`./autogen.sh` then
    # `./configure`), which is the only reading that makes sense.
    if defaults.len == 0:
      result = @[]
    else:
      result = defaults
      result[^1] = result[^1] & p.add
  of pmPrepend:
    result = p.argv & defaults
  of pmAppend:
    result = defaults & p.argv
  of pmReplace:
    result = p.argv

proc resolvePhases*(d: Definition, v: BuildVars,
                    extraConfigure: seq[string] = @[]): seq[ResolvedPhase] =
  ## `extraConfigure` carries the flags contributed by enabled and disabled
  ## features, which are known only after feature resolution.
  let defaults = defaultPhases(d.build.builder)

  for name in PhaseName:
    if name in {phUnpack, phPatch}: continue   ## driven by the build engine

    var argv = defaults.getOrDefault(name, @[])
    var skipped = false

    if d.build.phases.hasKey(name):
      let p = d.build.phases[name]
      if p.mode == pmSkip: skipped = true
      argv = applyOverride(argv, p)
    elif argv.len == 0:
      skipped = true

    if name == phConfigure and extraConfigure.len > 0 and argv.len > 0:
      argv[^1] = argv[^1] & extraConfigure

    var resolved: seq[seq[string]]
    for row in argv:
      var line: seq[string]
      for a in row:
        let s = substitute(a, v)
        let left = unresolvedPlaceholder(s)
        if left.len > 0:
          raise newException(PhaseError,
            "unknown placeholder " & left & " in phase '" & $name &
            "' of " & d.name & "; known placeholders are @dest@, @prefix@, " &
            "@src@, @build@ and @jobs@")
        line.add s
      if line.len > 0: resolved.add line

    result.add ResolvedPhase(name: name, argv: resolved,
                             skipped: skipped or resolved.len == 0)

func renderPhases*(phases: seq[ResolvedPhase]): string =
  ## Canonical text for hashing into the build identity, and for `nexis show`.
  for p in phases:
    if p.skipped:
      result.add $p.name & ": skip\n"
    else:
      for row in p.argv:
        result.add $p.name & ": " & row.join("\x1f") & "\n"
