# ClipVault 0.1.1 Test Evidence

Date: 2026-08-13. Evidence was captured from `feat/andrzej_adaptive_clip_previews` before PR integration.

| Check | Fresh result |
| --- | --- |
| `cargo fmt --check` | PASS |
| `cargo clippy --all-targets --all-features -- -D warnings` | PASS |
| `./script/test.sh` | PASS — shell policies, 4 Rust tests, 209 Swift tests in 23 suites |
| `swift build -c release -Xswiftc -warnings-as-errors` | PASS |
| `LOCAL_SIGNING_IDENTITY='<installed Developer ID Application identity>' ./script/build_and_run.sh --verify` | PASS — version `0.1.1`, build `3`, valid Developer ID signature |
| `./script/e2e_smoke.sh` | PASS — isolated capture, deduplication, persistence, and restart recovery |
| `xcrun notarytool history --keychain-profile clipvault-notary` | Expected BLOCKED:EXTERNAL — no Keychain password item exists for the profile |

## Performance and motion evidence

- A 585-clip projection test proves stable ordering, indexed selection lookup, and no projection generation change when selection-independent inputs are unchanged.
- Calendar-day and changed-clip tests prove the cache still refreshes when relative labels or clip content change.
- The UI policy test requires the shared `0.98` scale, 120 ms pointer gesture, Reduce Motion handling, and absence from clip rows.
- The interaction is transform-only and interruptible. Keyboard navigation and activation do not trigger the pointer animation.

## Environment limits

- macOS 27.0 beta (26A5378j), Xcode 26.6 (17F113), Apple silicon.
- No notarized artifact, clean-account Gatekeeper proof, Intel proof, or App Store Connect server proof exists.
