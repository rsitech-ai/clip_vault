# On-Demand Clip Selection Design

Date: 2026-07-15
Status: Approved by the user for planning

## Goal

Remove persistent selection circles from ClipVault's clip rows so normal browsing prioritizes clip content. Expose the circles only through an explicit selection mode entered from the clip-list header's top-right overflow menu.

## Interaction Contract

ClipVault uses **Select Clips**, not **Edit**, because the leading circle controls the set of clips used by AI actions; it does not edit clip content.

In normal browsing mode:

- clip rows do not show leading selection circles;
- each row begins with its existing clip-kind thumbnail;
- the top-right overflow menu contains **Select Clips** above the existing cleanup actions;
- the existing `N selected` badge remains visible when the AI selection is nonempty;
- single-click selection, double-click copy, Return-to-copy, drag and drop, and row context menus retain their existing behavior.

In clip-selection mode:

- each row shows its existing circle or filled check-circle control before the thumbnail;
- the header replaces the overflow control with a visible **Done** button;
- selecting a circle updates the existing AI-selection set;
- pressing **Done** returns to normal browsing without clearing that set.

Reopening **Select Clips** reveals the preserved selection so the user can add or remove clips. The row context menu continues to offer **Add to AI Selection** or **Remove from AI Selection** as a secondary shortcut in either mode.

## State Ownership

`ClipListView` owns the temporary presentation state that determines whether selection controls are visible. The existing `ClipVaultViewModel.selectedClipIDs` remains the source of truth for the durable in-session AI selection.

Selection mode is presentation-only. Entering or leaving it does not mutate clip data, change the open clip, clear AI selection, or modify persistence.

## Accessibility

- **Select Clips** and **Done** use explicit accessibility labels and help text.
- Circle controls retain their existing action-oriented accessibility labels and selected state.
- Hiding the circles in browsing mode does not remove selection access because the header menu and row context menu remain keyboard-accessible.
- The selected-count badge remains a visible reminder that AI selection is active after selection mode closes.

## Error And Edge Behavior

- Entering selection mode with no clips visible still presents **Done** and does not create a selection.
- Changing collections or search results does not clear selected clip IDs; this preserves the existing cross-view AI-selection behavior.
- Deleting, expiring, or otherwise removing clips continues to prune their IDs through the existing view-model paths.
- Cleanup sheets and destructive confirmations retain their current behavior.

## Verification

- A failing-first presentation-policy test proves selection controls are hidden during normal browsing and shown during selection mode.
- A failing-first policy test proves the header action is **Select Clips** in normal mode and **Done** in selection mode.
- A realistic UI smoke proves pressing **Done** leaves `selectedClipIDs` intact: the selected-count badge remains, reopening selection mode restores the visible checks, and the same clips remain available to AI actions.
- Focused Swift tests and the repository's full `./script/test.sh` verification pass.
- The built app is exercised to confirm normal rows have no leading circles, **Select Clips** reveals them, **Done** hides them, the selected-count badge persists, and reopening selection mode restores the visible checks.

## Out Of Scope

- Clip-content editing or renaming.
- Bulk move, delete, pin, or cleanup actions from selection mode.
- Changing AI source precedence or prompt-enhancement behavior.
- Persisting AI selection across app relaunches.
- Removing the row context-menu selection shortcut.
