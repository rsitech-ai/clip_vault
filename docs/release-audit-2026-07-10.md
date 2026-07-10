# ClipVault End-to-End Release Audit

## Scope

- Date: 2026-07-10
- Auditor: Codex
- App path: `/Users/s1kor/dev/andrzej/ClipVault/dist/ClipVault.app`
- Package: SwiftPM executable `ClipVault` with Rust `SearchIndexCore`
- Bundle ID: `com.andrzej.ClipVault`
- Platform and surfaces: macOS 15+, workspace window, menu bar extra, Settings, Dock menu, screenshot capture, local Foundation Models actions
- Readiness target: repo-ready and locally package-ready for a Mac App Store upload candidate
- Safety boundary: no destructive action was confirmed against the user's persisted clipboard library; App Store Connect upload and submission were not attempted

## Standards Checked

- Apple App Sandbox and user-selected file access: <https://developer.apple.com/documentation/security/app-sandbox>
- Apple Designing for macOS: <https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/>
- Apple disclosure controls, sidebars, layout, and materials: <https://developer.apple.com/design/human-interface-guidelines/disclosure-controls>, <https://developer.apple.com/design/human-interface-guidelines/sidebars>, <https://developer.apple.com/design/human-interface-guidelines/layout>, <https://developer.apple.com/design/human-interface-guidelines/materials>
- SwiftUI `NavigationSplitViewVisibility`: <https://developer.apple.com/documentation/swiftui/navigationsplitviewvisibility>
- SwiftData `ModelContext` save/rollback behavior: <https://developer.apple.com/documentation/swiftdata/modelcontext>
- SwiftUI `MenuBarExtra`: <https://developer.apple.com/documentation/swiftui/menubarextra>
- SwiftUI content minimum window sizing: <https://developer.apple.com/documentation/swiftui/windowresizability/contentminsize>
- AppKit `NSWindow.contentMinSize`: <https://developer.apple.com/documentation/appkit/nswindow/contentminsize>
- Privacy manifest placement and declarations: <https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk>
- App Review payments and tips: <https://developer.apple.com/app-store/review/guidelines/>
- Rust unsafe contracts: <https://doc.rust-lang.org/stable/reference/unsafety.html>

## Commands And Artifacts

| Check | Command / tool | Result | Evidence |
| --- | --- | --- | --- |
| Full tests | `./script/test.sh` | Passed | Rust 3/3; Swift 49/49 across 13 suites |
| Release warnings | `swift build -c release -Xswiftc -warnings-as-errors` | Passed | No compiler warnings or errors |
| Rust static gate | `cargo fmt --check`, Clippy with `-D warnings`, release tests | Passed | No formatting or lint findings; 3/3 tests |
| Memory safety | `swift test --sanitize=address` | Passed | Full Swift suite passed under ASan |
| Dependency audit | `cargo audit` | Passed | One local Rust crate; no advisory match; no external Swift dependency |
| Signed launch | `./script/build_and_run.sh --verify` | Passed | Verification now waits for the exact staged PID to report that capture has started |
| Live storage E2E | `./script/e2e_smoke.sh` | Passed | Two consecutive final capture, dedupe, copy-count, restart, and persistence runs passed |
| Release preflight | `./script/app_store_check.sh` | Passed | Bundle, plist, privacy manifest, entitlements, signing, and identity inventory clean |
| Package | `./script/package_app_store.sh` | Passed | `dist/AppStore/ClipVault-0.1.0-1.pkg`, 2,654,514 bytes |
| Package integrity | `pkgutil --check-signature`, `codesign --verify --deep --strict` | Passed | Apple Distribution app signature and 3rd Party Mac Developer Installer chain valid |
| Package digest | `shasum -a 256` | Passed | `3dfedf547372bb6c7013972aa9b7e350969fd46d2484d3707392ca056d3e03cc` |
| Runtime logs | PID-scoped unified log error/fault filters | Passed | Two normal post-migration launches produced no error/fault rows; Computer Use attachment diagnostics are documented separately below |
| Idle sampling | `sample`, `ps`, `footprint`, `vmmap` | Passed | Main thread waited in the AppKit event loop; steady footprint fell from 591 MB to about 92 MB |
| Diff hygiene | `git diff --check` | Passed | No whitespace errors; historical untracked audit directories remained untouched |

## Scenario Matrix

| Surface | Scenario | Expected | Actual | Status |
| --- | --- | --- | --- | --- |
| Startup | Rebuild, sign, launch, restart | One healthy staged process and restored workspace | Passed; bundle process restarted cleanly | Verified |
| Compact workspace | Launch at 900 x 572 | Sidebar hidden automatically; content/detail remain readable | Two-column workspace appeared with no clipped footer controls | Verified |
| Workspace copy semantics | Select, press Return, double-click | Single selection does not copy; Return and double-click do | Pasteboard SHA-256 stayed unchanged after selection, then changed on Return and double-click | Verified |
| AI disclosure | Select for AI, expand/collapse, run local action | Shelf expands intentionally and never steals idle space | 48-point shelf, automatic 0-to-1 expansion, manual collapse, and local Explain result all passed | Verified |
| Image preview migration | Open legacy image clips after storage migration | Thumbnails and detail preview remain visible | 58 image matches loaded; list thumbnails and the selected full detail preview rendered | Verified |
| Clipboard | Copy a unique token twice | One stored row with copy count at least two | Signed app probe returned one row and copy count two; survived restart | Verified |
| Search | Query a token absent from all clips, including recent/pinned clips | Zero results | Workspace reported `All Clips 0 visible` and `No matching clips` | Verified |
| Folders | Invalid, duplicate, protected, nested, move, delete, persistence | Both stores enforce identical rules and rollback failures | Focused parity/persistence tests passed; empty create remained disabled in the live sheet | Verified |
| AI | Open-clip fallback and local action | Consistent context and local result | Explain completed locally; header and empty state both reported `Using open clip` | Verified |
| Window | Relaunch/recover/drag below minimum | No clipped workspace controls | Window remained 900 x 572 after a smaller drag attempt; right-side controls stayed visible | Verified |
| Settings | Review release and privacy state | Truthful copy and no prohibited external payment CTA | About showed sandbox/privacy readiness and no sponsor link | Verified |
| Destructive actions | Open delete/cleanup confirmations | No mutation before explicit confirmation | Delete, bulk cleanup, and clear-unpinned flows opened and were cancelled; count remained stable | Verified cancel path |
| Menu bar extra | Keyboard preview lock and action dismissal | Locked preview remains tied to the chosen clip | State logic was fixed and reviewed; system status-window automation remained unavailable | Manual follow-up |

## Findings And Fixes

| Severity | Area | Finding | Fix | Re-verification |
| --- | --- | --- | --- | --- |
| High | Search correctness | Recency and pin boosts made lexical nonmatches appear as results | Require a positive lexical match before adding boosts | Regression test plus live `zzqxy` search returned zero |
| High | E2E architecture | Host SQLite reads blocked on the sandbox container and made the live gate fail or hang | Added an explicit read-only signed-app store probe and removed the obsolete host timeout/process stack | Live capture/dedupe/restart smoke exited zero |
| Medium | Store parity | In-memory built-in assignments differed from SwiftData; duplicate refresh left public payload fields stale | Centralized built-in assignments and refreshed preview/OCR/image/metadata fields | All-kind parity and duplicate-refresh tests passed |
| Medium | Folder integrity | Duplicate folder IDs could silently replace a SwiftData record and diverge from the in-memory store | Reject duplicate IDs before mutation in both stores | Cross-store test confirms original title and tree remain unchanged |
| Medium | Window recovery | AppKit `setFrame` recovery could recreate a window below the content minimum | Declared content-minimum resizing and clamped recovery frames to 900 x 520 | Live resize attempt remained at 900 x 572 |
| Medium | Menu preview | Space toggled only an indicator and did not retain the selected preview clip | Store the locked clip ID, use it for preview, and clear it when filtered out | Source/state-flow review; status-window UI requires manual follow-up |
| Medium | App Review | Buy Me a Coffee buttons were external developer-tip purchase calls to action in a worldwide binary | Removed the sponsor UI, URL, and obsolete test | Source scan and live About Settings show no sponsor control |
| Medium | Rust FFI | Public raw-pointer functions lacked explicit unsafe signatures and safety contracts | Marked FFI calls unsafe, documented invariants, and added round-trip ownership coverage | Rust format, Clippy `-D warnings`, and release tests passed |
| Polish | AI context | Empty result copy said zero clips while the panel was using the open clip | Reused the panel's canonical context text | Live panel reports `Using open clip` consistently |
| High | Memory/performance | Every list clip decrypted and retained the original image payload; a 208 MB library produced a 591 MB idle footprint | Added an encrypted lightweight list payload with a bounded 1024-pixel thumbnail, lazy legacy migration, and exact original-payload preservation | Thumbnail, legacy-migration, and byte-preservation tests pass; steady footprint is about 92 MB and image previews still render |
| Medium | Launch/E2E readiness | `--verify` accepted a PID before the SwiftUI task had started clipboard capture, racing the E2E pasteboard write | Publish a capture-ready PID after the service starts and wait for that exact staged PID in the run script | Marker matched the live PID; two consecutive signed E2E runs passed |
| Medium | Startup layout | Compact sidebar adaptation mutated split-view visibility during AppKit layout and could emit a layout-recursion warning | Defer width-class adaptation through an async SwiftUI task keyed by width class | Two clean normal launches produced no error/fault rows |

No blocker, high, or medium code-review finding remains open in the reviewed tree.

## Security, Privacy, And Performance Review

- Clipboard payloads remain local and encrypted at rest; sensitive token/private-key patterns are rejected before persistence.
- Lightweight list payloads are also AES-GCM encrypted; original image bytes remain in the original encrypted payload and are loaded only for copy/export.
- Logs contain lifecycle and recoverable error state, not raw clipboard content, OCR text, notes, file paths, or encryption material.
- The app is sandboxed and the packaged entitlement set is limited to the application identifier, team identifier, App Sandbox, and user-selected read-only file access.
- The Rust core has no third-party crate dependency; SwiftPM has no external package dependency.
- The diagnostic store probe accepts exactly one nonempty token, reports only an exact-match count and copy count, is read-only, and exits before the UI/capture service starts.
- Final process sampling found the main thread idle in the AppKit event loop. Normal PID-scoped launch logs were clean.
- Computer Use accessibility attachment emits AppKit menu/geometry diagnostics on both the pre-change and current build. Those rows begin only when the instrumentation attaches and are not present in normal launches; they are not represented as product-clean runtime evidence.

## Remaining External Or Manual Gates

- Create or confirm the App Store Connect record, final name/bundle/account choice, metadata, privacy answers, support/privacy URLs, screenshots, package upload, server-side validation, and App Review.
- Install the distribution package on a clean macOS user or clean machine and repeat the signed runtime smoke before submission.
- Manually complete the status-item `MenuBarExtra` dismissal/preview-lock matrix; the automation service could inspect the workspace but timed out against SystemUIServer/Control Center.
- If developer tips are added later, implement them through StoreKit/In-App Purchase or ship a storefront-compliant configuration; do not restore the worldwide external payment button.

## Final Readiness Label

- Label: **repo-ready and local Mac App Store package-ready; blocked: external/manual submission gates**
- Evidence: all current source, test, signed runtime, live persistence, log, entitlement, and package checks above pass.
- Not claimed: App Store Connect upload acceptance, clean-machine installation, App Review approval, or automated status-item interaction proof.
