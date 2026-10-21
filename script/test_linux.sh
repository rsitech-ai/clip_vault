#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
LINUX_IMAGE="${LINUX_VALIDATION_IMAGE:-clipvault-linux-validation}"
LINUX_TARGET="${LINUX_TARGET_VOLUME:-clipvault-linux-target}"
PLATFORM_ARGS=()
if [[ -n "${LINUX_PLATFORM:-}" ]]; then PLATFORM_ARGS=(--platform "$LINUX_PLATFORM"); fi
# The conditional expansion also supports macOS Bash 3.2 with nounset enabled.
docker build ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} -t "$LINUX_IMAGE" -f Packaging/linux/Dockerfile .
docker run ${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"} --rm --memory=6g --cpus=2 \
  -v "$ROOT_DIR:/workspace:ro" \
  -v clipvault-linux-cargo:/usr/local/cargo/registry \
  -v "$LINUX_TARGET:/build" \
  -e CARGO_TARGET_DIR=/build \
  "$LINUX_IMAGE" bash -c 'cargo test --manifest-path rust/DeviceSync/Cargo.toml --workspace --locked && cargo build --manifest-path rust/DeviceSync/Cargo.toml -p clipvault-linux --locked && cargo clippy --manifest-path rust/DeviceSync/Cargo.toml --workspace --all-targets --locked -- -D warnings'
