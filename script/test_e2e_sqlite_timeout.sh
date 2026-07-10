#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/script/lib/run_with_timeout.sh"
SQLITE_WRAPPER="$ROOT_DIR/script/lib/sqlite_with_timeout.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-e2e-timeout-tests.XXXXXX")"
RUNTIME_TEMP_DIR="$TEMP_DIR/runtime"
mkdir -p "$RUNTIME_TEMP_DIR"

WRAPPER_PID=""

cleanup() {
  if [[ -n "$WRAPPER_PID" ]] && kill -0 "$WRAPPER_PID" 2>/dev/null; then
    kill -KILL "$WRAPPER_PID" 2>/dev/null || true
    wait "$WRAPPER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_equals() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(cat "$path")"
  [[ "$actual" == "$expected" ]] || fail "expected $path to contain '$expected', got '$actual'"
}

assert_pid_gone() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    fail "process $pid survived cleanup"
  fi
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

# A short timeout must not depend on the integer boundary of Bash SECONDS.
for ((iteration = 1; iteration <= 25; iteration++)); do
  success_output="$(
    TMPDIR="$RUNTIME_TEMP_DIR" \
    SQLITE3_BIN="$SUCCESS_SQLITE" \
    "$SQLITE_WRAPPER" 1 "/tmp/fake-clipvault.store" "SELECT 42;"
  )" || fail "immediate success iteration $iteration failed"
  [[ "$success_output" == "42" ]] || fail "immediate success iteration $iteration returned '$success_output'"
done

INIT_DELAY_BASH_ENV="$TEMP_DIR/bash-init-delay"
printf 'sleep 0.20\n' >"$INIT_DELAY_BASH_ENV"
DELAYED_SUCCESS="$TEMP_DIR/sqlite-delayed-success"
cat >"$DELAYED_SUCCESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 0.20
printf 'delayed success\n'
EOF
chmod +x "$DELAYED_SUCCESS"

for ((iteration = 1; iteration <= 5; iteration++)); do
  delayed_output="$(
    BASH_ENV="$INIT_DELAY_BASH_ENV" \
    TMPDIR="$RUNTIME_TEMP_DIR" \
    "$HELPER" 1 "$DELAYED_SUCCESS"
  )" || fail "delayed success iteration $iteration exceeded its 1-second timeout"
  [[ "$delayed_output" == "delayed success" ]] || fail "delayed success returned '$delayed_output'"
done

STATUS_CHILD="$TEMP_DIR/sqlite-status"
cat >"$STATUS_CHILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'child stdout %s\n' "$1"
printf 'child stderr %s\n' "$1" >&2
exit "$1"
EOF
chmod +x "$STATUS_CHILD"

for child_status in 124 143; do
  status_stdout="$TEMP_DIR/status-$child_status.stdout"
  status_stderr="$TEMP_DIR/status-$child_status.stderr"
  set +e
  "$HELPER" 2 "$STATUS_CHILD" "$child_status" >"$status_stdout" 2>"$status_stderr"
  observed_status=$?
  set -e
  [[ "$observed_status" -eq "$child_status" ]] || fail "child exit $child_status was reported as $observed_status"
  assert_file_equals "$status_stdout" "child stdout $child_status"
  assert_file_equals "$status_stderr" "child stderr $child_status"
done

NONZERO_CHILD="$TEMP_DIR/sqlite-nonzero"
cat >"$NONZERO_CHILD" <<'EOF'
#!/usr/bin/env bash
printf 'ordinary stdout\n'
printf 'ordinary stderr\n' >&2
exit 37
EOF
chmod +x "$NONZERO_CHILD"

set +e
"$HELPER" 2 "$NONZERO_CHILD" >"$TEMP_DIR/nonzero.stdout" 2>"$TEMP_DIR/nonzero.stderr"
nonzero_status=$?
set -e
[[ "$nonzero_status" -eq 37 ]] || fail "ordinary child exit status changed to $nonzero_status"
assert_file_equals "$TEMP_DIR/nonzero.stdout" "ordinary stdout"
assert_file_equals "$TEMP_DIR/nonzero.stderr" "ordinary stderr"

# Sourcing the helper must not leave its invocation traps installed in the caller.
trap ':' HUP
trap ':' INT
trap ':' TERM
before_hup_trap="$(trap -p HUP)"
before_int_trap="$(trap -p INT)"
before_term_trap="$(trap -p TERM)"
source "$HELPER"
set +e
run_with_timeout 2 "$NONZERO_CHILD" >"$TEMP_DIR/sourced.stdout" 2>"$TEMP_DIR/sourced.stderr"
sourced_status=$?
set -e
[[ "$sourced_status" -eq 37 ]] || fail "sourced helper changed ordinary status to $sourced_status"
[[ "$(trap -p HUP)" == "$before_hup_trap" ]] || fail "sourced helper did not restore HUP trap"
[[ "$(trap -p INT)" == "$before_int_trap" ]] || fail "sourced helper did not restore INT trap"
[[ "$(trap -p TERM)" == "$before_term_trap" ]] || fail "sourced helper did not restore TERM trap"
trap - HUP INT TERM

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

start_epoch="$(date +%s)"
set +e
timeout_output="$(
  TMPDIR="$RUNTIME_TEMP_DIR" \
  SQLITE3_BIN="$BLOCKING_SQLITE" \
  FAKE_SQLITE_PID_FILE="$BLOCKING_PID_FILE" \
  "$SQLITE_WRAPPER" 1 "/tmp/fake-clipvault.store" "SELECT 1;" 2>&1
)"
timeout_status=$?
set -e
elapsed_seconds=$(( $(date +%s) - start_epoch ))

[[ "$timeout_status" -eq 74 ]] || fail "expected host-access timeout exit 74, got $timeout_status: $timeout_output"
[[ "$timeout_output" == *"Host access timeout"* ]] || fail "missing actionable host-access timeout message: $timeout_output"
[[ "$timeout_output" == *"/tmp/fake-clipvault.store"* ]] || fail "timeout message omitted the store path: $timeout_output"
(( elapsed_seconds < 5 )) || fail "blocking sqlite was not bounded; elapsed ${elapsed_seconds}s"
[[ -s "$BLOCKING_PID_FILE" ]] || fail "blocking sqlite did not record its pid"
assert_pid_gone "$(cat "$BLOCKING_PID_FILE")"

if find "$RUNTIME_TEMP_DIR" -mindepth 1 -print -quit | grep -q .; then
  fail "sqlite timeout helper left temporary files behind"
fi

EXTERNAL_BLOCKING="$TEMP_DIR/external-blocking"
cat >"$EXTERNAL_BLOCKING" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'child output must not be replayed after wrapper TERM\n'
printf 'child error must not be replayed after wrapper TERM\n' >&2
printf '%s\n' "$$" >"$FAKE_EXTERNAL_PID_FILE"
trap '' HUP INT TERM
while true; do
  :
done
EOF
chmod +x "$EXTERNAL_BLOCKING"

external_stdout="$TEMP_DIR/external.stdout"
external_stderr="$TEMP_DIR/external.stderr"
for signal_case in HUP:129 INT:130 TERM:143; do
  IFS=: read -r external_signal expected_status <<<"$signal_case"
  external_pid_file="$TEMP_DIR/external-$external_signal.pid"
  external_stdout="$TEMP_DIR/external-$external_signal.stdout"
  external_stderr="$TEMP_DIR/external-$external_signal.stderr"
  TMPDIR="$RUNTIME_TEMP_DIR" \
  FAKE_EXTERNAL_PID_FILE="$external_pid_file" \
    perl -e '$SIG{HUP} = "DEFAULT"; $SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV or die "$!"' \
      "$HELPER" 5 "$EXTERNAL_BLOCKING" >"$external_stdout" 2>"$external_stderr" &
  WRAPPER_PID=$!

  for ((attempt = 1; attempt <= 50; attempt++)); do
    [[ -s "$external_pid_file" ]] && break
    sleep 0.02
  done
  [[ -s "$external_pid_file" ]] || fail "externally terminated child did not start for $external_signal"

  kill -"$external_signal" "$WRAPPER_PID"
  set +e
  wait "$WRAPPER_PID"
  external_status=$?
  set -e
  WRAPPER_PID=""

  [[ "$external_status" -eq "$expected_status" ]] || fail "external $external_signal returned $external_status instead of $expected_status"
  assert_pid_gone "$(cat "$external_pid_file")"
  [[ ! -s "$external_stdout" ]] || fail "external $external_signal replayed child stdout"
  [[ ! -s "$external_stderr" ]] || fail "external $external_signal replayed child stderr"
  if grep -q 'cat:' "$external_stderr"; then
    fail "external $external_signal emitted a misleading cat error"
  fi
  if find "$RUNTIME_TEMP_DIR" -mindepth 1 -print -quit | grep -q .; then
    fail "external $external_signal left temporary files behind"
  fi
done

echo "E2E sqlite timeout tests passed (25 immediate, 5 delayed, 2 independent-status, 1 timeout, 3 external signals)."
