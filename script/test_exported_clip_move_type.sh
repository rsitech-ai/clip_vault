#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TYPE_IDENTIFIER="com.andrzej.ClipVault.clip-move"

for generator in \
  "$ROOT_DIR/script/build_and_run.sh" \
  "$ROOT_DIR/script/package_app_store.sh"; do
  [[ "$(rg -c "<string>$TYPE_IDENTIFIER</string>" "$generator")" == "1" ]]
  [[ "$(rg -c '<string>public\.data</string>' "$generator")" == "1" ]]
done

VALIDATOR="$ROOT_DIR/script/validate_app_store_package.sh"
rg -Fq 'UTExportedTypeDeclarations:0:UTTypeIdentifier' "$VALIDATOR"
rg -Fq 'UTExportedTypeDeclarations:0:UTTypeConformsTo:0' "$VALIDATOR"
rg -Fq "$TYPE_IDENTIFIER" "$VALIDATOR"

echo "Exported clip move type declaration tests passed."
