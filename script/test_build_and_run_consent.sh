#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
VIEW_MODEL="$ROOT_DIR/Sources/ClipVault/App/ClipVaultViewModel.swift"

if rg -q 'temporary_capture_consent|defaults[[:space:]]+(read|write|delete)' "$BUILD_SCRIPT"; then
  echo "signed launch verification must not mutate sandbox preferences from the host" >&2
  exit 1
fi

VERIFY_BODY="$(sed -n '/--verify|verify)/,/^    ;;/p' "$BUILD_SCRIPT")"
[[ "$VERIFY_BODY" == *'pgrep -f -x -- "$APP_BINARY"'* ]]
[[ "$VERIFY_BODY" == *'kill -0 "$APP_PID"'* ]]

rg -q 'private static var initialCaptureConsent: Bool' "$VIEW_MODEL"
rg -q '#if CLIPVAULT_E2E_PROBE' "$VIEW_MODEL"
rg -Fq 'CaptureConsentPolicy(' "$VIEW_MODEL"
rg -q 'hasPersistedConsent: ClipVaultViewModel.initialCaptureConsent' "$VIEW_MODEL"

STOP_CAPTURE_BODY="$(sed -n '/private func stopCapture()/,/^    }/p' "$VIEW_MODEL")"
[[ "$STOP_CAPTURE_BODY" == *'captureService.stop()'* ]]
[[ "$STOP_CAPTURE_BODY" == *'removeObject(forKey: ClipVaultSettingsKey.captureReadyProcessID)'* ]]
[[ "$(rg -c 'captureService\.stop\(\)' "$VIEW_MODEL")" == "1" ]]

DISCLOSURE_HOST_COUNT="$(rg -l 'captureConsentDisclosure\(model: model\)' "$ROOT_DIR/Sources/ClipVault/Views" | wc -l | tr -d ' ')"
[[ "$DISCLOSURE_HOST_COUNT" == "1" ]]
rg -q 'captureConsentDisclosure\(model: model\)' "$ROOT_DIR/Sources/ClipVault/Views/ContentView.swift"

echo "Sandbox-safe launch and E2E-only capture-consent tests passed."
