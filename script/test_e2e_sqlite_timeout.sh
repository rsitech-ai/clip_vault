#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="$ROOT_DIR/script/lib/run_with_timeout.sh"
PERL_HELPER="$ROOT_DIR/script/lib/run_with_timeout.pl"
SQLITE_WRAPPER="$ROOT_DIR/script/lib/sqlite_with_timeout.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-e2e-timeout-tests.XXXXXX")"
INVALID_TMPDIR="$TEMP_DIR/does-not-exist"

WRAPPER_PID=""
ACTIVE_PROCESS_FILE=""
ACTIVE_SINGLE_PID_FILE=""

cleanup() {
  if [[ -n "$WRAPPER_PID" ]] && kill -0 "$WRAPPER_PID" 2>/dev/null; then
    kill -KILL "$WRAPPER_PID" 2>/dev/null || true
    wait "$WRAPPER_PID" 2>/dev/null || true
  fi

  if [[ -n "$ACTIVE_PROCESS_FILE" && -s "$ACTIVE_PROCESS_FILE" ]]; then
    read -r active_group_id _ <"$ACTIVE_PROCESS_FILE"
    kill -KILL -- "-$active_group_id" 2>/dev/null || true
  fi
  if [[ -n "$ACTIVE_SINGLE_PID_FILE" && -s "$ACTIVE_SINGLE_PID_FILE" ]]; then
    kill -KILL "$(cat "$ACTIVE_SINGLE_PID_FILE")" 2>/dev/null || true
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

assert_elapsed_between() {
  local label="$1"
  local start="$2"
  local end="$3"
  local lower="$4"
  local upper="$5"

  /usr/bin/perl -e '
    my ($label, $start, $end, $lower, $upper) = @ARGV;
    my $elapsed = $end - $start;
    die sprintf("FAIL: %s elapsed %.3fs, expected %.3fs..%.3fs\n", $label, $elapsed, $lower, $upper)
      if $elapsed < $lower || $elapsed > $upper;
  ' "$label" "$start" "$end" "$lower" "$upper" || exit 1
}

assert_pid_gone() {
  local pid="$1"
  local attempt

  for ((attempt = 1; attempt <= 100; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return
    fi
    sleep 0.02
  done

  fail "process $pid survived cleanup"
}

assert_group_file_gone() {
  local path="$1"
  local parent_pid=""
  local parent_pgid=""
  local pid=""
  local pgid=""

  while read -r pid pgid; do
    [[ -n "$parent_pid" ]] || {
      parent_pid="$pid"
      parent_pgid="$pgid"
    }
    [[ "$pgid" == "$parent_pgid" ]] || fail "process $pid escaped process group $parent_pgid as $pgid"
    assert_pid_gone "$pid"
  done <"$path"

  [[ -n "$parent_pid" ]] || fail "missing process records in $path"
  [[ "$parent_pid" == "$parent_pgid" ]] || fail "child $parent_pid did not lead its process group $parent_pgid"
}

monotonic_now() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.6f\n", clock_gettime(CLOCK_MONOTONIC)'
}

wait_for_file() {
  local path="$1"
  local attempt

  for ((attempt = 1; attempt <= 100; attempt++)); do
    [[ -s "$path" ]] && return
    sleep 0.02
  done

  fail "timed out waiting for $path"
}

[[ -f "$PERL_HELPER" ]] || fail "missing process-owning Perl helper: $PERL_HELPER"

SUCCESS_CHILD="$TEMP_DIR/success-child"
cat >"$SUCCESS_CHILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'success\n'
EOF
chmod +x "$SUCCESS_CHILD"

# Repetition makes immediate child completion exercise the parent/reap boundary.
for ((iteration = 1; iteration <= 25; iteration++)); do
  success_output="$(TMPDIR="$INVALID_TMPDIR" "$ADAPTER" 1 "$SUCCESS_CHILD")" || \
    fail "immediate success iteration $iteration failed"
  [[ "$success_output" == "success" ]] || \
    fail "immediate success iteration $iteration returned '$success_output'"
done

DELAYED_SUCCESS="$TEMP_DIR/delayed-success"
cat >"$DELAYED_SUCCESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 0.70
printf 'delayed success\n'
EOF
chmod +x "$DELAYED_SUCCESS"

delayed_start="$(monotonic_now)"
delayed_output="$("$ADAPTER" 1 "$DELAYED_SUCCESS")" || \
  fail "delayed success exceeded its one-second deadline"
delayed_end="$(monotonic_now)"
[[ "$delayed_output" == "delayed success" ]] || fail "delayed success returned '$delayed_output'"
assert_elapsed_between "delayed success" "$delayed_start" "$delayed_end" 0.65 1.20

STATUS_CHILD="$TEMP_DIR/status-child"
cat >"$STATUS_CHILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'child stdout %s\n' "$1"
printf 'child stderr %s\n' "$1" >&2
exit "$1"
EOF
chmod +x "$STATUS_CHILD"

for child_status in 37 124 143; do
  status_stdout="$TEMP_DIR/status-$child_status.stdout"
  status_stderr="$TEMP_DIR/status-$child_status.stderr"
  set +e
  "$ADAPTER" 2 "$STATUS_CHILD" "$child_status" >"$status_stdout" 2>"$status_stderr"
  observed_status=$?
  set -e
  [[ "$observed_status" -eq "$child_status" ]] || \
    fail "child exit $child_status was reported as $observed_status"
  assert_file_equals "$status_stdout" "child stdout $child_status"
  assert_file_equals "$status_stderr" "child stderr $child_status"
done

# Sourcing must preserve caller traps and add only the intentional public function.
trap ':' HUP
trap ':' INT
trap ':' TERM
before_hup_trap="$(trap -p HUP)"
before_int_trap="$(trap -p INT)"
before_term_trap="$(trap -p TERM)"
before_exit_trap="$(trap -p EXIT)"
declare -F | awk '{print $3}' | LC_ALL=C sort >"$TEMP_DIR/functions-before"
source "$ADAPTER"
set +e
run_with_timeout 2 "$STATUS_CHILD" 37 >"$TEMP_DIR/sourced.stdout" 2>"$TEMP_DIR/sourced.stderr"
sourced_status=$?
set -e
[[ "$sourced_status" -eq 37 ]] || fail "sourced adapter changed ordinary status to $sourced_status"
[[ "$(trap -p HUP)" == "$before_hup_trap" ]] || fail "sourced adapter changed the HUP trap"
[[ "$(trap -p INT)" == "$before_int_trap" ]] || fail "sourced adapter changed the INT trap"
[[ "$(trap -p TERM)" == "$before_term_trap" ]] || fail "sourced adapter changed the TERM trap"
[[ "$(trap -p EXIT)" == "$before_exit_trap" ]] || fail "sourced adapter changed the EXIT trap"
declare -F | awk '{print $3}' | LC_ALL=C sort >"$TEMP_DIR/functions-after"
new_functions="$(comm -13 "$TEMP_DIR/functions-before" "$TEMP_DIR/functions-after")"
[[ "$new_functions" == "run_with_timeout" ]] || \
  fail "sourced adapter leaked helper functions: ${new_functions:-none}"
trap - HUP INT TERM

set +e
TMPDIR="$INVALID_TMPDIR" run_with_timeout 2 "$SUCCESS_CHILD" >"$TEMP_DIR/invalid-tmp.stdout" 2>"$TEMP_DIR/invalid-tmp.stderr"
invalid_tmp_status=$?
set -e
[[ "$invalid_tmp_status" -eq 0 ]] || fail "invalid TMPDIR affected the helper: status $invalid_tmp_status"
assert_file_equals "$TEMP_DIR/invalid-tmp.stdout" "success"

MISSING_ADAPTER_DIR="$TEMP_DIR/missing-helper/lib"
mkdir -p "$MISSING_ADAPTER_DIR"
cp "$ADAPTER" "$MISSING_ADAPTER_DIR/run_with_timeout.sh"
chmod +x "$MISSING_ADAPTER_DIR/run_with_timeout.sh"
set +e
"$MISSING_ADAPTER_DIR/run_with_timeout.sh" 1 "$SUCCESS_CHILD" \
  >"$TEMP_DIR/missing-helper.stdout" 2>"$TEMP_DIR/missing-helper.stderr"
missing_helper_status=$?
set -e
[[ "$missing_helper_status" -eq 125 ]] || \
  fail "missing Perl helper returned $missing_helper_status instead of infrastructure status 125"

set +e
"$ADAPTER" 1 "$TEMP_DIR/does-not-exist-command" \
  >"$TEMP_DIR/missing-command.stdout" 2>"$TEMP_DIR/missing-command.stderr"
missing_command_status=$?
set -e
[[ "$missing_command_status" -eq 125 ]] || \
  fail "exec setup failure returned $missing_command_status instead of infrastructure status 125"

set +e
"$ADAPTER" 0 "$SUCCESS_CHILD" >"$TEMP_DIR/invalid-timeout.stdout" 2>"$TEMP_DIR/invalid-timeout.stderr"
invalid_timeout_status=$?
set -e
[[ "$invalid_timeout_status" -eq 125 ]] || \
  fail "invalid timeout returned $invalid_timeout_status instead of infrastructure status 125"

RESISTANT_CHILD="$TEMP_DIR/resistant-child"
cat >"$RESISTANT_CHILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap '' HUP INT TERM
(
  trap '' HUP INT TERM
  while true; do
    :
  done
) &
descendant_pid=$!
parent_pgid="$(/bin/ps -o pgid= -p "$$" | tr -d ' ')"
descendant_pgid="$(/bin/ps -o pgid= -p "$descendant_pid" | tr -d ' ')"
printf '%s %s\n%s %s\n' "$$" "$parent_pgid" "$descendant_pid" "$descendant_pgid" >"$PROCESS_FILE"
counter=0
while true; do
  counter=$((counter + 1))
  printf 'stream stdout %s\n' "$counter"
  printf 'stream stderr %s\n' "$counter" >&2
  sleep 0.02
done
EOF
chmod +x "$RESISTANT_CHILD"

timeout_pids="$TEMP_DIR/timeout.pids"
ACTIVE_PROCESS_FILE="$timeout_pids"
timeout_start="$(monotonic_now)"
set +e
PROCESS_FILE="$timeout_pids" "$ADAPTER" 1 "$RESISTANT_CHILD" \
  >"$TEMP_DIR/timeout.stdout" 2>"$TEMP_DIR/timeout.stderr"
timeout_status=$?
set -e
timeout_end="$(monotonic_now)"
[[ "$timeout_status" -eq 124 ]] || fail "helper deadline returned $timeout_status instead of 124"
assert_elapsed_between "TERM-resistant timeout" "$timeout_start" "$timeout_end" 1.85 3.50
wait_for_file "$timeout_pids"
assert_group_file_gone "$timeout_pids"
ACTIVE_PROCESS_FILE=""
grep -q 'stream stdout' "$TEMP_DIR/timeout.stdout" || fail "timeout lost inherited stdout"
grep -q 'stream stderr' "$TEMP_DIR/timeout.stderr" || fail "timeout lost inherited stderr"
if grep -q 'cat:' "$TEMP_DIR/timeout.stderr"; then
  fail "timeout emitted a replay/cat error"
fi

SQLITE_SUCCESS="$TEMP_DIR/sqlite-success"
cat >"$SQLITE_SUCCESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == "/tmp/fake-clipvault.store" ]]
[[ "$2" == "SELECT 42;" ]]
printf '42\n'
EOF
chmod +x "$SQLITE_SUCCESS"
sqlite_output="$(SQLITE3_BIN="$SQLITE_SUCCESS" "$SQLITE_WRAPPER" 1 "/tmp/fake-clipvault.store" "SELECT 42;")" || \
  fail "successful SQLite wrapper invocation failed"
[[ "$sqlite_output" == "42" ]] || fail "SQLite wrapper returned '$sqlite_output'"

SQLITE_BLOCKING="$TEMP_DIR/sqlite-blocking"
cat >"$SQLITE_BLOCKING" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trap '' TERM
printf '%s\n' "$$" >"$SQLITE_PID_FILE"
while true; do
  :
done
EOF
chmod +x "$SQLITE_BLOCKING"

sqlite_pid_file="$TEMP_DIR/sqlite.pid"
ACTIVE_SINGLE_PID_FILE="$sqlite_pid_file"
set +e
sqlite_timeout_output="$(
  SQLITE3_BIN="$SQLITE_BLOCKING" \
  SQLITE_PID_FILE="$sqlite_pid_file" \
    "$SQLITE_WRAPPER" 1 "/tmp/fake-clipvault.store" "SELECT 1;" 2>&1
)"
sqlite_timeout_status=$?
set -e
[[ "$sqlite_timeout_status" -eq 74 ]] || \
  fail "SQLite host timeout returned $sqlite_timeout_status instead of 74: $sqlite_timeout_output"
[[ "$sqlite_timeout_output" == *"Host access timeout"* ]] || \
  fail "missing actionable host-access timeout message: $sqlite_timeout_output"
[[ "$sqlite_timeout_output" == *"/tmp/fake-clipvault.store"* ]] || \
  fail "host-access timeout omitted the store path: $sqlite_timeout_output"
wait_for_file "$sqlite_pid_file"
assert_pid_gone "$(cat "$sqlite_pid_file")"
ACTIVE_SINGLE_PID_FILE=""

for signal_case in HUP:129 INT:130 TERM:143; do
  IFS=: read -r external_signal expected_status <<<"$signal_case"
  external_pids="$TEMP_DIR/external-$external_signal.pids"
  ACTIVE_PROCESS_FILE="$external_pids"
  external_stdout="$TEMP_DIR/external-$external_signal.stdout"
  external_stderr="$TEMP_DIR/external-$external_signal.stderr"
  PROCESS_FILE="$external_pids" "$ADAPTER" 10 "$RESISTANT_CHILD" \
    >"$external_stdout" 2>"$external_stderr" &
  WRAPPER_PID=$!
  wait_for_file "$external_pids"

  external_start="$(monotonic_now)"
  kill -"$external_signal" "$WRAPPER_PID"
  set +e
  wait "$WRAPPER_PID"
  external_status=$?
  set -e
  WRAPPER_PID=""
  external_end="$(monotonic_now)"

  [[ "$external_status" -eq "$expected_status" ]] || \
    fail "external $external_signal returned $external_status instead of $expected_status"
  assert_elapsed_between "external $external_signal grace" "$external_start" "$external_end" 0.85 2.50
  assert_group_file_gone "$external_pids"
  ACTIVE_PROCESS_FILE=""
  grep -q 'stream stdout' "$external_stdout" || fail "external $external_signal lost inherited stdout"
  grep -q 'stream stderr' "$external_stderr" || fail "external $external_signal lost inherited stderr"
  if grep -q 'cat:' "$external_stderr"; then
    fail "external $external_signal emitted a replay/cat error"
  fi
done

echo "E2E sqlite timeout tests passed (25 immediate iterations, delayed timing bounds, 3 ordinary statuses, source hygiene, 3 infrastructure paths, timeout/group cleanup, SQLite mapping, and 3 external signals)."
