# ClipVault Interface Craft Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the workspace content-first and native by adding progressive AI disclosure, clear select/copy semantics, compact-width adaptation, and restrained motion/materials.

**Architecture:** Add platform-neutral presentation decisions to `ClipVaultCore` so width and auto-expansion behavior are covered with failing-first tests. Keep SwiftUI state in `ContentView` and `DetailWorkspaceView`; preserve the existing view model, stores, menu-bar copy workflow, and `VSplitView` when AI is expanded.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, SwiftPM, AppKit-backed macOS runtime, Computer Use, Rust SearchIndexCore, existing build/E2E/release scripts.

## Global Constraints

- Support macOS 15+; availability-gate macOS 26 Liquid Glass.
- Add no dependency, cloud provider, persistence migration, or new destructive behavior.
- Preserve one-click menu-bar copy; change only full-workspace row semantics.
- Keep historical untracked `audits/` directories untouched and unstaged.
- Run destructive UI only through cancel paths against the user's persisted store.
- Merge only after full local verification, hosted PR review, and any configured checks pass.

---

### Task 1: Presentation Policies

**Files:**
- Create: `Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift`
- Create: `Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift`

**Interfaces:**
- Produces: `WorkspaceWidthClass`, `WorkspaceSidebarState`, `WorkspaceSidebarAdaptation`, and `AIWorkspaceDisclosurePolicy`.
- Consumers: `ContentView` and `DetailWorkspaceView` in Task 2.

- [ ] **Step 1: Write failing width/adaptation tests**

Test these exact behaviors with Swift Testing:

```swift
#expect(WorkspaceWidthClass(width: 1_039) == .compact)
#expect(WorkspaceWidthClass(width: 1_040) == .regular)

var adaptation = WorkspaceSidebarAdaptation()
#expect(adaptation.update(width: 900, current: .all) == .contentAndDetail)
#expect(adaptation.update(width: 1_200, current: .contentAndDetail) == .all)

adaptation.recordManualVisibilityChange()
#expect(adaptation.update(width: 1_200, current: .contentAndDetail) == nil)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter WorkspacePresentationPolicyTests`

Expected: compilation fails because the policy types do not exist.

- [ ] **Step 3: Implement the minimal pure policies**

Use a 1040-point breakpoint. `WorkspaceSidebarAdaptation.update` returns a target only when entering compact width from `.all` or restoring a sidebar that it previously hid. `recordManualVisibilityChange` clears automatic restoration ownership.

- [ ] **Step 4: Add and verify failing AI disclosure tests, then implement**

```swift
#expect(AIWorkspaceDisclosurePolicy.shouldExpand(previousSelectionCount: 0, selectionCount: 1))
#expect(!AIWorkspaceDisclosurePolicy.shouldExpand(previousSelectionCount: 1, selectionCount: 2))
#expect(AIWorkspaceDisclosurePolicy.shouldExpandForGeneration(isGenerating: true))
```

Run the focused test after each red/green step and keep public APIs `Sendable` and `Equatable` where meaningful.

- [ ] **Step 5: Commit the tested policy slice**

```bash
git add Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift
git commit -m "Add workspace presentation policies"
```

---

### Task 2: Progressive AI And Compact Columns

**Files:**
- Modify: `Sources/ClipVault/Views/ContentView.swift`
- Modify: `Sources/ClipVault/Views/AIActionPanel.swift`

**Interfaces:**
- Consumes: Task 1 presentation policies.
- Produces: persisted AI disclosure, compact AI shelf, and automatic sidebar adaptation.

- [ ] **Step 1: Bind `NavigationSplitView` visibility**

Add `@State` for `NavigationSplitViewVisibility`, `WorkspaceSidebarAdaptation`, and an automatic-update guard. Wrap the workspace in a `GeometryReader`; call the policy on appear and width change. Map `.all` and `.contentAndDetail` between core and SwiftUI types. Clear automatic ownership when a user-driven visibility change occurs.

- [ ] **Step 2: Add persisted AI disclosure**

Add `@AppStorage("aiWorkspaceExpanded") private var isAIExpanded = false` and `@Environment(\.accessibilityReduceMotion)`. In collapsed state, render a 48-point shelf with context/readiness text and a `chevron.up` expand button. In expanded state, retain `VSplitView` and provide a collapse closure to `AIActionPanel`.

- [ ] **Step 3: Add automatic expansion triggers**

Expand only on an empty-to-nonempty AI selection transition or when `model.isGenerating` becomes true. Do not automatically collapse. Use a short opacity/layout transition only when Reduce Motion is off.

- [ ] **Step 4: Expose the inline collapse action**

Add an optional `collapse` closure to `AIActionPanel`. Show an icon-only `chevron.down` button only for inline placement, with help text and accessibility label `Collapse AI Workspace`.

- [ ] **Step 5: Compile and run policy/full tests**

Run:

```bash
swift test --filter WorkspacePresentationPolicyTests
swift build -Xswiftc -warnings-as-errors
```

Expected: both exit zero without warnings.

---

### Task 3: Workspace Semantics And Visual Restraint

**Files:**
- Modify: `Sources/ClipVault/Views/ClipListView.swift`
- Modify: `Sources/ClipVault/Views/MenuBarView.swift`
- Modify: `Sources/ClipVault/Views/SidebarView.swift`

**Interfaces:**
- Consumes: existing `ClipVaultViewModel.copyToClipboard`, `select`, and folder prompt actions.
- Produces: browse-first workspace rows, explicit AI selection, one Add menu, immediate repeated interactions, and quieter navigation color/material.

- [ ] **Step 1: Change workspace row activation**

Remove single-click `selectAndCopy`. Let `List(selection:)` own single-click selection, add double-click copy, and add Return-key copy while the list is focused. Keep the detail Copy button and all menu-bar copy behavior unchanged.

- [ ] **Step 2: Make AI selection explicit**

Render a dedicated `circle` / `checkmark.circle.fill` button before the existing noninteractive thumbnail. Give it action-oriented help, accessibility label, and selected value. Remove button behavior from the thumbnail itself.

- [ ] **Step 3: Replace footer actions with one Add menu**

Use a small `Menu` labeled `Add` containing `New Folder` and `New Collection`, routing to the existing `SidebarPrompt` values. Keep the capture indicator below it.

- [ ] **Step 4: Restrain material and color**

Remove custom glass from the static clip-list header and sidebar footer; use standard material plus native dividers. Use secondary/accent navigation glyphs, preserving red only for Errors and rich type colors in clip rows.

- [ ] **Step 5: Remove high-frequency movement**

Delete the list-wide result animation and keyboard `withAnimation` around menu scrolling. Change menu preview transition to opacity only and scope a 100–120 ms ease-out to pointer hover changes.

- [ ] **Step 6: Build and run full tests**

Run `./script/test.sh` and `swift build -c release -Xswiftc -warnings-as-errors`.

---

### Task 4: Native Runtime And Audit Evidence

**Files:**
- Modify: `docs/release-audit-2026-07-10.md`
- Modify: `docs/production-plan.md`

**Interfaces:**
- Consumes: final signed app and package scripts.
- Produces: updated scenario matrix, before/after findings, evidence, and readiness label.

- [ ] **Step 1: Rebuild and relaunch the signed app**

Run `./script/build_and_run.sh --verify`. Confirm only `dist/ClipVault.app` supplies runtime evidence.

- [ ] **Step 2: Exercise real UI paths**

With Computer Use, verify compact auto-collapse, regular restoration, AI shelf expand/collapse, selection-triggered and generation-triggered expansion, single-click non-copy, double-click/Return copy, explicit AI selection, Add menu, search, Settings, resize, and destructive cancel flows.

- [ ] **Step 3: Run the full audit matrix**

Run full tests, ASan, Release warnings, Rust fmt/Clippy/release tests/audit, shell syntax, live E2E, subsystem logs, idle sampling, App Store preflight, package creation, strict codesign, installer signature, linkage, privacy manifest, entitlements, and diff hygiene.

- [ ] **Step 4: Update audit documents**

Record exact commands/results, screenshot paths, artifact hash, findings/fixes, blocked status-item or clean-account work, and the weakest truthful readiness label.

---

### Task 5: Review, PR, Merge, And Post-Merge Proof

**Files:**
- Review every path in `git diff main...HEAD`.

**Interfaces:**
- Produces: reviewed PR and verified merged `main`.

- [ ] **Step 1: Inspect and stage intentionally**

Run `git diff --check`, secret/dead-code scans, full diff review, and stage tracked work plus named new files only. Do not stage `audits/`.

- [ ] **Step 2: Commit and push the required branch**

Commit coherent changes, push `feat/andrzej_agent_sota_lab`, and verify the remote head equals local `HEAD`.

- [ ] **Step 3: Create and review a ready PR**

Create a ready PR against `main`, inspect hosted files/commits/comments/checks, resolve every actionable issue, and record local verification when the repository has no CI checks.

- [ ] **Step 4: Merge only when clean**

Merge with repository-supported history, fetch, fast-forward local `main`, and verify `main == origin/main`.

- [ ] **Step 5: Repeat post-merge proof**

Run `./script/test.sh`, Release warnings-as-errors, signed E2E, App Store preflight, strict package validation, artifact hash, and clean subsystem log filter on merged `main`.
