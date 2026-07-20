# ClipVault 0.1.0 Test Evidence

Date: 2026-07-20. Run from the isolated release-hardening worktree; transient logs and staged QA bundles were removed after inspection.

| Check | Fresh result |
| --- | --- |
| `./script/test.sh` | PASS: 10 shell groups; Rust 4/4; Swift 178/178 in 17 suites. |
| `cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml --check` | PASS. |
| `cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets -- -D warnings` | PASS. |
| `cargo audit --file rust/SearchIndexCore/Cargo.lock` | PASS: 1 local crate scanned; no vulnerable dependency. |
| `cargo deny --manifest-path rust/SearchIndexCore/Cargo.toml check advisories bans sources` | PASS. License check intentionally blocked pending project license. |
| `swift build -c release` | PASS. |
| `./script/e2e_smoke.sh` | PASS: per-run sandbox/Keychain namespace; isolated capture, dedupe, persistence, relaunch recovery, bounded offline probe, cleanup. |
| `./script/build_and_run.sh --verify` | PASS after canonicalizing `/tmp` to `/private/tmp`; exact staged executable remained alive. |
| Native UI smoke | PASS on isolated `com.andrzej.ClipVault.ossqa`: consent declined and re-presented; empty collections/search/no-match; AI workspace; all Settings tabs. Clipboard capture was never enabled. |
| `gitleaks detect --no-git --source . --redact --no-banner --log-level warn` | PASS on current tree. |
| Markdown links | PASS: every relative Markdown target resolves. |
| YAML / JSON parsing | PASS for GitHub workflow/templates/Dependabot and release manifest. |
| `git diff --check` | PASS. |
| `./script/app_store_check.sh` | Expected exit 3: bundle/plist/entitlements/privacy/signatures pass locally; application/installer distribution identities and expected Team ID are missing. |
| `./script/package_direct_download.sh --preflight` | Expected exit 2: fail-closed direct-download gate reports the missing Developer ID Application identity before build/notarization work. |

## Runtime observations

- First launch displayed the complete clipboard-capture disclosure. **Not Now** kept capture disabled, and **Start Capture** presented the disclosure again.
- Sidebar smart collections, empty states, search/no-result copy, and the AI workspace exposed meaningful accessibility labels and correct disabled actions with no clip.
- Settings General, Capture, Access, AI, Surfaces, and About rendered current local-only privacy/AI state, version 0.1.0 (1), and sandbox/privacy-manifest release notes.
- The isolated UI bundle, Keychain item, defaults, staged bundle, and QA database files were removed after the smoke. macOS may retain empty protected sandbox-container directories as system metadata.

## Environment limits

- macOS 27.0 beta host, Xcode 26.6, Apple silicon only.
- No clean macOS 15 machine/account, Intel runtime, Developer ID/notarized build, App Store Connect server validation, or hosted exact-head CI proof.
- No formal Codex Security scan was run by owner request.
