# Unified Clip Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the split clip-detail/AI inspector with one readable workspace, inline AI state, and a reversible detail-only focus mode.

**Architecture:** `ContentView` continues to own `NavigationSplitViewVisibility` and adds explicit focus-mode state. `DetailWorkspaceView` becomes a single composition rather than a `VSplitView`; `AIActionPanel` is reduced to a compact command bar plus an inline result disclosure, both embedded in `ClipDetailView`'s one vertical hierarchy. Pure width and focus restoration decisions remain in `ClipVaultCore` for deterministic testing.

**Tech Stack:** Swift 6, SwiftUI for macOS 14+, Observation, Swift Testing, Swift Package Manager, existing ClipVault design helpers; no new dependencies.

## Global Constraints

- Preserve clip storage, encryption, capture, search, deduplication, AI provider, prompts, and generation semantics.
- Preserve Copy, Pin, Move, Delete, AI actions, Enhance Prompt, tags, notes, image annotation, and multi-selection behavior.
- Use one vertical content `ScrollView`; do not introduce `VSplitView` or a nested vertical AI result scroll.
- AI UI is absent when idle with no result or error; progress, result, cancellation, success, and error appear inline only when present.
- Provide an explicit detail-only focus mode and restore the last normal browser visibility.
- All compact controls require labels, help, hints, and keyboard reachability.
- Add no dependency and do not redesign the sidebar or clip list.

---

## File Structure

- `Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift`: pure focus-mode restoration and command-bar width policy; remove obsolete split-height policy.
- `Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift`: focused policy tests replacing split-height tests.
- `Sources/ClipVault/App/ClipVaultViewModel.swift`: explicit dismissal of presented AI state.
- `Tests/ClipVaultCoreTests/AIActionProviderTests.swift`: only if a core state type gains behavior; otherwise view-model dismissal is verified through an existing app test seam or compilation/runtime smoke.
- `Sources/ClipVault/Views/AIActionPanel.swift`: compact `AICommandBar` and `InlineAIResultView`; remove inspector/shelf/placement variants after migration.
- `Sources/ClipVault/Views/ClipDetailView.swift`: unified header, command bar, single scroll body, adaptive actions, and inline result placement.
- `Sources/ClipVault/Views/ContentView.swift`: explicit enter/restore focus behavior and simplified `DetailWorkspaceView`.
- `docs/superpowers/specs/2026-08-13-unified-clip-workspace-design.md`: authoritative approved behavior; no edits unless implementation reveals a genuine contradiction.

---

### Task 1: Pure Workspace Focus and Width Policy

**Files:**
- Modify: `Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift`
- Modify: `Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift`

**Interfaces:**
- Produces: `WorkspaceBrowserVisibility`, `WorkspaceFocusState`, `AICommandBarLayout`.
- Produces: `WorkspaceFocusState.enterFocus(from:)`, `WorkspaceFocusState.restore()`, and `AICommandBarLayout.init(width:)`.
- Removes: `AIWorkspaceDisclosurePolicy`, `AIWorkspaceLayoutMetrics`, and `AIWorkspaceLayoutPolicy` after callers migrate in Task 4.

- [ ] **Step 1: Write failing focus and width tests**

Add tests that establish exact restoration and breakpoint behavior:

```swift
@Test("focus mode restores the last browser visibility")
func focusModeRestoresBrowser() {
    var state = WorkspaceFocusState()
    #expect(state.enterFocus(from: .all) == .detailOnly)
    #expect(state.isFocused)
    #expect(state.restore() == .all)

    #expect(state.enterFocus(from: .contentAndDetail) == .detailOnly)
    #expect(state.restore() == .contentAndDetail)
}

@Test("command bar keeps all actions reachable at compact width")
func commandBarAdapts() {
    #expect(AICommandBarLayout(width: 540) == .expanded)
    #expect(AICommandBarLayout(width: 419) == .compact)
}
```

- [ ] **Step 2: Run focused tests and confirm RED**

Run:

```bash
swift test --filter WorkspacePresentationPolicyTests
```

Expected: compilation fails because `WorkspaceFocusState` and `AICommandBarLayout` do not exist.

- [ ] **Step 3: Implement the pure policies**

Add explicit, Sendable value types:

```swift
public enum WorkspaceBrowserVisibility: Equatable, Sendable {
    case all
    case contentAndDetail
    case detailOnly
}

public struct WorkspaceFocusState: Equatable, Sendable {
    public private(set) var isFocused = false
    private var restoreVisibility: WorkspaceBrowserVisibility = .all

    public mutating func enterFocus(
        from visibility: WorkspaceBrowserVisibility
    ) -> WorkspaceBrowserVisibility {
        if visibility != .detailOnly { restoreVisibility = visibility }
        isFocused = true
        return .detailOnly
    }

    public mutating func restore() -> WorkspaceBrowserVisibility {
        isFocused = false
        return restoreVisibility
    }
}

public enum AICommandBarLayout: Equatable, Sendable {
    case compact
    case expanded

    public init(width: Double) {
        self = width < 420 ? .compact : .expanded
    }
}
```

Extend the existing SwiftUI-to-core visibility mapping in `ContentView` during Task 4 rather than importing SwiftUI into core.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run `swift test --filter WorkspacePresentationPolicyTests`.

Expected: the new focus/width tests and existing sidebar-adaptation tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift
git commit -m "feat: define unified workspace presentation policy"
```

---

### Task 2: Explicit AI Presentation Dismissal

**Files:**
- Modify: `Sources/ClipVault/App/ClipVaultViewModel.swift`
- Test: use the nearest existing `ClipVaultViewModel` test file; if none exists, create `Tests/ClipVaultCoreTests/AIResultPresentationTests.swift` only for extracted pure state.

**Interfaces:**
- Produces: `ClipVaultViewModel.dismissAIResult()`.
- Consumes: existing `aiResult`, `aiError`, and `promptEnhancementState` properties.

- [ ] **Step 1: Add a failing pure-state test when extraction is necessary**

If app-target view models are not importable from the test target, extract this minimal state transition into core:

```swift
@Test("dismissal clears terminal AI presentation without touching active progress")
func dismissalPolicy() {
    #expect(AIPresentationDismissal.result.dismissed == .idle)
    #expect(AIPresentationDismissal.error.dismissed == .idle)
    #expect(AIPresentationDismissal.generating.dismissed == .generating)
}
```

Prefer a direct view-model test if the existing package target supports it; do not create a broad new abstraction solely for test access.

- [ ] **Step 2: Run the focused test and confirm RED**

Run the exact new test filter. Expected: missing dismissal interface or failed state expectation.

- [ ] **Step 3: Implement explicit dismissal**

Add a main-actor method with direct state transitions:

```swift
func dismissAIResult() {
    guard !isGenerating else { return }
    aiResult = nil
    aiError = nil
    switch promptEnhancementState {
    case .success, .failed, .cancelled:
        promptEnhancementState = .idle
    case .idle, .enhancing, .saving:
        break
    }
}
```

Do not clear the question, selected clip, selected clip IDs, or saved enhanced prompts.

- [ ] **Step 4: Run the focused test and confirm GREEN**

Expected: terminal state clears, active progress remains protected, and selected context is unchanged.

- [ ] **Step 5: Commit Task 2**

```bash
git add Sources/ClipVault/App/ClipVaultViewModel.swift Tests/ClipVaultCoreTests/AIResultPresentationTests.swift
git commit -m "feat: dismiss inline AI results safely"
```

If no new test file was required, stage only the modified source and the exact existing test file used.

---

### Task 3: Compact AI Command Bar and Inline Result

**Files:**
- Modify: `Sources/ClipVault/Views/AIActionPanel.swift`
- Modify: `Sources/ClipVault/Design/ClipVaultDesign.swift` only if an existing spacing/token cannot express the approved design.

**Interfaces:**
- Produces: `AICommandBar(model:)` and `InlineAIResultView(model:)`.
- Consumes: `AICommandBarLayout`, `ClipVaultViewModel.runAIAction(_:)`, `runPromptEnhancement()`, `cancelPromptEnhancement()`, `openPrompts()`, and `dismissAIResult()`.

- [ ] **Step 1: Add a compile-failing caller stub**

Temporarily migrate `DetailWorkspaceView` to reference the new names behind the current composition:

```swift
AICommandBar(model: model)
InlineAIResultView(model: model)
```

Run `swift build` and confirm failure because the new views do not exist. Revert only the temporary caller if it blocks isolated development; the final caller migration occurs in Task 4.

- [ ] **Step 2: Implement `AICommandBar`**

Build one adaptive bar:

```swift
struct AICommandBar: View {
    @Bindable var model: ClipVaultViewModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            expandedBar
            compactBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
```

`expandedBar` shows labeled Summarize, Explain, Action Items, and Enhance Prompt controls followed by one question field and Ask button. `compactBar` places the four actions in a labeled Menu and preserves the question field and Ask button. Reuse existing availability, disabled-state, help, accessibility, and selection-context calculations; remove the permanent header, badge, empty explanation, and duplicate Ask row.

- [ ] **Step 3: Implement `InlineAIResultView`**

Move existing result rendering without an inner `ScrollView`:

```swift
@ViewBuilder
var body: some View {
    if model.isGenerating || model.aiError != nil || model.aiResult != nil || model.promptEnhancementState != .idle {
        VStack(alignment: .leading, spacing: 12) {
            resultHeader
            resultContent
        }
        .padding(14)
        .clipVaultGlassSurface(cornerRadius: ClipVaultDesign.sectionRadius)
    }
}
```

Show a close button only for dismissible terminal states. Preserve Local fallback, cited count, progress, cancellation, saving, success, Open Prompts, and sanitized error copy.

- [ ] **Step 4: Remove legacy AI layouts after caller migration compiles**

Delete `AIActionPanelPlacement`, `inspectorLayout`, `inlineLayout`, `AIWorkspaceShelf`, split-pane collapse affordances, result-area minimum heights, permanent availability badge, and duplicate empty-state message. Keep small private helpers used by the two new components.

- [ ] **Step 5: Build and inspect warnings**

Run:

```bash
swift build
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: both builds exit 0 with no unused legacy declarations.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/ClipVault/Views/AIActionPanel.swift Sources/ClipVault/Design/ClipVaultDesign.swift
git commit -m "feat: integrate compact AI workspace controls"
```

Stage the design-token file only if it changed.

---

### Task 4: Compose the Unified Detail Workspace and Focus Mode

**Files:**
- Modify: `Sources/ClipVault/Views/ClipDetailView.swift`
- Modify: `Sources/ClipVault/Views/ContentView.swift`
- Modify: `Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift`
- Modify: `Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift`

**Interfaces:**
- Consumes: `AICommandBar(model:)`, `InlineAIResultView(model:)`, `WorkspaceFocusState`, and existing clip editors/actions.
- Produces: `ClipDetailView(model:isFocused:toggleFocus:)`.

- [ ] **Step 1: Change `ClipDetailView`'s interface and confirm compile RED**

Define the intended call shape at `DetailWorkspaceView`:

```swift
ClipDetailView(
    model: model,
    isFocused: isFocused,
    toggleFocus: toggleFocus
)
```

Run `swift build`. Expected: initializer mismatch until the view properties are added.

- [ ] **Step 2: Build the single hierarchy**

Refactor the selected-clip branch to:

```swift
VStack(spacing: 0) {
    ClipDetailHeader(
        clip: clip,
        model: model,
        isFocused: isFocused,
        toggleFocus: toggleFocus,
        requestDelete: { pendingDeleteClip = clip }
    )
    AICommandBar(model: model)
    Divider()
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            InlineAIResultView(model: model)
            clipBody(for: clip)
            clipMetadataAndEditors(for: clip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
    }
}
```

Do not render `AICommandBar` when there is neither an open clip nor explicit multi-selection. Keep the existing Select a Clip empty state otherwise.

- [ ] **Step 3: Adapt the clip header actions**

Use `ViewThatFits(in: .horizontal)` for labeled versus compact Copy/Pin controls. Keep Move and overflow reachable in both variants. Move Delete into the overflow Menu, retain its destructive role and existing confirmation dialog, and add the Focus/Restore Browser button with accurate label/help/accessibility text.

- [ ] **Step 4: Refine the reading surface by clip kind**

For text/prompt/error/link payloads, constrain only the text column to a readable maximum while allowing the workspace to expand:

```swift
Text(content)
    .textSelection(.enabled)
    .frame(maxWidth: 760, alignment: .leading)
```

For code and SQL, retain monospaced typography and add a horizontal `ScrollView` around the payload only. For images, retain fit-to-width behavior and place OCR/annotation below. Keep tags, notes, and collection chips after the primary content.

- [ ] **Step 5: Replace `DetailWorkspaceView` split behavior**

Remove `@AppStorage("aiWorkspaceExpanded")`, `VSplitView`, `AIWorkspaceLayoutPolicy`, selection-triggered expansion, and generation-triggered expansion. `DetailWorkspaceView` becomes a direct wrapper around `ClipDetailView` with focus properties supplied by `ContentView`.

- [ ] **Step 6: Implement explicit focus and restoration in `ContentView`**

Add `@State private var focusState = WorkspaceFocusState()` and map visibility explicitly:

```swift
private func toggleDetailFocus() {
    isApplyingAutomaticVisibility = true
    if focusState.isFocused {
        columnVisibility = navigationVisibility(for: focusState.restore())
    } else {
        columnVisibility = navigationVisibility(
            for: focusState.enterFocus(from: workspaceBrowserVisibility)
        )
    }
}
```

Guard `adaptSidebar(to:)` while `focusState.isFocused`. A manual system visibility change away from `.detailOnly` ends focus mode without losing the new manual state.

- [ ] **Step 7: Remove obsolete policies and tests**

Delete `AIWorkspaceDisclosurePolicy`, `AIWorkspaceLayoutMetrics`, `AIWorkspaceLayoutPolicy`, and their expansion/height tests once `rg` confirms zero production callers:

```bash
rg -n "AIWorkspaceDisclosurePolicy|AIWorkspaceLayoutPolicy|AIWorkspaceLayoutMetrics|aiWorkspaceExpanded|VSplitView" Sources Tests
```

Expected: zero matches after removal.

- [ ] **Step 8: Run focused and full tests**

```bash
swift test --filter WorkspacePresentationPolicyTests
./script/test.sh
```

Expected: focus/width policies pass and the complete Swift/Rust suite has zero failures.

- [ ] **Step 9: Commit Task 4**

```bash
git add Sources/ClipVault/Views/ContentView.swift Sources/ClipVault/Views/ClipDetailView.swift Sources/ClipVaultCore/Support/WorkspacePresentationPolicy.swift Tests/ClipVaultCoreTests/WorkspacePresentationPolicyTests.swift
git commit -m "feat: unify the clip detail workspace"
```

---

### Task 5: Runtime, Accessibility, and Visual Verification

**Files:**
- Modify only files required by verified defects found during this task.
- Record evidence in the plan progress log before branch integration.

**Interfaces:**
- Consumes the complete unified workspace.
- Produces a repo-ready branch with staged-app runtime evidence; it does not itself grant push, PR, merge, signing, notarization, or publication authority.

- [ ] **Step 1: Run static and automated gates**

```bash
cargo fmt --check --manifest-path rust/SearchIndexCore/Cargo.toml
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings
./script/test.sh
swift build -c debug
swift build -c release -Xswiftc -warnings-as-errors
git diff --check origin/main...HEAD
```

Expected: every command exits 0.

- [ ] **Step 2: Stage and exercise the signed app**

```bash
./script/build_and_run.sh --verify
./script/e2e_smoke.sh
```

Expected: staged bundle validation and capture/dedupe/persistence/restart smoke pass. Treat TCC, Developer ID, and notarization as separate gates.

- [ ] **Step 3: Inspect representative content in the running app**

Using the approved local Mac interaction workflow, inspect:

- long text/prompt;
- code or SQL with long lines;
- GitHub and ordinary links;
- image with OCR;
- AI generating, result, error/local fallback, and dismissed states;
- prompt enhancement progress and terminal states;
- no-selected-clip and multi-selection states.

At each state, verify content selection, action reachability, one vertical workspace scroll, and absence of a permanent empty AI panel.

- [ ] **Step 4: Verify window adaptation**

Render and inspect minimum, typical, wide, and detail-only focus layouts. Enter focus, resize the window, restore the browser, and confirm automatic sidebar adaptation does not override explicit focus. Check Dark mode, keyboard traversal, Reduce Motion, and long metadata. Check Light mode and Increased Contrast if available without changing system-wide security/privacy settings.

- [ ] **Step 5: Fix only observed blockers and rerun the smallest failed gate**

For each defect, add the smallest focused test when behavior can be isolated, implement the fix, rerun that focused test, then rerun the affected build/runtime path. Do not add unrelated visual redesign.

- [ ] **Step 6: Run final fresh verification and review the diff**

```bash
./script/test.sh
swift build -c release -Xswiftc -warnings-as-errors
git diff --check origin/main...HEAD
git status --short
git log --oneline origin/main..HEAD
```

Expected: tests and build pass, diff check is clean, and only intentional files/commits are present.

- [ ] **Step 7: Commit any verification fixes**

Stage exact files only and use a focused message such as:

```bash
git commit -m "fix: polish unified clip workspace adaptation"
```

Do not create an empty verification commit.

---

## Completion Bar

- The unified workspace matches every acceptance criterion in the approved design spec.
- Fresh automated, build, staged runtime, and rendered evidence is recorded.
- Any unavailable appearance/accessibility check is labeled `unverified`, not inferred.
- The branch remains unpushed and unmerged until the user chooses an integration option.
