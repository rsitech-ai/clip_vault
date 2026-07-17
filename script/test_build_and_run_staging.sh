#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
APP_STORE_CHECK="$ROOT_DIR/script/app_store_check.sh"

rg -Fq './script/build_and_run.sh --stage' "$APP_STORE_CHECK"

STAGE_BODY="$(sed -n '/--stage|stage)/,/^    ;;/p' "$BUILD_SCRIPT")"
[[ -n "$STAGE_BODY" ]]
[[ "$STAGE_BODY" != *'open_app'* ]]

echo "Non-launching staged bundle tests passed."
