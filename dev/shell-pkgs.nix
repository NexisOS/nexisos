{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "nexisos-dev";

  buildInputs = with pkgs; [
    # Rust toolchain
    rustup

    # Build essentials
    pkg-config
    openssl.dev

    # Blake3 hashing (nexis-store)
    blake3

    # Compression (store, packages)
    lz4.dev
    zstd.dev

    # Sandbox / capabilities (nexis-init, build sandbox)
    libseccomp.dev
    libcap.dev

    # SELinux (nexis-guard, store labeling)
    libselinux.dev

    # D-Bus (nexis-init systemd compat layer)
    dbus.dev

    # ELF inspection (ABI-level rebuild decisions)
    elfutils.dev

    # Crypto signing (package verification)
    libsodium.dev

    # Metadata DB (store index, generation history)
    lmdb.dev

    # Archive handling (erofs images, package extraction)
    libarchive.dev

    # Network (package fetching)
    curl.dev

    # Dev tooling
    cargo-deny       # license + advisory audits
    cargo-watch      # auto-rebuild on save
    cargo-nextest    # faster test runner
  ];

  RUST_BACKTRACE = "1";

  shellHook = ''
    echo "nexisos dev shell — Rust $(rustc --version 2>/dev/null || echo 'not installed')"
    echo "run: make check / make build / make test"
  '';
}
