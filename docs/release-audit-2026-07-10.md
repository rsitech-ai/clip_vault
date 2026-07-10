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
| Full tests | `./script/test.sh` | Passed | Rust 3/3; Swift 42/42 across 11 suites |
| Release warnings | `swift build -c release -Xswiftc -warnings-as-errors` | Passed | No compiler warnings or errors |
| Rust static gate | `cargo fmt --check`, Clippy with `-D warnings`, release tests | Passed | No formatting or lint findings; 3/3 tests |
| Memory safety | `swift test --sanitize=address` | Passed | Full Swift suite passed under ASan |
| Dependency audit | `cargo audit` | Passed | One local Rust crate; no advisory match; no external Swift dependency |
| Signed launch | `./script/build_and_run.sh --verify` | Passed | `dist/ClipVault.app` rebuilt, signed, launched, and remained responsive |
| Live storage E2E | `./script/e2e_smoke.sh` | Passed | Capture, dedupe, copy count, restart, and post-restart persistence verified by the signed app-owned probe |
| Release preflight | `./script/app_store_check.sh` | Passed | Bundle, plist, privacy manifest, entitlements, signing, and identity inventory clean |
| Package | `./script/package_app_store.sh` | Passed | `dist/AppStore/ClipVault-0.1.0-1.pkg`, 2,637,676 bytes |
| Package integrity | `pkgutil --check-signature`, `codesign --verify --deep --strict` | Passed | Apple Distribution app signature and 3rd Party Mac Developer Installer chain valid |
| Package digest | `shasum -a 256` | Passed | `436faff9cac2f0c356b86ee7b3837c9da682d457583b7c533725cf8336e15f99` |
| Runtime logs | Unified log error/fault filter for `com.andrzej.ClipVault` | Passed | No ClipVault-authored error or fault rows in the final 30-minute window |
| Idle sampling | `sample <pid> 2 1` and `ps` | Passed | Main thread blocked in the normal AppKit event loop; no spin or busy update loop |
| Diff hygiene | `git diff --check` | Passed | No whitespace errors; historical untracked audit directories remained untouched |

## Scenario Matrix

| Surface | Scenario | Expected | Actual | Status |
| --- | --- | --- | --- | --- |
| Startup | Rebuild, sign, launch, restart | One healthy staged process and restored workspace | Passed; bundle process restarted cleanly | Verified |
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

No blocker, high, or medium code-review finding remains open in the reviewed tree.

## Security, Privacy, And Performance Review

- Clipboard payloads remain local and encrypted at rest; sensitive token/private-key patterns are rejected before persistence.
- Logs contain lifecycle and recoverable error state, not raw clipboard content, OCR text, notes, file paths, or encryption material.
- The app is sandboxed and the packaged entitlement set is limited to the application identifier, team identifier, App Sandbox, and user-selected read-only file access.
- The Rust core has no third-party crate dependency; SwiftPM has no external package dependency.
- The diagnostic store probe accepts exactly one nonempty token, reports only an exact-match count and copy count, is read-only, and exits before the UI/capture service starts.
- Final process sampling found the main thread idle in the AppKit event loop and no ClipVault error/fault log entries.

## Remaining External Or Manual Gates

- Create or confirm the App Store Connect record, final name/bundle/account choice, metadata, privacy answers, support/privacy URLs, screenshots, package upload, server-side validation, and App Review.
- Install the distribution package on a clean macOS user or clean machine and repeat the signed runtime smoke before submission.
- Manually complete the status-item `MenuBarExtra` dismissal/preview-lock matrix; the automation service could inspect the workspace but timed out against SystemUIServer/Control Center.
- If developer tips are added later, implement them through StoreKit/In-App Purchase or ship a storefront-compliant configuration; do not restore the worldwide external payment button.

## Final Readiness Label

- Label: **repo-ready and local Mac App Store package-ready; blocked: external/manual submission gates**
- Evidence: all current source, test, signed runtime, live persistence, log, entitlement, and package checks above pass.
- Not claimed: App Store Connect upload acceptance, clean-machine installation, App Review approval, or automated status-item interaction proof.
