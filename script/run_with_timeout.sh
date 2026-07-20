#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: run_with_timeout.sh <positive-seconds> <command> [arguments...]" >&2
  exit 64
fi

timeout_seconds="$1"
shift

"$@" &
command_pid=$!

terminate_process_tree() {
  local process_id="$1"
  local signal_name="$2"
  local child_id

  while read -r child_id; do
    [[ -n "$child_id" ]] && terminate_process_tree "$child_id" "$signal_name"
  done < <(pgrep -P "$process_id" || true)

  if kill -0 "$process_id" >/dev/null 2>&1; then
    kill -"$signal_name" "$process_id" >/dev/null 2>&1 || true
  fi
}

terminate_command() {
  terminate_process_tree "$command_pid" TERM
}

trap 'terminate_command; exit 130' INT
trap 'terminate_command; exit 143' TERM

start_seconds="$(date +%s)"
while kill -0 "$command_pid" >/dev/null 2>&1; do
  if (( $(date +%s) - start_seconds >= timeout_seconds )); then
    terminate_command
    for _ in {1..10}; do
      kill -0 "$command_pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if kill -0 "$command_pid" >/dev/null 2>&1; then
      terminate_process_tree "$command_pid" KILL
    fi
    wait "$command_pid" >/dev/null 2>&1 || true
    echo "Command timed out after $timeout_seconds second(s)." >&2
    exit 124
  fi
  sleep 0.1
done

if wait "$command_pid"; then
  exit 0
else
  exit $?
fi
