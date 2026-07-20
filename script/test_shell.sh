#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/test_signing_identities.sh
./script/test_release_artifact_helpers.sh
./script/test_upload_app_store.sh
./script/test_build_and_run_consent.sh
./script/test_build_and_run_staging.sh
./script/test_run_with_timeout.sh
./script/test_e2e_pasteboard.sh
./script/test_exported_clip_move_type.sh
./script/test_ai_workspace_glass_policy.sh
