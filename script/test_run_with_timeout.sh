#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_WITH_TIMEOUT="$ROOT_DIR/script/run_with_timeout.sh"

[[ -x "$RUN_WITH_TIMEOUT" ]]

success_output="$("$RUN_WITH_TIMEOUT" 2 /bin/sh -c 'printf success')"
[[ "$success_output" == "success" ]]

set +e
start_seconds="$(date +%s)"
child_pid_file="$(mktemp "${TMPDIR:-/tmp}/clipvault-timeout-child.XXXXXX")"
timeout_output="$("$RUN_WITH_TIMEOUT" 1 /bin/sh -c 'sleep 30 & echo $! > "$1"; wait' shell "$child_pid_file" 2>&1)"
timeout_status=$?
elapsed_seconds="$(( $(date +%s) - start_seconds ))"
set -e

[[ "$timeout_status" -eq 124 ]]
[[ "$elapsed_seconds" -lt 5 ]]
[[ "$timeout_output" == "Command timed out after 1 second(s)." ]]
child_pid="$(<"$child_pid_file")"
! kill -0 "$child_pid" >/dev/null 2>&1
unlink "$child_pid_file"

set +e
"$RUN_WITH_TIMEOUT" 0 /usr/bin/true >/dev/null 2>&1
invalid_timeout_status=$?
"$RUN_WITH_TIMEOUT" 1 >/dev/null 2>&1
missing_command_status=$?
set -e

[[ "$invalid_timeout_status" -eq 64 ]]
[[ "$missing_command_status" -eq 64 ]]

echo "Bounded command runner tests passed."
