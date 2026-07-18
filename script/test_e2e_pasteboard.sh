#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/script/write_e2e_pasteboard.swift"
VIEW_MODEL="$ROOT_DIR/Sources/ClipVault/App/ClipVaultViewModel.swift"
APP_ENTRY="$ROOT_DIR/Sources/ClipVault/App/ClipVaultApp.swift"
E2E_SMOKE="$ROOT_DIR/script/e2e_smoke.sh"
PACKAGE_VALIDATOR="$ROOT_DIR/script/validate_app_store_package.sh"

[[ -x "$HELPER" ]]

set +e
missing_output="$("$HELPER" 2>&1)"
missing_status=$?
empty_output="$("$HELPER" "   " 2>&1)"
empty_status=$?
extra_output="$("$HELPER" "first" "second" 2>&1)"
extra_status=$?
oversized_token="$(printf 'x%.0s' {1..4097})"
oversized_output="$("$HELPER" "$oversized_token" 2>&1)"
oversized_status=$?
set -e

[[ "$missing_status" -eq 64 ]]
[[ "$empty_status" -eq 65 ]]
[[ "$extra_status" -eq 64 ]]
[[ "$oversized_status" -eq 65 ]]
[[ "$missing_output" == "usage: write_e2e_pasteboard.swift <token>" ]]
[[ "$empty_output" == "E2E pasteboard token is empty or too large." ]]
[[ "$extra_output" == "$missing_output" ]]
[[ "$oversized_output" == "$empty_output" ]]

success_output="$("$HELPER" "ClipVault private E2E pasteboard shell test" 2>&1)"
[[ -z "$success_output" ]]

[[ "$(rg -c 'com\.andrzej\.ClipVault\.e2e\.capture' "$HELPER")" == "1" ]]
[[ "$(rg -c 'com\.andrzej\.ClipVault\.e2e\.capture' "$VIEW_MODEL")" == "1" ]]
[[ "$(rg -c 'com\.andrzej\.ClipVault\.e2e\.capture' "$PACKAGE_VALIDATOR")" == "1" ]]
rg -Fq 'E2E_BUNDLE_ID="${E2E_BUNDLE_ID-com.andrzej.ClipVault.e2e.v2}"' "$E2E_SMOKE"
rg -Fq 'KeychainKeyProvider(migrateLegacyKey: model.shouldMigrateLegacyKey)' "$APP_ENTRY"
[[ "$(rg -c 'write_e2e_pasteboard\.swift \"\$TOKEN\"' "$E2E_SMOKE")" == "2" ]]
rg -Fq 'INITIAL_COPY_COUNT="$PROBE_COPY_COUNT"' "$E2E_SMOKE"
rg -Fq 'wait_for_store_probe 1 "$((INITIAL_COPY_COUNT + 1))"' "$E2E_SMOKE"
! rg -q 'pbcopy' "$E2E_SMOKE"
rg -Fq -- '"--verify-generated-prompt-batch"' "$PACKAGE_VALIDATOR"
rg -Fq -- '"CLIPVAULT_GENERATED_PROMPT_BATCH_PROBE"' "$PACKAGE_VALIDATOR"

echo "Private E2E pasteboard tests passed."
