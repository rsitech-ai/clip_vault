# Adaptive Clip Previews

## Goal

Make ClipVault’s main clip list recognizable at a glance without turning it
into a second detail pane. A user scanning hundreds of clips should be able to
identify likely content from the row itself, then use the existing detail pane
for complete reading and editing.

The approved direction is **Adaptive Preview**: content-first rows with a
strong title, a useful one- or two-line preview, quiet metadata, URL-aware link
labels, and subtle time grouping.

## Product intent

- Intended user: a keyboard-heavy macOS user who retrieves recent clipboard
  history across text, code, links, files, and images.
- Primary job: recognize and retrieve the correct clip quickly.
- Personality: focused, legible, local-first.
- Success condition: nearby clips with similar titles remain distinguishable
  without opening each detail view or relying on a tooltip.
- Existing behavior to preserve: selection, keyboard navigation, Return and
  Command-C copy, double-click copy, drag and drop, context menus, AI selection,
  pinning, search ordering, and the detail pane.

## Evidence and current defect

The current `ClipRowView` fixes every row at 44 points and gives the visible
content one truncated title line plus a type label. Copy count and time occupy
the same horizontal axis. In narrow and typical list widths this produces
middle-truncated text such as `https://gith…gbot/condor` and
`Edited age…e handoff.`. Different text clips become visually interchangeable,
and URLs lose the domain/repository structure that would identify them.

This is a major recognition and legibility problem, not a data-loss defect. The
full payload remains available in the detail pane and tooltip, but ordinary list
browsing hides too much meaning.

## Selected direction

### Default row hierarchy

Each row uses three columns:

1. A 38-point kind thumbnail or icon.
2. A flexible content column with title, preview, and metadata.
3. A trailing relative timestamp.

The content column owns the available width. The timestamp uses only its
intrinsic width. Pin state stays near metadata instead of interrupting the
title. Copy count is rendered as plain language (`2 copies`, `302 copies`) in
the metadata line rather than a competing bold `x302` counter.

Default rows are content-sized with a minimum height near 64 points. They must
not use a hard maximum height that clips accessibility text. Selection remains
a restrained accent surface with the same hit target as the row.

### Content hierarchy

- Title: one strong line, trailing truncation for prose and code; no middle
  truncation except for filesystem paths where preserving both ends is useful.
- Preview: up to two lines in secondary text. It must contain payload-derived
  content that differs from the title when possible.
- Metadata: one quiet line containing kind, copy count when greater than one,
  pin state when pinned, and source app at widths of 360 points or greater.
- Timestamp: relative and tertiary, aligned to the top content line.

The row must remain useful when title and preview are identical. In that case,
the duplicate preview is omitted rather than wasting a line.

## Clip-kind presentation

### Links

Parse valid HTTP(S) URLs for presentation only; retain and copy the original
payload unchanged.

- Eyebrow: lowercased host without a leading `www.`.
- Title: a meaningful endpoint derived from the final one or two non-empty path
  components. GitHub URLs prefer `owner / repository`. The root path falls back
  to the host.
- Preview: the original normalized display URL or the clip’s existing preview,
  whichever adds more recognition value.
- Invalid or non-HTTP URLs fall back to the ordinary title/preview path with no
  silent mutation.

Query values are not promoted into the title. Sensitive-looking URL query
values must not become more visible than they already are in stored clip
content.

### Text, code, and SQL

- Title: existing user title or derived first meaningful line.
- Preview: the first useful payload excerpt after the title line, with repeated
  whitespace normalized for list presentation.
- Preserve code punctuation and line boundaries enough to distinguish commands,
  paths, SQL, and prose. Do not generate summaries or call a model.

### Files

- Title: filename.
- Preview: parent path and file type when known.
- Use middle truncation for long paths while keeping the filename intact.

### Images

- Keep the actual image thumbnail.
- Title: existing title.
- Preview: useful OCR excerpt when present and different from the title;
  otherwise source app or image dimensions when available.

### Other kinds

Use the same title/preview/metadata hierarchy and fall back to existing stored
fields. No new persistence or migration is required.

## Time grouping

Group the current result sequence with lightweight inline section labels:

- Current calendar day: `Today`.
- Previous calendar day: `Yesterday`.
- Earlier in the current calendar week: localized full weekday name.
- Older: localized abbreviated date.

Grouping is presentation-only and preserves the exact search/result order
within each group. Search results use the same deterministic groups.

## Adaptive layout

- Typical list width: full Adaptive Preview row.
- Narrow list width: keep title and one preview line; remove source app first,
  then collapse copy count into the metadata line. Never remove the title or
  timestamp.
- Very narrow minimum supported width: keep icon, title, one preview line, and
  timestamp; metadata may move under the preview.
- Wide list width: do not stretch text across the whole pane. Keep a readable
  content measure while allowing metadata to breathe.
- Accessibility text sizes: rows grow vertically. Essential content is not
  repaired by shrinking fonts or applying `minimumScaleFactor`.

## Interaction behavior

- Single click selects without copying.
- Double click copies.
- Return and Command-C copy the selected clip.
- Up/down navigation continues to select and scroll the row into view.
- Context menu, drag preview, and AI selection controls remain available.
- The whole row stays the selection target; inline metadata is not separately
  interactive.
- Hover help may show the full payload, but it is supplemental rather than the
  only readable representation.

## Component boundaries

### Pure presentation model

Introduce a small pure value type named `ClipRowPresentation` that
derives:

- eyebrow;
- title;
- preview;
- metadata items;
- title truncation strategy;
- accessibility summary.

It accepts a `Clip` and locale-aware formatting inputs but performs no I/O and
does not mutate stored data. URL and excerpt derivation live in focused pure
helpers so boundary cases can be unit tested without rendering SwiftUI.

### SwiftUI row

`ClipRowView` renders the presentation value and owns only layout and
accessibility. Image-thumbnail loading remains in the existing cached image
component. `ClipListView` owns grouping and selection behavior.

### Grouping helper

A pure grouping helper maps the already ordered `[SearchResult]` to ordered
sections. It never sorts clips independently or changes search relevance.

## Accessibility

- VoiceOver label begins with the meaningful title or host/endpoint label.
- VoiceOver value includes kind, the displayed preview when present, copy count,
  pin state, and relative time without reading decorative icons.
- Selection retains `.isSelected`; AI selection exposes its existing state.
- Support Bold Text, increased contrast, reduced transparency, keyboard-only
  use, and accessibility text sizes.
- Color continues to identify kind, but kind is also present in text and the
  symbol has a semantic alternative.

## States and failure handling

- Empty and no-search-results states remain unchanged.
- Missing preview: omit the preview line and keep a compact content-sized row.
- URL parse failure: ordinary clip presentation; never show an error row.
- Missing source app or copy count of one: omit that metadata item.
- Extremely long unbroken content: trailing truncation in the row; full content
  stays available in the detail pane. The accessibility value reads at most the
  first 300 characters of preview content to remain navigable.
- Decryption or payload-read failures are not introduced into list rendering;
  the design uses fields already present in the in-memory `Clip` projection.

## Scope

### First implementation slice

- Adaptive Preview as the only default list presentation.
- Pure row-presentation derivation with URL-aware links.
- Useful two-line previews and quiet metadata.
- Deterministic time sections.
- Responsive and accessibility-aware row layout.
- Focused unit tests, previews, and real-app screenshot verification.

### Deferred

- User-selectable Compact mode.
- Card mode.
- AI-generated titles or summaries.
- Website metadata fetching, favicons, or network requests.
- Persistence/schema changes.
- New sorting or filtering behavior.
- Redesign of the sidebar or detail pane.

## Verification and acceptance criteria

### Unit behavior

- GitHub repository links render as host eyebrow plus `owner / repository`.
- Root, malformed, encoded, query-heavy, and very long URLs fall back safely.
- Text/code/SQL excerpts remove redundant title content without losing useful
  punctuation.
- Duplicate title/preview does not render twice.
- Copy count, pin state, source app, and kind metadata appear only when relevant.
- Time grouping preserves input order exactly.

### Rendered behavior

- At the minimum, typical, and wide supported list widths, examples from the
  supplied screenshots are distinguishable without opening the detail pane.
- Selected, hovered, pinned, image, link, text, code, SQL, file, long-content,
  and missing-preview rows render without overlap or essential clipping.
- Default, large, and accessibility text sizes grow cleanly.
- Dark and Light appearance, increased contrast, reduced transparency, and
  keyboard navigation are exercised.
- VoiceOver reads title, preview, type, copy count, pin state, and time in a
  logical order.
- Scrolling a 580-item fixture remains smooth and thumbnail work stays bounded.

### Regression behavior

- Single-click selection, double-click copy, Return, Command-C, arrow keys,
  context menu actions, drag/drop, and AI multi-selection still work.
- Search result order and collection counts do not change.
- Existing detail content and persisted clip data remain unchanged.

## Rollback

The change is presentation-only. Reverting the row presentation, grouping
helper, and list composition restores the current 44-point rows without data
migration or persisted-state recovery.
