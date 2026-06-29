# ClipVault MVP Reflection

Date: 2026-06-26

## Success Criteria

- macOS SwiftUI app builds as a menu-bar-plus-window utility.
- Core clipboard models, sensitive exclusion, retention, search, and AI provider boundaries are testable outside UI.
- Rust search/index core has deterministic tests and is callable from Swift through a narrow boundary.
- The app can run from one project-local script and has a Codex Run action.

## Failure Hypotheses

- Foundation Models and multimodal APIs may be unavailable or SDK-gated, so AI features must compile with graceful fallback paths.
- Linking Rust into SwiftPM can fail if the Rust library is not built before Swift; the run/test scripts must own that order.
- Full rich clipboard capture can sprawl quickly; MVP must store representations and previews while indexing extracted text and metadata.

## Candidate Approaches

- SwiftPM GUI app with staged `.app` bundle: fastest reproducible route for this empty repo.
- Xcode project: more native packaging, but heavier to generate and maintain manually in one pass.
- Swift-only first pass with Rust later: simpler, but violates the MVP plan's Rust core boundary.

## Chosen Approach

Use SwiftPM for the macOS app and tests, plus a Rust static library for search/index primitives. Keep Apple AI behind protocols and availability checks so the product remains usable without model access.

## Final Signal

- `./script/test.sh` passes: Rust search tests plus Swift sensitive-rule, retention, and FFI tests.
- `./script/build_and_run.sh --verify` passes: builds the Rust core, builds Swift, stages `dist/ClipVault.app`, launches it, and confirms the process exists.
- Foundation Models remain capability-gated; cloud AI is represented only as a disabled provider boundary.

## Follow-up Signal

- Added copy-back behavior so selected clips can be restored to the system pasteboard for paste.
- Added a pasteboard writer with tests for text and image payloads.
- Improved image capture to prioritize actual image data, keep OCR as searchable metadata, and use more accurate Vision OCR settings.
- Added in-memory collection folders/subfolders and native sidebar creation controls.
- Reworked the status-bar panel with fixed-height hover rows and a right-side preview pane; clicking a row copies the original payload to the system clipboard.
- Added clip-attached notes for screenshots/snippets, plus delete and clear-unpinned cleanup actions.
- Added persisted folder records, duplicate copy counts, title overrides, tags, bulk cleanup filters, screenshot annotation controls, status-bar keyboard flow, and adaptive workspace layout.
- Added App Store readiness assets: sandbox entitlements, privacy manifest, generated app icon, metadata/privacy docs, readiness checker, and Mac App Store packaging script. Local checks pass through bundle validation; packaging is blocked until Apple Distribution and 3rd Party Mac Developer Installer certificates are installed.
