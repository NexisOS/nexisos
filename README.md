<div align="center">
  <img src="https://github.com/NexisOS/.github/blob/main/NexisOS2.png" width="50%" alt="NexisOS Logo">
</div>

# NexisOS

A free and open-source Linux distribution built around **transparency, control, reproducibility, security, and system integrity** through declarative system configuration.

NexisOS is inspired by NixOS, but takes a different approach to the relationship between package management and the Linux runtime filesystem:

> **The package store should be immutable and reproducible, but the Linux runtime should remain boring.**

Packages are built reproducibly into a content-addressed store. The store is not the runtime namespace. Applications see conventional paths such as `/usr/bin/foo`, allowing the dynamic linker, SELinux, existing binaries, and standard Linux administration tools to work normally.

NexisOS is written primarily in **Nim**, with **C** used where kernel integration or existing system libraries make it the better fit.

---

## Why NexisOS?

NexisOS aims to combine four properties that are rarely designed together:

* **Reproducible package construction**
* **Immutable system state**
* **Conventional FHS-compatible Linux runtime semantics**
* **SELinux and other security mechanisms as first-class parts of the system**

The core idea is to separate the **immutable package store** from the **runtime filesystem**.

```text
Configuration
     ↓
Dependency graph
     ↓
Planner
     ↓
Reproducible builds ──────┐
     ↓                    │
Content-addressed store   │
     ↓                    │
Artifact metadata ────────┤
                          ▼
                    State database
                          ↓
                    Generation plan
                          ↓
                    Sealed composition
                          ↓
                    Atomic activation
                          ↓
                  Normal Linux runtime
```

This means NexisOS can provide generation-based rollback and reproducible builds without making `/store/<hash>/...` paths the interface applications have to use.

---

## Core principles

* **Declarative configuration** — System state is described with schema-validated TOML.
* **Reproducibility** — Builds use declared and verified inputs.
* **Content addressing** — Store objects are identified by their content.
* **Immutable generations** — System state is assembled into sealed filesystem generations.
* **Atomic activation** — Changes are prepared and activated as complete generations.
* **Rollback by design** — Previous generations remain available for fast rollback.
* **Standard Linux compatibility** — The runtime uses a conventional FHS layout.
* **Security by construction** — SELinux, seccomp, namespaces, capabilities, and cgroups are part of the system model.
* **Real dependency conflicts** — Conflicting files in a generation fail the build rather than silently choosing one.
* **Decentralized package definitions** — There is no single authoritative package repository.
* **Composable configuration** — Modules and profiles allow configurations to scale across multiple machines.
* **Contained development environments** — Project dependencies can be isolated without polluting the host.

---

## System manager, not just a package manager

`nexis` is a **system manager**.

It does not only decide which packages exist. It manages the relationship between:

* packages and their dependencies,
* system generations,
* services,
* users and home configuration,
* security policy,
* firewall rules,
* development environments,
* containers,
* and garbage collection roots.

The goal is for these things to describe one coherent system state.

For example, removing a service from the declaration should also remove its associated firewall exposure and security policy. There should not be separate imperative configuration that can drift away from the declared system.

---

## Store and runtime

NexisOS uses a content-addressed package store, but the store is deliberately **not** the runtime filesystem.

```text
/store
  └── immutable content-addressed artifacts

/system/generations/
  ├── 1
  ├── 2
  └── 3
       ↓
    composefs
       ↓
      /usr
      /etc
      /var
```

Generations are sealed composefs-based filesystem compositions built from store artifacts.

The same underlying objects can be shared by:

* the running system,
* previous generations,
* user environments,
* development environments,
* and containers.

This provides deduplication and shared page cache without requiring the runtime itself to expose content-addressed paths.

---

## Compositions

NexisOS uses one composition mechanism for several purposes:

* **System generations**
* **Per-user home layers**
* **Development environments**
* **Containers**

Each composition can be merged, validated for path collisions, sealed, labelled for SELinux, and registered as a garbage-collection root.

This keeps the underlying model small while allowing the same guarantees to apply across different environments.

---

## Dependency and build model

NexisOS deliberately separates several identities rather than representing everything with one hash:

* **Source identity** — what source definition was used.
* **Package identity** — what was declared.
* **Build identity** — what build inputs and policy were used.
* **Artifact identity** — the resulting content.
* **Interface identity** — what a runtime dependency provides.

This allows the system to distinguish changes that actually require rebuilding dependents from changes that do not.

Builds are performed in controlled sandboxes with declared environments and inputs. Independent nodes in the dependency graph can build concurrently.

Definitions are resolved from **ordered, pinned sources** rather than a mandatory central repository.

---

## Security model

Security is intended to be part of the system architecture rather than something installed afterward.

The design includes:

* SELinux enforcing
* seccomp
* Linux namespaces
* capabilities
* cgroups
* service-specific security contracts
* derived firewall rules
* build sandboxing
* sealed generation metadata

SELinux labels are intended to be stored with the generation composition so that filesystem contents and security contexts change together during activation and rollback.

---

## Compared with NixOS

| Area          | NixOS                               | NexisOS                     |
| ------------- | ----------------------------------- | --------------------------- |
| Configuration | Nix                                 | Schema-validated TOML       |
| Package store | `/nix/store`                        | Content-addressed `/store`  |
| Runtime       | Store paths are part of composition | Conventional FHS runtime    |
| System image  | NixOS closure                       | Sealed composefs generation |
| SELinux       | Difficult with store paths          | First-class design goal     |
| Init          | systemd                             | `nexis-init`                |
| Definitions   | nixpkgs ecosystem                   | Decentralized sources       |
| Rollback      | Generations                         | Generations                 |

NexisOS is **not intended to be a reimplementation of NixOS**. It takes inspiration from NixOS's declarative and reproducible model while making different trade-offs around the Linux runtime, security model, package definitions, and system composition.

---

## ⚠️ Development status

**Early development — not yet pre-alpha.**

There are currently:

* **No releases**
* **No published ISOs**
* **No production-ready operating system**
* **No stable package ecosystem**
* **No guarantee that current formats or APIs will remain compatible**

The architecture is actively evolving. Security properties described in the documentation should be considered **design goals unless explicitly marked as implemented and tested**.

The installer currently provides the most complete end-to-end functionality and operates in dry-run mode without modifying disks.

See **[TODO.md](TODO.md)** for the current unblocking order and **[docs/roadmap.md](docs/roadmap.md)** for the development phases.

---

## Building

Requires **Nim 2.2+**.

```sh
nimble buildNexis
nimble buildInstaller
nimble testInstaller

nimble installer
nimble preview
nimble previewVt
nimble animate
nimble plan
nimble genconfig

nimble build
nimble check
nimble distro
```

See **[QUICKSTART.md](QUICKSTART.md)** for the complete build and VM workflow.

## What this repo does
The goal is to make the installer iso with the distro's packages
Once you flash to a flashdrive and boot the tui installer will launch.

This is not a live environment, it is just an easy way to install the distro.

### Main requirements

**Package development**

- Nim
- GCC or Clang
- GNU binutils
- GNU Make
- pkg-config
- Git
- Python 3

**ISO / VM development**

- cpio
- gzip
- zstd
- SquashFS tools
- GRUB
- xorriso
- mtools
- QEMU
- KVM
- OVMF

---

## Roadmap

The roadmap is maintained separately in **[docs/roadmap.md](docs/roadmap.md)**.

| Phase | Goal                                                          | Status      |
| ----- | ------------------------------------------------------------- | ----------- |
| 0     | Skeleton — store, index, resolver, parser, installer core     | In progress |
| 1     | Realisation — scheduler, sandbox enforcement, dry-run rebuild | Planned     |
| 2     | Generations — composition, activation, rollback               | Planned     |
| 3     | `nexis-init` — supervision and service management             | Planned     |
| 4     | Coverage — package tooling and ecosystem support              | Planned     |
| 5     | Security — SELinux and firewall integration                   | Planned     |
| 6     | Usability — environments, home layers, diagnostics            | Planned     |
| 7     | Distribution — signing, Secure Boot, benchmarks, ISOs         | Planned     |

---

## Documentation

This README is a summary. More detailed architecture documentation can be found in the doc directory.

| Document                                              | Purpose                               |
| ----------------------------------------------------- | ------------------------------------- |
| [QUICKSTART.md](QUICKSTART.md)                        | Build NexisOS and boot it in a VM     |
| [architecture.md](docs/architecture.md)               | Overall architecture and system model |
| [package-format.md](docs/package-format.md)           | Package definition format             |
| [configuration.md](docs/configuration.md)             | System configuration and modules      |
| [authoring.md](docs/authoring.md)                     | Writing package definitions           |
| [comparison.md](docs/comparison.md)                   | Comparison with other systems         |
| [security.md](docs/security.md)                       | Security architecture                 |
| [selinux.md](docs/selinux.md)                         | SELinux integration                   |
| [firewall.md](docs/firewall.md)                       | Firewall model                        |
| [init.md](docs/init.md)                               | `nexis-init`                          |
| [systemd-replacement.md](docs/systemd-replacement.md) | systemd replacement strategy          |
| [home.md](docs/home.md)                               | User configuration and home layers    |
| [environments.md](docs/environments.md)               | Development environments              |
| [installer.md](docs/installer.md)                     | Installer architecture                |
| [packaging-strategy.md](docs/packaging-strategy.md)   | Decentralized package definitions     |
| [cli.md](docs/cli.md)                                 | `nexis` command interface             |
| [benchmarks.md](docs/benchmarks.md)                   | Benchmarking methodology              |
| [docs/roadmap.md](docs/roadmap.md)                    | Development roadmap                   |
| [TODO.md](TODO.md)                                    | Current work and dependencies         |

Architecture Decision Records are available under [`docs/adr-*`](docs/).

---

## Community

Use GitHub Issues for discussion, bug reports, and feedback.

* [Contributing Guidelines](https://github.com/NexisOS/.github/blob/main/CONTRIBUTING.md)
* [Code of Conduct](https://github.com/NexisOS/.github/blob/main/CODE_OF_CONDUCT.md)
* [Security Policy](https://github.com/NexisOS/.github/blob/main/SECURITY.md)
* [Governance](https://github.com/NexisOS/.github/blob/main/GOVERNANCE.md)

**Contact:** [kyle.gortych.dev@gmail.com](mailto:kyle.gortych.dev@gmail.com)

Please prefer GitHub Issues where possible.

---

## License

**GNU General Public License v3.0.**

Provided "as is", without warranty of any kind. NexisOS collects no user data, provides no hosted services, and is independently developed.

AI-assisted development is permitted under the conditions in the [AI Policy](https://github.com/NexisOS/.github/blob/main/AI_Policy.md). Human review is mandatory, and contributors remain responsible for what they submit.
