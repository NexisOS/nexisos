## Types for the NexisOS package definition format v1.
##
## Three stages, deliberately distinct types so that an unresolved definition
## cannot be mistaken for a resolved one:
##
##   RawDefinition   parsed TOML, nothing checked
##   Definition      schema-valid in isolation
##   Resolved        groups expanded, features settled, identities computed

import std/tables
import ./sri

const SchemaVersion* = 1

type
  SourceRole* = enum
    srPrimary = "primary"
    srPatch = "patch"

  Unpack* = enum
    upAuto = "auto"
    upNone = "none"
    upTar = "tar"
    upZip = "zip"

  Source* = object
    role*: SourceRole
    urls*: seq[string]
    hash*: Sri
    unpack*: Unpack
    strip*: int          ## patch -pN; ignored for primary sources
    line*: int

  Builder* = enum
    bAutotools = "autotools"
    bCMake = "cmake"
    bMeson = "meson"
    bMake = "make"
    bCargo = "cargo"
    bGo = "go"
    bScript = "script"

  PhaseName* = enum
    phUnpack = "unpack"
    phPatch = "patch"
    phConfigure = "configure"
    phBuild = "build"
    phCheck = "check"
    phInstall = "install"

  PhaseMode* = enum
    pmDefault = "default"
    pmSkip = "skip"
    pmArgs = "args"         ## append flags to the default invocation
    pmPrepend = "prepend"   ## extra argv arrays before the default
    pmAppend = "append"     ## extra argv arrays after the default
    pmReplace = "replace"   ## discard the default entirely

  Phase* = object
    mode*: PhaseMode
    add*: seq[string]         ## pmArgs
    argv*: seq[seq[string]]   ## pmPrepend / pmAppend / pmReplace
    line*: int

  ## A dependency reference: `name[@slot][:output]`.
  ## The slot and output sigils are distinct because a package can have both,
  ## e.g. `llvm@18:dev`.
  DepSpec* = object
    name*: string
    slot*: string
    output*: string

  Feature* = object
    name*: string
    default*: bool
    dependencies*: seq[DepSpec]
    native*: seq[DepSpec]
    configure*: seq[string]
    configureOff*: seq[string]
    outputs*: seq[string]
    line*: int

  Output* = object
    name*: string
    paths*: seq[string]
    line*: int

  Provide* = object
    name*: string
    path*: string
    priority*: int
    line*: int

  Selinux* = object
    domain*: string
    executableType*: string

  Security* = object
    needsNetwork*: bool
    needsMount*: bool
    needsPtrace*: bool
    capabilities*: seq[string]
    selinux*: Selinux

  Build* = object
    builder*: Builder
    target*: string
    nativeGroups*: seq[string]
    dependencyGroups*: seq[string]
    native*: seq[DepSpec]
    dependencies*: seq[DepSpec]
    environment*: Table[string, string]
    phases*: Table[PhaseName, Phase]

  Definition* = object
    schema*: int
    name*: string
    version*: string
    revision*: int
    slot*: string
    description*: string
    homepage*: string
    license*: string
    outputs*: seq[string]      ## declaration order; first is the default
    conflicts*: seq[string]
    replaces*: seq[string]
    sources*: seq[Source]
    build*: Build
    features*: OrderedTable[string, Feature]
    featureConflicts*: seq[seq[string]]
    output*: OrderedTable[string, Output]
    provides*: seq[Provide]
    security*: Security
    path*: string              ## source file, for diagnostics

  Severity* = enum
    sevError, sevWarning

  Diagnostic* = object
    severity*: Severity
    line*: int
    msg*: string

  ValidationError* = object of CatchableError
    diagnostics*: seq[Diagnostic]

proc `$`*(d: DepSpec): string =
  result = d.name
  if d.slot.len > 0: result.add "@" & d.slot
  if d.output.len > 0: result.add ":" & d.output

proc defaultOutput*(d: Definition): string =
  if d.outputs.len > 0: d.outputs[0] else: "out"

proc err*(line: int, msg: string): Diagnostic =
  Diagnostic(severity: sevError, line: line, msg: msg)

proc warn*(line: int, msg: string): Diagnostic =
  Diagnostic(severity: sevWarning, line: line, msg: msg)

proc hasErrors*(ds: seq[Diagnostic]): bool =
  for d in ds:
    if d.severity == sevError: return true
  false

proc render*(ds: seq[Diagnostic], path: string): string =
  for d in ds:
    let tag = if d.severity == sevError: "error" else: "warning"
    result.add path & ":" & (if d.line > 0: $d.line else: "?") & ": " &
               tag & ": " & d.msg & "\n"
