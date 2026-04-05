# nexisos

Main repository for the NexisOS ISO installer source code and core tools for building and testing the distro.

---

## Download ISO

You can try the latest ISO build of NexisOS by downloading it from SourceForge:

> ⚠️ *Note: The ISO is currently experimental and intended for testing and feedback. Expect rapid iteration and updates.*

<div align="center">

| Build Status | Latest Stable Release |
|--------------|-----------------------|
| ![nexisos](https://img.shields.io/github/actions/workflow/status/NexisOS/nexisos/main.yml?label=nexisos) | ![GitHub release](https://img.shields.io/github/v/release/NexisOS/nexisos?label=latest%20stable) |

</div>

[Download NexisOS ISO](https://sourceforge.net/projects/nexisos/files/latest/download)

---

## Project Structure

```
nexisos/
├── Cargo.toml                  # workspace manifest
├── Cargo.lock
├── Makefile                    # build/test/iso orchestration
├── rust-toolchain.toml         # pinned Rust toolchain
├── deny.toml                   # cargo-deny license/advisory config
├── .cargo/
│   └── config.toml             # cross-compile + static linking settings
│
├── crates/
│   ├── nexis-common/           # shared types, errors, fs helpers, logging
│   ├── nexis-store/            # content-addressed store, blake3 hashing, rpath projection
│   ├── nexis-config/           # TOML config loading, schema validation, composition
│   ├── nexis-pm/               # package manager (build, resolve, generations, fleet)
│   ├── nexis-init/             # PID 1 init — single-threaded, pidfd, parallel boot
│   ├── nexis-guard/            # security orchestrator (firewall, SELinux, suricata, tetragon, clamav)
│   ├── nexis-cli/              # `nexis` command-line tool
│   ├── nexis-ctl/              # `nexisctl` runtime control tool
│   └── nexis-installer/        # TUI installer (ratatui + crossterm)
│
├── modules/                    # TOML system configuration modules
│   ├── core/                   # base.toml, networking.toml, users.toml
│   ├── hardware/               # amd.toml, intel.toml, arm.toml, riscv.toml
│   ├── profiles/               # minimal.toml, desktop.toml, server.toml
│   ├── services/               # nginx.toml, postgres.toml, ssh.toml
│   └── bundles/                # dev-machine.toml, web-server.toml
│
├── buildroot/                  # Buildroot submodule (ISO base system)
├── configs/                    # Buildroot defconfig, kernel configs
├── overlay/                    # rootfs overlay (files baked into the ISO)
├── build/                      # build artifacts (gitignored)
│   ├── rootfs/
│   ├── iso/
│   └── images/
│
├── scripts/
│   ├── build_rootfs.sh         # build root filesystem via Buildroot
│   ├── build_iso.sh            # assemble ISO with overlay + packages
│   └── qemu.sh                 # boot the ISO in QEMU with UEFI
│
├── tests/                      # integration test fixtures
│   └── fixtures/
│       ├── configs/
│       └── packages/
├── benches/                    # criterion benchmarks
│
├── shell-buildroot.nix         # nix-shell for Buildroot/ISO builds
├── shell-pkgs.nix              # nix-shell for Rust crate development
├── Dockerfile.dev              # container dev environment (non-nix)
├── .devcontainer/
│   └── devcontainer.json       # VS Code / Codespaces config
└── .envrc                      # direnv auto-activation for nix-shell
```

---

## Build Prerequisites

### Option A: Nix (recommended)

Nix provides reproducible, hermetic development shells. Two separate shells keep Buildroot's FHS requirements isolated from normal Rust development.

```bash
# Rust crate development
nix-shell shell-pkgs.nix

# Buildroot / ISO builds (FHS environment)
nix-shell shell-buildroot.nix
```

If you use [direnv](https://direnv.net/), the included `.envrc` auto-activates `shell-pkgs.nix` when you `cd` into the repo.

### Option B: Container (Docker / Podman)

For contributors without Nix:

```bash
# Build the dev image
docker build -f Dockerfile.dev -t nexisos-dev .

# Enter the dev shell
docker run -it --rm -v "$(pwd):/workspace" -w /workspace nexisos-dev
```

### Option C: VS Code Dev Containers / GitHub Codespaces

Open the repo in VS Code with the Dev Containers extension — it will auto-build from `.devcontainer/devcontainer.json`.

### Option D: Manual setup

#### Rust toolchain

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup show   # reads rust-toolchain.toml automatically
```

#### System dependencies (Rust crates)

```bash
# Debian/Ubuntu
sudo apt install build-essential pkg-config libssl-dev \
    libblake3-dev liblz4-dev libzstd-dev libseccomp-dev \
    libcap-dev libselinux1-dev libdbus-1-dev libsodium-dev \
    libelf-dev liblmdb-dev libarchive-dev libcurl4-openssl-dev
```

#### Buildroot host dependencies

```bash
sudo apt install make git python3 wget unzip rsync cpio \
    libncurses-dev libssl-dev bc flex bison curl \
    qemu-system-x86 ovmf
```

---

## Building

All build operations go through the Makefile. Run `make help` to see available targets.

### Rust crates

```bash
make check           # cargo check across the workspace
make build           # debug build of all crates
make release         # optimized release build
make test            # run all tests
make clippy          # lint with clippy
make fmt             # format code with rustfmt
make deny            # check licenses and advisories
```

### ISO

```bash
make rootfs          # build root filesystem via Buildroot
make iso             # assemble bootable ISO
make qemu            # boot the ISO in QEMU with UEFI
```

### Individual crates

```bash
make installer       # build nexis-installer only
make init            # build nexis-init only
make guard           # build nexis-guard only
```

### Full workflow

```bash
make all             # build everything: crates (release) + rootfs + ISO
make clean           # remove build artifacts
```

---

## Installer Flow

The live ISO boots directly into the TUI installer on `tty1` — no login shell, no live desktop. The installer is a single static binary (`nexis-installer`) built with `ratatui` and `crossterm`, running on the raw Linux VT with 256-color support.

Steps: locale → keyboard → network → disk selection → partitioning → filesystem → encryption (LUKS2) → hostname → timezone → root password → user account → profile selection → summary → install → reboot.

On completion, the installer generates `hardware.toml` (auto-detected from the machine) and the base TOML configuration files, then runs the initial system build.

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

## Development Environment

| Method | File | Who it's for |
|--------|------|--------------|
| Nix shell | `shell-pkgs.nix`, `shell-buildroot.nix` | NixOS / Nix users |
| direnv | `.envrc` | Auto-activate nix-shell on `cd` |
| Docker | `Dockerfile.dev` | Any Linux/macOS with Docker |
| Dev Container | `.devcontainer/devcontainer.json` | VS Code, Codespaces |
| Manual | See prerequisites above | Direct install on host |

---

## Organization Resources

For general contribution, security, and governance policies across all NexisOS projects, see:

- [Contributing Guidelines](https://github.com/NexisOS/.github/blob/main/CONTRIBUTING.md)
- [Code of Conduct](https://github.com/NexisOS/.github/blob/main/CODE_OF_CONDUCT.md)
- [Security Policy](https://github.com/NexisOS/.github/blob/main/SECURITY.md)
- [Governance](https://github.com/NexisOS/.github/blob/main/GOVERNANCE.md)
- [Pull Request Template](https://github.com/NexisOS/.github/blob/main/PULL_REQUEST_TEMPLATE.md)
