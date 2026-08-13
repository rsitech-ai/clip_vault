# ClipVault 0.1.1 Release Status

Date: 2026-08-13 (Europe/Warsaw)

## Verdict

**SOURCE MERGED AND INSTALLED — downloadable publication is blocked:external.**

PR #21 passed hosted CI and merged to `main` at `ba1a034bbd385c01e704878e33656ea7a5a120a5`. The exact-main `0.1.1 (3)` Developer ID candidate builds, signs, launches from `/Applications`, switches across the installed 585-clip library, and passes the isolated capture, deduplication, encrypted persistence, and restart smoke on this Apple-silicon host. Public binary publication remains fail-closed because the `clipvault-notary` Keychain profile is absent; notarization, stapling, Gatekeeper, checksum publication, and clean-account proof have therefore not been claimed.

## Gate matrix

| Gate | Result |
| --- | --- |
| Rust format and Clippy with warnings denied | PASS |
| Rust tests | PASS — 4 tests |
| Swift tests | PASS — 209 tests in 23 suites |
| Swift production build with warnings denied | PASS |
| Shell and UI policy checks | PASS |
| Developer ID staged bundle `0.1.1 (3)` | PASS — bundle and nested library signatures verify |
| Isolated E2E capture and restart smoke | PASS |
| Pull request, hosted CI, review, merge | PASS — PR #21; exact-main CI run `31705300080` |
| Installed `/Applications` runtime | PASS — exact-main `0.1.1 (3)` Developer ID build |
| Direct-download notarization | BLOCKED:EXTERNAL — missing `clipvault-notary` profile |

No tag or GitHub Release asset may be created until the direct-download gate passes.
