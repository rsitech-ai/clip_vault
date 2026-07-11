# Test Evidence

Date: 2026-07-11. Worktree: `/private/tmp/ClipVault-agent-sota-lab`.

| Check | Fresh result |
| --- | --- |
| `./script/test.sh` | PASS: shell suite; Rust 3/3; Swift 74/74 in 15 suites |
| `swift build -c release -Xswiftc -warnings-as-errors` | PASS: no warnings/errors |
| `swift test --sanitize=address` | PASS: 74/74 tests; no sanitizer failure |
| `cargo fmt --check` | PASS |
| `cargo clippy --all-targets -- -D warnings` | PASS |
| `cargo audit --file rust/SearchIndexCore/Cargo.lock` | PASS: no vulnerable dependency; one local crate |
| `./script/build_and_run.sh --verify` | PASS: exact staged PID published capture readiness and caller preference restored |
| `./script/e2e_smoke.sh` | PASS after final feature/runtime fixes: capture, dedupe, copy count, persistence, exact-process restart recovery, and cleanup |
| Native first-launch QA | PASS: Not Now leaves capture off; Start Capture reopens disclosure; acceptance changes toolbar to Pause Capture |
| Native list/search/move QA | PASS: real-keystroke one-result and zero-result search, recovery, keyboard Down selection, checked move destination, human collection title, and exact single-drag semantics |
| Native Settings/screenshot QA | PASS: consent/privacy controls exposed; `/usr/sbin/screencapture -i -c` launched as an exact app child and was cancelled; Settings survived repeated lifecycle cycles |
| Normal launch log scan | PASS: fresh PID had no warning/error/fault or `operation_failed` entry |
| `ps` and `vmmap` after five Settings cycles | PASS: idle CPU 0.2%; physical footprint 90.3 MB, 92.5 MB peak |
| `leaks --diffFrom` around five Settings cycles | PASS with framework note: 928 bytes across AppKit `NSAccessibilityCustomAction`/`NSArray`; no app-owned retaining path |
| App Store screenshots | PASS: two sanitized actual-product JPEGs visually inspected at 1280x800 |
| Local package validator | PASS: strict signatures, hardened runtime, entitlements, arm64, contained load paths, privacy manifest, matching dSYM |
| GitHub Actions PR #9 | BLOCKED before runner assignment: GitHub annotation reports failed account payments or an insufficient Actions spending limit; no workflow step executed. The configured `macos-26` label is listed in GitHub's current [hosted-runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). |

Package evidence: source commit `d11b7f96467d65cabb37e63a66545b9780595aac`; package SHA-256 `264b949215d02a07cc35211eff956873b9f120e85ff35a4834a3440ebede5d0d`; binary/dSYM UUID `D257D9A6-523D-313C-9370-3192F0B5FEED`.

Devices/runtimes: macOS 26.3 on Apple silicon. Paired iPhone 15 and Apple Watch were inventoried but are irrelevant because no iOS/watch target exists. macOS 15 and macOS 27 runtimes were unavailable. No clean secondary macOS user/machine was used.

Accessibility checks covered disclosure/button labels, toolbar labels, list selection state, detail controls, search, move menus, drop-target help, and Settings. Dark appearance was observed. Real keyboard input and move-command selection were exercised, and selection-following scroll is implemented. Light appearance, increased contrast, Reduce Motion, and full SystemUIServer status-item coverage remain open because changing host accessibility/appearance settings was not authorized in this pass.
