# ClipVault 0.1.0 Release Status

Date: 2026-07-20 (Europe/Warsaw)

## Verdict

**HOLD — locally verified candidate, not approved for public open-source publication.**

The current source, release build, isolated runtime, E2E path, documentation links, dependency checks, and current-tree secret hygiene pass locally. Publication remains blocked by owner decisions and external repository state: no license or approved copyright holder, personal author email throughout Git history, no approved public repository owner/contact routes, private repository visibility, unavailable confidential reporting routes, hosted CI that has not run successfully on the exact candidate, and missing default-branch protection.

No formal Codex Security scan was run; the owner explicitly waived that workflow for this pass. The evidence below is ordinary source/provenance review plus local tools and does not claim formal scan coverage.

## Readiness labels

| Lane | Status | Meaning |
| --- | --- | --- |
| Source engineering candidate | LOCALLY VERIFIED | Local tests, release compilation, E2E, native UI smoke, documentation validation, and current-tree hygiene passed. |
| Public open-source repository | HOLD | License/copyright, history privacy, repository owner/visibility, contact routes, settings, and exact-head hosted CI remain unresolved. |
| Direct-download macOS binary | BLOCKED:EXTERNAL | No Developer ID identity, notarization, stapling, Gatekeeper, or clean-machine install proof. |
| Mac App Store package | BLOCKED:EXTERNAL | Local bundle structure passes, but distribution identities, expected Team ID, App Store Connect validation, and owner declarations are unavailable. |

## Current environment and identity

- Source baseline: `50e0e4d52168530204b828289c5196d77d08c8d0` (`main` and `origin/main` before this release-hardening change).
- Candidate branch: `chore/oss-release-readiness`; final integration commit is recorded by Git, not self-embedded in this document.
- macOS 27.0 (26A5378j), Apple silicon.
- Xcode 26.6 (17F113), Swift 6.3.3.
- Rust/Cargo 1.91.0.
- Product bundle ID `com.andrzej.ClipVault`, version `0.1.0`, build `1`, minimum macOS `15.0`, arm64.
- Current GitHub repository is private. Public owner/name, visibility, and publication timing are not approved by this dossier.

## Gate matrix

| Gate | Result | Evidence / next action |
| --- | --- | --- |
| Rust format, lint, tests | PASS | `cargo fmt --check`; Clippy with `-D warnings`; 4/4 Rust tests. |
| Swift tests | PASS | 178/178 tests in 17 suites via `./script/test.sh`. |
| Swift release build | PASS | `swift build -c release`. |
| Shell policy tests | PASS | Nine shell groups, including bounded-process descendant cleanup and E2E isolation checks. |
| Dependency advisories/policy | PASS | RustSec scanned the one-crate lockfile; cargo-deny advisories, bans, and sources passed. License policy intentionally remains blocked because this project has no approved license. |
| Current-tree secret hygiene | PASS | Gitleaks current-tree run and targeted identity/token checks found no confirmed live secret. Synthetic token fixtures are assembled from fragments. |
| E2E runtime | PASS | Per-run test bundle verified consent-enabled private-pasteboard capture, deduplication, encrypted persistence, relaunch recovery, bounded probes, and app-owned cleanup. |
| Native visual/accessibility smoke | PASS | Isolated `com.andrzej.ClipVault.ossqa` build exercised consent decline/retry, sidebar empty states, search/no-result recovery, AI workspace disabled states, and General/Capture/Access/AI/Surfaces/About settings. Production clipboard data was not captured. |
| Bundle contents/signature | PASS (local only) | Plist, privacy manifest, sandbox entitlements, nested dylib signature/load path, and ad-hoc signature validate locally. |
| Distribution signing/package | BLOCKED:EXTERNAL | `app_store_check.sh` exits 3: no application/installer distribution identity or expected Team ID. |
| License/copyright | BLOCKED:OWNER | Add an approved `LICENSE`, copyright holder, and matching Cargo metadata. CI intentionally fails without this. |
| Git-history privacy | BLOCKED:OWNER | All 122 historical commits expose a personal author email. Owner must consent or authorize a rewrite/orphan public snapshot. |
| Public namespace/contact | BLOCKED:OWNER | Approve repository owner/name plus support, privacy-policy, conduct, and vulnerability-reporting routes. |
| GitHub visibility/security/rules | BLOCKED:EXTERNAL | Repository is private; private vulnerability reporting, branch rules, and required checks are not enabled. |
| Hosted exact-head CI | BLOCKED:EXTERNAL | Existing Actions runs are blocked before execution by account billing/spending state; rerun on the final exact commit after resolution. |
| Public tag/release | BLOCKED:OWNER | Requires explicit publication approval after every preceding gate closes. |

## Residual engineering risks

- Deduplication fingerprints remain plaintext local metadata and are not keyed; the privacy policy discloses this boundary. A keyed fingerprint migration can reduce guessing risk but is outside this release-hardening slice.
- The Keychain item uses `AfterFirstUnlockThisDeviceOnly`; changing accessibility semantics requires a separate migration and background-behavior decision.
- Historical audit reports are retained as historical records and may reference ephemeral artifacts that no longer exist. Current claims are limited to this dossier and reproducible commands.
- No macOS 15 clean-machine, Intel, Developer ID/notarized, or App Store Connect server proof exists. Intel is not declared supported.
- `/usr/sbin/screencapture` remains an App Review/API-surface risk.

## Next decision point

The owner must choose the license/copyright holder, decide how to handle historical author email, approve the public repository owner/name and contact routes, and authorize any public visibility/settings/release changes. Only then can the candidate be integrated, pushed, rerun in hosted CI, tagged, and published.
