import std/[strutils, unittest]
import ../../../src/nexis/package/sri

suite "SRI hashes":
  test "round-trips a sha256 digest":
    let s = parseSri("sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ=")
    check s.algo == haSha256
    check s.digest.len == 32
    check s.isPinned
    check $s == "sha256-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ="

  test "an empty digest parses but is not pinned":
    let s = parseSri("sha256-")
    check s.algo == haSha256
    check not s.isPinned

  test "a bare hex digest is rejected with a hint":
    expect SriError:
      discard parseSri("abcdef0123456789abcdef0123456789" &
                       "abcdef0123456789abcdef0123456789")
    try:
      discard parseSri("abcdef0123456789abcdef0123456789" &
                       "abcdef0123456789abcdef0123456789")
    except SriError as e:
      check "prefix it with the algorithm" in e.msg

  test "an unknown algorithm is rejected":
    expect SriError:
      discard parseSri("md5-4QrcOUm6Wau+VuBX8g+IPg==")

  test "a digest of the wrong length for its algorithm is rejected":
    expect SriError:
      discard parseSri("sha512-r8w0AQPGZKGdxrJZ+bF6O5UYaTTb0k9jvHmvWyc4mtQ=")

  test "non-base64 is rejected":
    expect SriError:
      discard parseSri("sha256-not valid base64 at all!!")
