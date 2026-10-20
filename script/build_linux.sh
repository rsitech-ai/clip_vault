#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(uname -s)" == Linux ]] || { echo 'Build the Linux package on Linux, or use script/test_linux.sh for container validation.' >&2; exit 1; }
cargo build --manifest-path rust/DeviceSync/Cargo.toml -p clipvault-linux --release --locked
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/rust/DeviceSync/target}"
PACKAGE_ROOT="$ROOT_DIR/dist/linux/package"
[[ ! -e "$PACKAGE_ROOT" ]] || { echo 'Move the previous dist/linux/package staging folder before packaging again.' >&2; exit 1; }
install -Dm755 "$TARGET_DIR/release/clipvault-linux" "$PACKAGE_ROOT/usr/bin/clipvault-linux"
install -Dm644 Packaging/linux/com.rsitech.ClipVault.desktop "$PACKAGE_ROOT/usr/share/applications/com.rsitech.ClipVault.desktop"
python3 script/generate_sync_notices.py "$PACKAGE_ROOT/usr/share/doc/clipvault/THIRD-PARTY-NOTICES.txt"
install -Dm644 Packaging/linux/com.rsitech.ClipVault.Capture.service "$PACKAGE_ROOT/usr/share/dbus-1/services/com.rsitech.ClipVault.Capture.service"
EXTENSION_ROOT="$PACKAGE_ROOT/usr/share/gnome-shell/extensions/clipvault-capture@rsitech.ai"
install -Dm644 rust/DeviceSync/linux/gnome-extension/metadata.json "$EXTENSION_ROOT/metadata.json"
install -Dm644 rust/DeviceSync/linux/gnome-extension/extension.js "$EXTENSION_ROOT/extension.js"
install -Dm644 rust/DeviceSync/linux/gnome-extension/boundedSelection.js "$EXTENSION_ROOT/boundedSelection.js"
mkdir -p "$PACKAGE_ROOT/DEBIAN"
ARCHITECTURE="$(dpkg --print-architecture)"
cat > "$PACKAGE_ROOT/DEBIAN/control" <<CONTROL
Package: clipvault
Version: 0.2.0~preview1
Section: utils
Priority: optional
Architecture: $ARCHITECTURE
Maintainer: RSI Tech <info@rsitech.ai>
Depends: libgtk-4-1 (>= 4.8), libadwaita-1-0, libdbus-1-3, dbus-user-session, gnome-keyring
Description: Encrypted local clipboard workspace with paired device sharing
 Includes the preview ClipVault capture extension targeting GNOME Shell 51.
 Enable the extension explicitly after installing on a supported GNOME desktop.
CONTROL
dpkg-deb --build --root-owner-group "$PACKAGE_ROOT" "$ROOT_DIR/dist/linux/clipvault_0.2.0-preview1_$ARCHITECTURE.deb"
