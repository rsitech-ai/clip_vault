# On-Demand Clip Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide clip-row AI-selection circles during normal browsing and reveal them only through a top-right **Select Clips** mode that exits with **Done** without clearing the selected clips.

**Architecture:** Add a small pure `ClipSelectionMode` presentation type to `ClipVaultCore` so browsing/selecting semantics and header copy are testable without SwiftUI. `ClipListView` owns the transient mode while `ClipVaultViewModel.selectedClipIDs` remains the unchanged source of truth for AI selection.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, SwiftPM, AppKit, existing ClipVault build and runtime scripts.

## Global Constraints

- Support macOS 15+.
- Add no dependency, persistence change, data migration, AI behavior change, or clip-content editing.
- Keep single-click selection, double-click copy, Return-to-copy, drag and drop, cleanup, and row context-menu behavior unchanged.
- Preserve `selectedClipIDs` when **Done** leaves selection mode.
- Preserve all existing untracked audit and documentation directories.
- Do not push, merge, upload, publish, or change external Apple state.

---

### Task 1: On-Demand Clip Selection Mode

**Files:**
- Modify: `Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift`
- Modify: `Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift`
- Modify: `Sources/ClipVault/Views/ClipListView.swift`

**Interfaces:**
- Produces: `ClipSelectionMode` with `.browsing`, `.selecting`, `showsSelectionControls: Bool`, and `headerActionTitle: String`.
- Consumes: existing `ClipVaultViewModel.selectedClipIDs` and `ClipVaultViewModel.select(_:)` without changing either interface.

- [ ] **Step 1: Add the failing normal-browsing presentation test**

Append this test to `WorkspacePresentationPolicyTests`:

```swift
@Test("normal browsing hides AI selection controls")
func normalBrowsingHidesAISelectionControls() {
    let mode = ClipSelectionMode.browsing

    #expect(!mode.showsSelectionControls)
    #expect(mode.headerActionTitle == "Select Clips")
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter WorkspacePresentationPolicyTests.normalBrowsingHidesAISelectionControls
```

Expected: compilation fails because `ClipSelectionMode` does not exist.

- [ ] **Step 3: Implement only the browsing presentation**

Add to `WorkspacePresentationPolicy.swift`:

```swift
public enum ClipSelectionMode: Equatable, Sendable {
    case browsing

    public var showsSelectionControls: Bool { false }

    public var headerActionTitle: String { "Select Clips" }
}
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2. Expected: one selected test passes.

- [ ] **Step 5: Add the failing active-selection presentation test**

Append this second test:

```swift
@Test("selection mode shows controls and offers Done")
func selectionModeShowsControlsAndOffersDone() {
    let mode = ClipSelectionMode.selecting

    #expect(mode.showsSelectionControls)
    #expect(mode.headerActionTitle == "Done")
}
```

- [ ] **Step 6: Run the focused suite and verify RED**

Run:

```bash
swift test --filter WorkspacePresentationPolicyTests
```

Expected: compilation fails because `.selecting` does not exist.

- [ ] **Step 7: Complete the two-state presentation policy**

Replace the temporary browsing-only enum with:

```swift
public enum ClipSelectionMode: Equatable, Sendable {
    case browsing
    case selecting

    public var showsSelectionControls: Bool {
        self == .selecting
    }

    public var headerActionTitle: String {
        switch self {
        case .browsing: "Select Clips"
        case .selecting: "Done"
        }
    }
}
```

- [ ] **Step 8: Run the focused suite and verify GREEN**

Run `swift test --filter WorkspacePresentationPolicyTests`. Expected: every workspace-presentation test passes.

- [ ] **Step 9: Wire the mode into `ClipListView`**

Add view-local state:

```swift
@State private var selectionMode: ClipSelectionMode = .browsing
```

Pass the mode into each row:

```swift
ClipRowView(
    result: result,
    showsSelectionControl: selectionMode.showsSelectionControls,
    isSelectedForAI: model.selectedClipIDs.contains(result.clip.id),
    toggleAISelection: {
        model.select(result.clip)
    }
)
```

Add `var showsSelectionControl: Bool` immediately after `var result: SearchResult` in `ClipRowView`. Wrap the existing leading circle button in:

```swift
if showsSelectionControl {
    Button(action: toggleAISelection) {
        Image(systemName: isSelectedForAI ? "checkmark.circle.fill" : "circle")
            .font(.callout.weight(.semibold))
            .foregroundStyle(isSelectedForAI ? Color.accentColor : Color.secondary)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(isSelectedForAI ? "Remove clip from AI selection" : "Add clip to AI selection")
    .accessibilityLabel(isSelectedForAI ? "Remove clip from AI selection" : "Add clip to AI selection")
    .accessibilityValue(isSelectedForAI ? "Selected" : "Not selected")
}
```

Replace the existing overflow `Menu` block with this mode-aware header action:

```swift
if selectionMode == .selecting {
    Button(selectionMode.headerActionTitle) {
        selectionMode = .browsing
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help("Finish selecting clips")
    .accessibilityLabel("Done selecting clips")
} else {
    Menu {
        Button(selectionMode.headerActionTitle) {
            selectionMode = .selecting
        }
        Divider()
        Button("Bulk Cleanup") {
            showCleanup = true
        }
        Button("Clear Unpinned Clips", role: .destructive) {
            confirmClearUnpinned = true
        }
    } label: {
        Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.button)
    .fixedSize()
    .help("Open clip list actions")
    .accessibilityLabel("Open clip list actions")
}
```

Do not mutate `model.selectedClipIDs` in either header action. Rename the browsing menu help and accessibility label to **Open clip list actions**.

- [ ] **Step 10: Compile and run focused/full automated verification**

Run:

```bash
swift test --filter WorkspacePresentationPolicyTests
swift build -Xswiftc -warnings-as-errors
./script/test.sh
git diff --check
```

Expected: all commands exit zero, and the full suite retains existing Rust and Swift behavior.

- [ ] **Step 11: Verify the signed running app**

Run `./script/build_and_run.sh --verify`, then exercise the exact staged app:

- normal rows begin with the clip-kind thumbnail and contain no leading circles;
- the top-right menu contains **Select Clips**, **Bulk Cleanup**, and **Clear Unpinned Clips**;
- **Select Clips** reveals the circles and replaces the menu with **Done**;
- selecting two clips updates the `2 selected` badge;
- **Done** hides the circles but keeps the badge and AI selection;
- reopening **Select Clips** restores both visible checkmarks;
- single-click, double-click or Return copy, context-menu selection, search, and cleanup presentation remain unchanged;
- unified logs show no new ClipVault error/fault, invalid-symbol, or repeated-glass-update signal.

- [ ] **Step 12: Record evidence and commit only intentional files**

Update this plan with exact focused/full/build/runtime results. Stage only:

```bash
git add \
  Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift \
  Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift \
  Sources/ClipVault/Views/ClipListView.swift \
  docs/superpowers/plans/2026-07-15-on-demand-clip-selection.md
git commit -m "feat: add on-demand clip selection mode"
```

Do not stage existing untracked `audits/`, `docs/monetization/`, or `docs/plans/` content.

## Rollback

Revert the focused implementation commit. The change owns presentation state only, so rollback requires no data migration and does not alter stored clips or AI selection data.
