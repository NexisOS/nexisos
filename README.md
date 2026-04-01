# nexisos

Main repository for the NexisOS ISO installer source code and core tools for building and testing the distro.

---

## Download ISO

You can try the latest ISO build of NexisOS by downloading it from SourceForge:

[Download NexisOS ISO](https://sourceforge.net/projects/nexisos/files/latest/download)

> ⚠️ *Note: The ISO is currently experimental and intended for testing and feedback. Expect rapid iteration and updates.*

<div align="center">

| Build Status | Latest Stable Release |
|--------------|-----------------------|
| ![nexisos](https://img.shields.io/github/actions/workflow/status/NexisOS/nexisos/main.yml?label=nexisos) | ![GitHub release](https://img.shields.io/github/v/release/NexisOS/nexisos?label=latest%20stable) |

</div>

---

## Project Structure

```
nexisos/
├── buildroot/                   # Buildroot git submodule (ISO base system)
├── configs/                     # Kernel and system configuration files
├── overlay/                     # Root filesystem overlay applied to the ISO
├── packages/
│   ├── nexisos-core/            # Core distro tooling (C, built with Meson + Ninja)
│   │   ├── bin/
│   │   │   ├── nexis/           # CLI entry point (nexis build, switch, rollback, etc.)
│   │   │   ├── nexisctl/        # Service control interface (talks to nexis-init)
│   │   │   ├── nexis-guard/     # Security orchestrator (ClamAV, Suricata, Tetragon)
│   │   │   └── nexis-init/      # Custom PID 1 (epoll, pidfd, sd-bus D-Bus compat)
│   │   ├── lib/
│   │   │   ├── common/          # Shared utilities
│   │   │   └── pm/              # Package manager library
│   │   │       ├── build/       # Sandboxed build executor
│   │   │       ├── config/      # TOML config loading, schema validation, lockfiles
│   │   │       ├── core/        # Build orchestration, generation switch
│   │   │       ├── files/       # Declarative file management, content addressing
│   │   │       ├── fleet/       # Fleet deployment, profiles, machine management
│   │   │       ├── generations/ # Generation management, rollback, GRUB entries
│   │   │       ├── packages/    # Dependency resolution, fetching, caching
│   │   │       ├── security/    # SELinux, immutability, permissions
│   │   │       ├── services/    # Init service generation, initctl bridge
│   │   │       ├── store/       # CAS store, LMDB metadata, GC, hashing
│   │   │       ├── users/       # User/home/profile management
│   │   │       └── vcs/         # Git integration (branches, tags)
│   │   ├── include/nexis/       # Public headers
│   │   ├── modules/             # Bundled TOML modules (profiles, hardware, services)
│   │   ├── tests/               # Integration tests
│   │   ├── bench/               # Benchmarks (store ops, etc.)
│   │   ├── meson.build
│   │   └── meson_options.txt
│   └── tui-installer/           # TUI installer launched from the ISO
├── scripts/
│   ├── build_iso.sh             # Assemble final ISO from Buildroot + overlay + packages
│   ├── build_rootfs.sh          # Build the root filesystem
│   └── qemu.sh                  # Launch ISO in QEMU for testing
├── build/                       # Build output (images, iso, rootfs)
├── meson.build                  # Top-level Meson build definition
├── meson_options.txt
├── shell-buildroot.nix          # Nix shell for Buildroot dependencies
└── shell-pkgs.nix               # Nix shell for package development
```

---

## Build Prerequisites

### Buildroot host dependencies

```bash
sudo apt install build-essential make git python3 wget unzip rsync \
    cpio libncurses-dev libssl-dev bc flex bison curl
```

### nexisos-core (C libraries)

| Library | Purpose |
| :------ | :------ |
| `meson` + `ninja` | Build system |
| `gcc` | C compiler |
| `libblake3` | BLAKE3 content hashing (CAS store, package identity) |
| `liblmdb` | Metadata DB — memory-mapped B+ tree for package index and generation history |
| `libarchive` | Archive extraction and erofs image composition |
| `libcurl` | Package fetching, binary substitution downloads |
| `liblz4` | LZ4 compression for erofs generation images |
| `libzstd` | Zstd compression for package distribution |
| `libseccomp` | seccomp-BPF sandbox profiles for builds and services |
| `libcap` | Capability dropping in nexis-init service spawning |
| `libselinux` | SELinux context transitions, label-at-build for erofs images |
| `libsystemd` | `sd-bus` for the `org.freedesktop.systemd1` D-Bus compatibility layer in nexis-init |
| `elfutils` | ELF inspection for InterfaceHash (ABI-level rebuild decisions) |
| `libsodium` | Cryptographic signing for package verification |

### Virtual testing

QEMU + OVMF (UEFI support) for booting the ISO locally.

---

## Building from Source

### 1. Clone with submodules

```bash
git clone --recurse-submodules https://github.com/NexisOS/nexisos.git
cd nexisos
# Or if already cloned:
git submodule update --init --recursive
```

### 2. Build nexisos-core

```bash
cd packages/nexisos-core
meson setup builddir
ninja -C builddir
ninja -C builddir test    # run tests
```

### 3. Build the ISO

```bash
# From the repo root
./scripts/build_rootfs.sh   # build root filesystem via Buildroot
./scripts/build_iso.sh      # assemble ISO with overlay + packages
```

### 4. Test in QEMU

```bash
./scripts/qemu.sh           # boots the ISO with UEFI via OVMF
```

---

## Installer Flow

The live ISO boots into a TUI installer. Before installing, UEFI/Secure Boot settings should be configured in firmware.

The installer walks through disk partitioning, locale, timezone, user creation, and profile selection. On completion it generates `hardware.toml` (auto-detected from the machine) and the base TOML configuration files, then runs the initial system build.

<details>
<summary>Commands ran during install</summary>

- `nexis generate-hardware` — detect hardware and write `hardware.toml`
- `nexis resolve-versions` — resolve declared packages and write `nexis.lock`
- `nexis build` — build the system from config (CAS store → erofs generation image)
- `nexis switch` — atomically switch to the new generation
- `nexis rollback` — roll back to the previous generation

</details>

---

## Example TOML Configurations

<details>
<summary>Click to expand</summary>

### Minimal `config.toml`

```toml
[system]
hostname = "myhost"
timezone = "UTC"
version = "0.1.0"
kernel = "linux-6.9.2"
kernel_source = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.9.2.tar.xz"
kernel_config = "configs/kernel-default.config"

[users.myuser]
password_hash = "$argon2id$v=19$m=65536,t=3,p=4$..."
shell = "/bin/bash"
home = "/home/myuser"

[system.locale]
lang = "en_US.UTF-8"
keyboard_layout = "us"

[network]
interface = "eth0"
dhcp = true

[includes]
paths = [
  "packages/hardware.toml",
  "packages/editors.toml",
  "packages/devtools.toml"
]

[[packages]]
name = "vim"
version = "latest"
prebuilt = "https://github.com/vim/vim/releases/download/{tag}/vim-{tag}-linux-{arch}.tar.gz"
fallback_to_source = true
source = "https://github.com/vim/vim.git"
```

### `hardware.toml` (auto-generated by installer)

```toml
[cpu]
model = "amd_ryzen"
cores = 16
threads = 32
flags = ["sse4_2", "avx2", "aes"]

[gpu]
model = "nvidia-rtx-4090"
driver = "nvidia"

[storage]
devices = [
  { path = "/dev/nvme0n1", fs = "xfs", mount = "/", reflink = true },
  { path = "/dev/sda1", fs = "ext4", mount = "/home" }
]

[network]
interfaces = [
  { name = "eth0", mac = "00:11:22:33:44:55", dhcp = true }
]
```

### `nexis.lock` (auto-generated by `nexis resolve-versions`)

```toml
[[packages]]
name = "firefox"
version = "120.0"
resolved = "https://github.com/mozilla/firefox.git?tag=v120.0"

[[packages]]
name = "linux"
version = "6.10.1"
resolved = "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git?tag=v6.10.1"
```

### Service declaration in `services.toml`

```toml
[services.nginx]
exec = "/usr/sbin/nginx"
type = "notify"
restart = "on-failure"
restart_sec = 5
requires = ["network-online.target"]
after = ["network-online.target"]
user = "nginx"
cgroup.memory_max = "512M"
selinux.type = "httpd_t"
enable = true
```

### Declarative file management

Files are content-addressed in the store and symlinked into place, ensuring immutability and reproducibility.

```toml
[[files]]
path = "/etc/motd"
content = "Welcome to NexisOS — Managed by nexispm"
mode = "0644"
owner = "root"
group = "root"

[[files]]
path = "/home/myuser/.config/fish/config.fish"
content = '''
set -g -x PATH $PATH /nexis-store/bin
alias ll="ls -la"
'''
mode = "0644"
owner = "myuser"
group = "users"

[[files]]
path = "/home/myuser/.local/share/nexispm/test.txt"
source = "files/test.txt"   # reference to repo-tracked file
```

Fields: `path` (target install path), `content` (inline text) or `source` (import from repo), `mode`/`owner`/`group` (permissions). All files are normalized into the CAS store then linked to their declared path.

</details>

---

## Organization Resources

For general contribution, security, and governance policies across all NexisOS projects, see:

- [Contributing Guidelines](https://github.com/NexisOS/.github/blob/main/CONTRIBUTING.md)
- [Code of Conduct](https://github.com/NexisOS/.github/blob/main/CODE_OF_CONDUCT.md)
- [Security Policy](https://github.com/NexisOS/.github/blob/main/SECURITY.md)
- [Governance](https://github.com/NexisOS/.github/blob/main/GOVERNANCE.md)
- [Pull Request Template](https://github.com/NexisOS/.github/blob/main/PULL_REQUEST_TEMPLATE.md)
