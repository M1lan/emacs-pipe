# ── emacs-pipe Justfile -- build, test, parity ──
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

export RUST_BACKTRACE := "1"

# Default target -- list recipes
default:
    @just --list --unsorted

# ── Meta ──

# Print project + tool versions
info:
    @printf 'project        emacs-pipe (epipe)\n'
    @printf 'rust binary    target/release/epipe\n'
    @printf 'bash binary    bash/epipe.bash\n'
    @cargo --version
    @rustc --version
    @/opt/homebrew/bin/bash --version | head -1
    @if command -v shellcheck >/dev/null; then shellcheck --version | head -2; else echo "shellcheck: not installed"; fi
    @if command -v bats >/dev/null; then bats --version; else echo "bats: not installed"; fi

# ── Build ──

# Build rust binary in release mode
build:
    cargo build --release

# Build rust binary in debug mode
build-debug:
    cargo build

# ── Run ──

# Run rust binary with passthrough args
run *args:
    cargo run --release --quiet -- {{args}}

# Run bash script with passthrough args
run-bash *args:
    ./bash/epipe.bash {{args}}

# ── Test ──

# Run everything: cargo unit tests + bats parity for both impls
test: test-rust test-bash test-rust-parity

# Cargo unit tests
test-rust:
    cargo test --release

# bats parity tests against the bash implementation
test-bash: build-bash-deps
    EPIPE_BIN="$PWD/bash/epipe.bash" bats tests/shared.bats

# bats parity tests against the rust implementation
test-rust-parity: build
    EPIPE_BIN="$PWD/target/release/epipe" bats tests/shared.bats

# Internal -- ensure bash bits are executable
build-bash-deps:
    @chmod +x bash/epipe.bash tests/fixtures/fake-emacsclient.bash tests/fixtures/helpers.bash

# ── Lint & Format ──

# Format rust
fmt:
    cargo fmt --all

# Check rust formatting (CI gate)
fmt-check:
    cargo fmt --all -- --check

# Lint rust with clippy
clippy:
    cargo clippy --all-targets --all-features -- -D warnings

# Lint bash with shellcheck
shellcheck:
    @if command -v shellcheck >/dev/null 2>&1; then \
      shellcheck bash/epipe.bash tests/fixtures/fake-emacsclient.bash tests/fixtures/helpers.bash; \
    else echo "shellcheck not installed -- skipping"; fi

# Run all linters
lint: fmt-check clippy shellcheck

# ── Check & Verify ──

# Full pre-push gate: format + lint + tests
verify: fmt-check clippy shellcheck test

# ── Clean ──

# Wipe build artifacts
clean:
    cargo clean
    rm -rf target/

# ── Documentation ──

# Print the help text for both impls (visual parity check)
help-diff: build build-bash-deps
    @echo "── rust ──"
    @target/release/epipe --help
    @echo
    @echo "── bash ──"
    @./bash/epipe.bash --help
