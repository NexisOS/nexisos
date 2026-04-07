{ pkgs ? import <nixpkgs> {} }:

(pkgs.buildFHSEnv {
  name = "buildroot-env";
  multiPkgs = pkgs: with pkgs; [
    # Buildroot host tools
    bash coreutils gcc gnumake binutils bison flex bc
    perl unzip cpio rsync which file python3 git wget patch
    ncurses.dev findutils util-linux gawk gnutar zlib glibc
    diffutils gettext xz gzip bzip2 lzop lz4 zstd
    pkg-config autoconf automake libtool texinfo
    openssl.dev curl subversion

    # ISO assembly
    xorriso
    squashfsTools
    dosfstools       # mkfs.fat for EFI partition
    e2fsprogs        # mkfs.ext4
    btrfs-progs      # mkfs.btrfs
    xfsprogs         # mkfs.xfs
    cryptsetup       # LUKS support in ISO

    # QEMU + UEFI testing
    qemu
    qemu_kvm
    qemu-utils
    OVMF             # UEFI firmware for QEMU
  ];

  runScript = "bash";

}).env
