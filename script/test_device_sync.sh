#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
cargo fmt --manifest-path rust/DeviceSync/Cargo.toml --all -- --check
cargo test --manifest-path rust/DeviceSync/Cargo.toml --workspace --locked
cargo clippy --manifest-path rust/DeviceSync/Cargo.toml --workspace --all-targets --locked -- -D warnings
