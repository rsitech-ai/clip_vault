#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClipVault"
BUNDLE_ID="${APP_BUNDLE_ID:-com.andrzej.ClipVault}"
CAPTURE_CONSENT_KEY="clipboardCaptureConsentGranted"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"
LOCAL_SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY:-}"
SWIFT_CONFIGURATION="${SWIFT_CONFIGURATION:-release}"
ENABLE_STORE_PROBE="${ENABLE_STORE_PROBE:-false}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/temporary_capture_consent.sh"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
RUST_DYLIB_NAME="libsearch_index_core.dylib"
RUST_DYLIB_SOURCE="$ROOT_DIR/rust/SearchIndexCore/target/release/deps/$RUST_DYLIB_NAME"
RUST_DYLIB_BUNDLE="$APP_FRAMEWORKS/$RUST_DYLIB_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Packaging/ClipVault.entitlements"
PRIVACY_MANIFEST="$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"

cd "$ROOT_DIR"

SWIFT_BUILD_ARGS=(-c "$SWIFT_CONFIGURATION")
if [[ "$ENABLE_STORE_PROBE" == "true" ]]; then
  SWIFT_BUILD_ARGS+=(-Xswiftc -D -Xswiftc CLIPVAULT_E2E_PROBE)
fi

terminate_staged_app() {
  local app_pid
  while read -r app_pid; do
    [[ -n "$app_pid" ]] && kill "$app_pid" >/dev/null 2>&1 || true
  done < <(pgrep -f "^$APP_BINARY$" || true)
}

terminate_staged_app

cargo build --manifest-path rust/SearchIndexCore/Cargo.toml --release
swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

if [[ ! -f "$APP_ICON" ]]; then
  swift script/generate_app_icon.swift "$APP_ICON"
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$RUST_DYLIB_SOURCE" "$RUST_DYLIB_BUNDLE"
chmod +x "$RUST_DYLIB_BUNDLE"
install_name_tool -id "@rpath/$RUST_DYLIB_NAME" "$RUST_DYLIB_BUNDLE"
install_name_tool -change "$RUST_DYLIB_SOURCE" "@executable_path/../Frameworks/$RUST_DYLIB_NAME" "$APP_BINARY"
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
  <string>Copyright © 2026 ClipVault. All rights reserved.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

if [[ -f "$ENTITLEMENTS" ]]; then
  if [[ -z "$LOCAL_SIGNING_IDENTITY" ]]; then
    LOCAL_SIGNING_IDENTITY="$(security find-identity -v -p codesigning | sed -nE 's/.*"(Apple Development:[^"]*)".*/\1/p' | head -1)"
  fi

  if [[ -n "$LOCAL_SIGNING_IDENTITY" ]]; then
    echo "Signing $APP_NAME with $LOCAL_SIGNING_IDENTITY"
    codesign --force --sign "$LOCAL_SIGNING_IDENTITY" "$RUST_DYLIB_BUNDLE" >/dev/null
    codesign --force --sign "$LOCAL_SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  else
    echo "Signing $APP_NAME ad-hoc because no Apple Development identity was found"
    codesign --force --sign - "$RUST_DYLIB_BUNDLE" >/dev/null
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_BUNDLE" >/dev/null
  fi
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    preseed_capture_consent_for_verify "$BUNDLE_ID" "$CAPTURE_CONSENT_KEY"
    trap restore_capture_consent_after_verify EXIT
    open_app
    for _ in {1..80}; do
      APP_PID="$(pgrep -f "^$APP_BINARY$" | head -1 || true)"
      READY_PID="$(defaults read "$BUNDLE_ID" captureReadyProcessID 2>/dev/null || true)"
      if [[ -n "$APP_PID" && "$READY_PID" == "$APP_PID" ]]; then
        exit 0
      fi
      sleep 0.25
    done
    echo "$APP_NAME did not report capture readiness within 20 seconds." >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
