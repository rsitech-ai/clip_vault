#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipVault"
BUNDLE_ID="${APP_BUNDLE_ID:-com.andrzej.ClipVault}"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
MIN_SYSTEM_VERSION="${MIN_SYSTEM_VERSION:-15.0}"
APP_SIGNING_IDENTITY="${APP_SIGNING_IDENTITY:-}"
INSTALLER_SIGNING_IDENTITY="${INSTALLER_SIGNING_IDENTITY:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
PROVISIONING_PROFILE_PATH="${PROVISIONING_PROFILE_PATH:-}"

DIST_ROOT="$ROOT_DIR/dist/AppStore"
APP_BUNDLE="$DIST_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Packaging/ClipVault.entitlements"
DIST_ENTITLEMENTS="$DIST_ROOT/ClipVault-AppStore.entitlements"
PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"
PKG_PATH="$DIST_ROOT/$APP_NAME-$APP_VERSION-$APP_BUILD.pkg"

cd "$ROOT_DIR"

if [[ -z "$APP_SIGNING_IDENTITY" ]]; then
  APP_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"((Apple Distribution|Mac App Distribution|3rd Party Mac Developer Application):[^"]*)".*/\1/p' | head -1)"
fi

if [[ -z "$INSTALLER_SIGNING_IDENTITY" ]]; then
  INSTALLER_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"((3rd Party Mac Developer Installer|Mac Installer Distribution):[^"]*)".*/\1/p' | head -1)"
fi

if [[ -z "$APPLE_TEAM_ID" && -n "$APP_SIGNING_IDENTITY" ]]; then
  APPLE_TEAM_ID="$(printf '%s\n' "$APP_SIGNING_IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')"
fi

if [[ -z "$APP_SIGNING_IDENTITY" ]]; then
  echo "Missing APP_SIGNING_IDENTITY. Install an Apple Distribution/Mac App Distribution certificate first." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 2
fi

if [[ -z "$INSTALLER_SIGNING_IDENTITY" ]]; then
  echo "Missing INSTALLER_SIGNING_IDENTITY. Install a 3rd Party Mac Developer Installer certificate first." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 2
fi

cargo build --manifest-path rust/SearchIndexCore/Cargo.toml --release
swift build -c release

if [[ ! -f "$APP_ICON" ]]; then
  swift script/generate_app_icon.swift "$APP_ICON"
fi

rm -rf "$DIST_ROOT"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$(swift build -c release --show-bin-path)/$APP_NAME" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$PRIVACY_MANIFEST" "$APP_RESOURCES/PrivacyInfo.xcprivacy"
cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"

if [[ -n "$PROVISIONING_PROFILE_PATH" ]]; then
  cp "$PROVISIONING_PROFILE_PATH" "$APP_CONTENTS/embedded.provisionprofile"
fi

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
  <string>Copyright © 2026 ClipVault. All rights reserved.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -n "$APPLE_TEAM_ID" ]]; then
  cat >"$DIST_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$APPLE_TEAM_ID.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key>
  <string>$APPLE_TEAM_ID</string>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.files.user-selected.read-only</key>
  <true/>
</dict>
</plist>
PLIST
else
  cp "$ENTITLEMENTS" "$DIST_ENTITLEMENTS"
fi

/usr/bin/codesign \
  --force \
  --timestamp \
  --options runtime \
  --entitlements "$DIST_ENTITLEMENTS" \
  --sign "$APP_SIGNING_IDENTITY" \
  "$APP_BUNDLE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

/usr/bin/productbuild \
  --component "$APP_BUNDLE" /Applications \
  --sign "$INSTALLER_SIGNING_IDENTITY" \
  "$PKG_PATH"

/usr/sbin/pkgutil --check-signature "$PKG_PATH"

echo "Created Mac App Store package: $PKG_PATH"
