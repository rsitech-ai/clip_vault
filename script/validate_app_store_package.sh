#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
BUNDLE_ID="${APP_BUNDLE_ID:-com.andrzej.ClipVault}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
EXPECTED_ARCHS="${EXPECTED_ARCHS:-arm64}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-${APPLE_TEAM_ID:-}}"
EXPECTED_INSTALLER_SIGNING_IDENTITY="${EXPECTED_INSTALLER_SIGNING_IDENTITY:-}"
PKG_PATH="${1:-${PKG_PATH:-$ROOT_DIR/dist/AppStore/$APP_NAME-$APP_VERSION-$APP_BUILD.pkg}}"
DSYM_BUNDLE="${DSYM_BUNDLE:-$ROOT_DIR/dist/AppStore/$APP_NAME.app.dSYM}"

# shellcheck source=lib/release_artifact.sh
source "$ROOT_DIR/script/lib/release_artifact.sh"

fail() {
  printf 'Package validation failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$PKG_PATH" ]] || fail "missing package: $PKG_PATH"
[[ -d "$DSYM_BUNDLE" ]] || fail "missing dSYM: $DSYM_BUNDLE"
[[ -n "$EXPECTED_TEAM_ID" ]] || fail "EXPECTED_TEAM_ID or APPLE_TEAM_ID is required"
[[ -n "$EXPECTED_INSTALLER_SIGNING_IDENTITY" ]] || fail "EXPECTED_INSTALLER_SIGNING_IDENTITY is required"

INSPECT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-pkg-validation.XXXXXX")"
trap 'rm -rf "$INSPECT_ROOT"' EXIT

echo "== Package signature =="
PKG_SIGNATURE="$(/usr/sbin/pkgutil --check-signature "$PKG_PATH")"
printf '%s\n' "$PKG_SIGNATURE"
grep -Fq "Status: signed by a developer certificate issued by Apple" <<<"$PKG_SIGNATURE" || \
  fail "installer package is not signed by an Apple distribution certificate"
grep -Eq "3rd Party Mac Developer Installer:|Mac Installer Distribution:" <<<"$PKG_SIGNATURE" || \
  fail "installer package does not use a Mac App Store installer identity"
ACTUAL_INSTALLER_SIGNING_IDENTITY="$(printf '%s\n' "$PKG_SIGNATURE" | installer_identity_from_pkg_signature)"
[[ "$ACTUAL_INSTALLER_SIGNING_IDENTITY" == "$EXPECTED_INSTALLER_SIGNING_IDENTITY" ]] || \
  fail "installer signer mismatch: expected '$EXPECTED_INSTALLER_SIGNING_IDENTITY', got '$ACTUAL_INSTALLER_SIGNING_IDENTITY'"
[[ "$(team_identifier_from_identity "$ACTUAL_INSTALLER_SIGNING_IDENTITY")" == "$EXPECTED_TEAM_ID" ]] || \
  fail "installer signer team does not match expected team $EXPECTED_TEAM_ID"

echo "== Package payload =="
PAYLOAD_FILES="$(/usr/sbin/pkgutil --payload-files "$PKG_PATH")"
grep -Fq "$APP_NAME.app/Contents/MacOS/$APP_NAME" <<<"$PAYLOAD_FILES" || \
  fail "payload does not contain the application executable"
/usr/sbin/pkgutil --expand-full "$PKG_PATH" "$INSPECT_ROOT/expanded"

APP_COUNT="$(find "$INSPECT_ROOT/expanded" -type d -name "$APP_NAME.app" | wc -l | tr -d ' ')"
[[ "$APP_COUNT" -eq 1 ]] || fail "expected exactly one $APP_NAME.app in package payload"
APP_BUNDLE="$(find "$INSPECT_ROOT/expanded" -type d -name "$APP_NAME.app" -print -quit)"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
PRIVACY_MANIFEST="$APP_CONTENTS/Resources/PrivacyInfo.xcprivacy"
RUST_DYLIB="$APP_CONTENTS/Frameworks/libsearch_index_core.dylib"

[[ -x "$APP_BINARY" ]] || fail "payload executable is missing or not executable"
[[ -f "$RUST_DYLIB" ]] || fail "nested Rust library is missing"
[[ -f "$INFO_PLIST" ]] || fail "Info.plist is missing"
[[ -f "$PRIVACY_MANIFEST" ]] || fail "privacy manifest is missing"

echo "== Shipping binary probe markers =="
APP_BINARY_STRINGS="$INSPECT_ROOT/app-binary-strings.txt"
/usr/bin/strings "$APP_BINARY" >"$APP_BINARY_STRINGS"
for forbidden_marker in \
  "--verify-stored-clip" \
  "--verify-generated-prompt-batch" \
  "CLIPVAULT_STORE_PROBE" \
  "CLIPVAULT_GENERATED_PROMPT_BATCH_PROBE" \
  "com.andrzej.ClipVault.e2e.capture"; do
  if /usr/bin/grep -Fq -- "$forbidden_marker" "$APP_BINARY_STRINGS"; then
    fail "payload executable contains internal store probe marker: $forbidden_marker"
  fi
done

echo "== Strict signatures =="
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_BINARY"
/usr/bin/codesign --verify --strict --verbose=2 "$RUST_DYLIB"
APP_SIGNATURE="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
grep -Eq "^Authority=(Apple Distribution:|3rd Party Mac Developer Application:)" <<<"$APP_SIGNATURE" || \
  fail "application is not signed with a Mac App Store distribution identity"
for signed_artifact in "$APP_BUNDLE" "$APP_BINARY" "$RUST_DYLIB"; do
  assert_hardened_runtime "$signed_artifact"
  ACTUAL_TEAM_ID="$(codesign_details "$signed_artifact" | team_identifier_from_codesign_details)"
  [[ "$ACTUAL_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || \
    fail "codesign TeamIdentifier mismatch in $signed_artifact: expected $EXPECTED_TEAM_ID, got $ACTUAL_TEAM_ID"
done

echo "== Effective entitlements =="
EFFECTIVE_ENTITLEMENTS="$INSPECT_ROOT/effective-entitlements.plist"
/usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" >"$EFFECTIVE_ENTITLEMENTS" 2>"$INSPECT_ROOT/codesign-entitlements.log"
/usr/bin/plutil -lint "$EFFECTIVE_ENTITLEMENTS"
/usr/bin/plutil -p "$EFFECTIVE_ENTITLEMENTS"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$EFFECTIVE_ENTITLEMENTS")" == "true" ]] || \
  fail "effective app sandbox entitlement is not true"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-only' "$EFFECTIVE_ENTITLEMENTS")" == "true" ]] || \
  fail "effective user-selected read-only entitlement is not true"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$EFFECTIVE_ENTITLEMENTS")"
[[ "$TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail "effective team identifier does not match expected team"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$EFFECTIVE_ENTITLEMENTS")" == "$EXPECTED_TEAM_ID.$BUNDLE_ID" ]] || \
  fail "effective application identifier does not match team and bundle identifiers"

echo "== Embedded provisioning profile =="
PROVISIONING_PROFILE="$APP_CONTENTS/embedded.provisionprofile"
if [[ -f "$PROVISIONING_PROFILE" ]]; then
  PROFILE_PLIST="$INSPECT_ROOT/embedded-provisioning-profile.plist"
  /usr/bin/security cms -D -i "$PROVISIONING_PROFILE" >"$PROFILE_PLIST"
  /usr/bin/plutil -lint "$PROFILE_PLIST"
  PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")"
  [[ "$PROFILE_TEAM_ID" == "$EXPECTED_TEAM_ID" ]] || fail "provisioning profile team identifier mismatch"
  PROFILE_ENTITLEMENT_TEAM="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST")"
  [[ "$PROFILE_ENTITLEMENT_TEAM" == "$EXPECTED_TEAM_ID" ]] || fail "provisioning profile entitlement team mismatch"
  PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST")"
  [[ "$PROFILE_APP_ID" == "$EXPECTED_TEAM_ID.$BUNDLE_ID" ]] || fail "provisioning profile application identifier mismatch"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.app-sandbox' "$PROFILE_PLIST")" == "true" ]] || \
    fail "provisioning profile app sandbox entitlement is not true"
  PROFILE_EXPIRATION="$(/usr/bin/plutil -extract ExpirationDate raw "$PROFILE_PLIST")"
  NOW_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  [[ "$PROFILE_EXPIRATION" > "$NOW_UTC" ]] || fail "provisioning profile is expired: $PROFILE_EXPIRATION"
  printf 'Provisioning profile valid through: %s\n' "$PROFILE_EXPIRATION"
  PROVISIONING_STATUS="validated"
else
  echo "No embedded provisioning profile; App Store Connect provisioning validation remains unverified."
  PROVISIONING_STATUS="absent"
fi

echo "== Info.plist and privacy manifest =="
/usr/bin/plutil -lint "$INFO_PLIST"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" == "$BUNDLE_ID" ]] || fail "bundle identifier mismatch"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" == "$APP_VERSION" ]] || fail "version mismatch"
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO_PLIST")" == "$APP_BUILD" ]] || fail "build number mismatch"
[[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$INFO_PLIST")" == "$APP_NAME" ]] || fail "bundle executable mismatch"
[[ "$(/usr/bin/plutil -extract CFBundlePackageType raw "$INFO_PLIST")" == "APPL" ]] || fail "bundle package type mismatch"
[[ -n "$(/usr/bin/plutil -extract LSApplicationCategoryType raw "$INFO_PLIST")" ]] || fail "application category is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeIdentifier' "$INFO_PLIST")" == "com.andrzej.ClipVault.clip-move" ]] || \
  fail "clip move exported type identifier is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeConformsTo:0' "$INFO_PLIST")" == "public.data" ]] || \
  fail "clip move exported type must conform to public.data"
/usr/bin/plutil -lint "$PRIVACY_MANIFEST"
[[ "$(/usr/bin/plutil -extract NSPrivacyTracking raw "$PRIVACY_MANIFEST")" == "false" ]] || fail "privacy manifest must declare tracking false"

echo "== Architectures and load paths =="
for executable in "$APP_BINARY" "$RUST_DYLIB"; do
  ARCHS="$(/usr/bin/lipo -archs "$executable" | xargs)"
  [[ "$ARCHS" == "$EXPECTED_ARCHS" ]] || fail "unexpected architectures in $executable: $ARCHS (expected $EXPECTED_ARCHS)"
  assert_macho_paths_allowed "$executable"
done
/usr/bin/otool -L "$APP_BINARY" | grep -Fq "@executable_path/../Frameworks/libsearch_index_core.dylib" || \
  fail "application does not load the bundled Rust library"

echo "== dSYM UUID =="
assert_matching_uuids "$APP_BINARY" "$DSYM_BUNDLE"
/usr/bin/dwarfdump --uuid "$APP_BINARY"
/usr/bin/dwarfdump --uuid "$DSYM_BUNDLE"

if /usr/bin/xattr -lr "$APP_BUNDLE" | grep -Fq "com.apple.quarantine"; then
  fail "payload contains quarantine attributes"
fi

DSYM_DWARF="$DSYM_BUNDLE/Contents/Resources/DWARF/$APP_NAME"
[[ -f "$DSYM_DWARF" ]] || fail "dSYM DWARF file is missing"
PKG_SHA256="$(/usr/bin/shasum -a 256 "$PKG_PATH" | awk '{print $1}')"
DSYM_SHA256="$(/usr/bin/shasum -a 256 "$DSYM_DWARF" | awk '{print $1}')"
printf 'Package SHA-256: %s\n' "$PKG_SHA256"
printf 'dSYM DWARF SHA-256: %s\n' "$DSYM_SHA256"
echo "Repository-local Mac App Store package validation passed."
if [[ "$PROVISIONING_STATUS" == "absent" ]]; then
  echo "Provisioning gate: UNVERIFIED until App Store Connect server-side validation."
else
  echo "Provisioning gate: locally validated embedded profile; App Store Connect validation remains required."
fi
