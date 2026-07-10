#!/usr/bin/env bash

CAPTURE_CONSENT_DEFAULTS_BIN=""
CAPTURE_CONSENT_BUNDLE_ID=""
CAPTURE_CONSENT_SAVED_KEY=""
CAPTURE_CONSENT_HAD_VALUE=false
CAPTURE_CONSENT_ORIGINAL_VALUE=""

preseed_capture_consent_for_verify() {
  CAPTURE_CONSENT_DEFAULTS_BIN="${DEFAULTS_BIN:-defaults}"
  CAPTURE_CONSENT_BUNDLE_ID="$1"
  CAPTURE_CONSENT_SAVED_KEY="$2"

  if CAPTURE_CONSENT_ORIGINAL_VALUE="$($CAPTURE_CONSENT_DEFAULTS_BIN read "$CAPTURE_CONSENT_BUNDLE_ID" "$CAPTURE_CONSENT_SAVED_KEY" 2>/dev/null)"; then
    CAPTURE_CONSENT_HAD_VALUE=true
  else
    CAPTURE_CONSENT_HAD_VALUE=false
    CAPTURE_CONSENT_ORIGINAL_VALUE=""
  fi

  "$CAPTURE_CONSENT_DEFAULTS_BIN" write "$CAPTURE_CONSENT_BUNDLE_ID" "$CAPTURE_CONSENT_SAVED_KEY" -bool true
}

restore_capture_consent_after_verify() {
  if [[ -z "$CAPTURE_CONSENT_DEFAULTS_BIN" ]]; then
    return
  fi

  if [[ "$CAPTURE_CONSENT_HAD_VALUE" == true ]]; then
    local restored_value="$CAPTURE_CONSENT_ORIGINAL_VALUE"
    case "$restored_value" in
      1) restored_value=true ;;
      0) restored_value=false ;;
    esac
    "$CAPTURE_CONSENT_DEFAULTS_BIN" write \
      "$CAPTURE_CONSENT_BUNDLE_ID" \
      "$CAPTURE_CONSENT_SAVED_KEY" \
      -bool \
      "$restored_value"
  else
    "$CAPTURE_CONSENT_DEFAULTS_BIN" delete \
      "$CAPTURE_CONSENT_BUNDLE_ID" \
      "$CAPTURE_CONSENT_SAVED_KEY" >/dev/null 2>&1 || true
  fi

  CAPTURE_CONSENT_DEFAULTS_BIN=""
  CAPTURE_CONSENT_SAVED_KEY=""
}
