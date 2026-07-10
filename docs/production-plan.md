# Production Plan: ClipVault

## Product Brief

- Target user: developers, writers, and researchers who copy many fragments and need fast private retrieval.
- Primary job: capture clipboard items automatically, preserve useful context, and retrieve/copy them quickly from the menu bar or workspace.
- Core workflow: copy text/image/file content, search or browse captured clips, preview, annotate, pin, organize into collections, and copy a chosen clip back to the pasteboard.
- Business model: paid macOS app first; iCloud/iOS/team features later.
- Supported macOS versions: macOS 15+ in the current SwiftPM package and app bundle metadata.
- Offline behavior: fully local capture/search/storage; AI actions fall back when Foundation Models are unavailable.
- Data handled: clipboard text, OCR text, image preview data, file paths, URLs, notes, tags, folders, and app metadata.
- Privacy posture: local-first, encrypted payload storage, sensitive-item exclusion before persistence, no cloud AI enabled in MVP.
- V1 scope: menu bar plus workspace, durable clipboard capture, image OCR, search, notes/tags/title override, cleanup, pinning, AI fallback panel, App Store packaging path.
- Explicitly out of scope: iOS companion, iCloud sync, team pinboards, active BYO/cloud AI provider, and guaranteed App Review approval.

## Architecture

- Scene model: `WindowGroup`, `MenuBarExtra`, `Settings`, Dock tile/menu integration, and keyboard command for opening the workspace.
- Window roles: main adaptive workspace and menu bar popover/window.
- Layout model: sidebar, clip list, detail pane, and AI/action inspector; menu bar list with adjacent preview.
- State ownership: `ClipVaultViewModel` owns app state and delegates durable operations to services.
- Persistence: SwiftData records for clips/folders; encrypted payload blobs via Keychain-backed AES-GCM key.
- Services: pasteboard capture, pasteboard writeback, sensitive exclusion, Rust search/index core, Foundation Models provider boundary, Natural Language embedding boundary.
- Advanced capabilities: OCR through Vision; Foundation Models guarded by availability checks and fallback results.
- Folder/module structure: `App/`, `Views/`, `Models/`, `Services/`, `Tests/`, `rust/`, `script/`, `docs/`.

## Build And Run

- Project type: SwiftPM macOS app with Rust static library dependency.
- Build command: `swift build -c release`.
- Run command: `./script/build_and_run.sh`.
- `script/build_and_run.sh` status: stages `dist/ClipVault.app`, signs locally, launches, and supports `--verify`.
- Codex Run action status: configured in `.codex/environments/environment.toml`.

## Design System

- Native structures: SwiftUI split view, sidebar list, settings scene, context menus, toolbar commands, menu bar extra, and Dock contextual menu.
- Adaptive states: workspace switches detail/AI panel layout at narrow widths; menu bar list includes preview and keyboard flow.
- Visual style: system materials, semantic colors, compact operational density, rounded previews/cards only for framed content.
- Motion rules: short `.snappy` transitions for list/menu state changes and a low-frequency animated Dock pulse while capture is active; no long blocking animations.
- Accessibility requirements: icon buttons use labels where possible; keyboard menu flow supports arrows, Enter, Space, Delete, and P.
- Empty/loading/error/offline/permission states: empty list/detail states exist; AI unavailable state is surfaced; storage fallback now avoids crash and reports error.

## Test Strategy

- Unit tests: Rust normalization/search; Swift retention, sensitive exclusion, pasteboard writer, clip management, duplicate grouping, folders, notes/tags/title updates.
- Integration tests or mocks: named NSPasteboard writer tests and real-app smoke script for capture/restart persistence.
- UI/manual smoke: launch `dist/ClipVault.app`, capture text/image clips, hover/copy from menu bar, annotate screenshot, delete/cleanup, relaunch.
- Release smoke: `./script/app_store_check.sh` inspects bundle, plist, privacy manifest, entitlements, signing state, and certificate inventory.
- E2E database probes: every `sqlite3` process is owned by a repo-owned Perl parent with a two-second monotonic deadline and process-group cleanup; host container access timeouts exit `74` with an explicit permissions diagnostic instead of blocking the outer 20-second polling loop.
- Commands:
  - `./script/test.sh`
  - `swift build -c release`
  - `./script/build_and_run.sh --verify`
  - `./script/e2e_smoke.sh`
  - `./script/app_store_check.sh`
  - `git diff --check`

## Observability

- Logger subsystem: `com.andrzej.ClipVault`.
- Categories: `ViewModel` for lifecycle/action/recoverable errors.
- Key lifecycle/action events: bootstrap, capture, sensitive exclusion, copy-to-pasteboard, storage fallback, recoverable failures.
- Sensitive logging exclusions: logs do not include raw clipboard text, notes, OCR output, file paths, tokens, or encrypted payloads.

## App Store Readiness

- Bundle ID: currently `com.andrzej.ClipVault`; consider final brand/company bundle ID before first upload.
- Signing team: application distribution identity exists for `Apple Distribution: Rafal Sikora (2NY8A789TN)`.
- Sandbox/entitlements: App Sandbox enabled with user-selected read-only file entitlement.
- Privacy manifest: present in `Resources/PrivacyInfo.xcprivacy`.
- Privacy labels: should match local-only/no-tracking behavior unless future features change.
- Assets: app icon generated and bundled.
- Metadata: draft exists in `AppStore/metadata.md`.
- Review notes: state that clipboard processing is local, sensitive items are excluded before storage, and cloud AI is disabled in MVP.
- Local package identities: `Apple Distribution: Rafal Sikora (2NY8A789TN)` and `3rd Party Mac Developer Installer: Rafal Sikora (2NY8A789TN)` are both present; local package creation succeeds.
- Final implementation package: `dist/AppStore/ClipVault-0.1.0-1.pkg` was regenerated after the final source fixes; it is version `0.1.0` build `1`, 2,636,979 bytes, SHA-256 `d3f20f0dd510d466e20dfe8ccf35665a299a6c5175864782495f8e17c851e8bc`, and has a valid 3rd Party Mac Developer Installer chain.
- Remaining external gates: finalize the App Store name, bundle ID, company-account choice, metadata, privacy answers, and screenshots; create/confirm the App Store Connect record; upload the package; complete server-side validation and App Review. No upload was attempted and App Store Connect was not contacted in this review.
- Remaining manual gates: complete the MenuBarExtra dismissal/non-dismissal matrix, destructive workspace confirmation against controlled persisted data, result-text selection, compact splitter, light appearance, large-window, and clean-account package-install checks.

## Iteration Log

| Date | Gate | Change | Verification | Next blocker |
| --- | --- | --- | --- | --- |
| 2026-06-29 | Dynamic design and motion | Added live Dock tile integration with animated capture pulse, clip count badge, recent-kind color bars, and Dock menu actions for open, pause/resume capture, and copy recent clips. | `swift build -c release`, `./script/test.sh`, `./script/build_and_run.sh --verify`, `./script/e2e_smoke.sh`, `./script/app_store_check.sh`, `git diff --check` | Installer identity discovery and final App Store account/name decisions remained open at that gate. |
| 2026-06-29 | Production quality | Added non-crashing storage fallback, faster dedupe lookup, custom collection assignment, privacy-safe logging, and real E2E smoke. | `./script/test.sh`, `swift build -c release`, `./script/e2e_smoke.sh`, `./script/app_store_check.sh`, `git diff --check` | Correct installer identity discovery and complete final App Store account/name decisions. |
| 2026-07-10 | Menu, folders, and inline AI final verification | Reviewed `80db368..33dbf9b`; verified release build, E2E, staged runtime, AX controls, local Foundation Models responses, logs, idle behavior, and signing evidence. | `./script/test.sh` passed (Rust 2/2, Swift 32/32); `swift build -c release -Xswiftc -warnings-as-errors` passed; `./script/e2e_smoke.sh` exited 0; `./script/build_and_run.sh --verify` launched only `dist/ClipVault.app`; deep strict codesign passed. | Controller gate remained open for the incomplete MenuBarExtra dismissal matrix and intentional omission of destructive sidebar confirmation against persisted data. The installer classification from this gate was later found to be a policy-query error. |
| 2026-07-10 | Task 4 review remediation | `8e42fbd` fixes singular AI count grammar in every visible cited/selected count path; `7afed72` removes the approved design-spec EOF whitespace. | `swift build -c release -Xswiftc -warnings-as-errors` passed; `./script/test.sh` passed (Rust 2/2, Swift 32/32); `git diff --check` and `git diff --check 80db368..HEAD` are clean. | Manual MenuBarExtra/destructive-workspace/text-selection/splitter/light/large coverage and external App Store packaging decisions remain; no code defect from this review is known to remain. |
| 2026-07-10 | Whole-branch final review fixes | Corrected application/installer identity policies, made SwiftData folder changes rollback-safe, centralized create validation across both stores, added reopened-container regressions, made menu rows semantic buttons, added outcome hints, and removed dead AI placement metrics. | Identity shell test passed; `FolderTreeTests` 14/14; `./script/test.sh` Rust 2/2 and Swift 36/36; Release warnings-as-errors build passed; final `build_and_run.sh --verify` exited 0; final `app_store_check.sh` exited 0; strict codesign and package signature checks passed. | Final `e2e_smoke.sh` could not read the sandbox store from the automation host and was interrupted after blocking in `open(2)`; refresh the package from the final implementation head, then complete App Store Connect metadata/account/upload validation. |
| 2026-07-10 | Final-fix review closeout | Removed the obsolete Settings certificate blocker, made folder creation explicitly leaf-only in both stores, and bounded every E2E SQLite process with cleanup and a distinct host-access timeout. | Timeout shell test passed with successful and blocking fakes; `FolderTreeTests` 15/15; `./script/test.sh` Rust 2/2 and Swift 37/37; Release warnings-as-errors and `build_and_run.sh --verify` exited 0; stale Settings text is absent from source, staged executable, and packaged executable; E2E exited `74` in 4.71 seconds; `app_store_check.sh`, strict codesign, package signature/payload checks, and subsystem logs passed. | Complete the manual UI matrix and external App Store Connect/account/metadata/upload/server-review gates; no local certificate blocker remains. |

## Release Verification Evidence (2026-07-10)

### Scope and automated gates

- Reviewed the full branch diff from `80db368` to `33dbf9b`: 9 source/test files plus the approved implementation plan and design specification. No generated UI-kit assets or audit directories are part of the tracked diff; the pre-existing `audits/` directories remain untracked and unstaged.
- Source review found no added force unwraps, detached tasks, empty context menus, visible Email controls, or newly hidden lifecycle errors. Folder validation, persistence, protected-node policy, and custom collection ID behavior are exercised by the focused `FolderTreeTests` coverage.
- `./script/test.sh` passed: Rust 2/2 and Swift Testing 32/32 across 10 suites.
- `swift build -c release -Xswiftc -warnings-as-errors` passed with no warnings or errors.
- `./script/e2e_smoke.sh` exited 0 after capture, dedupe, persistence, and restart-recovery checks.
- `./script/build_and_run.sh --verify` rebuilt, signed, and launched the staged bundle. The only matching process was PID 92822, executing `/Users/s1kor/dev/andrzej/ClipVault/dist/ClipVault.app/Contents/MacOS/ClipVault`; no `/Applications/ClipVault.app` process supplied runtime evidence.

### Runtime and accessibility evidence

- The staged dark-appearance workspace exposed `Create a new folder` and `Create a new collection` as native AX buttons. Built-ins such as All Clips and Code had no management control, while custom Prompts exposed `Manage Prompts`; no observed folder footer or AI action was `AXUnknown`.
- Opening and cancelling the Folder action showed an accessible `New Folder` sheet, name field, Location menu, Cancel button, and disabled Create button without changing persisted workspace data. Automated create/rename/remove-confirm coverage remains the focused store-test evidence because destructive GUI actions were not applied to the existing user workspace.
- Foundation Models ran locally in the staged app: Explain completed using the open-clip fallback (1 cited clip); Summarize completed for two selected clips (2 cited clips); Todos completed with the explicit no-tasks result for a substantive local clip; and Ask answered `What are the two selected clips used for?` with 2 cited clips. No cloud provider or external transmission was enabled.
- The result scroll bar changed from AX value `0` to `1` after a real downward scroll. Compact action controls reported AX buttons with labels and contextual hover help for Summarize, Explain, Todos, and Ask. The pane remained visible at the available 900 x 572 display size.
- Canonical screenshots: `/tmp/clipvault-workspace-folders-final.png` (SHA-256 `b42d17e3a0f12b1b6ef3326111fa36381012b0de0c22cb9ffc77839e0b2ec0be`) and `/tmp/clipvault-ai-result-final.png` (SHA-256 `4e8b90258a768009f5c366f86be12c756a9e308d9e69e3a7f4ec51427aa9eb8b`). The AI image is a PNG conversion of the existing clean full-window Ask capture `/tmp/clipvault-task-3-after-ask-full.png`; it replaces the dimmed/malformed prior evidence and is not claimed as a new interaction on the fix head. No `/tmp/clipvault-menu-final.png` was created because the status-item menu could not be opened or inspected truthfully.

### Limits, logs, and release state

- MenuBarExtra controller evidence is incomplete: the staged app exposes the regular workspace window but not its status-item window to its own accessibility tree. Direct SystemUIServer inspection timed out; ControlCenter and an attempted splitter drag closed the Computer Use native pipe. Therefore the dismissing/non-dismissing menu matrix, fresh compact splitter stop, text-selection gesture, light appearance, and large-window appearance are not claimed as fresh runtime proof. The only available desktop work area was 900 x 572.
- `/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.andrzej.ClipVault" AND (messageType == error OR messageType == fault)'` returned no ClipVault-authored errors or faults. The broader process scan matched system diagnostics from SkyLight, FrontBoard, XCTest registration, BoardServices, Spotlight, LaunchServices, and Foundation Models language defaulting; these are system-framework messages, not ClipVault subsystem failures.
- After more than five minutes of staged runtime, PID 92822 sampled at `0.1%` CPU and `207344 KB` RSS, with no observed update loop. `codesign --verify --deep --strict --verbose=2 dist/ClipVault.app` passed.
- The old `./script/app_store_check.sh` result at this verification head exited `3` because it incorrectly queried the `codesigning` policy for installer identities. The whole-branch fix supersedes that classification: the corrected script queries `basic`, finds the installed 3rd Party Mac Developer Installer identity, and exits `0`.
- Repo state at this historical head remained limited by the incomplete MenuBarExtra/sidebar runtime matrix. Current external gates are App Store metadata, account, upload, and server-side validation, not a missing local installer identity.

## Task 4 Review Remediation (2026-07-10)

- `33dbf9b` remains the broad source and staged-runtime verification head. The earlier build, E2E, launch, AX, screenshot, log, idle, and signing evidence is retained as evidence for that head.
- `7afed72` (`Fix design spec diff hygiene`) removed the final blank line at EOF from the approved design specification. Fresh `git diff --check` and `git diff --check 80db368..HEAD` are clean. This explicitly supersedes the obsolete Task 4 report conclusion that branch diff hygiene was non-clean because of that EOF whitespace.
- `8e42fbd` (`Fix AI clip count grammar`) changes the three visible cited/selected count paths in `AIActionPanel.swift` to use one local formatter: `1 clip cited` and `1 clip selected`; zero and plural counts use `clips`. Fresh source-only evidence: `swift build -c release -Xswiftc -warnings-as-errors` completed with no warnings or errors, and `./script/test.sh` passed Rust 2/2 and Swift 32/32.
- The grammar-only change did not rerun the GUI/E2E matrix. The broad staged-runtime checks remain the recorded `33dbf9b` evidence; no broader runtime result is claimed for `8e42fbd`.

### Current Review State

- **Actual code defects:** The singular grammar defect is fixed. No known code defect from this review remains.
- **Manual verification limits:** Fresh proof is still absent for the MenuBarExtra dismissal/non-dismissal matrix, destructive GUI completion against the persisted workspace, result-text selection, compact-splitter stop, and light-appearance and large-window states.
- **Staged-app state:** The staged bundle was locally verified as Apple Development-signed. An Apple Distribution application identity is present; this is retained staged-app/signing evidence from the `33dbf9b` verification head, not a newly rerun runtime check.
- **External blockers:** Final App Store metadata, name/bundle-ID, company-account, upload, and server-side validation remain outside this review. There is no current missing-installer-identity blocker.

## Whole-Branch Final Review Fixes (2026-07-10)

- Implementation commits: `c257711` (identity discovery), `07cdffa` (storage validation and atomicity), and `713f258` (menu/workspace accessibility and AI placement cleanup).
- The corrected final-head `./script/app_store_check.sh` exited `0`, found both distribution identities, and reported that local upload prerequisites are present. `codesign --verify --deep --strict --verbose=2 dist/ClipVault.app` passed.
- `./script/package_app_store.sh` completed locally before the later storage/UI commits and created `dist/AppStore/ClipVault-0.1.0-1.pkg`; `pkgutil --check-signature` still validates its 3rd Party Mac Developer Installer certificate chain. Because the user stopped further broad work, the package was not regenerated from `713f258`; no upload or App Store Connect request was made.
- The final focused identity test passed, `FolderTreeTests` passed 14/14, `./script/test.sh` passed Rust 2/2 plus Swift 36/36, and `swift build -c release -Xswiftc -warnings-as-errors` passed.
- `./script/e2e_smoke.sh` did not complete on the final pass. The shell could stat the sandbox SwiftData store but any direct read blocked in `open(2)`, so the attempt was interrupted with exit `130` after more than five minutes. The new reopened-container SwiftData tests provide the storage regression evidence; the live sandbox-store E2E remains a host-access verification gap.
- Static source inspection confirmed `MenuClipRow` is a plain-styled `Button` with no row-level `onTapGesture`, and outcome hints exist for pause/resume and sidebar management. A final status-window AX role was not available to inspect, so no runtime `AXButton` claim is added for the menu row.
- `/usr/bin/log show --last 15m --style compact --predicate 'subsystem == "com.andrzej.ClipVault" AND (messageType == error OR messageType == fault)'` returned only the header and no ClipVault-authored errors or faults.

## Final-Fix Review Closeout (2026-07-10)

- `SettingsView` now gives generic App Store delivery guidance. The stale machine-specific installer-certificate sentence is absent from source, `dist/ClipVault.app/Contents/MacOS/ClipVault`, and the packaged executable.
- `WorkspaceFolderCreateValidator` rejects non-leaf create input with `FolderStoreError.nonLeafCreate` before either store mutates state. The same parity test passes against `InMemoryClipStore` and `SwiftDataClipStore`; default-tree seeding remains a separate atomic path.
- `script/e2e_smoke.sh` routes all five SQLite probes through a repo-owned Perl parent that forks and owns the command process group, inherits stdout/stderr directly, forwards HUP/INT/TERM, and uses monotonic deadline/grace checks before TERM/KILL cleanup. Infrastructure failures use status `125`; only the helper deadline uses `124`.
- The focused timeout suite passed 20/20 serial iterations in `205.57s`. Every iteration covered 25 immediate successes, a `0.70s` delayed success bounded between `0.65s` and `1.20s`, ordinary exits `37`/`124`/`143`, stdout/stderr, sourced trap/function hygiene, invalid `TMPDIR`, three infrastructure paths, TERM-resistant deadline/grace/group cleanup, SQLite `124` to `74` mapping, and external HUP/INT/TERM statuses `129`/`130`/`143` with no recorded survivors or replay errors.
- Fresh full verification passed: `./script/test.sh` exited `0` in `11.28s` with Rust 2/2 and Swift 37/37; `swift build -c release -Xswiftc -warnings-as-errors` exited `0` in `12.18s`. The live E2E remains a host-access gap: it exited `74` in `15.53s` including rebuild/signing after the first two-second sandbox-store probe reported `Host access timeout`; capture/dedupe/restart success is not claimed.
- `./script/package_app_store.sh` regenerated `dist/AppStore/ClipVault-0.1.0-1.pkg` after the final source fixes. `pkgutil --check-signature` validates the 3rd Party Mac Developer Installer chain; the payload contains the app executable, `Info.plist`, `PrivacyInfo.xcprivacy`, and `libsearch_index_core.dylib`; the packaged app passes deep strict codesign.
- `./script/app_store_check.sh` exits `0` with both application and installer distribution identities present. `/usr/bin/log` reports no ClipVault subsystem error/fault rows in the last 15 minutes. Current gates are the manual UI/package-install matrix and external App Store Connect/account/metadata/upload/server-review work; no upload or App Store Connect request was made.
