#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/signing_identities.sh
source "$ROOT_DIR/script/lib/signing_identities.sh"

APPLICATION_IDENTITY='Apple Distribution: Example Developer (ABCDEFGHIJ)'
INSTALLER_IDENTITY='3rd Party Mac Developer Installer: Example Developer (ABCDEFGHIJ)'

CODESIGNING_OUTPUT="$(printf '%s\n' \
  '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Example (AAAAAAAAAA)"' \
  "  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB \"$APPLICATION_IDENTITY\"" \
  '     2 valid identities found')"

BASIC_OUTPUT="$(printf '%s\n' \
  "  1) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC \"$INSTALLER_IDENTITY\"" \
  '     1 valid identities found')"

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_equal \
  "$APPLICATION_IDENTITY" \
  "$(printf '%s\n' "$CODESIGNING_OUTPUT" | application_signing_identity_from_output)" \
  "application parser selects the distribution identity"

assert_equal \
  "" \
  "$(printf '%s\n' "$CODESIGNING_OUTPUT" | installer_signing_identity_from_output)" \
  "installer parser does not accept application identities"

assert_equal \
  "$INSTALLER_IDENTITY" \
  "$(printf '%s\n' "$BASIC_OUTPUT" | installer_signing_identity_from_output)" \
  "installer parser selects the installer identity"

assert_equal \
  "" \
  "$(printf '%s\n' "$BASIC_OUTPUT" | application_signing_identity_from_output)" \
  "application parser does not accept installer identities"

security_identities() {
  case "$1" in
    codesigning)
      printf '%s\n' "$CODESIGNING_OUTPUT"
      ;;
    basic)
      printf '%s\n' "$BASIC_OUTPUT"
      ;;
    *)
      printf 'Unexpected identity policy: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

assert_equal \
  "$APPLICATION_IDENTITY" \
  "$(find_application_signing_identity)" \
  "application discovery queries the codesigning policy"

assert_equal \
  "$INSTALLER_IDENTITY" \
  "$(find_installer_signing_identity)" \
  "installer discovery queries the basic policy"

echo "Signing identity selection tests passed."
