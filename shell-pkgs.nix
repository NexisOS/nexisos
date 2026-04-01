with import <nixpkgs> {};

mkShell {
  buildInputs = [
    gcc
    meson
    ninja
    pkg-config

    curl
    libarchive
    lmdb
    lz4
    zstd
    libseccomp
    libcap
    elfutils
    libsodium
  ];
}
