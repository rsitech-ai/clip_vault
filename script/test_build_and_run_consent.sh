#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/script/lib/temporary_capture_consent.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_DEFAULTS="$TMP_DIR/defaults"
STATE_FILE="$TMP_DIR/state"

cat >"$FAKE_DEFAULTS" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
state_file="${FAKE_DEFAULTS_STATE:?}"
command="$1"
domain="$2"
key="$3"
case "$command" in
  read)
    [[ -f "$state_file" ]] || exit 1
    cat "$state_file"
    ;;
  write)
    [[ "$4" == "-bool" ]]
    printf '%s\n' "$5" >"$state_file"
    ;;
  delete)
    rm -f "$state_file"
    ;;
  *) exit 2 ;;
esac
SCRIPT
chmod +x "$FAKE_DEFAULTS"

assert_preseed_and_restore() {
  local initial_state="$1"
  rm -f "$STATE_FILE"
  if [[ "$initial_state" != "absent" ]]; then
    printf '%s\n' "$initial_state" >"$STATE_FILE"
  fi

  DEFAULTS_BIN="$FAKE_DEFAULTS" FAKE_DEFAULTS_STATE="$STATE_FILE" bash -c '
    set -euo pipefail
    source "$1"
    preseed_capture_consent_for_verify "com.andrzej.ClipVault" "clipboardCaptureConsentGranted"
    [[ "$(cat "$2")" == "true" ]]
    restore_capture_consent_after_verify
  ' _ "$HELPER" "$STATE_FILE"

  if [[ "$initial_state" == "absent" ]]; then
    [[ ! -e "$STATE_FILE" ]]
  else
    [[ "$(cat "$STATE_FILE")" == "$initial_state" ]]
  fi
}

assert_preseed_and_restore absent
assert_preseed_and_restore false

echo "Temporary capture-consent preference restore tests passed."
