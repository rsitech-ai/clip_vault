# ClipVault Menu And Workspace Polish Audit

Date: 2026-07-09
Branch: `feat/andrzej_clipvault_menu_workspace_polish`
Installed app: `/Applications/ClipVault.app`

## Scope
- Improve the menu-bar popover list density and scrolling behavior.
- Keep clip rows on one line for faster scanning.
- Move the AI workspace out of the cramped right inspector and into the detail workspace below the selected clip.
- Fix Ask so customer-style questions work with selected/open clip context and have a deterministic local fallback.
- Preserve native macOS SwiftUI patterns and avoid a broad rewrite.

## Implementation Review
- `Sources/ClipVault/Views/MenuBarView.swift`
  - Increased bounded menu results from 12 to 18 because each row is now 36 px.
  - Replaced two-line menu rows with one-line rows: thumbnail, compact middle-truncated title, pin/copy count/timestamp metadata.
  - Added focus clamping when search/results change so keyboard navigation does not point at stale rows.
  - Kept the left preview pane for full context and tooltips for full row content.
- `Sources/ClipVault/Views/ClipListView.swift`
  - Replaced two-line center list rows with 36 px one-line rows and trailing metadata.
  - Kept AI selection on the thumbnail button and full preview in hover help.
- `Sources/ClipVault/Views/ContentView.swift`
  - Kept `NavigationSplitView`.
  - Moved detail and AI into a vertical split so AI is contextual under the selected clip.
  - Tuned split column minimums so a 900 px workspace does not clip the detail pane.
- `Sources/ClipVault/Views/AIActionPanel.swift`
  - Added inline vs inspector placement settings.
  - Reduced inline padding, adaptive action width, ask-field minimum, and shadow treatment so actions fit under detail.
  - Disabled Ask until a non-empty question is typed, with direct inline feedback for the empty-question case.
- `Sources/ClipVault/App/ClipVaultApp.swift`
  - Consolidated workspace presentation/recovery.
  - Limited recovery to keyable `ClipVault` windows to avoid AppKit status-window key warnings.
- `Sources/ClipVault/App/ClipVaultViewModel.swift`
  - Added `canAskQuestion` and early validation for empty Ask requests.
  - Moved provider execution off the main actor while keeping state updates on the main actor.
- `Sources/ClipVaultCore/Services/AIActionProvider.swift`
  - Added `LocalClipAIActionProvider` as a deterministic fallback for summarize, explain, email, todos, and Ask.
  - Expanded Foundation Models prompt context with title, preview, extracted text, notes, and tags.
  - Preserved evidence/cited clip IDs when answering local customer/contact/account-style questions.
- `Tests/ClipVaultCoreTests/AIActionProviderTests.swift`
  - Added regression coverage for local Ask answering customer questions from clip evidence.
  - Added regression coverage for empty Ask validation.
- `script/app_store_check.sh`
  - Replaced deprecated `codesign --entitlements :-` usage with `codesign --entitlements -`.

## Visual Evidence
The repo intentionally ignores audit screenshots, so these are local verification artifacts rather than PR-tracked files:
- Final installed workspace capture: `audits/2026-07-09-menu-workspace-polish/screenshots/ship-gate-clipvault-window.png`
- Final Ask result capture: `audits/2026-07-09-menu-workspace-polish/screenshots/ship-gate-ask-result-after-wait.png`
- Final menu popover capture: `audits/2026-07-09-menu-workspace-polish/screenshots/ship-gate-menu-popover.png`

## Verification
- `swift build -Xswiftc -warnings-as-errors` passed.
- `swift test --filter AIActionProviderTests` passed.
- `./script/test.sh` passed:
  - Rust search index: 2 tests.
  - Swift test run: 23 tests across 10 suites.
  - Includes Ask fallback/validation, sponsor URL fixed, and relative clip labels without seconds.
- `./script/e2e_smoke.sh` passed:
  - capture, dedupe, persistence, and restart recovery verified.
- `git diff --check` passed.
- `plutil -lint Resources/PrivacyInfo.xcprivacy Packaging/ClipVault.entitlements` passed.
- `swift package dump-package` passed.
- Static scans found no newly introduced TODO/FIXME, force-cast, `try!`, raw `print`, or secret material. Hits were limited to existing icon-generation/fallback setup `fatalError` paths and intentional sensitive-rule/docs strings.
- `/Applications/ClipVault.app` was replaced from rebuilt `dist/ClipVault.app`.
- `codesign --verify --deep --strict --verbose=2 /Applications/ClipVault.app` passed.
- Installed process verified running from `/Applications/ClipVault.app/Contents/MacOS/ClipVault`.
- Installed menu-bar popover shows compact one-line rows with visible scroll indicators.
- Inline Ask was verified in the installed app:
  - Empty question keeps Ask disabled.
  - Typed question enables Ask.
  - Ask action reaches `Thinking` and returns an answer in the inline workspace.
- App-authored error/fault logs were clean:
  - predicate: `subsystem == "com.andrzej.ClipVault" AND (messageType == error OR messageType == fault)`.
- `./script/app_store_check.sh` passed all local bundle checks and exited `3` only because this machine lacks a Developer ID Installer distribution identity. The signing, sandbox, privacy manifest, and app bundle checks passed.

## Residual Notes
- A broad process-level log predicate still shows OS framework launch/focus noise from Apple subsystems (`BaseBoard` task-name-port and `TextInputUI` ViewBridge cancellation). No ClipVault-authored error/fault entries were present after the final install.
- The status popover rows are not exposed as normal accessibility windows, so row-click UI automation is limited. Source review confirms row click and Enter both call `selectAndCopy(...)` and then close the captured menu window via `orderOut(nil)`. Pasteboard write behavior is covered by `PasteboardWriterTests`.
- App Store upload readiness remains externally blocked until a Developer ID Installer distribution identity is installed/configured.
- Existing historical untracked audit folders were left untouched.

## Official References Checked
- Apple Design Resources: https://developer.apple.com/design/resources/?cid=ADC-DM-c00493-M01051
- SwiftUI `MenuBarExtra`: https://developer.apple.com/documentation/swiftui/menubarextra
- SwiftUI `NavigationSplitView`: https://developer.apple.com/documentation/swiftui/navigationsplitview
- SwiftUI performance guidance: https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance
