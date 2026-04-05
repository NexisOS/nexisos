.PHONY: help check build release test clippy fmt fmt-check deny \
       installer init guard cli ctl \
       installer-static init-static \
       rootfs iso qemu \
       all clean

VERSION := $(shell grep '^version' Cargo.toml | head -1 | sed 's/.*"\(.*\)"/\1/')
ARCH    := $(shell uname -m)

# Default target
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Rust workspace ────────────────────────────────────────────────────────────

check: ## Cargo check all crates
	cargo check --workspace

build: ## Debug build all crates
	cargo build --workspace

release: ## Release build all crates
	cargo build --workspace --release

test: ## Run all tests
	cargo test --workspace

clippy: ## Lint with clippy
	cargo clippy --workspace -- -D warnings

fmt: ## Format code
	cargo fmt --all

fmt-check: ## Check formatting without modifying
	cargo fmt --all -- --check

deny: ## Run cargo-deny (licenses + advisories)
	cargo deny check

# ── Individual crates ─────────────────────────────────────────────────────────

installer: ## Build nexis-installer
	cargo build -p nexis-installer --release

init: ## Build nexis-init
	cargo build -p nexis-init --release

guard: ## Build nexis-guard
	cargo build -p nexis-guard --release

cli: ## Build nexis CLI
	cargo build -p nexis-cli --release

ctl: ## Build nexisctl
	cargo build -p nexis-ctl --release

# ── Static binary (for ISO) ──────────────────────────────────────────────────

installer-static: ## Build static nexis-installer for the ISO
	RUSTFLAGS='-C target-feature=+crt-static' \
		cargo build -p nexis-installer --release --target x86_64-unknown-linux-musl

init-static: ## Build static nexis-init for the ISO
	RUSTFLAGS='-C target-feature=+crt-static' \
		cargo build -p nexis-init --release --target x86_64-unknown-linux-musl

# ── Buildroot / ISO ──────────────────────────────────────────────────────────

rootfs: ## Build root filesystem via Buildroot
	./scripts/build_rootfs.sh

iso: ## Assemble bootable ISO → build/nexisos-$(VERSION)-$(ARCH).iso
	@mkdir -p build
	./scripts/build_iso.sh
	@echo "ISO: build/nexisos-$(VERSION)-$(ARCH).iso"

qemu: ## Boot the ISO in QEMU with UEFI
	./scripts/qemu.sh

# ── Aggregate targets ────────────────────────────────────────────────────────

all: release rootfs iso ## Build everything: crates + rootfs + ISO

clean: ## Remove build artifacts
	cargo clean
	rm -f build/*.iso
