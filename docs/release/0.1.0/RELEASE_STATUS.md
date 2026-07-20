# ClipVault 0.1.0 Release Status

Date: 2026-07-20 (Europe/Warsaw)

## Verdict

**HOLD — source candidate locally verified; hosted CI and repository safeguard gates remain.**

The current source, release build, isolated runtime, E2E path, documentation links, dependency checks, and current-tree hygiene pass locally. The repository is owned by `rsitech-ai` and remains private. Apache-2.0, copyright ownership by Rafal Sikora, RSI Tech maintenance, `info@rsitech.ai` for public/confidential contact, and the full retained-history rewrite to the approved GitHub no-reply address are complete. Publication remains blocked until exact-head hosted CI, private vulnerability reporting, and default-branch protection are verified.

No formal Codex Security scan was run; the owner explicitly waived that workflow for this pass. The evidence below is ordinary source/provenance review plus local tools and does not claim formal scan coverage.

## Readiness labels

| Lane | Status | Meaning |
| --- | --- | --- |
| Source engineering candidate | LOCALLY VERIFIED | Local tests, release compilation, E2E, native UI smoke, documentation validation, and current-tree hygiene passed. |
| Public open-source repository | HOLD | Namespace, license/copyright, brand, contacts, and history privacy pass. Visibility/security settings and exact-head hosted CI remain to be completed. |
| Direct-download macOS binary | BLOCKED:EXTERNAL | A valid Developer ID Application identity is installed and timestamp signing passed. No `notarytool` keychain profile exists, so notarization, stapling, Gatekeeper, and clean-machine install proof remain unavailable. |
| Mac App Store package | BLOCKED:EXTERNAL | Local bundle structure passes, but distribution identities, expected Team ID, App Store Connect validation, and owner declarations are unavailable. |

## Current environment and identity

- Rewritten source baseline: `5cace92adaf5b51e45b45a300a9b29c2a3fbb9ca` (`main` and `origin/main` before integration of this release-hardening change).
- Candidate branch: `chore/oss-release-readiness`; final integration commit is recorded by Git, not self-embedded in this document.
- macOS 27.0 (26A5378j), Apple silicon.
- Xcode 26.6 (17F113), Swift 6.3.3.
- Rust/Cargo 1.91.0.
- Product bundle ID `com.andrzej.ClipVault`, version `0.1.0`, build `1`, minimum macOS `15.0`, arm64.
- Current GitHub repository is private at `https://github.com/rsitech-ai/clip_vault`. The namespace is approved; visibility and publication timing remain gated.

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
| GitHub visibility/security/rules | BLOCKED:EXTERNAL | Repository is private; private vulnerability reporting, branch rules, and required checks are not enabled. |
| Hosted exact-head CI | PENDING | The post-rewrite run passed checkout, architecture, syntax, and public-contract gates, then exposed that the clean runner lacks the shell harness's `rg` prerequisite. The candidate now installs a pinned ripgrep version before shell tests; rerun required. |
| Public tag/release | PENDING | Publication is authorized after history, exact-head CI, repository safeguards, and binary notarization gates close. |

## Residual engineering risks

- Deduplication fingerprints remain plaintext local metadata and are not keyed; the privacy policy discloses this boundary. A keyed fingerprint migration can reduce guessing risk but is outside this release-hardening slice.
- The Keychain item uses `AfterFirstUnlockThisDeviceOnly`; changing accessibility semantics requires a separate migration and background-behavior decision.
- Historical audit reports are retained as historical records and may reference ephemeral artifacts that no longer exist. Current claims are limited to this dossier and reproducible commands.
- No macOS 15 clean-machine, Intel, Developer ID/notarized, or App Store Connect server proof exists. Intel is not declared supported.
- `/usr/sbin/screencapture` remains an App Review/API-surface risk.

## Next decision point

Rerun exact-head hosted CI, enable repository safeguards, and publish the source repository. Binary publication additionally requires a scoped notarization credential profile and clean-account runtime proof.
