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
