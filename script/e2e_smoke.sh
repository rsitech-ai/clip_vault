#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_RUN_ID="${E2E_RUN_ID-$(date +%Y%m%d%H%M%S).$$}"
E2E_BUNDLE_ID="${E2E_BUNDLE_ID-com.andrzej.ClipVault.e2e.$E2E_RUN_ID}"

if [[ ! "$E2E_BUNDLE_ID" =~ ^com\.andrzej\.ClipVault\.e2e\.[A-Za-z0-9.-]+$ ]]; then
  echo "E2E_BUNDLE_ID must use the com.andrzej.ClipVault.e2e.* test namespace." >&2
  exit 2
fi

E2E_DIST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-e2e-dist.XXXXXX")"
E2E_DIST_DIR="$(cd "$E2E_DIST_DIR" && pwd -P)"
APP_EXECUTABLE="$E2E_DIST_DIR/ClipVault.app/Contents/MacOS/ClipVault"
RUN_WITH_TIMEOUT="$ROOT_DIR/script/run_with_timeout.sh"
STORE_PROBE_TIMEOUT_SECONDS="${STORE_PROBE_TIMEOUT_SECONDS-30}"

[[ -x "$RUN_WITH_TIMEOUT" ]] || {
  echo "Bounded command runner is missing: $RUN_WITH_TIMEOUT" >&2
  exit 1
}

run_store_probe() {
  local token="$1"
  "$RUN_WITH_TIMEOUT" "$STORE_PROBE_TIMEOUT_SECONDS" \
    "$APP_EXECUTABLE" --verify-stored-clip "$token"
}

terminate_e2e_app() {
  local app_pid
  while read -r app_pid; do
    [[ -n "$app_pid" ]] && kill "$app_pid" >/dev/null 2>&1 || true
  done < <(pgrep -f -x -- "$APP_EXECUTABLE" || true)

  for _ in {1..40}; do
    if ! pgrep -f -x -- "$APP_EXECUTABLE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  while read -r app_pid; do
    [[ -n "$app_pid" ]] && kill -KILL "$app_pid" >/dev/null 2>&1 || true
  done < <(pgrep -f -x -- "$APP_EXECUTABLE" || true)
}

launch_e2e_app() {
  /usr/bin/open -n "$E2E_DIST_DIR/ClipVault.app"
  for _ in {1..80}; do
    local app_pid
    app_pid="$(pgrep -f -x -- "$APP_EXECUTABLE" | head -1 || true)"
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
      sleep 1
      return 0
    fi
    sleep 0.25
  done
  echo "ClipVault E2E app did not launch and remain alive within 20 seconds." >&2
  return 1
}

delete_e2e_key() {
  security delete-generic-password \
    -s "$E2E_BUNDLE_ID" \
    -a payload-encryption-key >/dev/null 2>&1 || true
}

reset_e2e_store() {
  "$RUN_WITH_TIMEOUT" "$STORE_PROBE_TIMEOUT_SECONDS" \
    "$APP_EXECUTABLE" --reset-e2e-store
}

cleanup() {
  terminate_e2e_app
  if [[ -x "$APP_EXECUTABLE" ]]; then
    reset_e2e_store >/dev/null 2>&1 || true
  fi
  delete_e2e_key
  defaults delete "$E2E_BUNDLE_ID" >/dev/null 2>&1 || true
  rm -rf "$E2E_DIST_DIR"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT_DIR"
delete_e2e_key
defaults delete "$E2E_BUNDLE_ID" >/dev/null 2>&1 || true

APP_BUNDLE_ID="$E2E_BUNDLE_ID" DIST_DIR="$E2E_DIST_DIR" ENABLE_STORE_PROBE=true \
  ./script/build_and_run.sh --stage >/dev/null
[[ -x "$APP_EXECUTABLE" ]] || {
  echo "ClipVault staged executable is missing: $APP_EXECUTABLE" >&2
  exit 1
}
reset_e2e_store >/dev/null

TOKEN="ClipVault E2E $(date +%Y%m%d%H%M%S) duplicate persistence SELECT * FROM e2e_smoke;"

capture_until_store_probe() {
  local expected_rows="$1"
  local minimum_copy_count="$2"
  local timeout_seconds="${3:-60}"
  local start
  start="$(date +%s)"

  while true; do
    ./script/write_e2e_pasteboard.swift "$TOKEN"
    sleep 0.75
    terminate_e2e_app

    local output
    if output="$(run_store_probe "$TOKEN")"; then
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
      echo "Timed out capturing row_count=$expected_rows and copy_count>=$minimum_copy_count." >&2
      echo "Last probe output: $output" >&2
      return 1
    fi

    launch_e2e_app
  done
}

launch_e2e_app
capture_until_store_probe 1 1
INITIAL_COPY_COUNT="$PROBE_COPY_COUNT"

launch_e2e_app
capture_until_store_probe 1 "$((INITIAL_COPY_COUNT + 1))"

if [[ "$PROBE_ROW_COUNT" != "1" ]]; then
  echo "Expected one deduplicated stored clip for E2E token, found $PROBE_ROW_COUNT." >&2
  exit 1
fi

if (( PROBE_COPY_COUNT < INITIAL_COPY_COUNT + 1 )); then
  echo "Expected duplicate copy count to increase from $INITIAL_COPY_COUNT, found $PROBE_COPY_COUNT." >&2
  exit 1
fi
FINAL_COPY_COUNT="$PROBE_COPY_COUNT"

launch_e2e_app
terminate_e2e_app
restart_output="$(run_store_probe "$TOKEN")"
if [[ ! "$restart_output" =~ CLIPVAULT_STORE_PROBE[[:space:]]row_count=([0-9]+)[[:space:]]copy_count=([0-9]+) ]] \
  || [[ "${BASH_REMATCH[1]}" != "1" ]] \
  || (( BASH_REMATCH[2] < FINAL_COPY_COUNT )); then
  echo "Stored E2E clip did not survive restart." >&2
  echo "Restart probe output: $restart_output" >&2
  exit 1
fi

echo "E2E smoke passed: capture, dedupe, persistence, and restart recovery verified."
echo "Verifier: signed app-owned store probe"
