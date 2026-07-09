#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SQLITE_WRAPPER="$ROOT_DIR/script/lib/sqlite_with_timeout.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-e2e-timeout-tests.XXXXXX")"
RUNTIME_TEMP_DIR="$TEMP_DIR/runtime"
mkdir -p "$RUNTIME_TEMP_DIR"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SUCCESS_SQLITE="$TEMP_DIR/sqlite-success"
cat >"$SUCCESS_SQLITE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "/tmp/fake-clipvault.store" ]]
[[ "$2" == "SELECT 42;" ]]
printf '42\n'
EOF
chmod +x "$SUCCESS_SQLITE"

success_output="$({
  TMPDIR="$RUNTIME_TEMP_DIR" \
  SQLITE3_BIN="$SUCCESS_SQLITE" \
  "$SQLITE_WRAPPER" 1 "/tmp/fake-clipvault.store" "SELECT 42;"
} 2>&1)" || fail "successful sqlite wrapper invocation failed: $success_output"
[[ "$success_output" == "42" ]] || fail "expected successful sqlite output 42, got: $success_output"

BLOCKING_SQLITE="$TEMP_DIR/sqlite-blocking"
BLOCKING_PID_FILE="$TEMP_DIR/blocking.pid"
cat >"$BLOCKING_SQLITE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$FAKE_SQLITE_PID_FILE"
trap '' TERM
while true; do
  :
done
EOF
chmod +x "$BLOCKING_SQLITE"

start_seconds="$SECONDS"
set +e
timeout_output="$({
  TMPDIR="$RUNTIME_TEMP_DIR" \
  SQLITE3_BIN="$BLOCKING_SQLITE" \
  FAKE_SQLITE_PID_FILE="$BLOCKING_PID_FILE" \
  "$SQLITE_WRAPPER" 1 "/tmp/fake-clipvault.store" "SELECT 1;"
} 2>&1)"
timeout_status=$?
set -e
elapsed_seconds=$((SECONDS - start_seconds))

[[ "$timeout_status" -eq 74 ]] || fail "expected host-access timeout exit 74, got $timeout_status: $timeout_output"
[[ "$timeout_output" == *"Host access timeout"* ]] || fail "missing actionable host-access timeout message: $timeout_output"
[[ "$timeout_output" == *"/tmp/fake-clipvault.store"* ]] || fail "timeout message omitted the store path: $timeout_output"
(( elapsed_seconds < 5 )) || fail "blocking sqlite was not bounded; elapsed ${elapsed_seconds}s"
[[ -s "$BLOCKING_PID_FILE" ]] || fail "blocking sqlite did not record its pid"

blocking_pid="$(cat "$BLOCKING_PID_FILE")"
if kill -0 "$blocking_pid" 2>/dev/null; then
  fail "blocking sqlite child $blocking_pid survived timeout cleanup"
fi

if find "$RUNTIME_TEMP_DIR" -mindepth 1 -print -quit | grep -q .; then
  fail "sqlite timeout helper left temporary files behind"
fi

echo "E2E sqlite timeout tests passed."
