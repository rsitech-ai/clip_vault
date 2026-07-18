# ClipVault End-to-End Audit

## Result

- Date: 2026-07-17
- Reviewed baseline: `729f5ac8f2b1d3836f28f3fb4dae9f9c34adbe9a`
- Audit branch: `feat/andrzej_e2e_audit_2026_07_17`
- Readiness: **repo-ready and package-ready**
- Code-review result: no unresolved correctness, security, performance, or maintainability blocker in the reviewed change set
- External gates: App Store Connect provisioning/server validation and the separate running Codex Security scan remain unverified

The audit covered the SwiftUI/AppKit app, SwiftData persistence, Keychain/CryptoKit encryption, clipboard capture and writing, Vision OCR, Foundation Models availability and validation paths, Rust FFI search, shell/release tooling, signing, packaging, native interaction, process behavior, and runtime logs.

## Official Documentation Baseline

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra): the window style is suitable for richer status-item content, and its label is the status item's accessible identity.
- [ModelContext](https://developer.apple.com/documentation/swiftdata/modelcontext) and [save()](https://developer.apple.com/documentation/swiftdata/modelcontext/save()): the store uses explicit transaction/save boundaries and rollback on recoverable failures.
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) and [protecting user data](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox): the packaged app is sandboxed with a narrow user-selected read-only file entitlement.
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files): the validated package contains `Contents/Resources/PrivacyInfo.xcprivacy`.
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) and [storing keys](https://developer.apple.com/documentation/security/storing-keys-in-the-keychain): the payload key is stored in Keychain, status codes are checked, and startup now prepares the key away from the main actor.
- [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard) and [changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount): capture is change-count based, consent-gated, and writes preflight fallible image input before clearing shared clipboard contents.
- [Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images): image OCR remains on-device and is performed outside the main actor before ordered delivery.
- [SystemLanguageModel](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel): model availability, cancellation, output validation, and unavailable states remain explicit.
- [SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) and [responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness): expensive Keychain work was removed from the main actor and cached for the process lifetime.
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/): local evidence covers stability, sandboxing, privacy resources, accurate failure states, and package integrity; account-side review gates are intentionally not claimed.

## Architecture And Expected Flow

`ClipVaultApp` owns a single observable `ClipVaultViewModel` and supplies it to the workspace window, menu-bar extra, settings, dock tile, and optional notch activity. The view model coordinates consent, capture, storage, search projection, selection, prompt workflows, and user-facing state.

The capture flow is:

1. Persisted consent determines whether capture starts.
2. `ClipboardCaptureService` snapshots each new pasteboard change on the main actor.
3. Payload parsing and OCR execute asynchronously.
4. Completed payloads are buffered and delivered in original pasteboard-change order.
5. The view model applies sensitive-content exclusion and sends accepted payloads to `SwiftDataClipStore`.
6. Payload and user-detail fields are encrypted before persistence with one process-cached Keychain key.
7. Search projections feed the workspace and a separate global menu projection. The menu projection always uses All Clips, regardless of workspace collection selection.

The write flow validates an image payload before changing the shared pasteboard, writes the exact stored payload, and consumes the resulting local change so the app does not recapture its own copy.

The release flow now stages a signed app without launching it. Local readiness checks therefore cannot start a second production-bundle process against the same clipboard and SwiftData store.

## Validated Findings And Fixes

| Severity | Area | Finding | Fix and regression proof |
| --- | --- | --- | --- |
| Medium | Clipboard integrity | A failed image copy cleared existing clipboard contents before discovering that image bytes were absent or malformed. | Image bytes are decoded before `clearContents()`. Missing and malformed data both throw while preserving the previous clipboard; two regression tests cover the cases. |
| Medium | Capture ordering | OCR/payload tasks could complete out of order, causing later clipboard changes to be persisted ahead of earlier ones. | Capture and delivery sequence numbers plus a completion buffer preserve change order. Controlled async regression tests complete the second item first and prove that an ignored payload still releases the next valid capture. |
| Medium | Keychain isolation | Audit/test bundles used the production Keychain service, causing cross-bundle key access failures including status `-128`. | The default Keychain service follows `Bundle.main.bundleIdentifier`, with the production identifier retained as the no-bundle fallback. |
| Medium | Responsiveness | Each encryption/decryption operation could synchronously query Keychain from the main actor, producing Security Performance Diagnostics faults. | `LocalPayloadEncryptor` safely caches one key under a lock; startup prepares it in a detached user-initiated task and fails closed if preparation fails. Runtime fault filters are clean after the change. |
| Medium | Release tooling | `app_store_check.sh` used launch verification to create a missing staged bundle, which could run a second production ClipVault process against the same clipboard/store. | A non-launching `--stage` mode was added and is policy-tested. Final process IDs were identical before and after the readiness check. |
| Low | E2E reliability | The signed smoke treated “process alive” as capture-ready and could write its token during encryption preparation, after which capture intentionally rebased the pasteboard. | The smoke now retries the private test-pasteboard write until capture is observable, records the initial copy count, proves a further deduplicating copy increments it, and verifies that exact count after restart. |
| High | Startup concurrency | The workspace window and menu-bar surface could call `bootstrap()` concurrently. Both calls could suspend during detached Keychain preparation, create separate encryptors, and race to insert the same key; the losing call could report a duplicate-item failure and stop capture after the successful call. | `LocalPayloadEncryptionBootstrap` now coordinates one actor-isolated preparation task and returns the same prepared encryptor to concurrent callers. A regression test proves one factory invocation, one key load, and shared object identity; a second test proves failed preparation is cleared and can be retried. |
| Medium | Capture readiness | After encryption bootstrap failed, accepting consent or resuming capture could display “Watching clipboard” even though no store or capture callback had been installed. | `startCapture()` now fails closed unless storage is ready, clears stale readiness state, and returns success. Consent and resume paths report the storage failure instead of claiming capture is active; source-policy coverage locks the guard and both call sites. |
| Medium | E2E data compatibility | The default non-production bundle could reopen a pre-change SwiftData store encrypted with the former production-scoped Keychain service, making every store probe fail after Keychain isolation was corrected. | The disposable default E2E identity is versioned to `com.andrzej.ClipVault.e2e.v2`, giving the new encryption namespace a clean store without reading or deleting production data. A shell-policy assertion prevents accidental reuse of the incompatible pre-change identity; explicitly supplied bundle IDs remain supported. |

All nine findings are fixed in the audit branch. No reportable unresolved code finding remained after the final review.

## Verification Evidence

| Check | Result |
| --- | --- |
| `./script/test.sh` | Passed: 173 Swift tests in 17 suites, 4 Rust tests, and every repository shell/policy test |
| `swift build -c release -Xswiftc -warnings-as-errors` | Passed: production compile/link with warnings treated as errors |
| `cargo fmt --check` | Passed |
| `cargo clippy --all-targets --all-features -- -D warnings` | Passed |
| `bash -n script/*.sh script/lib/*.sh` | Passed |
| `git diff --check` | Passed |
| Fresh signed E2E bundle | Passed: private pasteboard capture, deduplication, encrypted persistence, exact signed-app store probe, termination, relaunch, and recovery |
| Fresh runtime performance sample | Passed: captured and persisted one token; no Security Performance Diagnostics or app `operation_failed` event; idle approximately 0.1% CPU and 136 MB RSS |
| Native interaction | Passed for All Clips/Code filtering, search, exact copy, capture pause/resume, relaunch persistence, visible status, and accessibility labels/help |
| Menu All Clips contract | Passed by presentation-policy and view-model regression tests; direct status-item automation was unavailable because SystemUIServer accessibility timed out |
| Local App Store package | Passed strict app, executable, and Rust dylib signatures; entitlements, Info.plist, privacy manifest, architectures/load paths, package signature, and dSYM UUID match |
| Duplicate-process guard | Passed: ClipVault PID set was `800` before and `800` after `app_store_check.sh` |

The repository has no `.swift-format` configuration. Running the tool's default strict profile produced broad two-space indentation/import-order findings that conflict with the project's established four-space style; it was treated as a tooling-configuration limitation rather than autoformatting unrelated source. The compiler, repository policy scripts, Rust formatter/linter, and diff checks are authoritative for this change.

## Native Scenario Matrix

| Scenario | Evidence | Result |
| --- | --- | --- |
| First-launch consent and decline/revoke behavior | Consent policy tests plus sandbox-safe launch tests | Passed; capture does not start without consent in production |
| Normal capture and duplicate copy | Fresh signed E2E app/store probe | Passed; one row, increasing copy count |
| Relaunch persistence | Fresh signed E2E termination/relaunch/store probe | Passed |
| Workspace collection selection | Direct native interaction and policy tests | Passed |
| Search within selected workspace scope | Direct `auditValue` search in Code and search-projection tests | Passed |
| Menu remains All Clips | Dedicated regression tests verify label and global projection independence | Passed; direct menu click unavailable to automation |
| Copy selected clip | Direct native interaction plus pasteboard writer tests | Passed; exact content returned and status updated |
| Pause/resume capture | Direct native interaction plus policy tests | Passed |
| Folder/collection moves and deletion semantics | Store integration tests, rollback tests, and protected-node tests | Passed; destructive live-data confirmation was not performed |
| Details, tags, and notes | Encrypted SwiftData round-trip and plaintext-at-rest scans | Passed |
| Prompt enhancement | Availability, cancellation, validation, atomic persistence, and rollback tests | Passed; no claim of model availability on unsupported runtime state |
| Window/layout/accessibility | Direct native inspection plus adaptive-layout and accessibility policy coverage | Passed for audited surfaces |
| Signing/package | Repository validators and Apple signing tools | Passed locally |

## Logs And Service Behavior

The final isolated runtime emitted only the expected app-authored bootstrap and capture information. Filters for Security main-thread performance diagnostics and `operation_failed` were empty after the fix. The app stayed alive, captured, persisted, terminated cleanly, and recovered the same encrypted record after relaunch.

The macOS 27 beta environment produced framework noise outside the app subsystem, including CoreSpotlight donation failures, Metal cache/slice messages, AppKit negative-geometry diagnostics while accessibility snapshots were running, and a benign ViewBridge termination. These messages did not reproduce as app-authored failures and did not break the validated flows. They should be rechecked on a non-beta release OS before submission.

## Package Evidence

- Package: `dist/AppStore/ClipVault-0.1.0-1.pkg`
- Matching symbols: `dist/AppStore/ClipVault.app.dSYM`
- Application identifier: `2NY8A789TN.com.andrzej.ClipVault`
- Team identifier: `2NY8A789TN`
- Sandbox: enabled
- User-selected files: read-only
- Architecture: arm64
- Binary/dSYM UUID: `C856B2D2-263C-36AC-BC5D-5A2E37D523B0`
- Package SHA-256: `f4679b3633f9f39b20cea85485dd8a1b6f9867aea098b530a0bed43367b38d8d`
- dSYM DWARF SHA-256: `3de2623d504699fce074ecbd94df3f4127d414b0a085d10a12e3642281286fe2`
- Embedded provisioning profile: absent; App Store Connect provisioning/server validation remains unverified

Four `write: Permission denied` lines appeared before `productbuild` during package creation, but packaging exited successfully and every independent payload, signature, entitlement, manifest, architecture, and UUID validator passed. An isolated `dsymutil` rerun did not reproduce the warning. This is retained as a tooling/environment limitation rather than hidden.

## Cleanup And Preserved State

- No tracked release dossier was removed: `docs/release/0.1.0` is the current release record, not obsolete clutter.
- The active `release-2026-07-15` worktree and its incomplete Codex Security scan were preserved without modification.
- User-owned untracked audit/documentation folders in the main checkout were preserved.
- Audit-only app bundles, containers, temporary packages, and build artifacts may be trashed after final merge evidence is captured.
- One production ClipVault audit token was created during direct copy verification. Removing that live user-data row requires explicit confirmation at deletion time.

## Final Gate

The reviewed implementation is **repo-ready and package-ready**. It is not yet labeled “ready for App Store Connect upload” because provisioning and server-side validation have not run, and the separate Codex Security scan `a14ee797-c831-4557-bf6f-38ee956ed058` is still running/incomplete. Those are external workflow gates, not unresolved local code failures.
