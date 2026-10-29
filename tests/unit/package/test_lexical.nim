import std/[strutils, unittest]
import ../../../src/nexis/package/[lexical, types]

proc messages(src: string): string =
  let s = scan(src)
  for d in s.diagnostics: result.add d.msg & "\n"

suite "rule 0: top-level keys after a table header":
  test "a misbound top-level key is caught with its binding spelled out":
    let m = messages("""
schema = 1
name = "x"

[build]
builder = "make"
outputs = ["out"]
""")
    check "top-level key 'outputs'" in m
    check "build.outputs" in m

  test "the same key is fine when it is legal in that table":
    # features.conflicts and features.<x>.outputs are real keys, not misbindings.
    let m = messages("""
schema = 1
outputs = ["out", "doc"]

[features]
conflicts = [["a", "b"]]

[features.a]
default = true
outputs = ["doc"]
""")
    check m.len == 0

  test "provides entries may carry a name":
    let m = messages("""
schema = 1
name = "x"

[[provides]]
name = "cc"
path = "/usr/bin/cc"
priority = 50
""")
    check m.len == 0

  test "top-level keys before any table are fine":
    let m = messages("""
schema = 1
name = "x"
outputs = ["out"]

[build]
builder = "make"
""")
    check m.len == 0

suite "unknown keys":
  test "a typo in a known table is reported with the legal set":
    let m = messages("""
schema = 1

[build]
bulider = "make"
""")
    check "unknown key 'bulider'" in m
    check "builder" in m

  test "the environment table is opaque":
    let m = messages("""
schema = 1

[build.environment]
ANYTHING_AT_ALL = "1"
""")
    check m.len == 0

suite "line index":
  test "records lines for tables and keys":
    let s = scan("""
schema = 1
name = "x"

[build]
builder = "make"

[[source]]
role = "primary"

[[source]]
role = "patch"
""")
    check s.lineOf("schema") == 1
    check s.lineOf("build") == 4
    check s.lineOf("build.builder") == 5
    check s.lineOf("source[0]") == 7
    check s.lineOf("source[1]") == 10

  test "multi-line arrays do not confuse the scanner":
    let s = scan("""
schema = 1
outputs = [
  "out",
  "dev",
]

[build]
builder = "make"
""")
    check s.lineOf("build") == 7
    check s.diagnostics.len == 0

  test "comments and blank lines are skipped":
    let s = scan("""
# a comment
schema = 1

# [build] inside a comment is not a header
name = "x"
""")
    check s.lineOf("name") == 5
    check s.diagnostics.len == 0
