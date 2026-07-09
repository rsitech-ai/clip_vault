#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <timeout-seconds> <store-path> <sql>" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TIMEOUT_SECONDS="$1"
STORE_PATH="$2"
SQL="$3"
SQLITE3_BIN="${SQLITE3_BIN:-/usr/bin/sqlite3}"

if OUTPUT="$(
  "$ROOT_DIR/script/lib/run_with_timeout.sh" \
    "$TIMEOUT_SECONDS" \
    "$SQLITE3_BIN" \
    "$STORE_PATH" \
    "$SQL"
)"; then
  printf '%s\n' "$OUTPUT"
  exit 0
else
  STATUS=$?
fi

if [[ "$STATUS" -eq 124 ]]; then
  echo "Host access timeout: sqlite3 could not open or read '$STORE_PATH' within ${TIMEOUT_SECONDS}s. Check container/Full Disk Access permissions and rerun." >&2
  exit 74
fi

exit "$STATUS"
