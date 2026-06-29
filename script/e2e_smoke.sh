#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
BUNDLE_ID="${APP_BUNDLE_ID:-com.andrzej.ClipVault}"
STORE_NAME="ClipVault.store"
SANDBOX_STORE="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/$STORE_NAME"
FALLBACK_STORE="$HOME/Library/Application Support/$STORE_NAME"

cd "$ROOT_DIR"

./script/build_and_run.sh --verify >/dev/null

if [[ -f "$SANDBOX_STORE" ]]; then
  STORE_PATH="$SANDBOX_STORE"
elif [[ -f "$FALLBACK_STORE" ]]; then
  STORE_PATH="$FALLBACK_STORE"
else
  echo "ClipVault SwiftData store was not created." >&2
  exit 1
fi

TOKEN="ClipVault E2E $(date +%Y%m%d%H%M%S) duplicate persistence SELECT * FROM e2e_smoke;"

wait_for_sql_value() {
  local sql="$1"
  local expected="$2"
  local timeout_seconds="${3:-20}"
  local start
  start="$(date +%s)"

  while true; do
    local value
    value="$(sqlite3 "$STORE_PATH" "$sql")"
    if [[ "$value" == "$expected" ]]; then
      return 0
    fi

    if (( $(date +%s) - start >= timeout_seconds )); then
      echo "Timed out waiting for SQL value '$expected'. Last value: '$value'." >&2
      echo "SQL: $sql" >&2
      return 1
    fi

    sleep 0.5
  done
}

printf '%s' "$TOKEN" | pbcopy
wait_for_sql_value "SELECT count(*) FROM ZCLIPRECORD WHERE ZPREVIEW = '$TOKEN';" "1"

printf '%s' "$TOKEN" | pbcopy
wait_for_sql_value "SELECT coalesce(max(ZCOPYCOUNT), 0) FROM ZCLIPRECORD WHERE ZPREVIEW = '$TOKEN';" "2"

ROW_COUNT="$(sqlite3 "$STORE_PATH" "SELECT count(*) FROM ZCLIPRECORD WHERE ZPREVIEW = '$TOKEN';")"
COPY_COUNT="$(sqlite3 "$STORE_PATH" "SELECT coalesce(max(ZCOPYCOUNT), 0) FROM ZCLIPRECORD WHERE ZPREVIEW = '$TOKEN';")"

if [[ "$ROW_COUNT" != "1" ]]; then
  echo "Expected one deduplicated stored clip for E2E token, found $ROW_COUNT." >&2
  exit 1
fi

if (( COPY_COUNT < 2 )); then
  echo "Expected duplicate copy count >= 2, found $COPY_COUNT." >&2
  exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
sleep 1
./script/build_and_run.sh --verify >/dev/null

POST_RESTART_COUNT="$(sqlite3 "$STORE_PATH" "SELECT count(*) FROM ZCLIPRECORD WHERE ZPREVIEW = '$TOKEN';")"
if [[ "$POST_RESTART_COUNT" != "1" ]]; then
  echo "Stored E2E clip did not survive restart." >&2
  exit 1
fi

echo "E2E smoke passed: capture, dedupe, persistence, and restart recovery verified."
echo "Store: $STORE_PATH"
