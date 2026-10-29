import std/[os, sequtils, strutils, tables, unittest]
import ../../../src/nexis/build/[phases, sandbox, outputs]
import ../../../src/nexis/package/[parse, types, resolve, groups]
import ../../../src/lib/hashing

const fixtures = currentSourcePath().parentDir.parentDir.parentDir /
                 "fixtures" / "packages"

proc loadDef(name: string): Definition =
  let p = fixtures / name
  let (d, diags) = parseDefinition(readFile(p), p)
  doAssert not diags.hasErrors(), diags.render(p)
  d

proc defWith(body: string): Definition =
  let src = """
schema = 1
name = "t"
version = "1"
outputs = ["out"]

[[source]]
urls = ["https://e.org/t.tgz"]
hash = "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

""" & body & """

[output.out]
paths = ["/usr/bin/**"]
"""
  let (d, diags) = parseDefinition(src, "inline")
  doAssert not diags.hasErrors(), diags.render("inline")
  d

proc phaseNamed(ps: seq[ResolvedPhase], n: PhaseName): ResolvedPhase =
  for p in ps:
    if p.name == n: return p

suite "builder defaults":
  test "autotools configures, builds and installs into a destdir":
    let d = defWith("[build]\nbuilder = \"autotools\"")
    let ps = resolvePhases(d, defaultVars())
    check phaseNamed(ps, phConfigure).argv[0][0] == "./configure"
    check "--prefix=/usr" in phaseNamed(ps, phConfigure).argv[0]
    check "DESTDIR=/build/dest" in phaseNamed(ps, phInstall).argv[0]

  test "cargo builds offline and locked":
    # Without these a build can reach the network and silently resolve a
    # different dependency set than the lockfile pins.
    let d = defWith("[build]\nbuilder = \"cargo\"")
    let ps = resolvePhases(d, defaultVars())
    check "--offline" in phaseNamed(ps, phBuild).argv[0]
    check "--locked" in phaseNamed(ps, phBuild).argv[0]

  test "go trims paths":
    # -trimpath keeps absolute build directories out of the binary.
    let d = defWith("[build]\nbuilder = \"go\"")
    let ps = resolvePhases(d, defaultVars())
    check "-trimpath" in phaseNamed(ps, phBuild).argv[0]

  test "the script builder has no defaults, so every phase is skipped":
    let d = defWith("[build]\nbuilder = \"script\"")
    let ps = resolvePhases(d, defaultVars())
    for p in ps:
      check p.skipped

suite "phase overrides":
  test "args append to the last argv of the default":
    let d = defWith("""
[build]
builder = "autotools"

[build.phases]
configure = { mode = "args", add = ["--disable-tests"] }
""")
    let c = phaseNamed(resolvePhases(d, defaultVars()), phConfigure)
    check c.argv.len == 1
    check c.argv[0][^1] == "--disable-tests"
    check c.argv[0][0] == "./configure"

  test "replace discards the default entirely":
    let d = defWith("""
[build]
builder = "autotools"

[build.phases]
configure = { mode = "replace", argv = [["./autogen.sh"], ["./configure", "--prefix=/usr"]] }
""")
    let c = phaseNamed(resolvePhases(d, defaultVars()), phConfigure)
    check c.argv.len == 2
    check c.argv[0] == @["./autogen.sh"]

  test "prepend and append keep the default in place":
    let d = defWith("""
[build]
builder = "make"

[build.phases]
build = { mode = "prepend", argv = [["./bootstrap"]] }
""")
    let b = phaseNamed(resolvePhases(d, defaultVars()), phBuild)
    check b.argv[0] == @["./bootstrap"]
    check b.argv[1][0] == "make"

  test "skip marks the phase skipped":
    let d = defWith("""
[build]
builder = "autotools"

[build.phases]
check = { mode = "skip" }
""")
    check phaseNamed(resolvePhases(d, defaultVars()), phCheck).skipped

suite "substitution":
  test "placeholders are replaced from the build vars":
    var v = defaultVars()
    v.jobs = 8
    v.destDir = "/build/out"
    let d = defWith("[build]\nbuilder = \"autotools\"")
    let ps = resolvePhases(d, v)
    check "-j8" in phaseNamed(ps, phBuild).argv[0]
    check "DESTDIR=/build/out" in phaseNamed(ps, phInstall).argv[0]

  test "an unknown placeholder is an error, not a literal":
    # Passing `@outdir@` through to `make install` creates a directory with
    # that name instead of failing.
    let d = defWith("""
[build]
builder = "make"

[build.phases]
install = { mode = "replace", argv = [["make", "DESTDIR=@outdir@", "install"]] }
""")
    expect PhaseError:
      discard resolvePhases(d, defaultVars())

  test "an email address is not mistaken for a placeholder":
    let d = defWith("""
[build]
builder = "make"

[build.phases]
build = { mode = "replace", argv = [["make", "MAINTAINER=a@b.com"]] }
""")
    let b = phaseNamed(resolvePhases(d, defaultVars()), phBuild)
    check "MAINTAINER=a@b.com" in b.argv[0]

  test "feature flags reach the configure phase":
    let d = loadDef("featured.toml")
    let ps = resolvePhases(d, defaultVars(), @["-Dgtk3=enabled"])
    check "-Dgtk3=enabled" in phaseNamed(ps, phConfigure).argv[0]

suite "resolved phases feed the build identity":
  test "changing our builder defaults changes the rendered phases":
    # If the identity hashed only the declared overrides, a change to the
    # NexisOS autotools defaults would serve stale cached artifacts.
    let a = renderPhases(resolvePhases(defWith("[build]\nbuilder = \"autotools\""),
                                       defaultVars()))
    let b = renderPhases(resolvePhases(defWith("[build]\nbuilder = \"cmake\""),
                                       defaultVars()))
    check a != b

  test "rendering is stable":
    let d = defWith("[build]\nbuilder = \"meson\"")
    check renderPhases(resolvePhases(d, defaultVars())) ==
          renderPhases(resolvePhases(d, defaultVars()))

  test "job count does not change the identity-relevant rendering":
    # Parallelism is a property of the machine, not of the artifact. Two
    # machines with different core counts must produce the same build id.
    var v1 = defaultVars()
    var v8 = defaultVars()
    v1.jobs = 1
    v8.jobs = 8
    let d = defWith("[build]\nbuilder = \"autotools\"")
    check renderPhases(resolvePhases(d, v1)) !=
          renderPhases(resolvePhases(d, v8))

suite "sandbox invariants":
  test "a default sandbox has no violations":
    check newSandbox(@["/store/objects/aa/x"]).violations().len == 0

  test "isolation is on by default":
    let s = newSandbox(@[])
    check s.namespaces.net
    check s.namespaces.mount
    check s.namespaces.user
    check s.namespaces.uts
    check not s.allowNetwork

  test "a network build drops the net namespace consistently":
    let s = newSandbox(@[], allowNetwork = true)
    check not s.namespaces.net
    check s.violations().len == 0

  test "an inconsistent network spec is caught":
    var s = newSandbox(@[])
    s.allowNetwork = true
    check s.violations().anyIt("network is allowed" in it)

  test "losing the mount namespace is caught":
    var s = newSandbox(@[])
    s.namespaces.mount = false
    check s.violations().anyIt("host filesystem" in it)

  test "the environment is constructed, not inherited":
    let s = newSandbox(@[])
    check s.env["SOURCE_DATE_EPOCH"] == "0"
    check s.env["TZ"] == "UTC"
    check s.env["LC_ALL"] == "C"
    check not s.env.hasKey("PWD")
    check not s.env.hasKey("SSH_AUTH_SOCK")

  test "toolchain variables in the environment are a violation":
    var s = newSandbox(@[])
    s.env["CFLAGS"] = "-O3 -march=native"
    check s.violations().anyIt("CFLAGS" in it)

  test "unpinning the clock is a violation":
    var s = newSandbox(@[])
    s.env["SOURCE_DATE_EPOCH"] = $1893456000
    check s.violations().anyIt("SOURCE_DATE_EPOCH" in it)

  test "uid, gid and hostname are fixed":
    let s = newSandbox(@[])
    check s.uid == BuildUid
    check s.hostname == BuildHostname
    var t = s
    t.uid = 0
    check t.violations().anyIt("uid/gid" in it)

  test "store inputs are mounted read-only":
    let s = newSandbox(@["/store/objects/ab/cd"])
    for m in s.mounts:
      if m.source == "/store/objects/ab/cd":
        check m.kind == mkBind
    check not s.isWritable("/store/objects/ab/cd")

  test "only the build trees are writable":
    let s = newSandbox(@["/store/objects/ab/cd"])
    check s.isWritable("/build/dest/usr/bin/foo")
    check s.isWritable("/tmp/x")
    check not s.isWritable("/usr/bin/gcc")
    check not s.isWritable("/etc/passwd")

  test "a writable mount outside the build root is a violation":
    var s = newSandbox(@[])
    s.mounts.add Mount(kind: mkBindRw, source: "/etc", target: "/etc")
    check s.violations().anyIt("writable mount outside" in it)

  test "bind-mounting the host /usr is a violation":
    var s = newSandbox(@[])
    s.mounts.add Mount(kind: mkBind, source: "/usr", target: "/usr")
    check s.violations().anyIt("host /usr" in it)

  test "the spec renders for the build log":
    let r = newSandbox(@["/store/objects/aa/bb"]).render()
    check "uid=1000" in r
    check "network=false" in r
    check "SOURCE_DATE_EPOCH=0" in r

suite "output splitting":
  setup:
    let d = loadDef("featured.toml")
    proc f(p: string): TreeEntry =
      TreeEntry(path: p, kind: ekFile, digest: sha256(p))

  test "files land in the first matching output":
    let r = splitOutputs(d, @[f("usr/bin/tool"), f("usr/include/x.h")],
                         @["out", "dev"])
    check r.assignments["out"].len == 1
    check r.assignments["dev"].len == 1
    check r.unmatched.len == 0

  test "declaration order decides an overlap":
    let r1 = splitOutputs(d, @[f("usr/lib/libz.so.1")], @["out", "dev"])
    check r1.assignments["out"].len == 1

  test "an unmatched file is reported rather than dropped":
    # This is how an upstream that started installing somewhere new gets
    # noticed instead of the file quietly vanishing.
    let r = splitOutputs(d, @[f("opt/weird/thing")], @["out", "dev"])
    check r.unmatched == @["/opt/weird/thing"]

  test "a disabled feature's output receives nothing":
    let r = splitOutputs(d, @[f("usr/bin/tool")], @["out", "dev"])
    check "doc" notin r.assignments

  test "an active but empty output is reported":
    let r = splitOutputs(d, @[f("usr/bin/tool")], @["out", "dev", "doc"])
    check "dev" in r.empty
    check "doc" in r.empty

  test "directories are not assigned on their own":
    let r = splitOutputs(d, @[TreeEntry(path: "usr/bin", kind: ekDir),
                              f("usr/bin/tool")], @["out"])
    check r.assignments["out"].len == 1

  test "explain names the output and the pattern that claimed a path":
    let (o, p) = explain(d, "usr/include/foo.h", @["out", "dev"])
    check o == "dev"
    check p == "/usr/include/**"

  test "explain returns nothing for an unclaimed path":
    let (o, _) = explain(d, "opt/x", @["out", "dev"])
    check o == ""
