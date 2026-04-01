# nexisos
Main repository for the NexisOS ISO installer source code and core tools for building and testin the distro.

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

## 🔧 Building From Source Prerequisites

### Buildroot:
- build-essential
- make
- git
- python3
- wget
- unzip
- rsync
- cpio
- libncurses-dev
- libssl-dev
- bc
- flex
- bison
- curl

### Project:

- Packages
    - installer
        - blank
    - nexisos-core
        - meson
        - ninja
        - gcc
        - blake3 
        - lmdb
        - libarchive
        - libcurl
        - lz4
        - zstd
        - libseccomp
        - libcap
        - libselinux
        - elfutils
        - libsodium 

- scripts
    - blank

- virtual testing
    - QEMU + OVMF (UEFI support)

---

## Build ISO Targets & Testing

### Recommended Workflow
#### initialize buildroot submodule
git submodule update --init --recursive 

### meson commands

## Installer ISO Script


Before the end-user installs the distro, UEFI or boot settings must be set.

Once precondtions are met the iso launches the installer TUI.
After setting the option blank the hardware.toml and defaults toml files are created/added.

---

## Commands ran during install

<details>
<summary>Click to see</summary>

- `nexis generate-hardware` → Regenerate `hardware.toml`
- `nexis resolve-versions` → Update `nexis.lock` with latest versions
- `nexis build` → Build system from config
- `nexis switch` → Switch to new generation
- `nexis rollback` → Rollback to previous generation

</details>

---

## ⚙️ Example TOML Configurations

<details>
<summary>Click to see</summary>

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

### `hardware.toml`
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

### `packages/desktop.toml`
```toml
[[packages]]
name = "firefox"
version = "latest"
source = "https://github.com/mozilla/firefox.git"

[[packages]]
name = "steam"
version = "latest"
provider = "steam" # future version provider extension
```

### `nexis.lock`
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

### Example init service in `nexis_init.toml`
```toml
[[packages]]
name = ""

[packages.nexis-init_services.nginx]
type = "process"
command = "/usr/sbin/nginx -g 'daemon off;'"
depends = ["network", "filesystem"]
user = "nginx"
working_directory = "/var/www"
restart = "always"
log_file = "/var/log/nginx/access.log"
start_timeout = 30
enable = true
```

### Declarative File Management
Like Nix’s `writeText` or `environment.etc`, NexisPM allows declarative
creation and tracking of files (configs, dotfiles, system files). Files are
stored in `/nexis-store` with hash-based paths and symlinked into place,
ensuring immutability and reproducibility.

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
fleet = "?"
owner = "myuser"
group = "users"

[[files]]
path = "/home/myuser/.local/share/nexispm/test.txt"
source = "files/test.txt"   # reference to repo-tracked file
```

- `path` → target install path
- `content` → inline text (hash stored in `/nexis-store`)
- `source` → import an existing file into the store
- `mode`, `owner`, `group` → permission metadata

This gives one **unified method**: whether inline or external, all files are normalized into the store, then linked to their declared `path`.

### Default `files.toml` Template
A starter template for user and system file management:
```toml
# System Message of the Day
[[files]]
path = "/etc/motd"
content = "Welcome to NexisOS — Declarative and Secure!"
mode = "0644"
owner = "root"
group = "root"

# User shell configuration
[[files]]
path = "/home/user/.bashrc"
content = '''
# Custom aliases
alias ll="ls -la"
export EDITOR=vim
'''
mode = "0644"
owner = "user"
group = "users"

# Dotfile for fish shell
[[files]]
path = "/home/user/.config/fish/config.fish"
content = '''
set -g -x PATH $PATH /nexis-store/bin
alias gs="git status"
'''
mode = "0644"
owner = "user"
group = "users"

# Import external tracked file
[[files]]
path = "/home/user/.config/nvim/init.vim"
source = "dotfiles/init.vim"
mode = "0644"
owner = "user"
group = "users"
```

</details>

---

## 📚 Organization Resources

For general contribution, security, and governance policies across all NexisOS projects, see:

- [Contributing Guidelines](https://github.com/NexisOS/.github/blob/main/CONTRIBUTING.md)
- [Code of Conduct](https://github.com/NexisOS/.github/blob/main/CODE_OF_CONDUCT.md)
- [Security Policy](https://github.com/NexisOS/.github/blob/main/SECURITY.md)
- [Governance](https://github.com/NexisOS/.github/blob/main/GOVERNANCE.md)
- [Pull Request Template](https://github.com/NexisOS/.github/blob/main/PULL_REQUEST_TEMPLATE.md)
