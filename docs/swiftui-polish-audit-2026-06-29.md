# SwiftUI Polish Audit Report: ClipVault

## Scope

- Date: 2026-06-29
- Auditor: Codex
- Platform: macOS
- Project: `/Users/s1kor/dev/andrzej/ClipVault`
- Scheme/target: SwiftPM executable product `ClipVault`
- Devices/simulators: local macOS desktop app bundle at `dist/ClipVault.app`
- Configuration: Debug app bundle launch plus Release SwiftPM build
- Readiness target: local polish and App Store preparation readiness

Official Apple references refreshed for this audit:

- SwiftUI performance: https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
- App responsiveness: https://developer.apple.com/documentation/xcode/improving-app-responsiveness
- UI responsiveness and animation hitches: https://developer.apple.com/documentation/xcode/understanding-user-interface-responsiveness
- XCTest: https://developer.apple.com/documentation/xctest

## Commands And Evidence

| Check | Command or Tool | Result | Evidence |
| --- | --- | --- | --- |
| Project shape | `find . -maxdepth 3 -name Package.swift ...` | SwiftPM-only macOS app | `Package.swift` |
| Full tests | `./script/test.sh` | Passed: Rust tests plus 18 Swift tests in 8 suites | `/tmp/clipvault-test-audit.log` |
| Release build | `swift build -c release` | Passed | `/tmp/clipvault-release-build-audit.log` |
| Launch | `./script/build_and_run.sh --verify` | Passed; app signed with Apple Development identity | `/tmp/clipvault-launch-audit.log` |
| UI smoke | System Events + screenshot | Workspace visible at `pos=306,222`, `size=900x572` | `/tmp/clipvault-polish-audit-workspace.png` |
| E2E runtime smoke | `./script/e2e_smoke.sh` | Passed: capture, dedupe, persistence, restart recovery | `/tmp/clipvault-e2e-audit.log` |
| Logs | `/usr/bin/log show ... process == "ClipVault"` | No ClipVault subsystem errors; only generic FrontBoard debug lines | terminal output |
| Performance | Release build timing, E2E timing, idle process sample | Release build passed; E2E smoke completed; idle sample around 177 MB RSS and low CPU after recent launch | `ps -o pid,%cpu,rss,etime,command` |
| Signing/readiness | `./script/app_store_check.sh` | Local bundle checks passed; exits 3 for missing installer identity | terminal output |
| Package path | `./script/package_app_store.sh` | Fails cleanly with missing installer identity | terminal output |
| Diff hygiene | `git diff --check` | Passed | terminal output |

## Feature Matrix

| Workflow / Feature | State Tested | Status | Notes |
| --- | --- | --- | --- |
| Clipboard text capture | real pasteboard via E2E smoke | verified | Stored in sandbox SwiftData store. |
| Duplicate grouping | repeated same pasteboard content | verified | E2E requires one row with `copyCount >= 2`. |
| Restart persistence | kill/relaunch app bundle | verified | E2E verifies stored row after restart. |
| URL capture | named pasteboard unit test | verified | Plain URL string now preserves `.url` kind and host metadata. |
| RTF capture | named pasteboard unit test | verified | Rich text now wins before plain string fallback. |
| File URL capture | named pasteboard unit test | verified | Metadata now stores reversible paths. |
| Image writeback | named pasteboard unit test | verified | Image payload writes TIFF data. |
| Text/code writeback | named pasteboard unit test | verified | Text payload writes string content. |
| Sensitive exclusion | unit tests | verified | Private keys, API tokens rejected; useful snippets retained. |
| Retention | unit tests | verified | Ordinary expiry and pinned persistence covered. |
| Folder tree | unit tests | verified | Nested folders and persisted folders covered. |
| Custom collection assignment | unit test | verified | Selected clips can be assigned without duplicate IDs. |
| Search ranking | Rust tests | verified | Normalization and lexical scoring covered. |
| Menu bar list/copy | code path + pasteboard writer tests | partially verified | Direct click path is implemented; full menu-extra UI automation was not available. |
| Workspace window | System Events + screenshot | verified | Workspace visible and not offscreen during audit. |
| AI actions | static + fallback review | partially verified | Availability/fallback boundary exists; real Foundation Models generation not exercised. |
| App Store package | script check | blocked | Missing Mac installer distribution certificate. |

## Visual And Animation Review

- Layout: workspace screenshot shows visible three-column app surface with sidebar, list, detail/AI area; no obvious text overlap at the audited window size.
- Light/Dark: dark appearance reviewed through screenshot. Light mode was not separately captured in this pass.
- Dynamic Type: macOS text uses system font styles, but there is no dedicated large-text screenshot pass.
- Reduce Motion: animations are narrow (`.snappy` on list/menu state) but no Reduce Motion runtime toggle was exercised.
- Animation smoothness: no profiler-backed hitch claim; code review found no broad full-screen animation except list identity changes and menu hover state.
- Interaction feedback: row hover/selection, copy, pin, delete, and context menus are implemented.
- Screenshot: `/tmp/clipvault-polish-audit-workspace.png`.

## Performance Review

- Reproduction path: copy text twice, wait for capture, relaunch, verify persistence.
- Baseline: `./script/e2e_smoke.sh` passed in a real `.app` bundle.
- Finding: live image/OCR payload normalization previously ran synchronously inside the main-actor pasteboard polling path.
- Fix: pasteboard access now snapshots data on the main actor, then payload normalization/OCR runs in a utility detached task before returning to the main actor.
- After: tests and E2E smoke pass after the refactor.
- Remaining risk: OCR accuracy and latency for very large images should still be profiled with Instruments before claiming best-in-class screenshot performance.

## Issues

| Severity | Area | Finding | Evidence | Fix / Next Action |
| --- | --- | --- | --- | --- |
| high | Capture performance | OCR ran on the main-actor polling path. | Code review of `ClipboardCaptureService.poll()`. | Fixed by snapshotting pasteboard data and doing payload/OCR work off-main. |
| medium | Capture correctness | URL/RTF pasteboards could fall through as plain text before richer types were parsed. | New capture tests initially failed. | Fixed precedence and host metadata; tests now pass. |
| medium | File pasteback fidelity | File payload metadata did not preserve reversible paths. | Code review and new file capture test. | Fixed by storing `paths` metadata during capture. |
| medium | Release packaging | Mac App Store package cannot be created yet. | `package_app_store_exit=2`. | Install `Mac Installer Distribution` / `3rd Party Mac Developer Installer` certificate. |
| polish | Visual QA coverage | Light mode, Reduce Motion, and large text were not manually screenshotted. | Audit scope limitation. | Do a final manual HIG/accessibility pass before upload. |
| polish | Menu extra UI automation | Status bar hover/click flow was not fully automated. | macOS menu extra UI automation limitation in this pass. | Manual smoke: hover preview, Enter/click copy, Delete remove, P pin. |

## Final Readiness Label

- Label: **Polish-ready locally; blocked for App Store upload**.
- Why: build, tests, release build, real app launch, durable capture/dedupe/restart smoke, signing inspection, and log review are clean after fixes.
- Remaining blockers:
  - install Mac installer distribution certificate;
  - decide final app name and bundle ID before first App Store upload;
  - complete manual menu-bar visual smoke and accessibility pass;
  - fill final App Store metadata/privacy answers/screenshots.
- Next verification step: after installing installer certificate, run `./script/package_app_store.sh`, install/test the signed package, then repeat `./script/e2e_smoke.sh` against the distribution-signed build.
