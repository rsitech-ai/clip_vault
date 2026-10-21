#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Match the Swift package deployment floor, including native C objects in Rust dependencies.
MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --manifest-path "$ROOT_DIR/rust/DeviceSync/Cargo.toml" --release -p clipvault-sync-bridge --locked
python3 "$ROOT_DIR/script/generate_sync_notices.py" "$ROOT_DIR/dist/ClipVaultSync-THIRD-PARTY-NOTICES.txt"
