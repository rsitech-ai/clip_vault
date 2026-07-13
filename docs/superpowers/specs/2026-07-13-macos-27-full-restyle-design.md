# ClipVault Full macOS 27 Visual Restyle Design

Date: 2026-07-13
Status: Approved by the user for implementation

## Goal

Make ClipVault feel authored for macOS 27: luminous but restrained, fast to scan, stable at every supported window size, and unmistakably centered on retrieval and reuse. The visual restyle must close the reliability defects found during the same audit rather than placing new chrome over unstable behavior.

## Platform Contract

- The live compatibility target is macOS 27.0.
- The package continues to support macOS 15+.
- macOS 26+ Liquid Glass APIs remain availability-gated; older systems use native material and bordered-control fallbacks.
- Xcode 26.6 is the currently installed build toolchain. Runtime compatibility on macOS 27 is not described as Xcode 27 SDK validation.
- No dependency, storage migration, cloud provider, analytics path, or data transmission is added.
- Production payload encryption remains Keychain-backed.

## Visual Direction

ClipVault uses a content-first three-layer hierarchy:

1. **Window chrome and navigation:** native split-view structure, toolbar search, and a calm sidebar with one emphasized capture state.
2. **Working surfaces:** list and detail use subtle tonal separation, selection fills, separators, and semantic content color rather than independent glass cards.
3. **Important actions:** Copy, AI actions, capture, and compact utility groups receive availability-gated Liquid Glass. Glass is never nested and never applied to large editable or scrolling regions.

The result should resemble a focused Apple utility, not a dashboard. Color communicates clip kind, selection, readiness, or error; it is not decorative.

## Shared Design System

`ClipVaultDesign` owns spacing, radii, semantic tints, stable SF Symbol names, and reusable surface decisions. New tokens cover compact/regular padding, row radius, hero icon size, control group spacing, and subdued backgrounds.

Every custom symbol name used by the app must resolve at runtime on the current system. The move action uses a long-supported symbol rather than `folder.badge.arrow.forward`.

## Workspace

### Sidebar

- The workspace list remains native `List`/sidebar navigation.
- The footer becomes a compact glass utility bar only on macOS 26+, with one adaptive Add menu and a capture-status indicator.
- At narrow sidebar widths the Add label becomes icon-only while retaining its tooltip, accessibility label, and hint. Status copy collapses to a dot plus concise state instead of truncating the control.
- Built-in navigation remains calm; clip-kind colors stay in content rows.

### Clip list

- Rows gain consistent 10-point rounding, a clear selected fill, a dedicated AI-selection check control, kind glyph tile, title, metadata, and pin state.
- Single click selects; double-click and Return copy. Menu-bar rows preserve one-click copy.
- Search results use a stronger relevance floor for multi-term queries. The header says `N matches` during search and `N clips` otherwise.
- Pinning, moving, editing, or reloading preserves the selected clip by stable identifier whenever it remains visible.

### Detail

- The detail header becomes a hero region: semantic kind tile, editable title, date/source metadata, and one grouped action cluster.
- Copy is primary. Pin and Move are secondary. Delete remains destructive and visually separated.
- Body, OCR, notes, tags, and screenshot metadata use quiet native sections. Text editors use standard bordered/material treatment rather than interactive glass.
- Large content surfaces never nest glass effects.

## AI Workspace

- The 48-point collapsed shelf becomes a polished compact command bar with context, readiness, and an explicit expand affordance.
- The expanded pane uses one glass action group and an ordinary result canvas/composer.
- A pure `AIWorkspaceLayoutPolicy` calculates safe detail/AI minimums. The total child minimum plus divider must never exceed available height.
- At very short heights, the expanded pane uses compact minimums. It never emits negative geometry and never forces inaccessible content offscreen.
- Reduce Motion removes explicit disclosure animation. No continuous decorative motion is introduced.

## Settings And Consent

- Settings keep native grouped forms and tab semantics; visual consistency comes from headings, concise status rows, and shared symbols rather than custom containers.
- Revoking clipboard capture consent requires confirmation and states that capture stops until disclosure is accepted again.
- Permission labels name exact states. No permission is changed during automated verification.

## Verification Architecture

Unit storage tests inject a deterministic reversible encryptor and never invoke Keychain UI. Dedicated encryption tests retain production-boundary coverage.

`build_and_run.sh --verify` validates that the exact signed staged app launches and remains alive without host writes into its sandbox. `e2e_smoke.sh` builds with `CLIPVAULT_E2E_PROBE`; only that build starts with in-memory E2E capture consent and validates capture, deduplication, persistence, and restart through the app-owned store probe.

## Error And Edge Behavior

- A missing symbol is treated as a test/runtime failure, not a visual fallback hidden in logs.
- Failed pin, move, edit, or reload operations keep the prior selection and show the existing error status.
- Search with no strong matches shows the existing empty state.
- Compact width and compact height policies are independent.
- Empty, selected, image, text, code, AI-ready, AI-fallback, generating, result, and error states remain usable.
- Real destructive actions are never executed during audit; confirmation and cancel paths provide interaction proof.

## Acceptance Criteria

- Full tests finish without Keychain prompts or status `-128`.
- Signed launch verification performs no sandbox preference write.
- Capture/dedupe/persistence/restart E2E remains fail-closed and passes with the probe build.
- Runtime logs contain no invalid SF Symbol, repeated glass update, or negative-geometry faults during the audited flows.
- Pinning preserves the selected detail clip.
- Sidebar controls never truncate at the supported minimum width.
- Search labels and results match user expectations for exact, partial, and unrelated queries.
- Minimum, regular, and large windows remain readable and adjustable.
- Menu-bar copy, workspace copy, AI actions, Settings, drag/drop, screenshot cancel/permission routing, keyboard navigation, and confirmation/cancel flows receive fresh macOS 27 proof.
- The final signed app is rebuilt at `dist/ClipVault.app` and package/signing/privacy checks pass.
