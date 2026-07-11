# ClipVault 0.1.0 Release Status

## Final verdict

**NOT READY**

Date: 2026-07-11 (Europe/Warsaw)

Core source, automated tests, signed runtime, local packaging, lifecycle proof, and accepted-size screenshots pass. The release is not yet ready because formal security scans, the newest stable Xcode toolchain, remaining appearance/status-item QA, PR/CI evidence, and external App Store Connect/legal gates remain incomplete.

## Toolchain and release identity

- Project: SwiftPM macOS application; no iOS, extension, widget, helper, watch, or Xcode project target exists.
- Bundle: `com.andrzej.ClipVault`; version `0.1.0`; build `1`; deployment target macOS 15.0; architecture arm64.
- Production archive/package toolchain: Xcode 26.5 (17F42), macOS 26.5 SDK, Swift 6.3.2.
- Host tested: macOS 26.3 (25D125), Apple silicon.
- Apple sources checked 2026-07-11: [Xcode support](https://developer.apple.com/support/xcode/), [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/), and [Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/). Xcode 26.5 remains upload-compatible for macOS, but Apple lists Xcode 26.6 as the latest stable release. This mission requires the newest accepted production toolchain, so regeneration on 26.6 remains a release gate.
- Xcode/macOS 27 compatibility: **BLOCKED** because no Xcode 27 or macOS 27 runtime is installed. No 27-only API or deployment requirement was found. This is a separate compatibility track, not the production package toolchain.

## Release gates

| Gate | Status | Command or inspection | Evidence | Owner | Next action |
| --- | --- | --- | --- | --- | --- |
| Repository/targets | PASS | SwiftPM and file inventory | This file; `Package.swift` | Engineering | None |
| Debug/unit tests | PASS | `./script/test.sh` | `TEST_EVIDENCE.md` | Engineering | Keep CI green |
| Release warnings | PASS | `swift build -c release -Xswiftc -warnings-as-errors` | `TEST_EVIDENCE.md` | Engineering | None |
| Newest production toolchain | BLOCKED | Apple Xcode support page vs installed Xcode | This file; `BLOCKERS.md` | Engineering/QA | Install Xcode 26.6 and regenerate candidate |
| Signed runtime/E2E | PASS | `build_and_run.sh --verify`; two `e2e_smoke.sh` runs | `TEST_EVIDENCE.md` | Engineering | Repeat after merged changes |
| Runtime logs | PASS | PID-scoped warning/error/fault scan | `TEST_EVIDENCE.md` | Engineering | None; one system-owned WindowServer task-port row documented |
| Accessibility/UI | FAIL | Broad native accessibility-tree interaction | `TEST_EVIDENCE.md` | Engineering/QA | Complete light/contrast/Reduce Motion and status-item matrix |
| Performance/leaks | PASS | repeated Settings lifecycle, `ps`, `vmmap`, differential `leaks` | `TEST_EVIDENCE.md` | Engineering/QA | Monitor on clean macOS 15 environment |
| Security/dependencies | BLOCKED | source audit, Clippy, `cargo audit`; native final scan awaiting start | `SECURITY_STATUS.md` | Engineering/user | Start and complete standard/final diff scans |
| Privacy implementation | PASS | consent, retention, encryption, manifest inspections | `PRIVACY_DATA_MAP.md` | Engineering | Publish policy URL |
| Local distribution package | PASS | package and strict validator | `RELEASE_MANIFEST.json` | Engineering | Preserve uncommitted package externally if needed |
| Provisioning/server validation | BLOCKED | no embedded profile; no ASC credentials | `BLOCKERS.md` | Apple account owner | Validate/upload in App Store Connect |
| Required metadata/URLs | BLOCKED | metadata audit | `APP_STORE_CHECKLIST.md` | Product owner | Supply public URLs and final fields |
| Screenshots | PASS | dimensions and visual content inspected | `AppStore/Screenshots/`; `APP_STORE_CHECKLIST.md` | Engineering/QA | Upload after owner metadata review |
| Legal/business declarations | BLOCKED | guideline/ASC field audit | `BLOCKERS.md` | Account/legal owner | Answer export, DSA, age, rights, price/territories |
| TestFlight/upload | BLOCKED | not attempted without credentials | `BLOCKERS.md` | Apple account owner | Authorize and provide ASC API credentials |
| iOS track | NOT APPLICABLE | no iOS shipping target | target inventory | Engineering | None |
| macOS 15 minimum runtime | BLOCKED | runtime unavailable on this host | `TEST_EVIDENCE.md` | QA | Run on macOS 15 hardware/VM |
| macOS 27 compatibility | BLOCKED | Xcode/runtime unavailable | `BLOCKERS.md` | QA | Run when beta/stable runtime is available |

## Verification summary

- Rust: 3 tests passed; format and Clippy clean; no RustSec advisory match.
- Swift: 74 tests in 15 suites passed; Release warnings-as-errors and the ASan test run passed.
- Shell release checks: identity selection, artifact helpers, upload dry-run, and consent preference restoration passed.
- Runtime: explicit consent decline/reopen/accept flow passed; capture, dedupe, persistence, exact-process restart, screenshot subprocess launch/cancel, search, keyboard navigation, hierarchical move, and one-clip drag semantics passed.
- Accessibility: first-launch disclosure, toolbar actions, search, list selection, Move menus, drop-target help, detail controls, and Settings were exposed with labels/state. No iOS devices/simulators apply.
- Performance: after five Settings open/close cycles, idle CPU settled at 0.2%; physical footprint was 90.3 MB (92.5 MB peak).
- Leaks: the lifecycle delta was 928 bytes only in AppKit `NSAccessibilityCustomAction`/`NSArray` objects after accessibility instrumentation; no app-owned retaining path was identified.
- Screenshots: two sanitized actual-product 1280x800 JPEGs are staged under `AppStore/Screenshots/`.
- Security: clipboard details are AES-GCM encrypted at rest with a Keychain-held key; future envelope versions fail closed; capture requires consent; sensitive values are filtered before persistence.
- Signing: Apple Distribution app and 3rd Party Mac Developer Installer identities are present. Final `.pkg`, nested dylib, hardened runtime, entitlements, load paths, architecture, Info.plist, privacy manifest, and matching dSYM passed repository-local validation.
- Upload: not attempted; App Store Connect credentials and server-side provisioning validation are unavailable.

## App Review and compliance

Official sources checked 2026-07-11: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), [privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files), [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications), [age ratings](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating), and [accessibility nutrition labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-app-accessibility/).

The explicit clipboard disclosure addresses guideline 2.5.14. A complete local privacy disclosure is available in Settings, and retention/deletion behavior and the privacy manifest are aligned, but a public policy URL and owner-confirmed App Store privacy answers remain mandatory. The use of `/usr/sbin/screencapture` is a residual App Review risk because it is an external system command rather than a documented app API; it has not produced a local failure.

## Changed implementation and commits

The release branch adds at-rest details encryption and legacy migration, explicit capture consent and lifecycle invalidation, hardened build/package/upload validation, CI, consent preference restoration, a warning-free accessible clip list, hierarchical Move to Collection menus, exact single-clip drag/drop, production probe isolation, and sanitized App Store screenshots. The reviewed release source spans `origin/main..d11b7f96467d65cabb37e63a66545b9780595aac`.

Changed-file groups: CI (`.github/workflows/ci.yml`); consent/settings/app views (`Sources/ClipVault/**`); encrypted storage/capture services (`Sources/ClipVaultCore/**`); regression tests (`Tests/ClipVaultCoreTests/**`); build, package, validation, upload, and shell tests (`script/**`); privacy/metadata and release dossier (`PRIVACY.md`, `AppStore/metadata.md`, `docs/**`). The PR URL and final CI result will replace the current placeholder after push.

Draft PR and CI status are populated after push. No merge, tag, upload, submission, or public release is authorized by this dossier.

## Exact next action to unblock submission

The Apple account owner must create/confirm the App Store Connect record, provide an authorized API key for validate-only upload, publish the support and privacy URLs, capture accepted-size screenshots, confirm provisioning, and supply truthful export-compliance, privacy-label, age-rating, DSA trader, content-rights, price, territory, and release-mode answers. Engineering can then run validate-only upload, resolve any server warnings, and update this verdict. Submit for Review still requires separate explicit approval.

## Residual risks

- No macOS 15, Intel, clean-user installation, or macOS 27 runtime proof in this run. Intel is not declared supported; the package is arm64 only.
- MenuBarExtra interaction through SystemUIServer could not be fully automated; source/state tests and workspace interactions passed.
- Two sanitized screenshots meet accepted dimensions; owner review before upload is still prudent.
- Historical pre-hardening SQLite freelist/WAL/backups may retain plaintext remnants on upgraded development data; first-release fresh installs do not write the protected detail fields in plaintext.
- `/usr/sbin/screencapture` remains an App Review/API-surface risk.
