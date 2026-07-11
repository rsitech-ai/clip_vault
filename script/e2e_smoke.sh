#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
APP_EXECUTABLE="$ROOT_DIR/dist/ClipVault.app/Contents/MacOS/ClipVault"

cd "$ROOT_DIR"

ENABLE_STORE_PROBE=true ./script/build_and_run.sh --verify >/dev/null
[[ -x "$APP_EXECUTABLE" ]] || {
  echo "ClipVault staged executable is missing: $APP_EXECUTABLE" >&2
  exit 1
}

TOKEN="ClipVault E2E $(date +%Y%m%d%H%M%S) duplicate persistence SELECT * FROM e2e_smoke;"

wait_for_store_probe() {
  local expected_rows="$1"
  local minimum_copy_count="$2"
  local timeout_seconds="${3:-20}"
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

printf '%s' "$TOKEN" | pbcopy
wait_for_store_probe 1 1

printf '%s' "$TOKEN" | pbcopy
wait_for_store_probe 1 2

if [[ "$PROBE_ROW_COUNT" != "1" ]]; then
  echo "Expected one deduplicated stored clip for E2E token, found $PROBE_ROW_COUNT." >&2
  exit 1
fi

if (( PROBE_COPY_COUNT < 2 )); then
  echo "Expected duplicate copy count >= 2, found $PROBE_COPY_COUNT." >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
ENABLE_STORE_PROBE=true ./script/build_and_run.sh --verify >/dev/null

wait_for_store_probe 1 2
if [[ "$PROBE_ROW_COUNT" != "1" ]]; then
  echo "Stored E2E clip did not survive restart." >&2
  exit 1
fi

echo "E2E smoke passed: capture, dedupe, persistence, and restart recovery verified."
echo "Verifier: signed app-owned store probe"
