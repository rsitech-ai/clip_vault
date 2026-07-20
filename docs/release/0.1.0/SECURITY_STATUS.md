# ClipVault 0.1.0 Security Status

Date: 2026-07-20

Verdict: **ordinary review passed with documented residuals; formal security scan not run by owner request.**

## Verified in this pass

- No confirmed live credential, private key, certificate, provisioning profile, signing identity, Team ID, or personal filesystem path remains in the current tracked candidate.
- Gitleaks passed against the current tree. Synthetic OpenAI- and GitHub-shaped test tokens are assembled at runtime from fragments.
- The repository has no external Swift dependency and the Rust crate has no third-party dependency.
- RustSec advisory audit and cargo-deny advisories, bans, and source policies passed.
- GitHub Actions uses read-only permissions, a full-SHA checkout pin, `persist-credentials: false`, `pull_request` rather than `pull_request_target`, and workflow concurrency cancellation.
- Release-package validation rejects binaries containing the E2E compile marker.
- E2E bundle IDs are validated under `com.andrzej.ClipVault.e2e.*`; every run receives an independent bundle, Keychain, defaults, and sandbox-store namespace. Reset and cleanup operate only inside that namespace.
- The bounded subprocess helper terminates descendants as well as the direct process and has a regression test proving the descendant is gone.
- Clipboard capture requires explicit consent in production; stopping or revoking capture invalidates in-flight work.
- Clip payloads/details use AES-GCM with a Keychain-backed key; sensitive-value filtering happens before persistence and is documented as best effort.

## Publication blockers

- Historical author metadata exposes a personal email in all 122 commits. The owner approved rewriting retained history to the GitHub no-reply address; publication remains blocked until the rewrite is verified on every retained ref.
- GitHub private vulnerability reporting is not enabled yet. The approved confidential fallback is `info@rsitech.ai`.
- Hosted CI has not executed successfully on the exact candidate. The prior run executed and failed only at the intentionally missing-license gate, which is now resolved in the candidate.

## Residual risks

- Plaintext, unkeyed deduplication fingerprints can permit guessing of common clipboard values if an attacker already obtains the sandbox database. The privacy policy discloses plaintext fingerprints.
- Keychain accessibility is `AfterFirstUnlockThisDeviceOnly`; a stricter accessibility class would affect background/relaunch behavior and needs an explicit migration design.
- Upgraded historical databases/backups may retain pre-hardening plaintext remnants.
- `/usr/sbin/screencapture` is a fixed system binary but remains an external command surface.

No formal Codex Security finding, badge, or scan completion is claimed by this document.
