#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Packaging/ClipVault.entitlements"
PRIVACY_MANIFEST="$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# shellcheck source=lib/signing_identities.sh
source "$ROOT_DIR/script/lib/signing_identities.sh"

cd "$ROOT_DIR"

if [[ ! -d "$APP_BUNDLE" ]]; then
  ./script/build_and_run.sh --verify
fi

echo "== Bundle =="
test -d "$APP_BUNDLE"
test -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
test -f "$INFO_PLIST"
test -f "$PRIVACY_MANIFEST"
test -f "$ICON"

echo "== Info.plist =="
plutil -lint "$INFO_PLIST"
plutil -extract CFBundleIdentifier raw "$INFO_PLIST"
plutil -extract CFBundleShortVersionString raw "$INFO_PLIST"
plutil -extract CFBundleVersion raw "$INFO_PLIST"
plutil -extract LSApplicationCategoryType raw "$INFO_PLIST"

echo "== Entitlements source =="
plutil -lint "$ENTITLEMENTS"
plutil -p "$ENTITLEMENTS" | grep -q '"com.apple.security.app-sandbox" => true'

echo "== Privacy manifest =="
plutil -lint "$PRIVACY_MANIFEST"
plutil -p "$PRIVACY_MANIFEST" | grep -q '"NSPrivacyTracking" => false'

echo "== Signing =="
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dvv --entitlements - "$APP_BUNDLE" 2>&1 | sed -n '1,80p'

echo "== Local application signing identities (codesigning policy) =="
APPLICATION_IDENTITIES="$(security_identities codesigning || true)"
printf '%s\n' "$APPLICATION_IDENTITIES"

echo "== Local installer signing identities (basic policy) =="
INSTALLER_IDENTITIES="$(security_identities basic || true)"
printf '%s\n' "$INSTALLER_IDENTITIES"

MISSING=0

if [[ -n "$(printf '%s\n' "$APPLICATION_IDENTITIES" | application_signing_identity_from_output)" ]]; then
  echo "Application distribution identity: present"
else
  echo "Application distribution identity: missing"
  MISSING=1
fi

if [[ -n "$(printf '%s\n' "$INSTALLER_IDENTITIES" | installer_signing_identity_from_output)" ]]; then
  echo "Installer distribution identity: present"
else
  echo "Installer distribution identity: missing"
  MISSING=1
fi

if [[ "$MISSING" -eq 1 ]]; then
  echo "Local bundle checks passed, but this machine is not upload-ready until missing distribution identities are installed."
  exit 3
fi

echo "App Store readiness check complete: upload prerequisites are present."
