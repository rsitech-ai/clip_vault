# ClipVault App Store Release Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a freshly verified Mac App Store submission candidate for ClipVault, fixing every safe repository-local release defect and documenting every external blocker precisely.

**Architecture:** Preserve the existing SwiftPM macOS application and Rust FFI boundary. Treat `script/test.sh`, `script/build_and_run.sh`, `script/e2e_smoke.sh`, `script/app_store_check.sh`, and `script/package_app_store.sh` as the release pipeline, strengthening only gates that fresh evidence proves incomplete. Store versioned release evidence under `docs/release/0.1.0/`; do not commit generated apps, packages, credentials, profiles, or private logs.

**Tech Stack:** Swift 6, SwiftUI/AppKit, SwiftData, Security/Keychain, Vision, NaturalLanguage, Rust 2021 FFI, Bash, Apple codesign/productbuild/pkgutil, GitHub CLI.

## Global Constraints

- Work only on `feat/andrzej_agent_sota_lab` in `/private/tmp/ClipVault-agent-sota-lab`.
- Shipping scope is macOS 15+ only unless repository discovery proves another application target exists.
- Use current official Apple documentation checked on 2026-07-11 for submission, privacy, App Review, age rating, accessibility, and screenshot claims.
- Do not upload, submit for review, release publicly, merge `main`, create a production tag, change pricing/territories, accept agreements, or make legal/privacy/trader/export declarations without explicit final approval.
- Preserve the eight untracked historical `audits/` directories in the primary checkout and do not stage unrelated files.
- Use TDD for deterministic behavior fixes where a regression test is feasible.
- Use the weakest truthful verdict: `READY FOR SUBMISSION`, `READY FOR TESTFLIGHT ONLY`, `BLOCKED`, or `NOT READY`.

---

### Task 1: Freeze the release inventory and gate matrix

**Files:**
- Create: `docs/release/0.1.0/RELEASE_STATUS.md`
- Create: `docs/release/0.1.0/RELEASE_MANIFEST.json`

**Interfaces:**
- Consumes: repository configuration, installed toolchain, official Apple sources.
- Produces: canonical target inventory and release-gate rows used by every later task.

- [ ] **Step 1: Record repository and target inventory**

Run `git status --short`, `git remote -v`, `swift package describe --type json`, `swift package show-dependencies --format json`, and `find . -name '*.xcodeproj' -o -name '*.xcworkspace'` and record the exact macOS app/library/test products, version, bundle ID, deployment target, dependency graph, and absence or presence of iOS targets.

- [ ] **Step 2: Record machine and Apple toolchain inventory**

Run `xcode-select -p`, `xcodebuild -version`, `xcodebuild -showsdks`, `xcrun swift --version`, `xcrun simctl list`, `xcrun devicectl list devices`, `security find-identity -v -p codesigning`, provisioning-profile inventory, `gh auth status`, and App Store Connect credential preflight without printing secrets.

- [ ] **Step 3: Create the initial gate matrix and manifest**

Record each gate as `PASS`, `FAIL`, `BLOCKED`, `NOT APPLICABLE`, or `NOT YET VERIFIED`, with command, evidence path, owner, and next action. Validate JSON with `python3 -m json.tool docs/release/0.1.0/RELEASE_MANIFEST.json`.

- [ ] **Step 4: Commit the inventory slice**

Run `git add docs/release/0.1.0 docs/superpowers/plans/2026-07-10-app-store-release-hardening.md && git commit -m "docs: start ClipVault 0.1.0 release evidence"` after reviewing the staged diff.

### Task 2: Close build, test, static-analysis, and supply-chain gates

**Files:**
- Modify only if proven necessary: `Package.swift`, `rust/SearchIndexCore/Cargo.toml`, `Sources/**`, `Tests/**`, `rust/SearchIndexCore/src/**`, `script/test.sh`
- Create: `docs/release/0.1.0/TEST_EVIDENCE.md`
- Create: `docs/release/0.1.0/SECURITY_STATUS.md`

**Interfaces:**
- Consumes: Task 1 inventory.
- Produces: warning-free Release artifacts, reproducible test evidence, dependency and security disposition.

- [ ] **Step 1: Run clean build and static gates**

Run `swift package reset`, rebuild the Rust release library, `swift build -c release -Xswiftc -warnings-as-errors`, `cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml -- --check`, `cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings`, dependency/license inspection, secret scan, and dead/debug-code searches.

- [ ] **Step 2: Run focused and full tests**

Run `./script/test.sh`; if a deterministic failure appears, reproduce it with the narrowest `swift test --filter` or `cargo test <name>`, add a failing regression, apply the minimum fix, prove red/green, and rerun the full command.

- [ ] **Step 3: Run sanitizer coverage**

Run the repository-supported AddressSanitizer configuration for Swift and Rust boundaries. Record unsupported sanitizer configurations explicitly rather than treating them as passed.

- [ ] **Step 4: Document security and supply-chain results**

Record every in-scope source/security surface, dependency provenance, licenses, secret-scan result, privacy-sensitive storage/logging result, and finding disposition in `SECURITY_STATUS.md`.

- [ ] **Step 5: Commit verified fixes and evidence**

Stage only intentional source/test/script/evidence files, inspect `git diff --cached`, and commit with a focused `fix:` or `docs:` message.

### Task 3: Close native macOS runtime, UI, accessibility, performance, and leak gates

**Files:**
- Modify only if proven necessary: `Sources/ClipVault/**`, `Tests/ClipVaultCoreTests/**`, `script/build_and_run.sh`, `script/e2e_smoke.sh`
- Create: `docs/release/0.1.0/TEST_EVIDENCE.md` runtime sections

**Interfaces:**
- Consumes: warning-free Release build from Task 2.
- Produces: exact-bundle runtime, interaction, accessibility, performance, memory, restart, persistence, and log evidence.

- [ ] **Step 1: Build and launch the exact Release bundle**

Run `./script/build_and_run.sh --verify`, capture the exact PID/binary path, and verify capture readiness, relaunch, state restoration, sandbox operation, and clean shutdown.

- [ ] **Step 2: Execute the stateful E2E flow**

Run `./script/e2e_smoke.sh` twice and verify capture, duplicate counting, app-owned persistence probing, and restart recovery without host access to sandbox data.

- [ ] **Step 3: Exercise the native interaction matrix**

Using safe local fixtures, inspect and operate the menu bar, workspace, search, clip selection/copy, folders, notes/tags/title, AI disclosure/fallback, settings, keyboard shortcuts, context menus, delete-confirm-cancel, minimum/typical/large windows, dark/light appearance, Reduce Motion, and increased contrast. Do not complete destructive actions against real user data.

- [ ] **Step 4: Inspect accessibility and performance**

Verify AX labels/order/actions and keyboard-only common tasks; sample Release launch time, idle CPU, memory footprint, main-thread state, and repeated open/close behavior. Capture a memgraph or equivalent retained-object evidence if app-owned growth is observed.

- [ ] **Step 5: Inspect runtime logs and crashes**

Query PID-scoped unified logs for error/fault, SwiftUI/AppKit constraint warnings, privacy leakage, crash reports, and hangs after each critical flow.

- [ ] **Step 6: Fix and reverify any deterministic runtime defects**

For each defect, add a focused regression when feasible, apply the smallest fix, rerun the failed interaction, rerun its parent workflow, and rerun `./script/test.sh`.

### Task 4: Close sandbox, signing, privacy, metadata, package, and validation gates

**Files:**
- Modify only if proven necessary: `Packaging/ClipVault.entitlements`, `Resources/PrivacyInfo.xcprivacy`, `PRIVACY.md`, `AppStore/metadata.md`, `script/app_store_check.sh`, `script/package_app_store.sh`, `script/upload_app_store.sh`
- Create: `docs/release/0.1.0/PRIVACY_DATA_MAP.md`
- Create: `docs/release/0.1.0/APP_STORE_CHECKLIST.md`
- Create: `docs/release/0.1.0/APP_REVIEW_NOTES.md`
- Create: `docs/release/0.1.0/RELEASE_NOTES.md`
- Create: `docs/release/0.1.0/BLOCKERS.md`

**Interfaces:**
- Consumes: final runtime artifact and verified functionality.
- Produces: truthful privacy/review/metadata package plus signed Mac App Store installer evidence.

- [ ] **Step 1: Reconcile privacy and permissions**

Map each handled data category to source, purpose, local storage, retention, deletion, recipient, tracking, and identity linkage; reconcile source behavior with the privacy manifest, privacy policy, entitlements, purpose strings, App Store privacy-label draft, and review notes.

- [ ] **Step 2: Complete repository-owned metadata**

Validate name/subtitle/description/keywords/category/copyright/review notes length and truthfulness; inventory required 16:10 Mac screenshots and URLs. Mark support/privacy URLs, pricing, territories, DSA trader status, age rating, export compliance, content rights, privacy labels, and release mode as owner/account blockers where they cannot be truthfully decided from the repository.

- [ ] **Step 3: Build the Mac App Store package**

Run `./script/app_store_check.sh`, then `./script/package_app_store.sh` with discovered non-secret distribution identities and team/bundle/version/build values. Verify actual app and nested dylib architecture, strict signatures, entitlements, Info.plist, privacy manifest, hardened runtime, package signature, payload, SHA-256, and absence of quarantine attributes.

- [ ] **Step 4: Perform supported local validation**

Use the current Apple-supported local validation path available on this machine. If App Store Connect authentication or an app record is unavailable, do not upload; record server-side validation/TestFlight as `BLOCKED` with exact owner/action.

- [ ] **Step 5: Commit release documentation and safe fixes**

Review all evidence for secrets and customer data, stage only repository-owned documentation/code, and commit cohesively. Never add `dist/` or package artifacts.

### Task 5: Independent review, GitHub PR, and final verdict

**Files:**
- Update: `docs/release/0.1.0/RELEASE_STATUS.md`
- Update: `docs/release/0.1.0/RELEASE_MANIFEST.json`

**Interfaces:**
- Consumes: complete release branch and all fresh evidence.
- Produces: reviewed draft PR and one exact final verdict.

- [ ] **Step 1: Run final diff and security review**

Review `git diff main...HEAD` for correctness, maintainability, readability, security, privacy, performance, dead code, and accidental scope; run the security diff scan and independent code review, then fix every validated blocker/high/release-blocking medium issue.

- [ ] **Step 2: Re-run final verification from the final commit**

Freshly rerun `./script/test.sh`, warnings-as-errors Release build, Rust fmt/Clippy, sanitizer gate, two E2E smokes, exact-bundle runtime/log checks, `./script/app_store_check.sh`, package creation, strict signature/entitlement/package inspections, JSON validation, and `git diff --check`.

- [ ] **Step 3: Push and open a draft PR**

Push `feat/andrzej_agent_sota_lab`, open or update a draft PR against `main`, include gate evidence and blockers, inspect GitHub checks and review comments, and address actionable failures. Do not merge.

- [ ] **Step 4: Publish the final release verdict**

Update every gate row with fresh evidence and choose exactly one verdict. If App Store Connect validation, required URLs/screenshots, truthful owner declarations, clean-account install, or status-item proof remain incomplete, use `BLOCKED` or `NOT READY`; name the exact next action and residual risk.
