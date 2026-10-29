import std/unittest
import ../../../src/nexis/package/glob

suite "glob matching":
  test "** spans zero or more segments":
    check matches("/usr/bin/**", "/usr/bin")
    check matches("/usr/bin/**", "/usr/bin/foo")
    check matches("/usr/bin/**", "/usr/bin/a/b/c")
    check not matches("/usr/bin/**", "/usr/sbin/foo")

  test "* does not cross a segment boundary":
    check matches("/usr/lib/*.so", "/usr/lib/libz.so")
    check not matches("/usr/lib/*.so", "/usr/lib/sub/libz.so")

  test "** followed by a pattern matches at any depth":
    check matches("/usr/lib/**/*.so.*", "/usr/lib/libz.so.1")
    check matches("/usr/lib/**/*.so.*", "/usr/lib/x/y/libz.so.1.2")
    check not matches("/usr/lib/**/*.so.*", "/usr/lib/libz.so")

  test "? matches exactly one character":
    check matches("/usr/bin/pytho?", "/usr/bin/python")
    check not matches("/usr/bin/pytho?", "/usr/bin/pytho")

suite "glob intersection":
  test "identical patterns intersect":
    check intersects("/usr/bin/**", "/usr/bin/**")

  test "disjoint prefixes do not intersect":
    check not intersects("/usr/bin/**", "/usr/share/**")

  test "a wildcard subsumes a literal":
    check intersects("/usr/lib/**", "/usr/lib/pkgconfig/foo.pc")

  test "*.so and *.so.* intersect only via a contrived name":
    # "a.so.b.so" matches both, so the honest answer is yes. The overlap
    # diagnostic is a warning precisely because cases like this are pedantic.
    check intersects("/usr/lib/*.so", "/usr/lib/*.so.*")
    check matches("/usr/lib/*.so", "/usr/lib/a.so.b.so")
    check matches("/usr/lib/*.so.*", "/usr/lib/a.so.b.so")

  test "distinct extensions do not intersect":
    check not intersects("/usr/lib/*.so", "/usr/lib/*.a")

  test "** on one side reaches under a literal on the other":
    check intersects("/usr/**", "/usr/share/doc/**")
    check not intersects("/var/**", "/usr/share/doc/**")

  test "differing fixed segments do not intersect":
    check not intersects("/usr/lib/pkgconfig/*", "/usr/lib/cmake/*")
