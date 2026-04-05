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
├── build/                      # final ISO output (gitignored)
│
├── scripts/
│   ├── build_rootfs.sh         # build root filesystem via Buildroot
│   ├── build_iso.sh            # assemble ISO with overlay + packages
│   └── qemu.sh                 # boot the ISO in QEMU with UEFI
│
├── tests/                      # integration test fixtures
│   └── fixtures/
├── benches/                    # criterion benchmarks
│
├── shell-buildroot.nix         # nix-shell for Buildroot/ISO builds
├── shell-pkgs.nix              # nix-shell for Rust crate development
├── Dockerfile.dev              # container dev environment
├── .devcontainer/
│   └── devcontainer.json       # VS Code / Codespaces config
└── .envrc                      # direnv auto-activation for nix-shell
```

ISOs are output as `build/nexisos-<version>-<arch>.iso` (e.g. `build/nexisos-0.1.0-x86_64.iso`). Buildroot intermediate artifacts stay in `buildroot/output/` and are never copied out.

---

## Development Environment

All contributors must use an ephemeral, isolated development environment regardless of host OS. This keeps builds reproducible and avoids polluting your system.

### Linux

**Nix (recommended):**

```bash
# Install Nix: https://nixos.org/download
# Then:
nix-shell shell-pkgs.nix          # Rust crate development
nix-shell shell-buildroot.nix     # Buildroot / ISO builds (FHS sandbox)
```

If you use [direnv](https://direnv.net/), the included `.envrc` auto-activates `shell-pkgs.nix` when you `cd` into the repo.

**Docker / Podman:**

```bash
docker build -f Dockerfile.dev -t nexisos-dev .
docker run -it --rm -v "$(pwd):/workspace" -w /workspace nexisos-dev
```

### macOS

macOS cannot build the ISO (Buildroot and the Linux kernel require a Linux host), but you can work on all Rust crates.

**Nix (recommended):**

```bash
# Install Nix: https://nixos.org/download
nix-shell shell-pkgs.nix
```

**Docker (for full ISO builds):**

```bash
docker build -f Dockerfile.dev -t nexisos-dev .
docker run -it --rm -v "$(pwd):/workspace" -w /workspace nexisos-dev
```

This gives you a full Linux environment inside the container where `make iso` will work.

### Windows

Use WSL2 with any of the Linux methods above. Native Windows builds are not supported.

```powershell
# Install WSL2 if you haven't
wsl --install -d Ubuntu-24.04

# Then inside WSL:
cd /mnt/c/Users/you/repos/nexisos
```

From there, follow the Linux instructions (Nix or Docker). If using Docker Desktop on Windows, enable the WSL2 backend and run docker commands from inside WSL.

### VS Code / GitHub Codespaces

Open the repo in VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension — it auto-builds from `.devcontainer/devcontainer.json`. This works on all three platforms and in GitHub Codespaces with zero local setup.

### Environment summary

| Host OS | Rust crate dev | ISO builds | Method |
|---------|---------------|------------|--------|
| Linux | ✓ | ✓ | Nix shell, Docker, or manual |
| macOS | ✓ | ✓ (via Docker) | Nix shell for Rust, Docker for ISO |
| Windows | ✓ (WSL2) | ✓ (WSL2) | WSL2 + Nix or Docker |
| Any | ✓ | ✓ | VS Code Dev Container / Codespaces |

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
make iso             # assemble bootable ISO → build/nexisos-<version>-<arch>.iso
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

## Organization Resources

For general contribution, security, and governance policies across all NexisOS projects, see:

- [Contributing Guidelines](https://github.com/NexisOS/.github/blob/main/CONTRIBUTING.md)
- [Code of Conduct](https://github.com/NexisOS/.github/blob/main/CODE_OF_CONDUCT.md)
- [Security Policy](https://github.com/NexisOS/.github/blob/main/SECURITY.md)
- [Governance](https://github.com/NexisOS/.github/blob/main/GOVERNANCE.md)
- [Pull Request Template](https://github.com/NexisOS/.github/blob/main/PULL_REQUEST_TEMPLATE.md)
