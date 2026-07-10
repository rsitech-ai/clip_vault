#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
PKG_PATH="${PKG_PATH:-$ROOT_DIR/dist/AppStore/$APP_NAME-$APP_VERSION-$APP_BUILD.pkg}"
ASC_API_KEY="${ASC_API_KEY:-}"
ASC_API_ISSUER="${ASC_API_ISSUER:-}"
ASC_API_KEY_PATH="${ASC_API_KEY_PATH:-}"
MODE="upload"

usage() {
  echo "Usage: $0 [--validate-only]" >&2
}

case "${1:-}" in
  "") ;;
  --validate-only) MODE="validate" ;;
  *)
    echo "Unknown argument: $1" >&2
    usage
    exit 2
    ;;
esac

if [[ $# -gt 1 ]]; then
  echo "Unknown argument: $2" >&2
  usage
  exit 2
fi

if [[ ! -f "$PKG_PATH" ]]; then
  echo "Missing package: $PKG_PATH" >&2
  echo "Run ./script/package_app_store.sh first." >&2
  exit 2
fi

if [[ -z "$ASC_API_KEY" || -z "$ASC_API_ISSUER" ]]; then
  echo "Missing ASC_API_KEY or ASC_API_ISSUER." >&2
  echo "Create an App Store Connect API key, then run with ASC_API_KEY and ASC_API_ISSUER." >&2
  exit 2
fi

if [[ -z "$ASC_API_KEY_PATH" ]]; then
  echo "Missing ASC_API_KEY_PATH." >&2
  echo "Set it to the readable App Store Connect key file named AuthKey_${ASC_API_KEY}.p8." >&2
  exit 2
fi

EXPECTED_KEY_NAME="AuthKey_${ASC_API_KEY}.p8"
if [[ "$(basename "$ASC_API_KEY_PATH")" != "$EXPECTED_KEY_NAME" ]]; then
  echo "ASC_API_KEY_PATH must name $EXPECTED_KEY_NAME." >&2
  exit 2
fi

if [[ ! -f "$ASC_API_KEY_PATH" || ! -r "$ASC_API_KEY_PATH" ]]; then
  echo "ASC_API_KEY_PATH is not a readable file: $ASC_API_KEY_PATH" >&2
  exit 2
fi

export API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_API_KEY_PATH")" && pwd)"

xcrun altool \
  --validate-app \
  --type macos \
  --file "$PKG_PATH" \
  --apiKey "$ASC_API_KEY" \
  --apiIssuer "$ASC_API_ISSUER"

if [[ "$MODE" == "validate" ]]; then
  echo "App Store Connect validation completed; package was not uploaded."
  exit 0
fi

xcrun altool \
  --upload-app \
  --type macos \
  --file "$PKG_PATH" \
  --apiKey "$ASC_API_KEY" \
  --apiIssuer "$ASC_API_ISSUER"
