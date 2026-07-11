# Clip Move and Sidebar Drag-and-Drop Design

## Goal

Let a user move one clip to a different custom collection either through an explicit **Move to Collection** menu or by dragging the clip row onto a collection in the sidebar.

## Product Semantics

- A move replaces every existing custom collection membership on the clip with the chosen destination collection.
- Automatic built-in memberships, such as Code, Links, Images, Files, and other kind-derived smart collections, remain unchanged.
- A drag always moves exactly the row being dragged. AI selection does not affect move scope.
- Plain folders organize collections but do not directly contain clips and are not valid drop destinations.
- Built-in smart collections are navigation filters and are not valid move destinations.
- Moving to the clip's current sole custom destination is an idempotent success.

## User Interface

### Move menu

Each clip row context menu and the selected clip's detail toolbar expose **Move to Collection**.

The submenu mirrors the current custom folder tree:

- folders render as nested menu groups;
- custom collections render as selectable destinations;
- the current custom destination is checkmarked;
- empty folders and built-in smart collections are omitted from the destination choices;
- when no custom collection exists, the menu is disabled and explains that a collection must be created first.

Choosing a destination moves only the clip whose menu or detail view initiated the action.

### Drag and drop

Clip rows publish an internal ClipVault drag payload containing only the clip identifier. Clipboard text, image bytes, OCR, file paths, notes, tags, and encryption material never enter the drag payload.

Custom collection rows in the sidebar accept this payload. While a valid payload is over a valid destination, the collection row shows a clear drop-target highlight. Plain folders and built-in smart collections do not accept the drop and do not show a success highlight.

Dropping invokes the same move operation as the menu. A successful move reports `Moved to <collection>`. If the active sidebar filter no longer contains the moved clip, the row disappears immediately from that filtered result while remaining available in All Clips and applicable smart collections.

The explicit menu is the complete keyboard and accessibility alternative to pointer drag-and-drop.

## Architecture

### Shared domain operation

Add one store operation for moving clip IDs to a custom collection. The single-clip view-model method calls it with exactly one clip ID. Menu and drop handlers both call that view-model method.

The store operation:

1. verifies that the destination exists and represents a custom collection;
2. loads the requested clip;
3. separates built-in kind-derived collection IDs from custom collection IDs;
4. writes the built-in IDs plus the one destination ID;
5. persists transactionally before publishing refreshed in-memory state.

The SwiftData and in-memory stores implement identical observable behavior. A persistence failure rolls back without changing the clip returned by subsequent reads.

### Destination tree

The view model exposes the existing folder tree as destination data rather than creating a second collection hierarchy. UI components recursively render only branches that contain at least one custom collection.

### Drag payload

Use a ClipVault-owned transferable value with an app-specific uniform type identifier and one string field: `clipID`. Decoding rejects empty or malformed identifiers. The destination resolves the identifier against the current store before moving, so a stale or foreign payload cannot create membership for a nonexistent clip.

## State and Error Handling

- Success refreshes clips and sets `captureStatus` to `Moved to <collection>`.
- Same-destination moves succeed without duplicate IDs.
- Missing clips, missing destinations, built-in destinations, malformed drag payloads, and storage failures do not mutate membership.
- User-visible failures use stable messages; detailed storage errors remain private in logs.
- Removing the final custom membership without choosing a replacement is outside this feature. Existing collection deletion behavior remains unchanged.

## Accessibility

- **Move to Collection** has a clear label and help text in row and detail actions.
- Destination menu items expose their folder path and selected state.
- Drop-target color is supplemented by the collection row's existing label and a semantic drop action; color is not the only signal.
- Dragging is optional. Every move is possible using menus and keyboard navigation.

## Testing

### Store behavior

- Moving a clip from multiple custom collections leaves exactly the destination custom collection.
- Built-in kind-derived memberships remain present.
- Moving to the current destination is idempotent and produces no duplicate IDs.
- A missing or built-in destination is rejected without mutation.
- A missing clip is rejected without affecting other clips.
- SwiftData and in-memory stores have matching results.
- A forced SwiftData save failure rolls back both memory and disk state.

### View-model and payload behavior

- Menu and drop entry points call the same single-clip move operation.
- AI-selected clips do not expand drag scope beyond the dragged clip.
- Drag payload round-trips only the clip ID and rejects malformed data.
- Status text reports the destination after success and a stable failure after rejection.

### Native smoke

- Move a row through its context menu and through the detail toolbar.
- Drag one row onto a nested custom collection and verify the target highlight.
- Confirm another AI-selected clip does not move with it.
- Confirm plain folders and built-in smart collections reject the drop.
- Confirm a moved row leaves the previous filtered collection, remains in All Clips, and survives relaunch.
- Verify menu labels, selected destination state, keyboard access, and runtime logs.

## Non-Goals

- Moving folders or collections within the sidebar.
- Dropping onto plain folders.
- Bulk-moving AI-selected clips.
- Reordering clips.
- Importing external drag data.
- Changing automatic smart-collection classification.
