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

if [[ -n "$ASC_API_KEY_PATH" ]]; then
  export API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_API_KEY_PATH")" && pwd)"
fi

xcrun altool \
  --upload-app \
  --type macos \
  --file "$PKG_PATH" \
  --apiKey "$ASC_API_KEY" \
  --apiIssuer "$ASC_API_ISSUER"
