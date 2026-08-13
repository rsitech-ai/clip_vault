#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_VERSION='APP_VERSION="${APP_VERSION:-0.1.1}"'
EXPECTED_BUILD='APP_BUILD="${APP_BUILD:-3}"'

release_scripts=(
  build_and_run.sh
  package_direct_download.sh
  package_app_store.sh
  app_store_check.sh
  upload_app_store.sh
  validate_app_store_package.sh
)

for script_name in "${release_scripts[@]}"; do
  script_path="$ROOT_DIR/script/$script_name"
  /usr/bin/grep -Fq "$EXPECTED_VERSION" "$script_path" || {
    printf '%s does not default to release version 0.1.1\n' "$script_name" >&2
    exit 1
  }
  /usr/bin/grep -Fq "$EXPECTED_BUILD" "$script_path" || {
    printf '%s does not default to release build 3\n' "$script_name" >&2
    exit 1
  }
done

printf 'Release version default tests passed.\n'
