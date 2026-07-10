# ClipVault Interface Craft Polish Design

Date: 2026-07-10
Status: Approved by the user for implementation

## Goal

Make ClipVault feel like a fast, native, menu-bar-first clipboard tool by returning visual priority to clip content, clarifying workspace interactions, adapting cleanly to compact windows, and removing decorative motion and material that compete with the content.

## Product Contract

- Menu-bar rows keep one-click copy behavior.
- Workspace rows use native browser semantics: one click selects and opens, while double-click, Return, or the visible Copy action copies.
- AI remains available but is secondary until requested.
- No new dependency, model provider, cloud path, or data migration is introduced.
- Existing folder, search, capture, persistence, signing, and App Store behavior stays unchanged.
- The app continues to support macOS 15+, with macOS 26 Liquid Glass behind availability checks.

## AI Workspace Disclosure

The detail area shows a compact AI shelf by default. The shelf is 48 points high and contains:

- `AI Workspace`
- the current context (`Using open clip`, selected count, or no clip)
- the current readiness state
- a clear expand affordance

Selecting the shelf expands the existing adjustable AI pane. The pane also expands when the AI selection changes from empty to nonempty or generation starts. Expansion is persisted with `AppStorage`; the pane never collapses automatically. The expanded header contains one collapse control adjacent to the content it hides.

When expanded, the current `VSplitView` remains adjustable. At compact heights, the AI minimum becomes 270 points so the result canvas and composer remain usable without taking half the window by default. Reduce Motion disables explicit expansion/collapse animation.

## Workspace Interaction Semantics

The workspace list is for browsing and inspection:

- single click selects the row and updates detail without changing the pasteboard;
- double-click copies the selected clip;
- Return copies when the list owns keyboard focus;
- the detail Copy button remains the visible primary action;
- menu-bar row click continues to copy immediately.

AI selection becomes a dedicated check-circle control before the clip thumbnail. The kind thumbnail stops acting as a hidden selection toggle. The selection control exposes stable help, accessibility label, and selected state.

## Compact Window Adaptation

The three-column workspace remains the regular presentation. Below 1040 points, ClipVault automatically hides the sidebar and shows the content list plus detail. When the window returns above 1040 points, the sidebar is restored only if ClipVault hid it automatically; a manual sidebar choice is preserved.

The sidebar footer replaces the two truncating Folder and Collection buttons with one `Add` menu containing `New Folder` and `New Collection`. Capture status remains visible underneath. This reduces footer width pressure without removing either action.

## Motion And Material

- Search result changes, list updates, and keyboard-driven menu scrolling are immediate.
- Pointer-driven menu preview changes use only a short opacity transition; no directional movement or spring is applied.
- AI disclosure is the only new layout transition and is scoped to an occasional user action.
- Static clip-list and sidebar footer surfaces use standard material and separators, not custom Liquid Glass.
- Liquid Glass remains on navigation and important interactive controls.

## Sidebar Color

Sidebar navigation glyphs use the user accent color or secondary color rather than a fixed rainbow. Error remains semantically red. Rich clip-kind color stays in the clip result list, where it identifies content rather than navigation.

## Architecture

`WorkspacePresentationPolicy` in `ClipVaultCore` owns testable width/disclosure decisions without importing SwiftUI. `ContentView` maps those decisions to `NavigationSplitViewVisibility` and owns the automatic-versus-manual sidebar state. `DetailWorkspaceView` owns persisted AI disclosure. Existing model/store responsibilities remain unchanged.

## Error And Edge Behavior

- Empty, no-selection, AI-unavailable, generating, result, and error states remain available in both shelf and expanded presentations.
- Repeated selection changes while AI is already expanded do not reset the splitter.
- Manual collapse remains possible after generation or AI selection.
- A compact window never overwrites a manual hidden-sidebar preference when it grows again.
- Double-click copy uses the existing pasteboard writer and status/error path.

## Verification

- Failing-first unit tests cover the 1040-point breakpoint, automatic sidebar restoration, manual override preservation, selection-triggered AI expansion, and generation-triggered expansion.
- Focused and full tests, Release warnings-as-errors, Rust formatting/Clippy/audit, and ASan pass.
- The signed app is exercised at compact and regular widths with shelf expand/collapse, AI auto-expansion, single-click non-copy, double-click/Return copy, explicit AI selection, Add menu, search, relaunch persistence, Settings, and cancel-only destructive flows.
- Unified logs, idle process sampling, signing, package validation, and the real capture/dedupe/restart E2E remain clean.
- The full diff is reviewed against `main`; PR creation and merge occur only after local and hosted gates pass.
