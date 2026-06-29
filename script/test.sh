#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

cargo test --manifest-path rust/SearchIndexCore/Cargo.toml
cargo build --manifest-path rust/SearchIndexCore/Cargo.toml --release
swift test
