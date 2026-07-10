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

is_build_host_rpath "/Applications/Xcode.app/Contents/Developer/usr/lib" || fail "Xcode path must be rejected"
is_build_host_rpath "/private/tmp/build/.build/release" || fail "temporary build path must be rejected"
is_build_host_rpath "/Users/example/project/.build/release" || fail "user build path must be rejected"
if is_build_host_rpath "/usr/lib/swift"; then
  fail "system Swift runtime path must be retained"
fi
if is_build_host_rpath "@loader_path"; then
  fail "relative loader path must be retained"
fi

UUID_FIXTURE=$'UUID: ABCDEF12-3456-7890-ABCD-EF1234567890 (arm64) executable\nUUID: 11111111-2222-3333-4444-555555555555 (x86_64) executable'
EXPECTED_UUIDS=$'11111111-2222-3333-4444-555555555555\nABCDEF12-3456-7890-ABCD-EF1234567890'
ACTUAL_UUIDS="$(printf '%s\n' "$UUID_FIXTURE" | uuids_from_dwarfdump)"
[[ "$ACTUAL_UUIDS" == "$EXPECTED_UUIDS" ]] || fail "UUID parser must normalize and sort UUIDs"

echo "Release artifact helper tests passed."
