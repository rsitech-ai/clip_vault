# Unified Clip Workspace Design

**Date:** 2026-08-13  
**Status:** Approved visual direction; implementation pending written-spec review  
**Branch:** `feat/andrzej_adaptive_clip_previews`

## Outcome

Replace the vertically split detail and AI panes with one concise right-side workspace that prioritizes reading the selected clip. AI remains immediately available as contextual actions inside the same hierarchy. A focus control must also allow the detail workspace to use the full window when the user needs maximum reading width.

The redesign preserves existing clip operations, AI actions, prompt enhancement, notes, tags, collection membership, image annotation, selection behavior, and error states. It changes presentation and disclosure, not storage or AI semantics.

## Product Problem

The current right side contains two independent vertical regions:

1. `ClipDetailView`, with its own scrolling content, header, actions, metadata, tags, and notes.
2. An expandable `AIActionPanel`, with another header, action area, result area, and question field.

This creates four observable problems:

- Long clip content receives too little height even when no AI result exists.
- Repeated context labels and permanent empty AI space compete with the selected clip.
- Two internal regions produce an unclear hierarchy and make the right pane feel like two products.
- The user cannot quickly dedicate the full window to reading the selected clip.

## Design Principles

1. **The selected clip is the workspace.** The clip content is always the primary surface.
2. **AI is contextual tooling.** AI actions appear beside the clip workflow and expand only when they have progress, output, or an error to show.
3. **One hierarchy and one content scroll.** There is no internal vertical split view and no second independently scrolling AI panel.
4. **Progressive disclosure.** Frequent actions stay visible; destructive and infrequent actions move to an overflow menu; secondary metadata and editors remain below the content.
5. **Native width control.** The user can hide or restore the browser columns to give the detail workspace the full window.

## Workspace Structure

The detail column becomes a single `VStack` with three regions.

### 1. Compact clip header

The top region remains visible above the content scroll and contains:

- kind icon;
- editable clip title;
- one compact metadata line: type, capture time, and source application when present;
- primary actions: Copy, Pin/Unpin, and Move;
- an overflow menu containing Delete and lower-frequency actions;
- a Focus/Restore Browser control that switches between the normal three-column workspace and a detail-only workspace.

The action row must adapt rather than clip:

- At comfortable widths, actions show labels and symbols.
- At constrained widths, Move and overflow remain available while Copy and Pin switch to symbol-only presentation with accessible labels and tooltips.
- Delete never occupies permanent primary space.

### 2. Contextual AI command bar

Immediately below the header is one compact command bar containing:

- Summarize;
- Explain;
- Action Items;
- Enhance Prompt;
- one question field and Ask control.

The bar does not show a separate `AI Workspace` title, `Using open clip`, `Actions ready`, an empty-state explanation, or a duplicate bottom question field. Availability is communicated through disabled controls, help text, accessibility values, and an inline warning only when an unavailable action is attempted or materially relevant.

When multiple clips are explicitly selected, the command bar shows a concise context token such as `3 selected`. When no multi-selection exists, actions use the open clip exactly as they do today.

At constrained widths, the actions move into a compact AI-actions menu while the question field retains the remaining width. No action becomes unreachable.

### 3. Single scrollable workspace body

One `ScrollView` owns everything below the command bar, in this order:

1. AI progress, result, success, cancellation, or error disclosure when present;
2. original clip content;
3. image-specific annotation tools or recognized text when applicable;
4. collection membership, tags, and notes.

When AI is idle and has no result or error, no AI result container is rendered. The clip content starts at the top of the scroll area.

## AI Result Behavior

AI state appears as an inline disclosure inside the same scroll view.

- **Generating:** a compact progress row identifies the active action and exposes cancellation when supported.
- **Success:** a titled result block contains selectable output and citation count. Local fallback remains labeled `Local`.
- **Failure:** an inline error block uses the existing sanitized message and leaves the original clip readable.
- **Prompt enhancement:** existing progress, cancellation, save, success, and Open Prompts behavior is preserved in the inline disclosure.
- **Dismissal:** completed, failed, or cancelled disclosures provide a close control backed by an explicit model action that clears the presented AI state without mutating the selected clip.
- **New action:** invoking another action replaces the previous presented result using the model's current single-result semantics.

The result block must not introduce its own vertical `ScrollView`; long output grows inside the workspace scroll.

## Reading and Editing Behavior

### Text, prompts, and errors

- Use the full available content width with a readable maximum line length near 72 characters on very wide panes.
- Keep text selectable.
- Preserve paragraph spacing and original line breaks.
- Do not place the original content in a visually heavy nested card when the pane itself already establishes the reading surface. Code and SQL payloads use a subtle contrasting background and border to define their horizontal scrolling region.

### Code and SQL

- Preserve monospaced typography and whitespace.
- Allow horizontal scrolling only inside the code payload when lines cannot wrap without changing meaning.
- Keep the overall workspace vertically single-scroll.

### Links

- Show the meaningful title and full selectable URL.
- Offer the existing copy behavior; opening a URL is outside this redesign unless already supported.

### Images

- Fit the image to available width without cropping.
- Place recognized text and screenshot annotation tools beneath the image in the same scroll.

### Tags, notes, and collections

- Keep these editors below the primary payload.
- Use compact section disclosures so empty editors do not dominate the reading surface.
- Preserve all save, validation, and collection semantics.

## Focus Mode and Column Resizing

The detail header exposes one native focus control:

- **Enter Focus:** set `NavigationSplitViewVisibility` to `.detailOnly`, hiding the sidebar and clip list and allowing the unified workspace to use the full window.
- **Restore Browser:** return to the last user-visible browser state, normally `.all` or `.doubleColumn`.

Manual focus changes must not be immediately reversed by automatic sidebar adaptation. The existing `WorkspaceSidebarAdaptation` state remains authoritative for ordinary window resizing, but focus mode is an explicit user state with higher priority until restored.

The normal detail column keeps its current minimum width behavior but should not impose a restrictive visual content maximum inside the pane. Readable line length is controlled by the document content container, not by preventing the detail column from expanding.

## Empty and Edge States

- With no selected clip, the detail column shows the existing Select a Clip empty state. The AI bar is absent because there is no active context.
- With selected clips but no open clip, existing multi-clip AI actions remain reachable through an appropriately labeled compact AI bar.
- Long titles wrap or truncate adaptively without pushing actions off-screen.
- Long source names truncate in the metadata line and remain available through accessibility/help text.
- At minimum supported window width, every action remains reachable through labels, symbols, or menus.
- Reduce Motion disables nonessential disclosure animation.
- Keyboard focus order follows header actions, AI actions/question, result, clip content, and editors.

## Architecture

### `ContentView`

- Owns normal versus detail-only column visibility.
- Passes focus/restore intent into `DetailWorkspaceView`.
- Prevents automatic sidebar adaptation from overriding explicit focus mode.

### `DetailWorkspaceView`

- Stops using `VSplitView`, `AIWorkspaceLayoutPolicy`, and the persisted expanded/collapsed AI workspace state.
- Composes one unified workspace and supplies focus-mode controls.
- Keeps existing automatic AI execution behavior but no longer auto-expands a second pane.

### `ClipDetailView`

- Is refactored into focused header, command bar, inline result disclosure, payload, and metadata/editor components.
- Retains the existing deletion confirmation and clip-kind-specific content.

### `AIActionPanel`

- Its business-facing controls and state presentations are reused or extracted into compact components.
- The legacy inspector and split-pane layouts, shelf, duplicate empty messaging, and placement-specific minimum heights are removed after callers migrate.
- No new dependency is introduced.

### Pure presentation policy

Any width/state decision that can be expressed without SwiftUI is placed in `ClipVaultCore` and unit tested. Obsolete `AIWorkspaceLayoutPolicy` and disclosure rules are removed only after all callers and tests are migrated.

## Accessibility

- Every compact or symbol-only action has an explicit label, hint, and help text.
- Focus mode announces Enter Focus and Restore Browser accurately.
- AI progress and prompt-enhancement progress expose meaningful accessibility values.
- Results and errors are announced when their state changes without stealing keyboard focus from the question field unnecessarily.
- The content remains text-selectable, and no visual-only status dot carries meaning alone.

## Verification

Implementation is complete only after:

1. Focused unit tests cover compact/regular command-bar decisions and explicit focus-mode restoration.
2. Existing AI action, prompt enhancement, workspace presentation, clip management, and persistence tests pass.
3. The full Swift and Rust test suite passes.
4. Debug and warnings-as-errors release builds pass.
5. The staged signed app is exercised with text, long prompt, code/SQL, link, and image clips.
6. Rendered inspection covers minimum, typical, wide, and detail-only window states.
7. The user can enter and exit focus mode, select/copy long text, invoke an AI action, read or dismiss its result, ask a question, and edit notes/tags without losing the selected clip.
8. Dark mode, keyboard traversal, long content, and Reduce Motion receive explicit runtime checks. Light mode and increased contrast are checked if the current product supports those appearances without unrelated redesign.

## Non-Goals

- Changing AI providers, prompts, or generation semantics.
- Adding conversational history or multi-turn chat.
- Changing clip storage, encryption, search, capture, or deduplication.
- Redesigning the sidebar or adaptive clip list.
- Adding URL-opening behavior or new clipboard actions.
- Introducing a new visual theme or dependency.

## Acceptance Criteria

- No `VSplitView` separates clip content from AI controls.
- The selected clip receives all remaining vertical space when AI is idle.
- There is one question field and no permanent empty AI result area.
- AI progress/results/errors appear inline in the single workspace scroll only when present.
- The user can switch to a detail-only full-window reading state and restore the browser columns.
- Copy, Pin, Move, Delete, AI actions, prompt enhancement, tags, notes, image annotation, and collection context remain reachable and behaviorally compatible.
- The minimum supported window width has no clipped actions or inaccessible content.
