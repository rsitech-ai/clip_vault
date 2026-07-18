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

START_CAPTURE_BODY="$(sed -n '/private func startCapture()/,/^    }/p' "$VIEW_MODEL")"
[[ "$START_CAPTURE_BODY" == *'guard store != nil else'* ]]
[[ "$START_CAPTURE_BODY" == *'isCapturing = false'* ]]
[[ "$START_CAPTURE_BODY" == *'return false'* ]]
[[ "$START_CAPTURE_BODY" == *'return true'* ]]

TOGGLE_CAPTURE_BODY="$(sed -n '/func toggleCapture()/,/^    }/p' "$VIEW_MODEL")"
ACCEPT_CAPTURE_BODY="$(sed -n '/func acceptCaptureConsent()/,/^    }/p' "$VIEW_MODEL")"
[[ "$TOGGLE_CAPTURE_BODY" == *'if startCapture()'* ]]
[[ "$ACCEPT_CAPTURE_BODY" == *'if startCapture()'* ]]

rg -Fq 'private let encryptionBootstrap: LocalPayloadEncryptionBootstrap' "$VIEW_MODEL"
rg -Fq 'let persistentStoreExists = FileManager.default.fileExists(atPath: configuration.url.path)' "$VIEW_MODEL"
rg -Fq 'migrateLegacyKey = persistentStoreExists' "$VIEW_MODEL"
rg -Fq 'shouldMigrateLegacyKey = migrateLegacyKey' "$VIEW_MODEL"
[[ "$(rg -c 'preparedEncryptor\(\)' "$VIEW_MODEL")" == "1" ]]

DISCLOSURE_HOST_COUNT="$(rg -l 'captureConsentDisclosure\(model: model\)' "$ROOT_DIR/Sources/ClipVault/Views" | wc -l | tr -d ' ')"
[[ "$DISCLOSURE_HOST_COUNT" == "1" ]]
rg -q 'captureConsentDisclosure\(model: model\)' "$ROOT_DIR/Sources/ClipVault/Views/ContentView.swift"

echo "Sandbox-safe launch and E2E-only capture-consent tests passed."
