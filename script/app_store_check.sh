#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Packaging/ClipVault.entitlements"
PRIVACY_MANIFEST="$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
PKG_PATH="${PKG_PATH:-$ROOT_DIR/dist/AppStore/$APP_NAME-$APP_VERSION-$APP_BUILD.pkg}"
DSYM_BUNDLE="${DSYM_BUNDLE:-$ROOT_DIR/dist/AppStore/$APP_NAME.app.dSYM}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

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
APPLICATION_SIGNING_IDENTITY="$(printf '%s\n' "$APPLICATION_IDENTITIES" | application_signing_identity_from_output)"
INSTALLER_SIGNING_IDENTITY="$(printf '%s\n' "$INSTALLER_IDENTITIES" | installer_signing_identity_from_output)"

if [[ -n "$APPLICATION_SIGNING_IDENTITY" ]]; then
  echo "Application distribution identity: present"
else
  echo "Application distribution identity: missing"
  MISSING=1
fi

if [[ -n "$INSTALLER_SIGNING_IDENTITY" ]]; then
  echo "Installer distribution identity: present"
else
  echo "Installer distribution identity: missing"
  MISSING=1
fi

if [[ -z "$APPLE_TEAM_ID" && -n "$APPLICATION_SIGNING_IDENTITY" ]]; then
  APPLE_TEAM_ID="$(printf '%s\n' "$APPLICATION_SIGNING_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
fi

if [[ -z "$APPLE_TEAM_ID" ]]; then
  echo "Expected Apple team ID: missing"
  MISSING=1
else
  echo "Expected Apple team ID: $APPLE_TEAM_ID"
fi

if [[ "$MISSING" -eq 1 ]]; then
  echo "Local bundle checks passed, but distribution package prerequisites are incomplete until missing identities are installed."
  exit 3
fi

echo "== Signed distribution package =="
if [[ ! -f "$PKG_PATH" || ! -d "$DSYM_BUNDLE" ]]; then
  echo "Distribution identities are present, but no complete validated package+dSYM pair exists." >&2
  echo "Run ./script/package_app_store.sh, then rerun this check." >&2
  exit 3
fi

DSYM_BUNDLE="$DSYM_BUNDLE" \
  EXPECTED_TEAM_ID="$APPLE_TEAM_ID" \
  EXPECTED_INSTALLER_SIGNING_IDENTITY="$INSTALLER_SIGNING_IDENTITY" \
  ./script/validate_app_store_package.sh "$PKG_PATH"

echo "App Store readiness check complete: local bundle, identities, and distribution package passed repository-local validation."
echo "Provisioning, App Store Connect authentication, server-side validation, metadata, and submission remain separate gates."
