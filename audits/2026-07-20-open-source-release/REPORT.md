# ClipVault Open-Source Release Audit

Date: 2026-07-20 (Europe/Warsaw)

## Outcome

**HOLD for public publication.** The engineering candidate is locally verified, but owner/legal and external GitHub gates remain open. No formal Codex Security scan was run, per owner instruction.

## Scope and authority

- Reviewed repository contents, current Git state/history metadata, local build/runtime behavior, documentation, packaging, and read-only GitHub state.
- Modified only the isolated release-hardening worktree.
- Did not change repository visibility, transfer/rename the repository, rewrite history, select a license, create a tag/release, submit to Apple, or publish externally.

## Product and UX

- Isolated native smoke passed for consent decline/retry, collection empty states, search/no-result recovery, AI workspace expansion/disabled states, and all six Settings tabs.
- Clipboard capture was deliberately not enabled during visual QA, so production clipboard contents were never captured.
- Current privacy, local-AI, version, sandbox, and release-readiness UI copy matched inspected behavior.

## Reliability and testability

- Full harness: 9 shell groups, 4 Rust tests, and 178 Swift tests passed.
- Release-mode Rust/Swift compilation passed.
- The E2E harness initially exposed two defects: an unbounded store-probe subprocess and false launch verification through the `/tmp` symlink. Regression tests now cover descendant termination and canonical distribution paths.
- E2E state now uses a per-run bundle/Keychain/defaults/store namespace and app-owned store cleanup.

## Privacy, provenance, and supply chain

- Current-tree secret/identity hygiene passed, including Gitleaks and targeted patterns; no confirmed live secret was found.
- Rust has one local crate and no third-party dependency; Swift has no external package dependency.
- RustSec plus cargo-deny advisories/bans/sources passed.
- GitHub checkout is full-SHA pinned, workflow permissions are read-only, and credential persistence is disabled.
- Historical author metadata still exposes a personal email in all 122 commits. This remains an owner decision before publication.
- No project license exists in current or reachable history. CI intentionally fails until one is approved.

## Documentation and community health

- Added README, changelog, contribution guide, security policy, support scope, code of conduct, architecture, release process, issue forms, pull-request template, CODEOWNERS, Dependabot, editor settings, and attributes.
- Removed unapproved public contact/canonical URLs. Confidential conduct and vulnerability routes remain explicit launch blockers.
- Current release evidence was refreshed; older audit files are retained as historical records and are not current release proof.

## Packaging and release operations

- Local app bundle, Info.plist, privacy manifest, sandbox entitlements, ad-hoc signature, nested dylib, and load path validate.
- `app_store_check.sh` exits 3 only for missing distribution application/installer identities and expected Team ID.
- Direct-download signing/notarization, App Store Connect validation, hosted exact-head CI, branch rules, visibility, tag, and release remain unproven or unauthorized.

## Required owner decisions

1. License and copyright holder.
2. Publish historical personal author email, rewrite history, or create an orphan/squashed public-source history.
3. Final public repository owner/name and visibility.
4. Canonical support/privacy URLs, confidential conduct route, and private vulnerability-reporting route.
5. Authorization for public tag/release after hosted CI and repository settings pass.

## Reproducible evidence

See `docs/release/0.1.0/TEST_EVIDENCE.md`, `SECURITY_STATUS.md`, `BLOCKERS.md`, and `RELEASE_MANIFEST.json`.
