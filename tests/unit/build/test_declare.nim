import std/[os, strutils, tables, unittest]
import ../../../src/nexis/build/declare

const Root = "/tmp/nexis-declare-tests"
const Hash = "sha256-LXEWQrcmsEQBYnyp+6wy9chTD7GQPMTbAiWHF5IaSIE="

proc defn(name: string, deps: seq[string] = @[], native: seq[string] = @[],
          declaredName = ""): string =
  result = "schema = 1\n\nname    = \"" &
           (if declaredName.len > 0: declaredName else: name) &
           "\"\nversion = \"1.0\"\n\n[[source]]\nrole = \"primary\"\nurls = " &
           "[\"https://example.org/" & name & ".tar.xz\"]\nhash = \"" & Hash &
           "\"\n\n[build]\nbuilder = \"make\"\n"
  if deps.len > 0:
    result.add "dependencies = [\"" & deps.join("\", \"") & "\"]\n"
  if native.len > 0:
    result.add "native = [\"" & native.join("\", \"") & "\"]\n"
  result.add "\n[output.out]\npaths = [\"/usr/bin/**\"]\n"

proc tree(sub: string, files: openArray[(string, string)]): SearchPath =
  let dir = Root / sub
  removeDir(dir)
  createDir(dir)
  for (name, body) in files:
    writeFile(dir / name & ".toml", body)
  @[dir]

suite "locating definitions":
  test "a definition is found as <name>.toml":
    let path = tree("plain", {"foo": defn("foo")})
    let (file, entry) = locate("foo", path)
    check file.endsWith("foo.toml")
    check entry == path[0]

  test "a definition is also found as <name>/package.toml":
    # Forcing a directory for a one-file package is noise; forcing a single
    # file for a package with patches is a lie.
    let dir = Root / "dirform"
    removeDir(dir)
    createDir(dir / "bar")
    writeFile(dir / "bar" / "package.toml", defn("bar"))
    let (file, _) = locate("bar", @[dir])
    check file.endsWith("package.toml")

  test "an absent definition returns empty, not a guess":
    let (file, entry) = locate("nope", tree("empty", []))
    check file == ""
    check entry == ""

  test "the first search entry wins":
    # This is how a machine overrides a definition without editing anything it
    # does not own.
    let a = tree("over-a", {"pkg": defn("pkg")})
    let b = tree("over-b", {"pkg": defn("pkg")})
    let (file, entry) = locate("pkg", a & b)
    check entry == a[0]

suite "walking the closure":
  test "transitive dependencies are pulled in":
    let path = tree("trans", {"app": defn("app", @["lib"]),
                              "lib": defn("lib", @["base"]),
                              "base": defn("base")})
    let c = buildClosure(@["app"], path)
    check not c.hasErrors()
    check c.packages.len == 3

  test "native dependencies are part of the closure too":
    let path = tree("native", {"app": defn("app", @[], @["cmake"]),
                               "cmake": defn("cmake")})
    let c = buildClosure(@["app"], path)
    check not c.hasErrors()
    check c.packages.len == 2

  test "a shared dependency appears once":
    let path = tree("diamond", {"app": defn("app", @["a", "b"]),
                                "a": defn("a", @["base"]),
                                "b": defn("b", @["base"]),
                                "base": defn("base")})
    let c = buildClosure(@["app"], path)
    check c.packages.len == 4

  test "a missing definition is an error here, not a build failure later":
    # Otherwise it is a build that fails forty minutes in on a missing header,
    # or one that silently succeeds against something the host had.
    let path = tree("missing", {"app": defn("app", @["absent"])})
    let c = buildClosure(@["app"], path)
    check c.hasErrors()
    check "absent" in c.missingDefinitions()

  test "the error names what required the missing package":
    let path = tree("blame", {"app": defn("app", @["lib"]),
                              "lib": defn("lib", @["absent"])})
    let c = buildClosure(@["app"], path)
    check "required by lib" in c.problems[0].format()

  test "several missing definitions are reported together":
    # Breadth-first exists so a gap three levels down is reported alongside
    # its siblings rather than aborting the walk.
    let path = tree("many", {"app": defn("app", @["x", "y", "z"])})
    let missing = buildClosure(@["app"], path).missingDefinitions()
    check missing.len == 3
    for name in ["x", "y", "z"]:
      check name in missing

  test "a file declaring a different name than its own is refused":
    # One of the two is wrong, and guessing which produces a closure that does
    # not match the declaration.
    let path = tree("mismatch", {"app": defn("app", declaredName = "other")})
    let c = buildClosure(@["app"], path)
    check c.hasErrors()
    check "declares itself" in c.problems[0].msg

  test "the closure is identical regardless of declaration order":
    let path = tree("order", {"a": defn("a"), "b": defn("b"), "c": defn("c")})
    let x = buildClosure(@["c", "a", "b"], path)
    let y = buildClosure(@["a", "b", "c"], path)
    check x.packages.len == y.packages.len
    for i in 0 ..< x.packages.len:
      check x.packages[i].def.name == y.packages[i].def.name

  test "an empty declaration is an empty closure, not an error":
    let c = buildClosure(@[], tree("none", []))
    check not c.hasErrors()
    check c.packages.len == 0

  test "the origin of every package is recorded":
    # So `nexis why` can say which file a package came from.
    let path = tree("origin", {"app": defn("app")})
    let c = buildClosure(@["app"], path)
    check c.origins["app"].path.endsWith("app.toml")
    check c.origins["app"].source == path[0]

suite "build identities":
  test "every package gets a buildId":
    let path = tree("ids", {"app": defn("app", @["lib"]), "lib": defn("lib")})
    let c = buildClosure(@["app"], path)
    for r in c.packages:
      check r.buildId.len > 0

  test "identities are stable across runs":
    let path = tree("stable", {"app": defn("app", @["lib"]),
                               "lib": defn("lib")})
    let a = buildClosure(@["app"], path)
    for _ in 0 .. 3:
      let b = buildClosure(@["app"], path)
      for i in 0 ..< a.packages.len:
        check a.packages[i].buildId == b.packages[i].buildId

  test "different packages get different identities":
    let path = tree("distinct", {"a": defn("a"), "b": defn("b")})
    let c = buildClosure(@["a", "b"], path)
    check c.packages[0].buildId != c.packages[1].buildId

  test "a dependency's identity feeds its dependant's":
    # Change the library, and the thing that links it must rebuild.
    let p1 = tree("dep1", {"app": defn("app", @["lib"]), "lib": defn("lib")})
    let a = buildClosure(@["app"], p1)
    writeFile(p1[0] / "lib.toml",
              defn("lib").replace("version = \"1.0\"", "version = \"2.0\""))
    let b = buildClosure(@["app"], p1)
    var appA, appB: string
    for r in a.packages:
      if r.def.name == "app": appA = r.buildId
    for r in b.packages:
      if r.def.name == "app": appB = r.buildId
    check appA != appB

  test "the target architecture is part of the identity":
    let path = tree("target", {"app": defn("app")})
    let x = buildClosure(@["app"], path, target = "x86_64-linux")
    let y = buildClosure(@["app"], path, target = "aarch64-linux")
    check x.packages[0].buildId != y.packages[0].buildId

suite "rendering":
  test "a clean closure lists its packages with versions":
    let path = tree("render", {"app": defn("app", @["lib"]),
                               "lib": defn("lib")})
    let text = buildClosure(@["app"], path).renderClosure()
    check "2 package(s)" in text
    check "app 1.0" in text

  test "problems replace the listing rather than accompanying it":
    let path = tree("renderbad", {"app": defn("app", @["absent"])})
    let text = buildClosure(@["app"], path).renderClosure()
    check "problem(s)" in text
    check "in the closure" notin text

suite "search path":
  test "the local overlay is consulted before the system definitions":
    let p = defaultSearchPath("/etc/nexis")
    check p[0].startsWith("/etc/nexis")
    check p[^1].startsWith("/usr/share")
