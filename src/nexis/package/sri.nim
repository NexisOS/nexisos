## Subresource-integrity style hashes: `<algo>-<base64>`.
##
## The algorithm lives inside the value so that adding a new one later is a
## per-package migration rather than a flag day. A bare hex digest is rejected.

import std/[base64, strutils]

type
  HashAlgo* = enum
    haSha256 = "sha256"
    haSha512 = "sha512"
    haBlake3 = "blake3"

  Sri* = object
    algo*: HashAlgo
    digest*: seq[byte]

  SriError* = object of CatchableError

const digestLen*: array[HashAlgo, int] = [32, 64, 32]

proc parseAlgo*(s: string): HashAlgo =
  for a in HashAlgo:
    if $a == s: return a
  raise newException(SriError, "unknown hash algorithm: " & s)

proc parseSri*(s: string): Sri =
  ## Parses `sha256-<base64>`. An empty digest is permitted so that a
  ## definition can be authored before the hash is known; validation reports
  ## it separately as an unpinned source rather than as a malformed hash.
  let dash = s.find('-')
  if dash <= 0:
    raise newException(SriError,
      "hash must be '<algo>-<base64>', got: " & s.escape() &
      (if s.len > 0 and s.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'}):
         " (looks like a bare hex digest; prefix it with the algorithm)"
       else: ""))
  result.algo = parseAlgo(s[0 ..< dash])
  let b64 = s[dash + 1 .. ^1]
  if b64.len == 0:
    result.digest = @[]
    return
  var raw: string
  try:
    raw = base64.decode(b64)
  except CatchableError:
    raise newException(SriError, "hash digest is not valid base64: " & b64)
  if raw.len != digestLen[result.algo]:
    raise newException(SriError,
      "hash digest is " & $raw.len & " bytes, expected " &
      $digestLen[result.algo] & " for " & $result.algo)
  result.digest = cast[seq[byte]](raw)

proc isPinned*(s: Sri): bool = s.digest.len > 0

proc `$`*(s: Sri): string =
  $s.algo & "-" & base64.encode(cast[string](s.digest))
