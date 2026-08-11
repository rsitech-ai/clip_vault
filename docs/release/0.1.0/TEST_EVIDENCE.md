# ClipVault 0.1.0 Test Evidence

Date: 2026-08-11. Run from `feat/andrzej_capture_release_audit`; transient logs and staged QA bundles were removed after inspection.

| Check | Fresh result |
| --- | --- |
| `./script/test.sh` | PASS: 10 shell groups; Rust 4/4; Swift 191/191 in 19 suites. |
| `cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml --check` | PASS. |
| `cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets -- -D warnings` | PASS. |
| `cargo audit --file rust/SearchIndexCore/Cargo.lock` | PASS: 1 local crate scanned; no vulnerable dependency. |
| `cargo deny --manifest-path rust/SearchIndexCore/Cargo.toml check` | PASS, including the approved Apache-2.0 license policy. |
| `swift build -c release -Xswiftc -warnings-as-errors` | PASS. |
| `./script/e2e_smoke.sh` | PASS: per-run sandbox/Keychain namespace; isolated capture, dedupe, persistence, relaunch recovery, bounded offline probe, cleanup. |
| Installed Developer ID runtime capture | PASS: `/Applications/ClipVault.app` 0.1.0 (2) captured an area, a Finder window, and a stitched scrolling Finder page; the images reached ClipVault and OCR. Screen Recording and Accessibility remained effective after a full quit/relaunch with no repeat prompt. |
| `./script/build_and_run.sh --verify` | PASS after canonicalizing `/tmp` to `/private/tmp`; exact staged executable remained alive. |
| Native UI smoke | PASS on isolated `com.andrzej.ClipVault.ossqa`: consent declined and re-presented; empty collections/search/no-match; AI workspace; all Settings tabs. Clipboard capture was never enabled. |
| `gitleaks detect --no-git --source . --redact --no-banner --log-level warn` | PASS on current tree. |
| Markdown links | PASS: every relative Markdown target resolves. |
| YAML / JSON parsing | PASS for GitHub workflow/templates/Dependabot and release manifest. |
| `git diff --check` | PASS. |
| `./script/app_store_check.sh` | Expected exit 3: bundle/plist/entitlements/privacy/signatures pass locally; application/installer distribution identities and expected Team ID are missing. |
| `DEVELOPER_ID_APPLICATION_IDENTITY='<installed Developer ID Application identity>' NOTARY_KEYCHAIN_PROFILE='clipvault-notary' ./script/package_direct_download.sh --preflight` | Expected exit 2: Developer ID identity validation passes and the fail-closed gate reports the missing notarization Keychain profile. |
| Hosted arm64 CI | NOT CURRENT-HEAD PROOF: run `29774529702`, job `88460604543` passed the older reviewed PR #13 head `45205f80ec19f7ad844b17bcf0db0da0c216c03b`. The owner explicitly waived current-branch GitHub Actions/CI errors for this release-candidate build; the waiver is not recorded as a pass. |

## Runtime observations

- First launch displayed the complete clipboard-capture disclosure. **Not Now** kept capture disabled, and **Start Capture** presented the disclosure again.
- Sidebar smart collections, empty states, search/no-result copy, and the AI workspace exposed meaningful accessibility labels and correct disabled actions with no clip.
- Settings General, Capture, Access, AI, Surfaces, and About rendered current local-only privacy/AI state, version 0.1.0 (2), and sandbox/privacy-manifest release notes.
- The installed 0.1.0 (2) Developer ID build initially encountered stale TCC rows created by an Apple Development build. Scoped Screen Capture and Accessibility refreshes bound both grants to `/Applications/ClipVault.app`; area and scrolling capture then passed and continued to pass after relaunch.
- The isolated UI bundle, Keychain item, defaults, staged bundle, and QA database files were removed after the smoke. macOS may retain empty protected sandbox-container directories as system metadata.

## Environment limits

- macOS 27.0 beta host, Xcode 26.6, Apple silicon only.
- No clean macOS 15 machine/account, Intel runtime, notarized downloadable build, current-head hosted CI, or App Store Connect server validation proof. The installed Developer ID build is signed and runtime-proven on this host, but Gatekeeper rejects it until notarization succeeds.
- No formal Codex Security scan was run by owner request.
