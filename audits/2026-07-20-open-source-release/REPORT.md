# ClipVault Open-Source Release Audit

Date: 2026-07-20 (Europe/Warsaw)

## Outcome

**SOURCE RELEASE COMPLETE; DOWNLOADABLE BINARY BLOCKED:EXTERNAL.** The engineering candidate, owner/legal decisions, history-privacy rewrite, hosted CI, PR merge, public organization repository, private vulnerability reporting, and default-branch rules are verified. No formal Codex Security scan was run, per owner instruction.

## Scope and authority

- Reviewed repository contents, current Git state/history metadata, local build/runtime behavior, documentation, packaging, and read-only GitHub state.
- Modified source only in the isolated release-hardening worktree and performed explicitly authorized recoverable workspace cleanup.
- Transferred the repository to the approved `rsitech-ai` organization, applied the approved legal/contact identity, completed the no-reply history rewrite while private, merged reviewed PR #13, and made the repository public. No tag or binary has been published.

## Product and UX

- Isolated native smoke passed for consent decline/retry, collection empty states, search/no-result recovery, AI workspace expansion/disabled states, and all six Settings tabs.
- Clipboard capture was deliberately not enabled during visual QA, so production clipboard contents were never captured.
- Current privacy, local-AI, version, sandbox, and release-readiness UI copy matched inspected behavior.

## Reliability and testability

- Full harness: 10 shell groups, 4 Rust tests, and 178 Swift tests passed.
- Release-mode Rust/Swift compilation passed.
- Hosted post-rewrite CI exposed an undeclared ripgrep prerequisite on the clean macOS runner. CI now installs a pinned ripgrep version before the shell harness, contributor requirements document it, and exact-head arm64 run `29774529702` passed all 17 steps.
- The E2E harness initially exposed two defects: an unbounded store-probe subprocess and false launch verification through the `/tmp` symlink. Regression tests now cover descendant termination and canonical distribution paths.
- E2E state now uses a per-run bundle/Keychain/defaults/store namespace and app-owned store cleanup.

## Privacy, provenance, and supply chain

- Current-tree secret/identity hygiene passed, including Gitleaks and targeted patterns; no confirmed live secret was found.
- Rust has one local crate and no third-party dependency; Swift has no external package dependency.
- RustSec plus cargo-deny advisories/bans/sources passed.
- GitHub checkout is full-SHA pinned, workflow permissions are read-only, and credential persistence is disabled.
- Both retained private branches were rewritten and force-updated. The GitHub-generated merge commit was replaced before publication with an equivalent two-parent commit because GitHub inserted the personal Gmail address; every commit reachable from published `main` now uses only the approved GitHub no-reply email, and reviewed tree content is unchanged.
- The approved Apache-2.0 license and matching Rust package metadata are present in the candidate.

## Documentation and community health

- Added README, changelog, contribution guide, security policy, support scope, code of conduct, architecture, release process, issue forms, pull-request template, CODEOWNERS, Dependabot, editor settings, and attributes.
- Canonical organization, website, public support, confidential conduct, privacy, and vulnerability fallback routes are approved and documented.
- Current release evidence was refreshed; older audit files are retained as historical records and are not current release proof.

## Packaging and release operations

- Local app bundle, Info.plist, privacy manifest, sandbox entitlements, ad-hoc signature, nested dylib, and load path validate.
- `app_store_check.sh` exits 3 only for missing distribution application/installer identities and expected Team ID.
- Added a fail-closed direct-download packaging command covering Developer ID signing, hardened-runtime checks, notarization acceptance, stapling, Gatekeeper, final ZIP creation, and checksum generation.
- Developer ID Application signing with a private key, hardened runtime, and Apple timestamp passes. Real preflight exits 2 because no `clipvault-notary` Keychain profile exists. Direct-download notarization/runtime proof, App Store Connect validation, tag, and binary release remain unproven; hosted exact-head CI, visibility, confidential reporting, and branch rules pass.

## Approved owner decisions

1. Apache-2.0; copyright owner Rafal Sikora.
2. RSI Tech public maintenance at `https://rsitech.ai` with `info@rsitech.ai` for public/confidential contact.
3. Rewrite every retained commit to `24563931+s1korrrr@users.noreply.github.com` before publication. Completed and verified on both retained branches.
4. Continue through PR review/merge, public organization publication, and a verified downloadable release.

The repository is public at `rsitech-ai/clip_vault` with Apache-2.0 detected, the RSI Tech homepage configured, private vulnerability reporting enabled, and active `main` rules requiring PRs and the `verify` check. Obsolete merged worktrees and untracked historical audit artifacts were removed from the workspace; the dirty July 15 release lane and pre-public history remain preserved as verified recovery archives in Trash.

## Reproducible evidence

See `docs/release/0.1.0/TEST_EVIDENCE.md`, `SECURITY_STATUS.md`, `BLOCKERS.md`, and `RELEASE_MANIFEST.json`.
