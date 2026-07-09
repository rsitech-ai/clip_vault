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
- Known blockers: Mac installer distribution certificate is still missing; final App Store name/bundle ID/company account decision is still open.

## Iteration Log

| Date | Gate | Change | Verification | Next blocker |
| --- | --- | --- | --- | --- |
| 2026-06-29 | Dynamic design and motion | Added live Dock tile integration with animated capture pulse, clip count badge, recent-kind color bars, and Dock menu actions for open, pause/resume capture, and copy recent clips. | `swift build -c release`, `./script/test.sh`, `./script/build_and_run.sh --verify`, `./script/e2e_smoke.sh`, `./script/app_store_check.sh`, `git diff --check` | Installer distribution certificate still required for upload-ready App Store package. |
| 2026-06-29 | Production quality | Added non-crashing storage fallback, faster dedupe lookup, custom collection assignment, privacy-safe logging, and real E2E smoke. | `./script/test.sh`, `swift build -c release`, `./script/e2e_smoke.sh`, `./script/app_store_check.sh`, `git diff --check` | Install Mac installer distribution certificate and complete final App Store account/name decisions. |
| 2026-07-10 | Menu, folders, and inline AI final verification | Reviewed `80db368..33dbf9b`; verified release build, E2E, staged runtime, AX controls, local Foundation Models responses, logs, idle behavior, and signing evidence. | `./script/test.sh` passed (Rust 2/2, Swift 32/32); `swift build -c release -Xswiftc -warnings-as-errors` passed; `./script/e2e_smoke.sh` exited 0; `./script/build_and_run.sh --verify` launched only `dist/ClipVault.app`; deep strict codesign passed. | Controller gate remains open for the incomplete MenuBarExtra dismissal matrix and intentional omission of destructive sidebar confirmation against persisted data. Installer distribution identity remains a separate external upload blocker. |
| 2026-07-10 | Task 4 review remediation | `8e42fbd` fixes singular AI count grammar in every visible cited/selected count path; `7afed72` removes the approved design-spec EOF whitespace. | `swift build -c release -Xswiftc -warnings-as-errors` passed; `./script/test.sh` passed (Rust 2/2, Swift 32/32); `git diff --check` and `git diff --check 80db368..HEAD` are clean. | Manual MenuBarExtra/destructive-workspace/text-selection/splitter/light/large coverage and external App Store packaging decisions remain; no code defect from this review is known to remain. |

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
- Canonical fresh screenshots: `/tmp/clipvault-workspace-folders-final.png` (SHA-256 `b42d17e3a0f12b1b6ef3326111fa36381012b0de0c22cb9ffc77839e0b2ec0be`) and `/tmp/clipvault-ai-result-final.png` (SHA-256 `aa00265cbbb9064836e5017428fd5f8af2e0362e2983510093cac2d00b04982a`). No `/tmp/clipvault-menu-final.png` was created because the status-item menu could not be opened or inspected truthfully.

### Limits, logs, and release state

- MenuBarExtra controller evidence is incomplete: the staged app exposes the regular workspace window but not its status-item window to its own accessibility tree. Direct SystemUIServer inspection timed out; ControlCenter and an attempted splitter drag closed the Computer Use native pipe. Therefore the dismissing/non-dismissing menu matrix, fresh compact splitter stop, text-selection gesture, light appearance, and large-window appearance are not claimed as fresh runtime proof. The only available desktop work area was 900 x 572.
- `/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.andrzej.ClipVault" AND (messageType == error OR messageType == fault)'` returned no ClipVault-authored errors or faults. The broader process scan matched system diagnostics from SkyLight, FrontBoard, XCTest registration, BoardServices, Spotlight, LaunchServices, and Foundation Models language defaulting; these are system-framework messages, not ClipVault subsystem failures.
- After more than five minutes of staged runtime, PID 92822 sampled at `0.1%` CPU and `207344 KB` RSS, with no observed update loop. `codesign --verify --deep --strict --verbose=2 dist/ClipVault.app` passed.
- `./script/app_store_check.sh` completed all local bundle, privacy, entitlement, and strict-signing checks, found the Apple Distribution application identity, and exited `3` only because a Mac installer distribution identity is missing.
- Repo state: **not controller-ready for merge or replacement of `/Applications/ClipVault.app`** until the incomplete MenuBarExtra/sidebar destructive runtime matrix is resolved. External state: **not upload-ready** until a Mac installer distribution identity is installed; this does not invalidate the local bundle evidence.

## Task 4 Review Remediation (2026-07-10)

- `33dbf9b` remains the broad source and staged-runtime verification head. The earlier build, E2E, launch, AX, screenshot, log, idle, and signing evidence is retained as evidence for that head.
- `7afed72` (`Fix design spec diff hygiene`) removed the final blank line at EOF from the approved design specification. Fresh `git diff --check` and `git diff --check 80db368..HEAD` are clean. This explicitly supersedes the obsolete Task 4 report conclusion that branch diff hygiene was non-clean because of that EOF whitespace.
- `8e42fbd` (`Fix AI clip count grammar`) changes the three visible cited/selected count paths in `AIActionPanel.swift` to use one local formatter: `1 clip cited` and `1 clip selected`; zero and plural counts use `clips`. Fresh source-only evidence: `swift build -c release -Xswiftc -warnings-as-errors` completed with no warnings or errors, and `./script/test.sh` passed Rust 2/2 and Swift 32/32.
- The grammar-only change did not rerun the GUI/E2E matrix. The broad staged-runtime checks remain the recorded `33dbf9b` evidence; no broader runtime result is claimed for `8e42fbd`.

### Current Review State

- **Actual code defects:** The singular grammar defect is fixed. No known code defect from this review remains.
- **Manual verification limits:** Fresh proof is still absent for the MenuBarExtra dismissal/non-dismissal matrix, destructive GUI completion against the persisted workspace, result-text selection, compact-splitter stop, and light-appearance and large-window states.
- **Staged-app state:** The staged bundle was locally verified as Apple Development-signed. An Apple Distribution application identity is present; this is retained staged-app/signing evidence from the `33dbf9b` verification head, not a newly rerun runtime check.
- **External blockers:** A Mac installer distribution identity is still missing, and final App Store metadata, name/bundle-ID, and account decisions remain outside this review.
