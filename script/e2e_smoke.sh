#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_BUNDLE_ID="${E2E_BUNDLE_ID-com.andrzej.ClipVault.e2e}"

if [[ -z "$E2E_BUNDLE_ID" || "$E2E_BUNDLE_ID" == "com.andrzej.ClipVault" ]]; then
  echo "E2E_BUNDLE_ID must be a non-production bundle identifier." >&2
  exit 2
fi

E2E_DIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-e2e-dist.XXXXXX")"
E2E_DIST_DIR="$(cd "$E2E_DIST_DIR" && pwd -P)"
APP_EXECUTABLE="$E2E_DIST_DIR/ClipVault.app/Contents/MacOS/ClipVault"

terminate_e2e_app() {
  local app_pid
  while read -r app_pid; do
    [[ -n "$app_pid" ]] && kill "$app_pid" >/dev/null 2>&1 || true
  done < <(pgrep -f -x -- "$APP_EXECUTABLE" || true)
}

cleanup() {
  terminate_e2e_app
  rm -rf "$E2E_DIST_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT_DIR"

APP_BUNDLE_ID="$E2E_BUNDLE_ID" DIST_DIR="$E2E_DIST_DIR" ENABLE_STORE_PROBE=true \
  ./script/build_and_run.sh --verify >/dev/null
[[ -x "$APP_EXECUTABLE" ]] || {
  echo "ClipVault staged executable is missing: $APP_EXECUTABLE" >&2
  exit 1
}

TOKEN="ClipVault E2E $(date +%Y%m%d%H%M%S) duplicate persistence SELECT * FROM e2e_smoke;"

wait_for_store_probe() {
  local expected_rows="$1"
  local minimum_copy_count="$2"
  local timeout_seconds="${3:-60}"
  local start
  start="$(date +%s)"

  while true; do
    local output
    if output="$("$APP_EXECUTABLE" --verify-stored-clip "$TOKEN")"; then
      if [[ "$output" =~ CLIPVAULT_STORE_PROBE[[:space:]]row_count=([0-9]+)[[:space:]]copy_count=([0-9]+) ]]; then
        local row_count="${BASH_REMATCH[1]}"
        local copy_count="${BASH_REMATCH[2]}"
        if [[ "$row_count" == "$expected_rows" ]] && (( copy_count >= minimum_copy_count )); then
          PROBE_ROW_COUNT="$row_count"
          PROBE_COPY_COUNT="$copy_count"
          return 0
        fi
      else
        echo "Unexpected store probe output: $output" >&2
        return 1
      fi
    else
      echo "Signed app store probe failed." >&2
      return 1
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      echo "Timed out waiting for row_count=$expected_rows and copy_count>=$minimum_copy_count." >&2
      echo "Last probe output: $output" >&2
      return 1
    fi

    sleep 0.5
  done
}

./script/write_e2e_pasteboard.swift "$TOKEN"
wait_for_store_probe 1 1

./script/write_e2e_pasteboard.swift "$TOKEN"
wait_for_store_probe 1 2

if [[ "$PROBE_ROW_COUNT" != "1" ]]; then
  echo "Expected one deduplicated stored clip for E2E token, found $PROBE_ROW_COUNT." >&2
  exit 1
fi

if (( PROBE_COPY_COUNT < 2 )); then
  echo "Expected duplicate copy count >= 2, found $PROBE_COPY_COUNT." >&2
  exit 1
fi

terminate_e2e_app
sleep 1
APP_BUNDLE_ID="$E2E_BUNDLE_ID" DIST_DIR="$E2E_DIST_DIR" ENABLE_STORE_PROBE=true \
  ./script/build_and_run.sh --verify >/dev/null

wait_for_store_probe 1 2
if [[ "$PROBE_ROW_COUNT" != "1" ]]; then
  echo "Stored E2E clip did not survive restart." >&2
  exit 1
fi

echo "E2E smoke passed: capture, dedupe, persistence, and restart recovery verified."
echo "Verifier: signed app-owned store probe"
