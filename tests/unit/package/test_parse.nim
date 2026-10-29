import std/[os, strutils, tables, unittest]
import ../../../src/nexis/package/[parse, types, sri]

const fixtures = currentSourcePath().parentDir.parentDir.parentDir /
                 "fixtures" / "packages"

proc load(name: string): (Definition, seq[Diagnostic]) =
  let p = fixtures / name
  parseDefinition(readFile(p), p)

proc msgs(ds: seq[Diagnostic]): string =
  for d in ds: result.add d.msg & "\n"

suite "parsing a valid definition":
  test "minimal fixture parses without errors":
    let (d, diags) = load("minimal.toml")
    check not diags.hasErrors()
    check d.name == "zlib"
    check d.version == "1.3.1"
    check d.outputs == @["out", "dev"]
    check d.sources.len == 1
    check d.sources[0].hash.isPinned
    check d.build.builder == bAutotools

  test "the default output is the first declared":
    let (d, _) = load("minimal.toml")
    check d.defaultOutput == "out"

  test "a skipped phase is recorded":
    let (d, _) = load("minimal.toml")
    check d.build.phases[phCheck].mode == pmSkip

  test "patch sources keep their role and strip level":
    let (d, diags) = load("featured.toml")
    check not diags.hasErrors()
    check d.sources.len == 2
    check d.sources[1].role == srPatch
    check d.sources[1].strip == 1

  test "features carry their own dependencies and flags":
    let (d, _) = load("featured.toml")
    check d.features["gtk3"].default
    check not d.features["qt6"].default
    check $d.features["gtk3"].dependencies[0] == "gtk3"
    check d.features["docs"].outputs == @["doc"]
    check d.featureConflicts == @[@["gtk3", "qt6"]]

suite "rule 0 through the full parser":
  test "a misbound top-level key is a hard error":
    let (_, diags) = load("misbound.toml")
    check diags.hasErrors()
    let m = msgs(diags)
    check "top-level key 'outputs'" in m
    check "build.outputs" in m

  test "the error names the line the key is on, not the table":
    let (_, diags) = load("misbound.toml")
    for d in diags:
      if "top-level key" in d.msg:
        check d.line == 16

suite "dependency specs":
  test "name, slot and output are separate sigils":
    var p: seq[Diagnostic]
    let (d, _) = parseDefinition("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://example.org/x.tar.gz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"
dependencies = ["openssl:dev", "llvm@18", "llvm@18:dev", "plain"]

[output.out]
paths = ["/usr/bin/**"]
""", "inline")
    discard p
    let deps = d.build.dependencies
    check $deps[0] == "openssl:dev"
    check deps[0].output == "dev"
    check $deps[1] == "llvm@18"
    check deps[1].slot == "18"
    check $deps[2] == "llvm@18:dev"
    check deps[2].slot == "18"
    check deps[2].output == "dev"
    check $deps[3] == "plain"

suite "validation rules":
  proc check1(src: string): string =
    let (_, diags) = parseDefinition(src, "inline")
    msgs(diags)

  test "environment as an array of KEY=value strings is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"
environment = ["CC=gcc"]

[output.out]
paths = ["/usr/bin/**"]
""")
    check "must be a table" in m

  test "setting a toolchain variable in the environment is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"
environment = { CC = "gcc" }

[output.out]
paths = ["/usr/bin/**"]
""")
    check "the toolchain owns" in m

  test "a bare hex hash is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]
""")
    check "must be '<algo>-<base64>'" in m

  test "a source with no urls is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = []
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]
""")
    check "no urls" in m

  test "an output listed but not defined is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out", "dev"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]
""")
    check "no [output.dev] table" in m

  test "an output defined but not listed is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]

[output.dev]
paths = ["/usr/include/**"]
""")
    check "not listed in `outputs`" in m

  test "two outputs claiming an identical pattern is an error":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out", "dev"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]

[output.dev]
paths = ["/usr/bin/**"]
""")
    check "can never match" in m

  test "overlapping but distinct patterns are a warning, not an error":
    let (_, diags) = parseDefinition("""
schema = 1
name = "x"
version = "1"
outputs = ["dev", "lib"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.dev]
paths = ["/usr/lib/pkgconfig/**"]

[output.lib]
paths = ["/usr/lib/**"]
""", "inline")
    check not diags.hasErrors()
    check "overlaps" in msgs(diags)
    check "go to 'dev'" in msgs(diags)

  test "a feature claiming an undeclared output is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[features.docs]
default = false
outputs = ["doc"]

[output.out]
paths = ["/usr/bin/**"]
""")
    check "claims output 'doc'" in m

  test "a conflicts entry naming an undeclared feature is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[features]
conflicts = [["gtk3", "nope"]]

[features.gtk3]
default = true

[output.out]
paths = ["/usr/bin/**"]
""")
    check "not a declared feature" in m

  test "an unqualified slot is rejected":
    let m = check1("""
schema = 1
name = "python"
version = "3.12.0"
slot = "3.12"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]
""")
    check "no output pattern is slot-qualified" in m

  test "a slot-qualified path satisfies the slot rule":
    let m = check1("""
schema = 1
name = "python"
version = "3.12.0"
slot = "3.12"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/python3.12", "/usr/lib/python3.12/**"]
""")
    check "slot-qualified" notin m

  test "the script builder requires explicit phases":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "script"

[build.phases]
build = { mode = "default" }

[output.out]
paths = ["/usr/bin/**"]
""")
    check "must use mode 'replace' or 'skip'" in m

  test "a replace phase without argv is rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[build.phases]
configure = { mode = "replace" }

[output.out]
paths = ["/usr/bin/**"]
""")
    check "declares no argv" in m

  test "an unpinned hash is a warning, not an error":
    let (_, diags) = parseDefinition("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-"

[build]
builder = "make"

[output.out]
paths = ["/usr/bin/**"]
""", "inline")
    check not diags.hasErrors()
    check "unpinned" in msgs(diags)

  test "duplicate provides names within one definition are rejected":
    let m = check1("""
schema = 1
name = "x"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/x.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

[build]
builder = "make"

[[provides]]
name = "cc"
path = "/usr/bin/cc"
priority = 50

[[provides]]
name = "cc"
path = "/usr/bin/gcc"
priority = 40

[output.out]
paths = ["/usr/bin/**"]
""")
    check "declared twice" in m

  test "an unsupported schema version is rejected":
    let m = check1("""
schema = 99
name = "x"
version = "1"
""")
    check "unsupported schema version 99" in m

  test "a TOML syntax error is reported with its location":
    let m = check1("schema = 1\nname = \"x\n")
    check "TOML syntax error" in m
