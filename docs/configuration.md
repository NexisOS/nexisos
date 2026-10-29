# Configuration

Configuration is **dendritic**: systems are assembled from reusable modules and
profiles rather than one monolithic file, so host-specific settings stay small
and features stay composable across several machines.

For the package definition schema see [package-format.md](package-format.md).
For dev environments see [environments.md](environments.md).

---

## Layout

System configuration lives in `/etc/nexis/` as schema-validated TOML.

```text
/etc/nexis/
├── system.toml       hostname, timezone, locale, profile selection
├── packages.toml     system package set
├── services.toml     service declarations
├── users.toml        users, groups, per-user packages and home entries
├── security.toml     SELinux mode, firewall, hardening
├── profiles/         reusable machine roles (server, desktop, minimal)
└── modules/          reusable feature units, composed by profiles
```

Nothing outside `/etc/nexis/` contributes to system state. That is the
invariant the whole design exists to hold: **system state is a pure function of
the declaration.**

## Shape

```toml
[system]
hostname = "nexis-host"
timezone = "UTC"

[system.profile]
name = "server"

[security]
selinux = "enforcing"

[service.ssh]
enabled = true

[service.ssh.security]
domain = "sshd_t"
```

The schema is still moving. Validation is not: an unknown key, a wrong type or
an unsatisfied constraint is a hard error before anything is built, and exits
`2`.

## Layering and precedence

Values resolve through layers, later winning over earlier:

```text
defaults  →  profile  →  modules (by declared priority)  →  host
```

`nexis explain <option>` prints where a value came from, layer by layer, in
precedence order. This exists because the most common failure mode of a
composable configuration system is a value nobody can find the origin of.

Modules declare a priority and a set of options; a profile is a named list of
modules. A module should be independently understandable — if reading one
requires reading three others, it is doing too much.

## Configuration versus state

| Location | Holds | Owner |
| --- | --- | --- |
| `/etc/nexis/` | Desired configuration | You |
| `/system/generations/` | Realized immutable generations | NexisOS |
| `/store/` | Content-addressed artifacts | NexisOS |
| `/var/` | Machine and application state | The running system |
| `/home/` | User data, plus declared home layers | Users |

Backing up `/etc/nexis/` plus `/var` and `/home` is sufficient to reconstruct
the machine. `/store` and `/system` are derived and can be rebuilt.
