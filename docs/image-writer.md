# ADR 0007 — Writing the generation image

**Status:** accepted, with a stated intent to revisit
**Context:** Phase 2. `compose/merge.nim` produces a merged tree; something has
to turn it into the EROFS metadata image composefs mounts.

## The choice

Two options, and the project's "Nim only" goal pulls toward the harder one.

**A. Shell out to `mkcomposefs`.** The composefs project ships it. It consumes
a textual dump describing the tree and emits the image.

**B. Write the EROFS image in Nim.** No external dependency; the whole
generation pipeline is one language and one binary.

## Decision: A now, B later, behind a narrow interface

Three reasons, in order of weight.

**The format is still moving.** composefs is young, and its on-disk layout has
changed within the last few releases. A reimplementation has to track that, and
a tracking error does not produce a clean failure — it produces an image that
mounts and is subtly wrong, which is the worst failure mode available to a
system whose entire claim is integrity.

**EROFS is not a weekend format.** Inode layout, compressed metadata blocks,
the shared xattr prefix table, and the tail-packing rules are each individually
tractable and collectively a real project. Writing it now would displace Phase
2's actual goal, which is that generations compose, seal, activate and roll
back.

**"Nim only" is about NexisOS's own logic, not about refusing C on the ISO.**
The medium already carries `sgdisk`, `mkfs.ext4`, `cage` and `foot`. One more
tool is a smaller cost than a half-correct filesystem writer, and it is a cost
that shrinks to zero when B lands.

### What makes this reversible

`compose/image.nim` exposes one function that takes a merged tree and returns
an image digest. Everything else in the pipeline goes through it. Swapping the
implementation is a change to one file with a test suite already pinned to its
behaviour — not an archaeology exercise across the compose layer.

The dump text is also generated as **data first**, exactly as `isolate.nim`
plans its mounts before performing them. The dump can be asserted in tests
without `mkcomposefs` installed, so the part that encodes NexisOS's intent is
covered even where the part that encodes EROFS is not.

## What this rules out

Building an ISO on a machine without composefs tooling. `tools/build.sh check`
therefore reports `mkcomposefs` alongside the rest, rather than letting the
absence surface as a failed generation build.

## Consequences

- The ISO carries `mkcomposefs`, and `rootfs.sh` must copy it.
- The dump format is a compatibility surface with a tool NexisOS does not
  control. The generator records which `mkcomposefs` version it was written
  against, and `image.nim` verifies the tool's version at startup rather than
  discovering a format change through a corrupt image.
- Until B lands, a generation cannot be built by a NexisOS binary alone. That
  is a bootstrap debt and is listed with the others in
  [roadmap.md](roadmap.md).

## Revisit when

Either the composefs format stabilises across two release cycles, or the ISO's
dependency on C tooling becomes the last one standing. Whichever comes first —
the second is the more likely, since Phase 4 is expected to remove the others.
