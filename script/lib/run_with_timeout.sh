#!/usr/bin/env bash

run_with_timeout() {
  local _run_with_timeout_dir
  local _run_with_timeout_helper

  _run_with_timeout_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" || {
    echo "run_with_timeout: infrastructure failure: cannot resolve helper directory" >&2
    return 125
  }
  _run_with_timeout_helper="$_run_with_timeout_dir/run_with_timeout.pl"

  if [[ ! -x /usr/bin/perl ]]; then
    echo "run_with_timeout: infrastructure failure: /usr/bin/perl is unavailable" >&2
    return 125
  fi
  if [[ ! -f "$_run_with_timeout_helper" || ! -r "$_run_with_timeout_helper" ]]; then
    echo "run_with_timeout: infrastructure failure: missing $_run_with_timeout_helper" >&2
    return 125
  fi

  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exec /usr/bin/perl "$_run_with_timeout_helper" "$@"
    echo "run_with_timeout: infrastructure failure: could not start /usr/bin/perl" >&2
    return 125
  fi

  /usr/bin/perl "$_run_with_timeout_helper" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_with_timeout "$@"
  exit $?
fi
