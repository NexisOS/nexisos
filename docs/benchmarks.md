# Benchmarks

Every performance claim in [comparison.md](comparison.md) is a design argument
until it is measured. This document specifies what will be measured, against
what, and what counts as failure — so the claims can be shown wrong rather than
merely asserted.

**Current status: unmeasured.** Nothing here has been run. The store and
generation builder are not finished.

## Method

- Same machine, same NVMe device, same kernel, cold and warm page cache
  reported separately.
- Comparison point is NixOS on the same hardware with an equivalent package
  set, not a synthetic workload.
- Every figure is a median of five runs with the spread reported. A single
  number without a spread is not a result.
- The store is populated to a realistic size before measuring: ten retained
  generations of a desktop system, which is where the scaling claims actually
  matter.

## Operations

| # | Operation | Claim | Compared against | Fails if |
| --- | --- | --- | --- | --- |
| 1 | Evaluate a full system declaration | Parse, not interpretation | `nixos-rebuild dry-build` eval time | Not at least 10× faster, or memory not bounded well under 1 GB |
| 2 | Rebuild with one package changed | Only the changed closure rebuilds | `nixos-rebuild switch` | Anything outside the changed closure rebuilds |
| 3 | Rebuild with an ABI-preserving dependency patch | Dependents are *not* rebuilt | Nix, which must rebuild them | Any dependent rebuilds |
| 4 | Build a generation image | Metadata only; no file content copied | Nix profile construction | Scales with `/usr` size rather than with change size |
| 5 | Activate a generation | One mount syscall | Nix activation script | Not effectively constant time |
| 6 | Retire one of ten generations | Cost tracks what that generation uniquely held | `nix-collect-garbage -d` | Scales with store size |
| 7 | Deduplication | No separate pass exists | `nix-store --optimise` | Any retroactive dedup is needed |
| 8 | Enter a cached dev environment | A mount, not a re-evaluation | `nix-shell` on the same inputs | Not effectively instant on a warm cache |
| 9 | Store size, ten generations | File-level CAS beats retroactive hardlinking | `/nix/store` after `--optimise` | Larger than an optimised Nix store |
| 10 | Page cache, host + container + dev shell sharing a package | One inode, cached once | OCI layers; Nix bind mounts | Resident pages scale with the number of consumers |

Operations 3, 6, 7 and 10 are the ones that would falsify the *architecture*
rather than the implementation. If interface identity does not actually spare
dependents, or if collection scales with the store, the design arguments in
[adr-0002](adr-0002-build-recipes-and-tiers.md) and
[adr-0003](adr-0003-store-index-and-gc.md) are wrong and should be revisited
rather than tuned around.

## Non-goals

- Raw compiler throughput. That is the toolchain's, and identical on both.
- First-build-from-source time. Both systems compile the same code.
- Anything measured only on an empty store, which is the shape that flatters
  every design here and tests none of the scaling claims.
