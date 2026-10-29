# Security

An index. The detail lives in the documents this points at — this page exists
to say how the pieces fit and to own the one topic that has no home elsewhere:
security profiles.

| Topic | Document |
| --- | --- |
| Why FHS makes enforcing SELinux tractable, and what stays hard | [selinux.md](selinux.md) |
| nftables ruleset derived from service declarations | [firewall.md](firewall.md) |
| Per-package security contracts, the schema | [package-format.md](package-format.md#4-security-contract) |
| Build sandbox and what a violation refuses | [adr-0002](adr-0002-build-recipes-and-tiers.md) |
| Service sandboxing and cgroup ownership | [init.md](init.md) |
| Generation sealing and verification | [architecture.md](architecture.md) |

---

## The position

Security mechanisms are part of the system model rather than tools installed
afterward. That claim is only meaningful if it changes something concrete, so:

- **SELinux labels are built into the generation image**, not applied by a
  `setfiles` pass at boot. Rollback restores filesystem and contexts as one
  sealed unit, and there is no window where the system is running unlabelled.
- **The firewall is derived from service declarations.** Removing a service
  closes its port necessarily, because there is only one description of the
  system.
- **The build sandbox is part of build identity.** Changing the sandbox changes
  the hash, so old and new artifacts cannot share a cache entry despite having
  been built under different conditions.
- **A package declares what it needs**; the generation builder and
  `nexis-init` construct the runtime environment from that, rather than the
  package's own postinstall script arranging its own privileges.

The mechanisms in play are SELinux, seccomp, namespaces, capabilities, cgroups
v2, nftables, kernel hardening sysctls, and — where the platform supports it —
Secure Boot and module signature verification.

## Security profiles

Not every deployment wants the same tooling, and shipping intrusion detection
on a laptop is as wrong as omitting it on a public server. So NexisOS separates
**base mechanisms**, which are always present and part of the model, from
**security profiles**, which are opt-in bundles of configuration and optional
packages.

```toml
[security]
selinux = "enforcing"

[security.profile]
name = "hardened-server"
```

A profile is an ordinary configuration module. It has no special powers — it
sets the same options a hand-written configuration would, and `nexis explain`
shows which profile set which value. That is deliberate: a security profile
that could reach past the normal layering would be a second source of truth.

Intended profiles: `baseline`, `workstation`, `hardened-server`. None is
implemented yet.

## Status

Most of this is design, not behaviour. Nothing on this page should be read as
a description of what the code currently does — see
[TODO.md](../TODO.md) for what exists.
