import std/[os, strutils, unittest]
import ../../../src/nexis/compose/[boot, generation]

const Root = "/tmp/nexis-boot-tests"
const Mid = "abc123"

proc gen(id: int, label = ""): Generation =
  result = Generation(id: id, label: label, kernel: "/boot/vmlinuz-6.12",
                      initramfs: "/boot/initramfs.img",
                      packages: @[newPackageRef("base", "1", "b", "a")])
  result.seal = computeSeal(result)

proc fresh(sub: string): string =
  let d = Root / sub
  removeDir(d)
  createDir(d)
  d

suite "entry naming":
  test "the machine id prefixes the filename":
    # On a shared ESP two installations otherwise overwrite each other's
    # entries and the second silently wins.
    check entryFileName(3, Mid) == "abc123-nexis-3.conf"

  test "an absent machine id still yields a usable name":
    check entryFileName(3, "") == "nexis-nexis-3.conf"

suite "kernel command line":
  test "the generation is named, which is what makes entries distinguishable":
    # Without it every entry points at the same kernel and a rollback has
    # nothing to select.
    let opts = kernelOptions(gen(7), "/dev/nvme0n1p2")
    check "nexis.generation=7" in opts

  test "the root device is passed through":
    check "root=/dev/vda2" in kernelOptions(gen(1), "/dev/vda2")

  test "both consoles are listed":
    # A headless machine has no other path, and a serial log is the only way
    # to debug a boot that fails before userspace.
    let opts = kernelOptions(gen(1), "/dev/vda2")
    check "console=tty1" in opts
    check "console=ttyS0,115200n8" in opts

  test "extra options are appended, not substituted":
    let opts = kernelOptions(gen(1), "/dev/vda2", @["nomodeset"])
    check "nomodeset" in opts
    check "rw" in opts

suite "rendering":
  test "an entry carries every key a bootloader needs":
    let text = entryFor(gen(1), "/dev/vda2", Mid).render()
    for key in ["title", "version", "linux", "initrd", "options", "sort-key"]:
      check key in text

  test "the sort key is zero-padded so 10 does not precede 9":
    # The same numeric-sorting bug that would put a rollback list in the wrong
    # order, here deciding menu order instead.
    let nine = entryFor(gen(9), "/dev/vda2", Mid).render()
    let ten = entryFor(gen(10), "/dev/vda2", Mid).render()
    var nineKey, tenKey: string
    for line in nine.splitLines():
      if line.startsWith("sort-key"): nineKey = line
    for line in ten.splitLines():
      if line.startsWith("sort-key"): tenKey = line
    check nineKey < tenKey

  test "a label appears in the title":
    let text = entryFor(gen(4, "before the kernel upgrade"), "/dev/vda2",
                        Mid).render()
    check "before the kernel upgrade" in text

  test "the kernel path is relative to the ESP, not absolute on the root":
    let e = entryFor(gen(1), "/dev/vda2", Mid)
    check e.linux == "/vmlinuz-6.12"
    check e.initrd == "/initramfs.img"

suite "writing and listing":
  test "an entry round-trips through the directory":
    let dir = fresh("roundtrip")
    writeEntry(entryFor(gen(5), "/dev/vda2", Mid), dir)
    check listEntries(Mid, dir) == @[5]

  test "entries list numerically, not lexically":
    let dir = fresh("sorted")
    for id in [1, 2, 9, 10, 11]:
      writeEntry(entryFor(gen(id), "/dev/vda2", Mid), dir)
    let listed = listEntries(Mid, dir)
    check listed == @[1, 2, 9, 10, 11]

  test "another installation's entries are not listed as ours":
    let dir = fresh("shared")
    writeEntry(entryFor(gen(1), "/dev/vda2", Mid), dir)
    writeEntry(entryFor(gen(2), "/dev/vda2", "otherhost"), dir)
    check listEntries(Mid, dir) == @[1]
    check listEntries("otherhost", dir) == @[2]

  test "an absent directory lists nothing rather than failing":
    check listEntries(Mid, Root / "nope").len == 0

  test "unrelated files in the directory are ignored":
    let dir = fresh("unrelated")
    writeFile(dir / "windows.conf", "not ours")
    writeEntry(entryFor(gen(1), "/dev/vda2", Mid), dir)
    check listEntries(Mid, dir) == @[1]

suite "the default entry":
  test "setting a default writes it into loader.conf":
    let dir = fresh("default")
    let conf = dir / "loader.conf"
    setDefault(3, Mid, conf)
    check "default abc123-nexis-3.conf" in readFile(conf)

  test "changing the default replaces it rather than appending":
    # Two default lines is a bootloader reading whichever it likes.
    let dir = fresh("replace")
    let conf = dir / "loader.conf"
    setDefault(3, Mid, conf)
    setDefault(4, Mid, conf)
    let text = readFile(conf)
    check text.count("default ") == 1
    check "nexis-4" in text

  test "an existing timeout is preserved":
    let dir = fresh("preserve")
    let conf = dir / "loader.conf"
    writeFile(conf, "timeout 10\nconsole-mode max\n")
    setDefault(1, Mid, conf)
    let text = readFile(conf)
    check "timeout 10" in text
    check "console-mode max" in text

suite "pruning":
  test "entries for collected generations are removed":
    # A menu item pointing at a collected generation boots to a panic, which
    # looks like a broken machine rather than a stale menu.
    let dir = fresh("prune")
    for id in [1, 2, 3]:
      writeEntry(entryFor(gen(id), "/dev/vda2", Mid), dir)
    check pruneEntries(@[2, 3], Mid, dir) == 1
    check listEntries(Mid, dir) == @[2, 3]

  test "pruning nothing removes nothing":
    let dir = fresh("prunenone")
    writeEntry(entryFor(gen(1), "/dev/vda2", Mid), dir)
    check pruneEntries(@[1], Mid, dir) == 0

  test "the oldest entries go when the menu is over its limit":
    # The newest and the last-known-good are what anyone uses; everything
    # between makes those two harder to find.
    check entriesOverLimit(@[1, 2, 3, 4, 5], limit = 3) == @[1, 2]

  test "a menu under the limit drops nothing":
    check entriesOverLimit(@[1, 2], limit = 20).len == 0
