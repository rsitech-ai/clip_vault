#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/direct_download.sh
source "$ROOT_DIR/script/lib/direct_download.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

VALID_IDENTITY="Developer ID Application: Example Developer (ABCDEFGHIJ)"
validate_developer_id_application_identity "$VALID_IDENTITY" || \
  fail "a Developer ID Application identity must be accepted"

for invalid_identity in \
  "" \
  "Apple Development: Example Developer (ABCDEFGHIJ)" \
  "Apple Distribution: Example Developer (ABCDEFGHIJ)" \
  "Developer ID Installer: Example Developer (ABCDEFGHIJ)" \
  "Developer ID Application: Example Developer"; do
  if validate_developer_id_application_identity "$invalid_identity" 2>/dev/null; then
    fail "non-Developer-ID application identity was accepted: $invalid_identity"
  fi
done

[[ "$(team_identifier_from_developer_id_identity "$VALID_IDENTITY")" == "ABCDEFGHIJ" ]] || \
  fail "Developer ID identity parser must return the exact team identifier"

ACCEPTED_JSON='{"status":"Accepted","id":"12345678-1234-1234-1234-123456789012"}'
INVALID_JSON='{"status":"Invalid","id":"12345678-1234-1234-1234-123456789012"}'
[[ "$(notarization_status_from_json "$ACCEPTED_JSON")" == "Accepted" ]] || \
  fail "notarization status parser must return Accepted"
[[ "$(notarization_status_from_json "$INVALID_JSON")" == "Invalid" ]] || \
  fail "notarization status parser must return Invalid"
require_accepted_notarization_status "$ACCEPTED_JSON" || \
  fail "Accepted notarization result must pass"
if require_accepted_notarization_status "$INVALID_JSON" 2>/dev/null; then
  fail "non-Accepted notarization result must fail"
fi

PREFLIGHT_OUTPUT="$(
  DEVELOPER_ID_APPLICATION_IDENTITY="" \
  NOTARY_KEYCHAIN_PROFILE="" \
    "$ROOT_DIR/script/package_direct_download.sh" --preflight 2>&1
)" && fail "preflight without release credentials must fail"
[[ "$PREFLIGHT_OUTPUT" == *"Missing DEVELOPER_ID_APPLICATION_IDENTITY"* ]] || \
  fail "preflight must explain the missing Developer ID identity"

echo "Direct-download packaging tests passed."
