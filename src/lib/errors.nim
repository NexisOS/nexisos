## Error types shared across the package manager.
##
## Errors carry structured context rather than a formatted string, because the
## same failure has to render three ways: a one-line CLI message, a diagnostic
## with a file and line, and a machine-readable exit code (see docs/cli.md).

type
  ErrorKind* = enum
    ekConfig      ## configuration invalid                  exit 2
    ekResolve     ## dependency resolution failed           exit 3
    ekBuild       ## build failed                           exit 4
    ekGeneration  ## generation validation failed           exit 5
    ekStore       ## store corruption or IO failure         exit 1
    ekIo          ## plain IO failure                       exit 1

  NexisError* = object of CatchableError
    kind*: ErrorKind
    path*: string     ## file involved, if any
    line*: int        ## line within that file, if known
    hint*: string     ## what the user should do about it

func exitCode*(k: ErrorKind): int =
  case k
  of ekConfig: 2
  of ekResolve: 3
  of ekBuild: 4
  of ekGeneration: 5
  of ekStore, ekIo: 1

proc raiseNexis*(kind: ErrorKind, msg: string, path = "", line = 0,
                 hint = "") {.noreturn.} =
  var e = newException(NexisError, msg)
  e.kind = kind
  e.path = path
  e.line = line
  e.hint = hint
  raise e

func format*(e: NexisError): string =
  if e.path.len > 0:
    result = e.path
    if e.line > 0: result.add ":" & $e.line
    result.add ": "
  result.add e.msg
  if e.hint.len > 0:
    result.add "\n  " & e.hint
