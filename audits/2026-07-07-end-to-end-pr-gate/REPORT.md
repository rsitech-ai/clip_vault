# ClipVault End-to-End Audit and PR Gate

Date: 2026-07-07

## Scope

Reviewed the current ClipVault implementation end to end against the repo standards, the app's intended local-first clipboard flow, and current Apple guidance for SwiftUI/macOS app structure and resources.

Official references used:

- Apple Design Resources: iOS/iPadOS 27 UI Kit, macOS 27 UI Kit, Icon Composer, and SF Symbols resources.
- Apple SwiftUI `MenuBarExtra`: menu-bar access to commonly used app functionality while the app is not active.
- Apple SwiftUI `NavigationSplitView`: root multi-column layout for desktop apps.
- Apple SwiftUI `navigationSplitViewColumnWidth`: explicit split-column sizing.
- Apple Xcode SwiftUI performance guidance: profile SwiftUI updates and reduce unnecessary view work.

## Verification

Passed:

- `<local-codex-config>/scripts/session-bootstrap.sh`
- `bash -n script/build_and_run.sh script/e2e_smoke.sh script/app_store_check.sh script/package_app_store.sh script/upload_app_store.sh script/test.sh`
- `swift build -Xswiftc -warnings-as-errors`
- `cargo test --manifest-path rust/SearchIndexCore/Cargo.toml`
- `./script/test.sh` - 21 Swift tests and 2 Rust tests passed.
- `swift build -c release`
- `./script/e2e_smoke.sh` - capture, duplicate coalescing, persistence, and restart recovery passed.
- `git diff --check`
- `codesign --verify --deep --strict --verbose=2 /Applications/ClipVault.app`
- `plutil -lint /Applications/ClipVault.app/Contents/Info.plist /Applications/ClipVault.app/Contents/Resources/PrivacyInfo.xcprivacy Packaging/ClipVault.entitlements`
- `otool -L /Applications/ClipVault.app/Contents/MacOS/ClipVault` - Rust dylib resolves through `@executable_path/../Frameworks/libsearch_index_core.dylib`.
- Unified log filter for installed app faults/errors over the launch window returned no ClipVault errors or faults.

Installed runtime proof:

- Fresh verified build copied to `/Applications/ClipVault.app`.
- Only `/Applications/ClipVault.app/Contents/MacOS/ClipVault` remained running after install.
- Computer Use accessibility read showed the workspace, live clip list, detail pane, and AI Workspace action buttons including `Explain`.

## Findings Fixed

1. App Store packaging script did not embed and relink `libsearch_index_core.dylib`.
   - Impact: a distribution package could pass superficial script setup but launch with a missing absolute build-path dylib.
   - Fix: `script/package_app_store.sh` now copies the Rust dylib into `Contents/Frameworks`, rewrites the install name, rewrites the app binary dependency to `@executable_path/../Frameworks/libsearch_index_core.dylib`, and signs the dylib before signing the app.

2. Settings capture toggle was not idempotent for programmatic value setting.
   - Impact: accessibility or programmatic setters could flip capture when setting the existing value.
   - Fix: the settings binding now only toggles when the requested value differs from `model.isCapturing`.

3. Audit evidence could accidentally stage large screenshots/traces.
   - Impact: PRs could include large local QA artifacts.
   - Fix: `.gitignore` now excludes audit screenshots and trace bundles while keeping markdown reports stageable.

## Review Result

Local app behavior is stable:

- Clipboard capture runs after launch.
- Duplicate text clips coalesce into one stored record with incremented copy count.
- SwiftData persistence survives restart.
- Copy paths write original payloads back to the pasteboard and consume the app-originated pasteboard change.
- Menu row code path copies on tap and closes the status-menu window.
- Main-list click-to-copy is consistent with the requested fast Maccy-like flow.
- AI Workspace is visible and has a resizable split-view implementation through `HSplitView`/`VSplitView`.
- Clip times use minute-or-larger labels and `.shortened` absolute time formatting, so seconds are not shown.
- Buy Me a Coffee is centralized in `ClipVaultSupport.buyMeACoffeeURL`, fixed to `https://www.buymeacoffee.com/s1korrrr`, and covered by tests.
- Cloud AI providers are disabled; Foundation Models is availability-gated with local fallback.
- Sandbox and privacy manifest are present and lint clean.

## Caveats

`./script/app_store_check.sh` exits `3` because this machine is missing a Mac installer distribution identity. The bundle checks pass and an application distribution identity is present, but App Store upload/package creation remains externally blocked until a `3rd Party Mac Developer Installer` or `Mac Installer Distribution` certificate is installed.

Direct status-menu click automation through System Events hung during the final audit. The menu copy/close behavior is verified by code review, pasteboard writer tests, E2E clipboard persistence tests, and the live app accessibility tree, but a deterministic automated click-through of the menu-bar extra still needs a stronger UI runner or a short manual smoke before App Store upload.

## Gate Call

Repo-side and installed-app readiness: pass.

App Store upload readiness: blocked externally by missing installer distribution certificate.
