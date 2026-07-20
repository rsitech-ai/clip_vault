# Menu Actions, Workspace Folders, and AI Pane Implementation Plan

> Historical implementation plan. Machine-local `/tmp` evidence paths below are not distributed artifacts and may no longer exist.

> **For Codex:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Make every completed menu-bar action dismiss the menu, make workspace folder management reliable and truthful, and rebuild the always-visible AI workspace as a compact native utility pane with a readable result area and pinned Ask composer.

**Architecture:** Keep `ClipVaultViewModel`, `ClipStore`, the Foundation Models provider, and the existing `NavigationSplitView`/`VSplitView` structure. Centralize menu dismissal in `MenuBarView`, expose only valid sidebar management actions, and give `AIActionPanel` separate inspector and inline presentation shells so the inline pane does not inherit the inspector card treatment.

**Tech Stack:** Swift 6, SwiftUI, AppKit interop for `NSWindow`, SwiftData, Swift Package Manager, XCTest, macOS Accessibility inspection, and the repository's build/run/E2E scripts.

**Design contract:** Implement against `docs/superpowers/specs/2026-07-09-menu-and-ai-workspace-design.md`. Use Apple's current macOS design resources as reference, without adding downloaded UI-kit assets to the repository: <https://developer.apple.com/design/resources/>.

---

## Task 1: Centralize dismiss-then-perform behavior in the menu bar

**Files:**
- Modify: `Sources/ClipVault/Views/MenuBarView.swift`

### Step 1: Record the failing runtime behavior

- [ ] Run `./script/build_and_run.sh --verify` and confirm `dist/ClipVault.app` launches.
- [ ] Activate Workspace, Shot, Settings, and Pause/Resume from the menu extra.
- [ ] Record the red condition: completed footer actions do not all dismiss reliably.
- [ ] Confirm row click/Enter already copies and dismisses, while search, scroll, Up/Down, hover, and Space preview intentionally stay open.

### Step 2: Add one synchronous menu action boundary

- [ ] Add `@Environment(\.openSettings) private var openSettings` beside the existing model property.
- [ ] Add these helpers beside `closeMenuWindow()`:

```swift
private func performAndClose(_ action: () -> Void) {
    closeMenuWindow()
    action()
}

private func captureAfterClosingMenu() {
    closeMenuWindow()
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(180))
        model.captureInteractiveScreenshot()
    }
}
```

`performAndClose` must execute the action even when the weak AppKit window reference is unavailable.

### Step 3: Route every completed footer action through the boundary

- [ ] Replace the footer action bodies with:

```swift
Button {
    performAndClose(openWorkspace)
} label: {
    Label("Workspace", systemImage: "rectangle.3.group")
}

Button {
    captureAfterClosingMenu()
} label: {
    Label("Shot", systemImage: "camera.viewfinder")
}

Button {
    performAndClose { openSettings() }
} label: {
    Label("Settings", systemImage: "gearshape")
}

Button {
    performAndClose { model.toggleCapture() }
} label: {
    Image(systemName: model.isCapturing ? "pause.circle" : "play.circle")
}
```

- [ ] Preserve all existing styles, help text, and accessibility labels.

### Step 4: Route row and keyboard commands through the same boundary

- [ ] Make `copyFromMenu` and `copyFocusedFromMenu` use `performAndClose`.
- [ ] Wrap the row completion closures:

```swift
openWorkspace: {
    performAndClose {
        model.selectedClipID = result.clip.id
        openWorkspace()
    }
},
togglePin: {
    performAndClose { model.togglePinned(result.clip) }
},
delete: {
    performAndClose { model.delete(result.clip) }
}
```

- [ ] Make keyboard Delete and P dismiss after completion. Keep Up, Down, and Space open.
- [ ] Verify context-menu actions reuse the same row closures.

### Step 5: Compile, run, and commit the focused menu slice

- [ ] Run `swift build -Xswiftc -warnings-as-errors`; expect exit 0 with no warnings.
- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] Verify row click/Enter, Workspace, Open in Workspace, Shot, Settings, Pause/Resume, Pin/Unpin, and Delete all dismiss after completion.
- [ ] Verify search, scroll, hover, Up/Down, and Space do not dismiss.
- [ ] Confirm Shot closes before the capture overlay.
- [ ] Commit only this slice:

```bash
git add Sources/ClipVault/Views/MenuBarView.swift
git commit -m "Fix menu action dismissal"
```

---

## Task 2: Finish reliable and truthful workspace folder management

**Files:**
- Modify: `Sources/ClipVault/Views/SidebarView.swift`
- Preserve/review existing modifications: `Sources/ClipVault/App/ClipVaultViewModel.swift`
- Preserve/review existing modifications: `Sources/ClipVaultCore/Services/ClipStore.swift`
- Modify tests as needed: `Tests/ClipVaultCoreTests/FolderTreeTests.swift`

### Step 1: Establish the model/store baseline

- [ ] Run `swift test --filter FolderTreeTests`.
- [ ] Expect create, rename/move, delete-with-clip-retention, built-in protection, title, and SwiftData persistence tests to pass.
- [ ] If a model/store test fails, repair that behavior before changing the UI.

### Step 2: Restrict management menus to valid nodes

- [ ] Add to `FolderNodeView`:

```swift
private var showsManagementMenu: Bool {
    folder.collectionID == nil || model.canManageWorkspaceFolder(folder)
}
```

- [ ] Render the trailing menu only when `showsManagementMenu` is true:

```swift
if showsManagementMenu {
    Menu {
        folderActions
    } label: {
        Image(systemName: "ellipsis.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .contentShape(Circle())
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .fixedSize()
    .help("Manage \(folder.title)")
    .accessibilityLabel("Manage \(folder.title)")
}
```

- [ ] Apply `.contextMenu` only to the managed branch. Built-in smart collections must not expose an empty context menu.

### Step 3: Expose assignment only for custom collections

- [ ] Replace the unconditional collection branch with:

```swift
if model.canManageWorkspaceFolder(folder),
   let collectionID = folder.collectionID {
    Button("Add Selected Clips Here") {
        model.addSelectedClips(toCollectionID: collectionID)
    }
}
```

- [ ] Preserve these contracts:
  - root/custom folders: New Subfolder and New Collection;
  - custom folders: Edit and Remove;
  - custom collections: Add Selected Clips Here, Edit, and Remove;
  - built-in smart collections: navigation only;
  - removing a workspace node never removes clips.

### Step 4: Keep management controls fixed and test the lifecycle

- [ ] Preserve the current `VStack` where `List`, `Divider`, and `sidebarFooter` are siblings.
- [ ] Do not move the footer back into `List.safeAreaInset`.
- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] Verify footer Folder and Collection create items, root creates nested items, custom nodes edit/move/remove, custom collections accept selected/open clips, built-ins have no ellipsis, and removed collections leave clips in All Clips.
- [ ] Scroll the tree fully and confirm the footer stays visible and exposes real `AXButton` roles.
- [ ] Run `swift test --filter FolderTreeTests`; expect all focused tests to pass.
- [ ] Review the existing unstaged model/store/test diff, then commit the complete slice:

```bash
git add Sources/ClipVault/App/ClipVaultViewModel.swift Sources/ClipVault/Views/SidebarView.swift Sources/ClipVaultCore/Services/ClipStore.swift Tests/ClipVaultCoreTests/FolderTreeTests.swift
git commit -m "Complete workspace folder management"
```

---

## Task 3: Rebuild the inline AI workspace as an always-visible utility pane

**Files:**
- Modify: `Sources/ClipVault/Views/AIActionPanel.swift`
- Modify only if runtime sizing requires it: `Sources/ClipVault/Views/ContentView.swift`
- Preserve/review existing modification: `Sources/ClipVault/Views/SettingsView.swift`

### Step 1: Capture the current red visual state

- [ ] Launch at a window size close to the user's screenshot.
- [ ] Capture the outer AI card, nested result/empty card, Ask composer above the response, and wasted vertical space.
- [ ] Trigger Explain and Ask with a real clip and confirm the response is clipped or subordinate to controls at the failing size.

### Step 2: Separate inspector and inline shells

- [ ] Replace the shared outer styling with:

```swift
@ViewBuilder
var body: some View {
    switch placement {
    case .inspector:
        inspectorLayout
            .padding(placement.contentPadding)
            .clipVaultGlassSurface(
                cornerRadius: ClipVaultDesign.panelRadius,
                tint: panelTint
            )
            .clipVaultPanelShadow(active: true)
            .padding(placement.outerPadding)
    case .inline:
        inlineLayout
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }
}

private var panelTint: Color {
    model.aiAvailability.isAvailable
        ? .accentColor.opacity(0.05)
        : .orange.opacity(0.08)
}
```

The inline pane must have no outer rounded card or shadow.

### Step 3: Put the response between the action toolbar and pinned composer

- [ ] Replace `inlineLayout` and `inlineControls` with:

```swift
private var inlineLayout: some View {
    VStack(alignment: .leading, spacing: 12) {
        header
        inlineActionToolbar

        inlineResultArea
            .frame(
                maxWidth: .infinity,
                minHeight: placement.resultMinimumHeight,
                maxHeight: .infinity,
                alignment: .topLeading
            )

        Divider()
        askRow
    }
}

private var inlineActionToolbar: some View {
    HStack(spacing: 8) {
        ForEach(Self.visibleActionKinds, id: \.self) { action in
            compactActionButton(for: action)
        }
        Spacer(minLength: 0)
    }
}
```

- [ ] Keep exactly Summarize, Explain, and Todos. Keep Email absent from the pane and the visible Settings action list.
- [ ] Preserve each colored SF Symbol, hover help, `AXButton` label, and accessibility hint.

### Step 4: Separate result content from inspector decoration

- [ ] Extract the existing states into:

```swift
@ViewBuilder
private var resultContent: some View {
    if model.isGenerating {
        ProgressView("Thinking")
            .frame(maxWidth: .infinity, alignment: .leading)
    } else if let error = model.aiError {
        Text(error)
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    } else if let result = model.aiResult {
        ScrollView {
            generatedResult(result)
        }
        .scrollIndicators(.visible)
    } else {
        emptyResultState
    }
}
```

- [ ] Retain glass only in the inspector:

```swift
private var resultArea: some View {
    resultContent
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipVaultGlassSurface(cornerRadius: ClipVaultDesign.sectionRadius)
}

private var inlineResultArea: some View {
    resultContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}
```

- [ ] Extract `generatedResult(_:)` and `emptyResultState` without changing result text, fallback labeling, citations, selection, or error semantics.

### Step 5: Show compact context and readiness

- [ ] Replace the header subtitle with:

```swift
private var contextText: String {
    if !model.selectedClips.isEmpty {
        return "\(model.selectedClips.count) clips selected"
    }
    if model.selectedClip != nil {
        return "Using open clip"
    }
    return "No clip available"
}
```

- [ ] Display `contextText` below `AI Workspace`; keep provider detail in status help.
- [ ] For inline placement, use:

```swift
private var inlineAvailabilityIndicator: some View {
    HStack(spacing: 5) {
        Circle()
            .fill(model.aiAvailability.isAvailable ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
        Text(model.aiAvailability.isAvailable ? "Ready" : "Fallback")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }
    .help(availabilityText)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(availabilityText)
}
```

- [ ] Keep the existing capsule only for `.inspector`; use a switch in `availabilityBadge` rather than adding abstraction.

### Step 6: Pin and clarify Ask

- [ ] Keep `askRow` after the bottom divider.
- [ ] Add:

```swift
private var askPlaceholder: String {
    model.selectedClips.isEmpty ? "Ask about the open clip" : "Ask selected clips"
}
```

- [ ] Bind `TextField(askPlaceholder, text: $model.question)` and preserve `model.canAskQuestion`, tint, help, and accessibility hint.

### Step 7: Verify resizing, response readability, and commit

- [ ] Run `swift build -Xswiftc -warnings-as-errors`.
- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] Verify minimum, typical, and tall heights: AI is always visible; divider resizing is smooth; header/actions/Ask remain visible; result gets flexible space and scrolls; long responses remain readable/selectable; there is no nested card or overlap.
- [ ] Inspect quick actions for `AXButton`, label, hint, and hover help.
- [ ] Modify only `aiMinimumHeight(for:)` in `ContentView.swift` if runtime proof shows the current `260`/`320` points block the accepted layout. Record before/after dimensions.
- [ ] Review and include the existing Settings Email-removal diff, then commit:

```bash
git add Sources/ClipVault/Views/AIActionPanel.swift Sources/ClipVault/Views/SettingsView.swift
git add Sources/ClipVault/Views/ContentView.swift  # only if modified
git commit -m "Redesign the inline AI workspace"
```

---

## Task 4: Run the complete release-oriented verification pass

**Files:**
- Modify: `docs/production-plan.md`
- Review: every file changed by Tasks 1-3

### Step 1: Review the branch diff

- [ ] Run:

```bash
git status --short
git diff --check
git diff --stat HEAD~3..HEAD
```

- [ ] Confirm no generated UI-kit assets, audit directories, or unrelated files are staged.
- [ ] Inspect every changed source file for force unwraps, detached tasks, duplicate actions, empty context menus, hidden errors, and visible Email controls.

### Step 2: Run all automated checks

- [ ] Run `./script/test.sh`; expect all Rust and Swift tests to pass.
- [ ] Run `swift build -c release -Xswiftc -warnings-as-errors`; expect exit 0 and no warnings.
- [ ] Run `./script/e2e_smoke.sh`; expect capture, dedupe, persistence, and restart recovery to pass.

### Step 3: Run the final UI and accessibility matrix

- [ ] Run `./script/build_and_run.sh --verify`.
- [ ] Repeat every dismissing/non-dismissing menu path from Task 1.
- [ ] Repeat every folder lifecycle path from Task 2.
- [ ] Run Explain, Summarize, Todos, and Ask with the open clip fallback and multiple selected clips.
- [ ] Verify result scrolling, selection, resizing, compact-button help, minimum/large window sizes, and light/dark appearances where available.
- [ ] Save evidence outside the repository:

```text
/tmp/clipvault-menu-final.png
/tmp/clipvault-workspace-folders-final.png
/tmp/clipvault-ai-result-final.png
```

- [ ] Confirm folder footer and AI controls expose `AXButton`/`AXMenuButton`, never `AXUnknown`.

### Step 4: Inspect logs and idle behavior

- [ ] Run:

```bash
log show --last 10m --style compact --predicate 'process == "ClipVault"' | rg -i "error|fault|crash|failed|warning"
```

Expected: no ClipVault-authored error, fault, crash, or repeated warning caused by the tested flows. Classify unrelated system messages explicitly.

- [ ] Run:

```bash
ps -o pid,%cpu,rss,etime,command -p "$(pgrep -x ClipVault | head -1)"
```

Expected: responsive process and settled idle CPU, with no sustained update loop. Compare qualitatively with prior evidence; do not invent a threshold from one sample.

### Step 5: Record evidence and commit documentation

- [ ] Add a dated row to `docs/production-plan.md` covering menu dismissal, folder lifecycle, always-visible AI results, exact commands, AX/screenshot/log/process evidence, and external signing blockers separately from repo readiness.
- [ ] Run `git diff --check` and `git status --short`.
- [ ] Commit only the documentation:

```bash
git add docs/production-plan.md
git commit -m "Document menu and workspace verification"
```

### Step 6: Final review gate

- [ ] Review the complete branch against the approved design specification.
- [ ] Confirm every acceptance criterion has fresh runtime or automated evidence.
- [ ] Do not merge or install over the user's current app until all checks are green and the final diff contains only intended files.
