# ClipVault Full macOS 27 Visual Restyle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the approved full macOS 27 restyle while closing every test, verification, interaction, layout, symbol, and runtime-log defect found by the 2026-07-13 audit.

**Status:** Implemented and verified with the platform/tooling residuals recorded in the execution result below; that result is authoritative over the original task checkboxes.

**Architecture:** Keep persistence, capture, and AI service boundaries unchanged. Add pure presentation/search policies in `ClipVaultCore`, inject deterministic encryption only in tests, make E2E consent compile-time isolated, and compose the SwiftUI restyle from one non-nested glass layer plus native materials.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, SwiftData, Swift Testing, SwiftPM, Rust SearchIndexCore, shell verification scripts, Computer Use, macOS unified logging.

## Global Constraints

- Support macOS 15+ and availability-gate Liquid Glass at macOS 26+.
- Treat macOS 27 runtime proof separately from Xcode 27 SDK proof.
- Add no dependency, cloud path, analytics, persistence migration, or production encryption bypass.
- Preserve menu-bar one-click copy and workspace select/double-click-or-Return copy semantics.
- Preserve real clipboard history and all existing untracked `audits/` directories.
- Exercise destructive UI only through confirmation and cancel.
- Do not push, merge, upload, publish, or change external Apple state in this plan.

---

### Task 1: Deterministic Storage Tests

**Files:**
- Modify: `Tests/ClipVaultCoreTests/FolderTreeTests.swift`

**Interfaces:**
- Consumes: public `PayloadEncrypting` and `SwiftDataClipStore(context:encryptor:)`.
- Produces: a private reversible `FolderTreeTestPayloadEncryptor` used by every persistent folder-tree test.

- [ ] **Step 1: Change the focused helper to inject a nonexistent test type**

```swift
let store = SwiftDataClipStore(
    context: ModelContext(container),
    encryptor: FolderTreeTestPayloadEncryptor()
)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter 'FolderTreeTests/recursiveDeletionRetainsClipsAndUnrelatedAssignmentsInBothStores'`

Expected: compile failure because `FolderTreeTestPayloadEncryptor` is undefined; no Keychain prompt is accepted.

- [ ] **Step 3: Add the deterministic reversible encryptor**

```swift
private struct FolderTreeTestPayloadEncryptor: PayloadEncrypting {
    func encrypt(_ data: Data) throws -> Data { data }
    func decrypt(_ data: Data) throws -> Data { data }
}
```

- [ ] **Step 4: Verify focused and parent gates GREEN**

Run the focused test, `swift test --filter FolderTreeTests`, and then `./script/test.sh`. All must exit zero without Keychain interaction.

---

### Task 2: Sandbox-Safe Signed Launch And E2E Consent

**Files:**
- Modify: `Sources/ClipVault/App/ClipVaultViewModel.swift`
- Modify: `script/build_and_run.sh`
- Modify: `script/test_build_and_run_consent.sh`
- Delete: `script/lib/temporary_capture_consent.sh`

**Interfaces:**
- Produces: `ClipVaultViewModel.initialCaptureConsent` with compile-time probe behavior; `build_and_run.sh --verify` checks exact process liveness only.
- Consumes: `e2e_smoke.sh` already builds with `ENABLE_STORE_PROBE=true` and validates capture through the app-owned probe.

- [ ] **Step 1: Rewrite the shell regression to require zero sandbox defaults mutation**

Assert `build_and_run.sh` does not source `temporary_capture_consent.sh`, does not invoke `defaults`, and its verify block polls the exact staged binary. Assert the view model contains an `#if CLIPVAULT_E2E_PROBE` consent branch.

- [ ] **Step 2: Run the shell test and verify RED**

Run: `./script/test_build_and_run_consent.sh`

Expected: failure because the current verify flow still sources the helper and invokes `defaults`.

- [ ] **Step 3: Isolate E2E consent in the probe build**

```swift
private static var initialCaptureConsent: Bool {
    #if CLIPVAULT_E2E_PROBE
    true
    #else
    UserDefaults.standard.bool(
        forKey: ClipVaultSettingsKey.clipboardCaptureConsentGranted,
        default: false
    )
    #endif
}
```

Initialize `CaptureConsentPolicy` from this value. Remove the temporary defaults helper from the build script and repository.

- [ ] **Step 4: Make verify prove exact process liveness**

After `open -n`, poll the exact staged executable for up to 20 seconds, wait one additional second, and ensure the same PID remains alive. Print a specific failure if launch or stability fails.

- [ ] **Step 5: Verify shell, signed launch, and E2E GREEN**

Run `./script/test_shell.sh`, `./script/build_and_run.sh --verify`, and `./script/e2e_smoke.sh`. The ordinary verify path must not read or write the sandbox preference domain.

---

### Task 3: Pure Layout And Search Policies

**Files:**
- Modify: `Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift`
- Modify: `Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift`
- Modify: `Sources/ClipVaultCore/Services/SearchIndexCore.swift`
- Modify: `Tests/ClipVaultCoreTests/SearchIndexCoreTests.swift`

**Interfaces:**
- Produces: `AIWorkspaceLayoutPolicy.metrics(availableHeight:) -> AIWorkspaceLayoutMetrics`.
- Produces: a multi-term relevance floor in `ClipSearcher.search` while keeping empty-query ordering.

- [ ] **Step 1: Add failing compact-height tests**

```swift
let metrics = AIWorkspaceLayoutPolicy.metrics(availableHeight: 430)
#expect(metrics.detailMinimum + metrics.aiMinimum + metrics.dividerAllowance <= 430)
#expect(metrics.detailMinimum >= 150)
#expect(metrics.aiMinimum >= 210)
```

Also test regular height `720` retains larger practical minimums.

- [ ] **Step 2: Run the focused policy suite and verify RED**

Run: `swift test --filter WorkspacePresentationPolicyTests`

- [ ] **Step 3: Implement clamped layout metrics**

Use 150/210 compact floors, 280/320 regular preferences, an 8-point divider allowance, and proportional compression when the preferred sum exceeds available height.

- [ ] **Step 4: Add failing relevance tests**

Create exact, partial, and unrelated clips. Query `resizable responsive`; require the exact multi-term clip to rank first and unrelated clips to be absent.

- [ ] **Step 5: Tighten the relevance floor and verify GREEN**

Filter nonempty queries using a floor derived from normalized term count while preserving the existing impossible-query behavior. Run both focused suites and all Rust tests.

---

### Task 4: Stable Symbols, Selection, And Consent UX

**Files:**
- Modify: `Sources/ClipVault/Views/ClipVaultDesign.swift`
- Modify: `Sources/ClipVault/Views/MoveToCollectionMenu.swift`
- Modify: `Sources/ClipVault/App/ClipVaultViewModel.swift`
- Modify: `Sources/ClipVault/Views/SettingsView.swift`

**Interfaces:**
- Produces: `ClipVaultDesign.moveIcon = "folder"` and stable shared icon tokens.
- Produces: pin mutation that restores `selectedClipID` to the acted-on clip when still present.
- Produces: a confirmation binding around consent revocation.

- [ ] **Step 1: Replace the invalid move symbol**

Route the menu through `ClipVaultDesign.moveIcon`; use a long-supported symbol and retain the explicit `Move` label/accessibility text.

- [ ] **Step 2: Preserve selection across pin reload**

Capture `clip.id`, perform the store mutation and reload, then explicitly restore that ID if it still exists and remains visible. On failure, retain the previous selection.

- [ ] **Step 3: Add consent confirmation**

The destructive Settings button presents `Revoke Clipboard Capture Consent?`; confirmation calls the existing model method and Cancel has no effect.

- [ ] **Step 4: Build and run focused/full checks**

Run `swift build -Xswiftc -warnings-as-errors`, focused policy tests, and `./script/test.sh`.

---

### Task 5: Full macOS 27 Workspace Restyle

**Files:**
- Modify: `Sources/ClipVault/Views/ClipVaultDesign.swift`
- Modify: `Sources/ClipVault/Views/ClipVaultGlass.swift`
- Modify: `Sources/ClipVault/Views/ContentView.swift`
- Modify: `Sources/ClipVault/Views/SidebarView.swift`
- Modify: `Sources/ClipVault/Views/ClipListView.swift`
- Modify: `Sources/ClipVault/Views/ClipDetailView.swift`
- Modify: `Sources/ClipVault/Views/AIActionPanel.swift`

**Interfaces:**
- Consumes: Task 3 layout metrics and Task 4 shared symbols.
- Produces: one non-nested glass layer for action groups, adaptive sidebar footer, redesigned clip rows/detail hero, and safe AI split geometry.

- [ ] **Step 1: Expand the shared design tokens**

Add exact spacing/radius/icon-size values for compact padding `12`, regular padding `20`, row radius `10`, hero icon `44`, and grouped-control spacing `8`. Keep semantic tints centralized.

- [ ] **Step 2: Make glass composition structurally safe**

Keep `GlassEffectContainer` only around coherent button groups. Remove glass from text editors, result canvases, body cards, and any surface already inside a glass container. Older macOS retains native material fallbacks.

- [ ] **Step 3: Restyle the sidebar and footer**

Use `ViewThatFits` for full versus icon-only Add. Pair the capture dot with concise `Capturing`, `Paused`, or `Consent` copy. Preserve all folder/collection actions and accessibility metadata.

- [ ] **Step 4: Restyle list rows and header**

Use rounded selected backgrounds, a semantic kind tile, stronger title hierarchy, quiet metadata, pin state, and `N matches` during search. Keep current selection/copy/AI-selection behavior.

- [ ] **Step 5: Restyle detail as a hero plus quiet sections**

Place the kind tile beside editable title and metadata. Use one action group; keep Copy prominent and separate Delete. Replace large glass content cards and interactive glass TextEditor with native material/border sections.

- [ ] **Step 6: Apply safe AI layout metrics and action-group glass**

Read `AIWorkspaceLayoutPolicy.metrics(availableHeight:)` in `DetailWorkspaceView`. Use its minimums and ideals. Keep result canvas/composer ordinary, with a single glass group for AI actions and explicit Reduce Motion handling.

- [ ] **Step 7: Compile and inspect static regressions**

Run warnings-as-errors, `rg` for the invalid symbol, `rg` for nested `clipVaultGlassSurface` call patterns, and `git diff --check`.

---

### Task 6: macOS 27 Runtime Audit And Final Rebuild

**Files:**
- Modify: `docs/release-audit-2026-07-10.md` only if final evidence changes its claims.
- Modify: `docs/production-plan.md` only if remaining gates change.

**Interfaces:**
- Consumes: final `dist/ClipVault.app` and project-owned validation scripts.
- Produces: exact final gate results and weakest truthful readiness label.

- [ ] **Step 1: Run complete non-UI gates**

Run `./script/test.sh`, Release warnings-as-errors, strict Rust fmt/Clippy/tests, shell syntax/tests, signed launch verification, E2E smoke, strict codesign, plist/privacy/linkage checks, and App Store preflight.

- [ ] **Step 2: Exercise the exact signed app**

Verify minimum, regular, and large window sizes; sidebar adaptation; search; pin continuity; menu-bar copy; workspace single/double/Return semantics; AI actions; settings; reversible surface toggles; drag/drop; screenshot cancel/permission routing; and every destructive confirmation/cancel path.

- [ ] **Step 3: Audit accessibility and motion**

Inspect roles, labels, hints, keyboard focus, disabled states, Reduce Motion-aware code/runtime behavior, and light/dark appearance where controllable without changing unrelated system state.

- [ ] **Step 4: Audit performance and logs**

Sample idle CPU/RSS and inspect app error/fault logs after the interaction sweep. The invalid symbol, repeated glass update, and negative-geometry signatures must be absent.

- [ ] **Step 5: Rebuild the final signed app and review the diff**

Re-run `./script/build_and_run.sh --verify`, verify `dist/ClipVault.app`, inspect `git status`, `git diff --check`, and the complete intentional diff. Preserve all historical untracked audit directories.

- [x] **Step 6: Commit intentional files only after all repository-actionable gates pass**

Stage named source/test/script/spec/plan files, never `audits/`, and create cohesive local commits on `feat/andrzej_agent_sota_lab`. Do not push or merge without a separate user request.

---

## Execution Result — 2026-07-13

- Tasks 1–5 are complete. The deterministic test encryptor, sandbox-safe signed verification, pure layout policy, search regression coverage, symbol/selection/consent fixes, and full workspace restyle are implemented.
- Task 6 non-UI gates pass: 77 Swift tests in 15 suites, 4 Rust tests, Release Swift warnings-as-errors, Rust format and strict Clippy, shell syntax/regressions, signed launch, signed app-owned E2E capture/dedupe/persistence/relaunch, strict codesign, plist/privacy-manifest validation, and dynamic linkage inspection.
- The exact signed app passed live macOS 27 checks for the reachable 900-point three-column layout, workspace Add menu, stable Move/Pin semantics, AI shelf/actions, Settings roles and hints, screenshot workflow, and consent revoke confirmation/cancel without changing stored consent or clip count.
- Former app defects are closed: no invalid SF Symbol, repeated Liquid Glass update, or layout-recursion signature appears. A controlled ordinary launch also has no negative-geometry fault.
- Residual platform evidence is recorded rather than hidden: macOS 27 emits Core Spotlight donation and Apple GPU archive diagnostics; the OS accessibility-capture tool can trigger AppKit negative-geometry faults while snapshotting an otherwise healthy window. App Store preflight validates the local bundle and installed distribution identities, then exits fail-closed because this task did not create a current distribution `.pkg` plus dSYM pair.
- Final artifact: `/Users/s1kor/dev/andrzej/ClipVault/dist/ClipVault.app`. Historical untracked `audits/` directories remain untouched. No push, merge, upload, privacy-setting change, consent revocation, or destructive clip action was performed.
