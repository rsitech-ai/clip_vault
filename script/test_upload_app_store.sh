#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipvault-upload-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_BIN="$TEST_ROOT/bin"
CALLS="$TEST_ROOT/xcrun-calls"
PKG="$TEST_ROOT/ClipVault.pkg"
KEY_ID="ABC123DEFG"
ISSUER_ID="11111111-2222-3333-4444-555555555555"
KEY="$TEST_ROOT/AuthKey_${KEY_ID}.p8"
mkdir -p "$FAKE_BIN"
touch "$PKG" "$KEY"

cat >"$FAKE_BIN/xcrun" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s|%s\n' "$API_PRIVATE_KEYS_DIR" "$*" >>"$FAKE_XCRUN_CALLS"
SCRIPT
chmod +x "$FAKE_BIN/xcrun"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

run_upload() {
  env \
    PATH="$FAKE_BIN:$PATH" \
    FAKE_XCRUN_CALLS="$CALLS" \
    PKG_PATH="$PKG" \
    ASC_API_KEY="$KEY_ID" \
    ASC_API_ISSUER="$ISSUER_ID" \
    ASC_API_KEY_PATH="$KEY" \
    "$ROOT_DIR/script/upload_app_store.sh" "$@"
}

assert_fails_with() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  grep -Fq "$expected" <<<"$output" || fail "missing error '$expected' in: $output"
}

: >"$CALLS"
run_upload --validate-only
[[ "$(wc -l <"$CALLS" | tr -d ' ')" == "1" ]] || fail "validate-only must invoke altool once"
grep -Fq -- "--validate-app" "$CALLS" || fail "validate-only must use --validate-app"
KEY_DIR="$(cd "$TEST_ROOT" && pwd)"
grep -Fq "$KEY_DIR|" "$CALLS" || fail "key directory must be exported for altool"
if grep -Fq -- "--upload-app" "$CALLS"; then
  fail "validate-only must not upload"
fi

: >"$CALLS"
run_upload
[[ "$(wc -l <"$CALLS" | tr -d ' ')" == "2" ]] || fail "upload must validate and then upload"
sed -n '1p' "$CALLS" | grep -Fq -- "--validate-app" || fail "validation must happen first"
sed -n '2p' "$CALLS" | grep -Fq -- "--upload-app" || fail "upload must happen after validation"

MISNAMED_KEY="$TEST_ROOT/not-the-required-name.p8"
touch "$MISNAMED_KEY"
assert_fails_with \
  "AuthKey_${KEY_ID}.p8" \
  env PATH="$FAKE_BIN:$PATH" FAKE_XCRUN_CALLS="$CALLS" PKG_PATH="$PKG" \
    ASC_API_KEY="$KEY_ID" ASC_API_ISSUER="$ISSUER_ID" ASC_API_KEY_PATH="$MISNAMED_KEY" \
    "$ROOT_DIR/script/upload_app_store.sh" --validate-only

assert_fails_with \
  "ASC_API_KEY_PATH" \
  env PATH="$FAKE_BIN:$PATH" FAKE_XCRUN_CALLS="$CALLS" PKG_PATH="$PKG" \
    ASC_API_KEY="$KEY_ID" ASC_API_ISSUER="$ISSUER_ID" ASC_API_KEY_PATH= \
    "$ROOT_DIR/script/upload_app_store.sh" --validate-only

MISSING_KEY="$TEST_ROOT/AuthKey_ZZZZZZZZZZ.p8"
assert_fails_with \
  "not a readable file" \
  env PATH="$FAKE_BIN:$PATH" FAKE_XCRUN_CALLS="$CALLS" PKG_PATH="$PKG" \
    ASC_API_KEY="ZZZZZZZZZZ" ASC_API_ISSUER="$ISSUER_ID" ASC_API_KEY_PATH="$MISSING_KEY" \
    "$ROOT_DIR/script/upload_app_store.sh" --validate-only

assert_fails_with \
  "Unknown argument" \
  run_upload --surprise

echo "App Store upload validation tests passed."
