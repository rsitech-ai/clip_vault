#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
BUNDLE_ID="${APP_BUNDLE_ID:-com.andrzej.ClipVault}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
EXPECTED_ARCHS="${EXPECTED_ARCHS:-arm64}"
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

INSPECT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-pkg-validation.XXXXXX")"
trap 'rm -rf "$INSPECT_ROOT"' EXIT

echo "== Package signature =="
PKG_SIGNATURE="$(/usr/sbin/pkgutil --check-signature "$PKG_PATH")"
printf '%s\n' "$PKG_SIGNATURE"
grep -Fq "Status: signed by a developer certificate issued by Apple" <<<"$PKG_SIGNATURE" || \
  fail "installer package is not signed by an Apple distribution certificate"
grep -Eq "3rd Party Mac Developer Installer:|Mac Installer Distribution:" <<<"$PKG_SIGNATURE" || \
  fail "installer package does not use a Mac App Store installer identity"

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

echo "== Strict signatures =="
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_BINARY"
/usr/bin/codesign --verify --strict --verbose=2 "$RUST_DYLIB"
APP_SIGNATURE="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
grep -Eq "^Authority=(Apple Distribution:|3rd Party Mac Developer Application:)" <<<"$APP_SIGNATURE" || \
  fail "application is not signed with a Mac App Store distribution identity"

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
[[ -n "$TEAM_ID" ]] || fail "effective team identifier is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$EFFECTIVE_ENTITLEMENTS")" == "$TEAM_ID.$BUNDLE_ID" ]] || \
  fail "effective application identifier does not match team and bundle identifiers"

echo "== Info.plist and privacy manifest =="
/usr/bin/plutil -lint "$INFO_PLIST"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$INFO_PLIST")" == "$BUNDLE_ID" ]] || fail "bundle identifier mismatch"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" == "$APP_VERSION" ]] || fail "version mismatch"
[[ "$(/usr/bin/plutil -extract CFBundleVersion raw "$INFO_PLIST")" == "$APP_BUILD" ]] || fail "build number mismatch"
[[ "$(/usr/bin/plutil -extract CFBundleExecutable raw "$INFO_PLIST")" == "$APP_NAME" ]] || fail "bundle executable mismatch"
[[ "$(/usr/bin/plutil -extract CFBundlePackageType raw "$INFO_PLIST")" == "APPL" ]] || fail "bundle package type mismatch"
[[ -n "$(/usr/bin/plutil -extract LSApplicationCategoryType raw "$INFO_PLIST")" ]] || fail "application category is missing"
/usr/bin/plutil -lint "$PRIVACY_MANIFEST"
[[ "$(/usr/bin/plutil -extract NSPrivacyTracking raw "$PRIVACY_MANIFEST")" == "false" ]] || fail "privacy manifest must declare tracking false"

echo "== Architectures and load paths =="
for executable in "$APP_BINARY" "$RUST_DYLIB"; do
  ARCHS="$(/usr/bin/lipo -archs "$executable" | xargs)"
  [[ "$ARCHS" == "$EXPECTED_ARCHS" ]] || fail "unexpected architectures in $executable: $ARCHS (expected $EXPECTED_ARCHS)"
  assert_no_build_host_rpaths "$executable"
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
echo "Mac App Store distribution package validation passed."
