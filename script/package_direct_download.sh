#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-package}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
BUNDLE_ID="${APP_BUNDLE_ID:-com.andrzej.ClipVault}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-15.0}"
DEVELOPER_ID_APPLICATION_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

DIST_ROOT="$ROOT_DIR/dist/DirectDownload"
APP_BUNDLE="$DIST_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Packaging/ClipVault.entitlements"
PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"
RUST_DYLIB_NAME="libsearch_index_core.dylib"
RUST_DYLIB_SOURCE="$ROOT_DIR/rust/SearchIndexCore/target/release/deps/$RUST_DYLIB_NAME"
RUST_DYLIB_BUNDLE="$APP_FRAMEWORKS/$RUST_DYLIB_NAME"
ARCHIVE_NAME="$APP_NAME-$APP_VERSION-macOS.zip"
ARCHIVE_PATH="$DIST_ROOT/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
SUBMISSION_JSON_PATH="$DIST_ROOT/notarization-submission.json"

# shellcheck source=lib/direct_download.sh
source "$ROOT_DIR/script/lib/direct_download.sh"
# shellcheck source=lib/release_artifact.sh
source "$ROOT_DIR/script/lib/release_artifact.sh"

preflight() {
  if [[ -z "$DEVELOPER_ID_APPLICATION_IDENTITY" ]]; then
    printf 'Missing DEVELOPER_ID_APPLICATION_IDENTITY. Install and name a Developer ID Application certificate.\n' >&2
    return 2
  fi
  validate_developer_id_application_identity "$DEVELOPER_ID_APPLICATION_IDENTITY" || return 2

  if ! /usr/bin/security find-identity -v -p codesigning | \
    /usr/bin/grep -Fq "\"$DEVELOPER_ID_APPLICATION_IDENTITY\""; then
    printf 'The requested Developer ID Application identity is not installed or valid: %s\n' \
      "$DEVELOPER_ID_APPLICATION_IDENTITY" >&2
    return 2
  fi

  if [[ -z "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    printf 'Missing NOTARY_KEYCHAIN_PROFILE. Store notarization credentials with notarytool first.\n' >&2
    return 2
  fi

  if ! /usr/bin/xcrun notarytool history \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --output-format json >/dev/null; then
    printf 'The notarytool keychain profile could not be authenticated: %s\n' \
      "$NOTARY_KEYCHAIN_PROFILE" >&2
    return 2
  fi
}

case "$MODE" in
  --preflight)
    preflight
    exit $?
    ;;
  package)
    ;;
  *)
    printf 'usage: %s [package|--preflight]\n' "$0" >&2
    exit 2
    ;;
esac

cd "$ROOT_DIR"
preflight || exit $?

cargo build --manifest-path rust/SearchIndexCore/Cargo.toml --release
swift build -c release -Xswiftc -warnings-as-errors
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

if [[ ! -f "$APP_ICON" ]]; then
  swift script/generate_app_icon.swift "$APP_ICON"
fi

rm -rf "$DIST_ROOT"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$RUST_DYLIB_SOURCE" "$RUST_DYLIB_BUNDLE"
chmod +x "$RUST_DYLIB_BUNDLE"
/usr/bin/install_name_tool -id "@rpath/$RUST_DYLIB_NAME" "$RUST_DYLIB_BUNDLE"
/usr/bin/install_name_tool -change "$RUST_DYLIB_SOURCE" \
  "@executable_path/../Frameworks/$RUST_DYLIB_NAME" "$APP_BINARY"
strip_nonallowlisted_rpaths "$APP_BINARY"
strip_nonallowlisted_rpaths "$RUST_DYLIB_BUNDLE"
assert_macho_paths_allowed "$APP_BINARY"
assert_macho_paths_allowed "$RUST_DYLIB_BUNDLE"
cp "$PRIVACY_MANIFEST" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Rafal Sikora</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>ClipVault uses Apple Events to scroll Chrome, Safari, and related browsers while capturing a full scrolling page.</string>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
      </array>
      <key>UTTypeDescription</key>
      <string>ClipVault Clip Move</string>
      <key>UTTypeIdentifier</key>
      <string>com.andrzej.ClipVault.clip-move</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --timestamp --options runtime \
  --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" "$RUST_DYLIB_BUNDLE"
/usr/bin/codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" \
  --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" "$APP_BUNDLE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
assert_hardened_runtime "$APP_BINARY"
assert_hardened_runtime "$RUST_DYLIB_BUNDLE"

EXPECTED_TEAM_ID="$(team_identifier_from_developer_id_identity \
  "$DEVELOPER_ID_APPLICATION_IDENTITY")"
ACTUAL_TEAM_ID="$(codesign_details "$APP_BUNDLE" | team_identifier_from_codesign_details)"
if [[ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  printf 'Signed app team identifier mismatch. Expected %s, found %s.\n' \
    "$EXPECTED_TEAM_ID" "$ACTUAL_TEAM_ID" >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
SUBMISSION_JSON="$(/usr/bin/xcrun notarytool submit "$ARCHIVE_PATH" \
  --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
  --wait \
  --output-format json)"
printf '%s\n' "$SUBMISSION_JSON" >"$SUBMISSION_JSON_PATH"
require_accepted_notarization_status "$SUBMISSION_JSON"

/usr/bin/xcrun stapler staple "$APP_BUNDLE"
/usr/bin/xcrun stapler validate "$APP_BUNDLE"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE_PATH"
(
  cd "$DIST_ROOT"
  /usr/bin/shasum -a 256 "$ARCHIVE_NAME" >"$ARCHIVE_NAME.sha256"
)

printf 'Created notarized direct-download app: %s\n' "$APP_BUNDLE"
printf 'Created release archive: %s\n' "$ARCHIVE_PATH"
printf 'Created SHA-256 checksum: %s\n' "$CHECKSUM_PATH"
