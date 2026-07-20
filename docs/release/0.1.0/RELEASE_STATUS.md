# ClipVault 0.1.0 Release Status

Date: 2026-07-20 (Europe/Warsaw)

## Verdict

**SOURCE PUBLISHED — public repository is repo-ready; downloadable binary remains blocked:external.**

The current source, release build, isolated runtime, E2E path, documentation links, dependency checks, and current-tree hygiene pass. PR #13 passed exact-head hosted arm64 CI, was reviewed and merged, and the repository is public under `rsitech-ai`. Apache-2.0, copyright ownership by Rafal Sikora, RSI Tech maintenance, `info@rsitech.ai` for public/confidential contact, the retained-history rewrite, private vulnerability reporting, and an active default-branch ruleset are verified. A downloadable binary must not be published until notarization, stapling, Gatekeeper, and clean-account runtime proof pass.

No formal Codex Security scan was run; the owner explicitly waived that workflow for this pass. The evidence below is ordinary source/provenance review plus local tools and does not claim formal scan coverage.

## Public surface cleanup (2026-07-20 late)

Removed tracked agent/Codex/skill plans, local reflection notes, and historical internal audit reports from the public tree. Added `NOTICE`, hardened `.gitignore`, pinned `actions/checkout` to v7.0.1, and closed the Dependabot branch that still reached a personal-Gmail merge commit. Current-tree Gitleaks remains clean. Downloadable binary publication remains blocked on notarization credentials.

## Readiness labels

| Lane | Status | Meaning |
| --- | --- | --- |
| Source engineering candidate | RUNTIME-PROVEN | Local tests, release compilation, E2E, native UI smoke, documentation validation, current-tree hygiene, and hosted arm64 CI passed. |
| Public open-source repository | REPO-READY / PUBLISHED | Public organization repository, Apache-2.0 detection, confidential reporting, PR/ruleset protection, and required CI are active. |
| Direct-download macOS binary | BLOCKED:EXTERNAL | A valid Developer ID Application identity is installed and timestamp signing passed. No `notarytool` keychain profile exists, so notarization, stapling, Gatekeeper, and clean-machine install proof remain unavailable. |
| Mac App Store package | BLOCKED:EXTERNAL | Local bundle structure passes, but distribution identities, expected Team ID, App Store Connect validation, and owner declarations are unavailable. |

## Current environment and identity

- Rewritten source baseline: `5cace92adaf5b51e45b45a300a9b29c2a3fbb9ca` (pre-integration `main`).
- Reviewed PR #13 head: `45205f80ec19f7ad844b17bcf0db0da0c216c03b`; privacy-corrected two-parent integration commit: `313dc34ef5ac62d583ddf282e148bf46f4772a13`.
- macOS 27.0 (26A5378j), Apple silicon.
- Xcode 26.6 (17F113), Swift 6.3.3.
- Rust/Cargo 1.91.0.
- Product bundle ID `com.andrzej.ClipVault`, version `0.1.0`, build `1`, minimum macOS `15.0`, arm64.
- Current GitHub repository is public at `https://github.com/rsitech-ai/clip_vault` with Apache-2.0 detected and `https://rsitech.ai` configured as the homepage.

## Gate matrix

| Gate | Result | Evidence / next action |
| --- | --- | --- |
| Rust format, lint, tests | PASS | `cargo fmt --check`; Clippy with `-D warnings`; 4/4 Rust tests. |
| Swift tests | PASS | 178/178 tests in 17 suites via `./script/test.sh`. |
| Swift release build | PASS | `swift build -c release`. |
| Shell policy tests | PASS | Ten shell groups, including direct-download release gates, bounded-process descendant cleanup, and E2E isolation checks. |
| Dependency advisories/policy | PASS | RustSec scanned the one-crate lockfile; cargo-deny advisories, bans, and sources passed. Apache-2.0 is approved and declared in the Rust package metadata. |
| Current-tree secret hygiene | PASS | Gitleaks current-tree run and targeted identity/token checks found no confirmed live secret. Synthetic token fixtures are assembled from fragments. |
| E2E runtime | PASS | Per-run test bundle verified consent-enabled private-pasteboard capture, deduplication, encrypted persistence, relaunch recovery, bounded probes, and app-owned cleanup. |
| Native visual/accessibility smoke | PASS | Isolated `com.andrzej.ClipVault.ossqa` build exercised consent decline/retry, sidebar empty states, search/no-result recovery, AI workspace disabled states, and General/Capture/Access/AI/Surfaces/About settings. Production clipboard data was not captured. |
| Bundle contents/signature | PASS (local only) | Plist, privacy manifest, sandbox entitlements, nested dylib signature/load path, and ad-hoc signature validate locally. |
| Direct-download packaging automation | PASS (logic/signing) / BLOCKED:EXTERNAL (notarization) | Identity validation, notarization-result handling, and fail-closed preflight tests pass. Developer ID timestamp/hardened-runtime signing succeeds; real preflight now exits 2 because `NOTARY_KEYCHAIN_PROFILE` is missing. |
| Distribution signing/package | BLOCKED:EXTERNAL | `app_store_check.sh` exits 3: no application/installer distribution identity or expected Team ID. |
| License/copyright | PASS | Apache-2.0, Rafal Sikora copyright ownership, RSI Tech maintenance, and matching package metadata are approved and committed in the candidate. |
| Git-history privacy | PASS | Both retained remote branches were force-updated after a verified rewrite. Every reachable candidate commit uses only `24563931+s1korrrr@users.noreply.github.com`; pre/post tree IDs match. |
| Public namespace/contact | PASS | `rsitech-ai/clip_vault`, `https://rsitech.ai`, and `info@rsitech.ai` are approved for public and confidential project contact. |
| GitHub visibility/security/rules | PASS | Repository is public; private vulnerability reporting is enabled; active ruleset `Protect main` blocks deletion/non-fast-forward updates and requires PRs, resolved threads, an up-to-date branch, and `verify`. |
| Hosted exact-head CI | PASS | PR #13 exact head passed all 17 steps on hosted arm64 CI in run `29774529702`, job `88460604543`. |
| Public source repository | PASS | PR #13 merged and the source repository is publicly available under `rsitech-ai`. |
| Public tag/binary release | BLOCKED:EXTERNAL | No tag or GitHub Release exists. Create both only after notarization, stapling, Gatekeeper, checksum, and clean-account runtime proof pass. |

## Residual engineering risks

- Deduplication fingerprints remain plaintext local metadata and are not keyed; the privacy policy discloses this boundary. A keyed fingerprint migration can reduce guessing risk but is outside this release-hardening slice.
- The Keychain item uses `AfterFirstUnlockThisDeviceOnly`; changing accessibility semantics requires a separate migration and background-behavior decision.
- Historical audit reports are retained as historical records and may reference ephemeral artifacts that no longer exist. Current claims are limited to this dossier and reproducible commands.
- No macOS 15 clean-machine, Intel, Developer ID/notarized, or App Store Connect server proof exists. Intel is not declared supported.
- `/usr/sbin/screencapture` remains an App Review/API-surface risk.

## Next decision point

Create the scoped `clipvault-notary` Keychain profile, run the fail-closed direct-download packaging command, verify the stapled app on a clean account/machine, and only then publish the version tag and GitHub Release asset.
