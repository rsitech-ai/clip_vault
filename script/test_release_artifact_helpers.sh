#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/release_artifact.sh
source "$ROOT_DIR/script/lib/release_artifact.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

OTOOL_FIXTURE='Load command 12
          cmd LC_RPATH
      cmdsize 48
         path /usr/lib/swift (offset 12)
Load command 13
          cmd LC_RPATH
      cmdsize 152
         path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx (offset 12)
Load command 14
          cmd LC_RPATH
      cmdsize 48
         path @loader_path (offset 12)'

EXPECTED_RPATHS=$'/usr/lib/swift\n/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx\n@loader_path'
ACTUAL_RPATHS="$(printf '%s\n' "$OTOOL_FIXTURE" | rpaths_from_otool)"
[[ "$ACTUAL_RPATHS" == "$EXPECTED_RPATHS" ]] || fail "LC_RPATH parser returned unexpected paths"

for allowed_path in \
  "/usr/lib/swift" \
  "/usr/lib/../lib/libSystem.B.dylib" \
  "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit" \
  "/System/Library/../Library/Frameworks/Foundation.framework/Foundation" \
  "@loader_path/libsearch_index_core.dylib" \
  "@rpath/libsearch_index_core.dylib" \
  "@executable_path/../Frameworks/libsearch_index_core.dylib"; do
  is_allowed_macho_path "$allowed_path" || fail "allowlisted Mach-O path was rejected: $allowed_path"
done

APP_ARTIFACT="/tmp/ClipVault.app/Contents/MacOS/ClipVault"
DYLIB_ARTIFACT="/tmp/ClipVault.app/Contents/Frameworks/libsearch_index_core.dylib"
is_allowed_macho_path \
  "@executable_path/../Frameworks/libsearch_index_core.dylib" "$APP_ARTIFACT" || \
  fail "legitimate executable-relative Frameworks path must remain inside the app"
is_allowed_macho_path \
  "@loader_path/libhelper.dylib" "$DYLIB_ARTIFACT" || \
  fail "legitimate loader-relative sibling path must remain inside the app"

for rejected_context_path in \
  "@executable_path/../../../../tmp/evil.dylib" \
  "@loader_path/../../../opt/evil.dylib" \
  "@rpath/../../evil.dylib" \
  "@executable_path//evil.dylib" \
  "@loader_path/./evil.dylib"; do
  if is_allowed_macho_path "$rejected_context_path" "$DYLIB_ARTIFACT"; then
    fail "escaping or ambiguous token path was accepted: $rejected_context_path"
  fi
done

for rejected_path in \
  "/tmp/build/lib.dylib" \
  "/private/tmp/build/lib.dylib" \
  "/opt/homebrew/lib/libexample.dylib" \
  "/Applications/Xcode.app/Contents/Developer/usr/lib/libexample.dylib" \
  "/Library/Developer/CommandLineTools/usr/lib/libexample.dylib" \
  "/Users/example/project/.build/release/libexample.dylib" \
  "/unexpected/absolute/libexample.dylib" \
  "/usr/lib/../../tmp/evil.dylib" \
  "/System/Library/../../../opt/evil.dylib" \
  "relative/libexample.dylib"; do
  if is_allowed_macho_path "$rejected_path"; then
    fail "non-allowlisted Mach-O path was accepted: $rejected_path"
  fi
done

UUID_FIXTURE=$'UUID: ABCDEF12-3456-7890-ABCD-EF1234567890 (arm64) executable\nUUID: 11111111-2222-3333-4444-555555555555 (x86_64) executable'
EXPECTED_UUIDS=$'11111111-2222-3333-4444-555555555555\nABCDEF12-3456-7890-ABCD-EF1234567890'
ACTUAL_UUIDS="$(printf '%s\n' "$UUID_FIXTURE" | uuids_from_dwarfdump)"
[[ "$ACTUAL_UUIDS" == "$EXPECTED_UUIDS" ]] || fail "UUID parser must normalize and sort UUIDs"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-runtime-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
NO_RUNTIME_BINARY="$TEST_ROOT/no-runtime"
RUNTIME_BINARY="$TEST_ROOT/runtime"
cp /bin/echo "$NO_RUNTIME_BINARY"
cp /bin/echo "$RUNTIME_BINARY"
/usr/bin/codesign --force --sign - "$NO_RUNTIME_BINARY" >/dev/null 2>&1
/usr/bin/codesign --force --sign - --options runtime "$RUNTIME_BINARY" >/dev/null 2>&1
if assert_hardened_runtime "$NO_RUNTIME_BINARY" 2>/dev/null; then
  fail "a signed binary without the runtime flag must be rejected"
fi
assert_hardened_runtime "$RUNTIME_BINARY" || fail "a signed binary with the runtime flag must pass"

CODESIGN_FIXTURE='Executable=/tmp/ClipVault
Identifier=com.andrzej.ClipVault
Authority=Apple Distribution: Example (2NY8A789TN)
TeamIdentifier=2NY8A789TN'
[[ "$(printf '%s\n' "$CODESIGN_FIXTURE" | team_identifier_from_codesign_details)" == "2NY8A789TN" ]] || \
  fail "codesign TeamIdentifier parser must return the exact team"

PKG_SIGNATURE_FIXTURE='Package "ClipVault.pkg":
   Status: signed by a developer certificate issued by Apple (Development)
   Certificate Chain:
    1. 3rd Party Mac Developer Installer: Example (2NY8A789TN)
       Expires: 2027-06-29 12:42:38 +0000'
EXPECTED_INSTALLER='3rd Party Mac Developer Installer: Example (2NY8A789TN)'
[[ "$(printf '%s\n' "$PKG_SIGNATURE_FIXTURE" | installer_identity_from_pkg_signature)" == "$EXPECTED_INSTALLER" ]] || \
  fail "package signature parser must return the exact installer identity"
[[ "$(team_identifier_from_identity "$EXPECTED_INSTALLER")" == "2NY8A789TN" ]] || \
  fail "identity parser must return the exact installer team"

echo "Release artifact helper tests passed."
