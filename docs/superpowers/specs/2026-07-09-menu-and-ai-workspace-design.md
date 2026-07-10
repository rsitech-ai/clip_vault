# ClipVault Menu Bar and AI Workspace Design

Date: 2026-07-09
Status: Implemented; App Review payment amendment applied 2026-07-10

## Context

ClipVault is a local-first macOS clipboard workspace with a normal app window and a menu bar extra. The current feature set is sound, but three interface problems remain:

1. Only copying a clip dismisses the menu bar window. Other completed commands leave it open.
2. The always-visible AI workspace is rendered as a rounded glass card inside the lower split pane, with another rounded result card inside it. This creates excessive chrome and unused idle space.
3. The workspace sidebar exposes management ellipses on built-in smart collections even though those items cannot be edited or removed. The add controls must also remain reliably clickable outside the scrolling list.

The primary product workflow remains fast clipboard retrieval and reuse. AI should support that workflow without turning the app into a dashboard.

## Goals

- Close the menu bar window after every completed command.
- Keep navigation interactions inside the menu bar window open.
- Keep the AI workspace always visible and vertically resizable.
- Make the AI workspace read as a native lower utility pane rather than a floating card.
- Give AI output the largest share of the lower pane.
- Keep custom folder and collection management discoverable and reliable.
- Remove misleading management affordances from protected smart collections.
- Preserve native macOS pointer, keyboard, accessibility, material, and split-view behavior.

## Non-Goals

- No new AI actions or model providers.
- No Email action.
- No automatic deletion or renaming of existing user folders or collections, including duplicate titles.
- No replacement of `NavigationSplitView`, `VSplitView`, SwiftData, or the current view model architecture.
- No custom titlebar, custom sidebar renderer, or animation-heavy redesign.
- No App Store packaging or signing changes in this slice.

## Design Reference

Apple Design Resources was refreshed on 2026-07-09. The current page lists the macOS 27 UI Kit, SF Symbols 8 beta, SF Symbols 7, and Icon Composer. These resources are reference inputs for hierarchy, control density, and icon vocabulary. Implementation remains native SwiftUI with availability-gated modern material APIs because ClipVault supports older macOS releases.

Source: https://developer.apple.com/design/resources/

## Menu Bar Interaction Contract

### Dismiss after completion

The menu bar window closes before these actions execute:

- copy a clip
- open a clip in Workspace
- open Workspace from the footer
- start Shot capture
- open Settings
- pause or resume clipboard capture
- pin or unpin a clip
- delete a clip

The same rule applies whether an action comes from a visible button, a row context menu, or a keyboard command.

### Remain open during navigation

The menu bar window remains open for:

- search field editing
- scrolling
- pointer hover and preview changes
- up and down keyboard navigation
- locking or unlocking the preview with Space

These interactions do not complete a command and should not interrupt retrieval.

### Action sequencing

`MenuBarView` owns one named dismiss-then-perform path. It closes the captured `NSWindow` first and then invokes the action on the main actor.

Most commands may run on the next main-loop turn. Shot capture waits briefly after dismissal before starting the screenshot controller so the menu window cannot appear in the captured area. Settings failures retain their existing user feedback behavior.

The AppKit boundary remains limited to the existing weak menu window reference and `NSWindow.orderOut`. SwiftUI and `ClipVaultViewModel` remain the sources of truth for action state.

## AI Workspace Layout

### Structure

The inline AI workspace becomes the full content of the lower `VSplitView` pane:

1. compact header
2. compact action toolbar
3. flexible result canvas
4. divider
5. pinned Ask composer

The pane remains always visible. The existing split handle continues to control its height, subject to practical minimum heights for the detail and AI areas.

### Header

The header contains:

- `AI Workspace` as the primary label
- a compact context label: `Using open clip`, `N clips selected`, or `No clip available`
- a small readiness indicator on the trailing edge

Readiness uses a status dot or compact symbol plus text. It must not use a large decorative capsule.

### Action toolbar

The toolbar contains compact Summarize, Explain, and Todos buttons. Each button:

- remains a real SwiftUI `Button`
- uses a standard SF Symbol
- uses restrained semantic tinting
- has a stable 30-34 point hit target
- exposes a descriptive hover tooltip
- exposes an accessibility label and hint
- disables consistently while generation is active

No Email action is shown.

### Result canvas

The result canvas is unframed and consumes the flexible space between the toolbar and composer. It supports:

- empty context state
- generating state
- error state
- model result with scrolling and text selection
- fallback marker and cited clip count when applicable

The empty state is compact and aligned near the top. It does not create a large nested card. Generated content uses the whole available width and remains readable at the minimum pane height.

### Ask composer

The Ask text field and button stay pinned to the bottom of the pane. The Ask button remains disabled until a non-empty question exists and generation is idle. Existing help text explains the disabled state.

### Surface treatment

The inline placement removes its outer rounded glass surface, panel shadow, and outer padding. The split pane and native separator provide the boundary. Custom glass remains limited to the compact interactive action controls where it conveys affordance.

The inspector placement, if still used elsewhere, may retain a contained presentation.

## Sidebar Behavior

### Fixed footer

The sidebar uses a normal vertical layout:

- scrolling source list
- divider
- fixed Folder and Collection actions
- capture status

The footer is not embedded in the list's safe-area inset. This keeps its controls in a stable hit-testing and presentation context.

### Row actions

- The root Collections folder exposes New Subfolder and New Collection.
- Custom folders expose New Subfolder, New Collection, Edit, and Remove.
- Custom collections expose Add Selected Clips Here, Edit, and Remove.
- Built-in smart collections expose no management ellipsis and no assignment action.
- Built-in items remain protected from edit and removal.

Collection titles select their collection. Folders with children expand and collapse. Empty folders are non-actionable labels with a management menu.

### Destructive behavior

Removing a custom folder or collection requires confirmation. The dialog states that clips remain in ClipVault. Cancel and confirm paths must both be exercised in the running app.

## Accessibility

- All actionable controls expose `AXButton` or `AXMenuButton`, not `AXUnknown`.
- Icon-only controls have action-oriented help, labels, and hints.
- Empty folders are not announced as buttons.
- Selection, focus, and disabled states remain visible.
- Menu dismissal does not steal focus from the newly opened Workspace, Settings, browser, or screenshot flow.
- The pane remains usable with increased contrast and Reduce Motion.

## Error Handling

- Missing menu window references must not block the requested action.
- Screenshot capture begins only after menu dismissal.
- AI errors remain visible in the result canvas and do not collapse the pane.
- Folder validation errors continue through the view model/store boundary without deleting clips.

## Verification Plan

### Build and tests

- `swift build -Xswiftc -warnings-as-errors`
- `swift test --filter FolderTreeTests`
- `./script/test.sh`
- `./script/build_and_run.sh --verify`
- `git diff --check`

### Menu bar runtime sweep

Verify the popover closes after every completed footer, clip, context-menu, and keyboard command. Verify search, scrolling, hover preview, up/down navigation, and Space preview lock keep it open. Confirm Shot starts only after the menu is gone.

### Sidebar runtime sweep

Create a temporary folder and collection, rename them, exercise both removal-cancel and removal-confirm, and clean up the temporary records. Confirm built-ins have no misleading management menu. Confirm collection selection and folder disclosure behavior.

### AI runtime sweep

At minimum, typical, and large window sizes:

- drag the horizontal split handle in both directions
- verify the pane remains visible
- run Summarize, Explain, Todos, and Ask
- confirm responses are visible and scrollable
- inspect all compact actions for hover help and `AXButton` roles
- verify empty, generating, error, and result layouts do not overlap or create nested cards

### Logs

After the interaction sweep, inspect ClipVault-authored error and fault logs with `/usr/bin/log`. The audited flows must not produce app errors, faults, crashes, or repeated failures.

## Acceptance Criteria

- Every completed menu bar command dismisses the menu window exactly once.
- Navigation-only menu interactions do not dismiss it.
- The AI workspace is always visible, resizable, and visually integrated with the lower split pane.
- AI output receives flexible space and the Ask composer remains pinned at the bottom.
- No nested outer AI card or oversized idle-state card remains.
- Left-panel add, edit, remove, selection, and disclosure behavior works in the running Release app.
- Built-in smart collections do not display invalid management actions.
- Full tests, Release launch, interaction smoke, accessibility inspection, screenshots, and ClipVault-authored logs are clean.
