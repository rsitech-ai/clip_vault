#!/usr/bin/env bash

run_with_timeout() {
  if [[ $# -lt 2 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 <timeout-seconds> <command> [args ...]" >&2
    return 64
  fi

  local timeout_seconds="$1"
  shift

  local old_hup_trap old_int_trap old_term_trap old_exit_trap
  old_hup_trap="$(trap -p HUP || true)"
  old_int_trap="$(trap -p INT || true)"
  old_term_trap="$(trap -p TERM || true)"
  old_exit_trap="$(trap -p EXIT || true)"

  local temp_dir stdout_file stderr_file timeout_marker watchdog_fifo
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-command-timeout.XXXXXX")"
  stdout_file="$temp_dir/stdout"
  stderr_file="$temp_dir/stderr"
  timeout_marker="$temp_dir/timeout"
  watchdog_fifo="$temp_dir/watchdog"
  mkfifo "$watchdog_fifo"

  local child_pid=""
  local watchdog_pid=""
  local watchdog_fd_open=0
  local interrupted_status=""
  local cleanup_done=0
  local traps_restored=0

  stop_child() {
    if [[ -n "$child_pid" ]]; then
      if kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          kill -0 "$child_pid" 2>/dev/null || break
          sleep 0.05
        done
        kill -KILL "$child_pid" 2>/dev/null || true
      fi
      wait "$child_pid" 2>/dev/null || true
      child_pid=""
    fi
  }

  cancel_watchdog() {
    if [[ "$watchdog_fd_open" -eq 1 && ! -s "$timeout_marker" ]]; then
      printf '\n' >&9 2>/dev/null || true
    fi
    if [[ "$watchdog_fd_open" -eq 1 ]]; then
      exec 9>&-
      watchdog_fd_open=0
    fi
    if [[ -n "$watchdog_pid" ]]; then
      if kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        sleep 0.05
        kill -KILL "$watchdog_pid" 2>/dev/null || true
      fi
      wait "$watchdog_pid" 2>/dev/null || true
      watchdog_pid=""
    fi
  }

  cleanup_all() {
    if [[ "$cleanup_done" -eq 1 ]]; then
      return
    fi
    cleanup_done=1
    cancel_watchdog
    stop_child
    rm -rf "$temp_dir"
  }

  restore_traps() {
    if [[ "$traps_restored" -eq 1 ]]; then
      return
    fi
    traps_restored=1
    trap - HUP INT TERM EXIT
    [[ -n "$old_hup_trap" ]] && eval "$old_hup_trap"
    [[ -n "$old_int_trap" ]] && eval "$old_int_trap"
    [[ -n "$old_term_trap" ]] && eval "$old_term_trap"
    [[ -n "$old_exit_trap" ]] && eval "$old_exit_trap"
  }

  on_signal() {
    case "$1" in
      HUP) interrupted_status=129 ;;
      INT) interrupted_status=130 ;;
      TERM) interrupted_status=143 ;;
    esac
    cleanup_all
  }

  trap 'on_signal HUP' HUP
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'cleanup_all' EXIT

  "$@" >"$stdout_file" 2>"$stderr_file" &
  child_pid=$!

  (
    exec 8<"$watchdog_fifo"
    if IFS= read -r -t "$timeout_seconds" _ <&8; then
      exit 0
    fi

    printf 'timeout\n' >"$timeout_marker"
    kill -TERM "$child_pid" 2>/dev/null || true
    if ! IFS= read -r -t 1 _ <&8; then
      kill -KILL "$child_pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog_pid=$!
  exec 9>"$watchdog_fifo"
  watchdog_fd_open=1

  local child_status=0
  if wait "$child_pid"; then
    child_status=0
  else
    child_status=$?
  fi

  if [[ -n "$interrupted_status" ]]; then
    restore_traps
    return "$interrupted_status"
  fi

  child_pid=""
  cancel_watchdog

  local final_status="$child_status"
  if [[ -s "$timeout_marker" ]]; then
    final_status=124
  fi

  # Replay only after the child has been reaped. Signal cleanup returns before
  # this path, so it cannot report deleted temporary files as cat failures.
  cat "$stdout_file" || true
  cat "$stderr_file" >&2 || true

  if [[ -n "$interrupted_status" ]]; then
    cleanup_all
    restore_traps
    return "$interrupted_status"
  fi

  cleanup_all
  restore_traps
  return "$final_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  set +e
  run_with_timeout "$@"
  command_status=$?
  exit "$command_status"
fi
