#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 <timeout-seconds> <command> [args ...]" >&2
  exit 64
fi

TIMEOUT_SECONDS="$1"
shift

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-command-timeout.XXXXXX")"
STDOUT_FILE="$TEMP_DIR/stdout"
STDERR_FILE="$TEMP_DIR/stderr"
CHILD_PID=""

cleanup() {
  if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
    sleep 0.1
    kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
  if [[ -n "$CHILD_PID" ]]; then
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT HUP INT TERM

"$@" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
CHILD_PID=$!
START_SECONDS=$SECONDS

while kill -0 "$CHILD_PID" 2>/dev/null; do
  if (( SECONDS - START_SECONDS >= TIMEOUT_SECONDS )); then
    kill "$CHILD_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$CHILD_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
    CHILD_PID=""
    cat "$STDERR_FILE" >&2
    exit 124
  fi
  sleep 0.1
done

COMMAND_STATUS=0
wait "$CHILD_PID" || COMMAND_STATUS=$?
CHILD_PID=""
cat "$STDOUT_FILE"
cat "$STDERR_FILE" >&2
exit "$COMMAND_STATUS"
