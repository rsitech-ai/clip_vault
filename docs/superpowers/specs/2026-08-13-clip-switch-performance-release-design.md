# Clip Switching Performance and Release Design

**Date:** 2026-08-13
**Status:** Approved direction; implementation pending written-spec review
**Branch:** `feat/andrzej_adaptive_clip_previews`

## Outcome

Make switching between clips feel immediate in a Release build, add crisp pointer press feedback to buttons without animating clip navigation, and ship the verified unified-workspace release through a reviewed pull request to `main`.

After merge, replace the previous `/Applications/ClipVault.app` with the new verified app, retain recoverability through Trash, remove obsolete local release artifacts and unneeded registered worktrees, and make the latest release downloadable.

## Diagnosed Hot Path

Selecting a clip mutates `selectedClipID` on the root observable model. `ClipListView` reads both selection and `model.visibleResults`, so the selection invalidation can re-evaluate the whole list. During that evaluation, `ClipResultSection.group(model.visibleResults)` rebuilds every time and historical section labels can construct `DateFormatter` instances repeatedly.

The detail workspace also resolves `selectedClip` with a linear scan through `clips`. That lookup is smaller than list regrouping but still belongs outside the repeated selection path.

The optimization must address these known costs before introducing broader architecture changes. If Release-build measurement shows a remaining delay after these fixes, capture a SwiftUI/Time Profiler trace and use the trace to select the next change.

## Performance Architecture

### Stable section projection

The view model owns a cached `[ClipResultSection]` projection derived from workspace results. It refreshes only when one of these inputs changes:

- workspace search results;
- current calendar day or calendar/locale boundary relevant to labels.

Changing `selectedClipID`, AI state, notes, or focus mode does not recompute the section projection. The list renders the cached sections with existing stable result IDs and does not sort or reorder results.

Section grouping reuses formatters within one grouping pass instead of constructing a formatter for every historical result.

### Indexed clip selection

The view model maintains a clip-ID lookup derived whenever `clips` changes. `selectedClip` resolves through that lookup. The index is a derived in-memory projection only; it does not change persistence or clip identity.

### Narrow row invalidation

Selection presentation is passed to row content as value inputs. The implementation avoids broad repeated reads from the root model inside each row where a focused closure or value is sufficient. A selection change must preserve scroll position and update the old row, new row, and detail content without recreating section membership.

No `equatable()` wrapper is added unless measurement proves its equality check is cheaper than rebuilding the specific subtree.

## Measurement and Acceptance

Use the staged Release build and the existing real dataset of approximately 585 clips.

Capture the same interaction before and after optimization:

1. Open All Clips in the normal three-column layout.
2. Switch repeatedly among adjacent text/link clips, including one historical section.
3. Record interaction-to-detail-update evidence using macOS signposts, Instruments SwiftUI/Time Profiler, or a bounded internal timing probe removed before release.

Acceptance criteria:

- section grouping is not invoked by selection-only changes;
- selected-clip lookup is constant-time after the clip projection refresh;
- pointer selection feels immediate in the staged Release build with no visible spinner or intermediate empty state;
- repeated clip selection introduces no animation delay;
- no regression in list order, selection, keyboard navigation, AI multi-selection, or focus mode;
- record the measurement method and before/after observation honestly, without claiming frame-time precision if only interaction evidence is available.

## Motion Design

Button feedback exists only to confirm pointer press.

- Apply a reusable button style to appropriate custom/material buttons.
- Pressed state uses `scaleEffect(0.98)`.
- The release response uses an interruptible ease-out animation of approximately 120 milliseconds.
- Do not animate width, height, padding, layout position, list selection, detail replacement, keyboard commands, or scrolling.
- Under Reduce Motion, omit the scale transform; retain native highlight/color feedback.
- Menus and native controls retain their platform behavior when an extra scale would interfere with hit testing or system animation.

The motion review must explicitly confirm that no high-frequency clip-navigation animation was added.

## Release and Integration Workflow

### Branch hardening

Before publication:

- review `origin/main...HEAD` for correctness, scope, stale policy, accessibility, and performance regressions;
- run formatter, Clippy, full Swift/Rust tests, debug build, warnings-as-errors Release build, signed staged-app verification, E2E smoke, and rendered interaction checks;
- verify Focus/Restore, inline AI result/dismissal, clip switching, long text, link, code/SQL, and image paths;
- inspect signing identity, nested dylib signature, hardened runtime/entitlements, and downloadable artifact contents.

### Pull request and merge

The user explicitly authorizes push, PR creation, review, merge to `main`, and release publication for this task.

- Fetch and compare against current `origin/main` immediately before push.
- Push the feature branch without force.
- Create a ready-for-review PR using repository conventions.
- Review the PR diff and CI status; address actionable findings and rerun affected verification.
- Merge only when required checks are green and there are no unresolved important findings.
- Verify local and remote `main` resolve to the merged commit after integration.

### Application replacement

After the merged-source release artifact is rebuilt and verified:

1. Quit the running installed ClipVault process cleanly.
2. Confirm the exact existing target is `/Applications/ClipVault.app`.
3. Move the previous app bundle to Trash rather than permanently deleting it.
4. Copy the new verified app bundle to `/Applications/ClipVault.app`.
5. Verify bundle identifier, version, signing identity, nested signatures, launch, persistence, and installed-path behavior.
6. Report the TCC/signing boundary explicitly; an existing Screen Recording grant tied to a prior signing identity is not treated as runtime proof for the replacement.

### Cleanup

Cleanup occurs only after the merged build and installed app pass verification.

- Enumerate Git worktrees and remove only stale/unneeded linked worktrees that are clean and not the active checkout.
- Prune stale worktree registrations.
- Remove obsolete generated release directories/artifacts using Trash when material and recoverable.
- Preserve source-controlled release documentation, the latest downloadable artifact, user data, signing material, and unrelated dirty files.
- Do not delete GitHub releases until the latest release is published and their obsolescence is confirmed; preserve tags required for release history.

### Downloadable release

- Determine the next version from the repository's existing release/version convention.
- Build the artifact from merged `main`, not the pre-merge branch.
- Sign and notarize when configured credentials and workflow are available; otherwise label the exact distribution gate honestly.
- Generate integrity metadata such as SHA-256 using existing project scripts.
- Publish one canonical latest downloadable artifact and verify its URL and checksum.
- Do not label a locally signed development build as notarized or public release-ready.

## Verification Matrix

- Focused projection/index tests demonstrate red-green behavior.
- Full Swift and Rust suites pass.
- Rust format and Clippy pass with warnings denied.
- Debug and warnings-as-errors Release builds pass.
- Source-policy scripts pass.
- Signed staged app verifies and E2E capture/dedupe/persistence/restart passes.
- Release-build rendered inspection covers rapid clip switching, buttons, Reduce Motion behavior, focus/restore, AI inline result/dismissal, and representative clip kinds.
- PR diff review and required remote CI pass.
- Merged-main artifact is rebuilt, installed, launched, and identity-checked.
- Download URL and checksum are verified after publication.

## Non-Goals

- Rewriting the view model or storage architecture.
- Adding animated clip transitions, list choreography, hover spectacle, or spring navigation.
- Changing capture, storage, encryption, search scoring, AI providers, or prompt semantics.
- Removing user data, credentials, source-controlled release history, or unrelated worktrees.
- Force-pushing, bypassing branch protection, or claiming notarization without proof.

## Completion Labels

- `repo-ready`: optimized source and full local verification pass.
- `runtime-proven`: staged Release interaction and E2E paths pass.
- `signed/notarized`: only when the resulting artifact proves those exact gates.
- `release-ready`: merged-main artifact, installed app, downloadable artifact, checksum, and required distribution gates are verified.
- `blocked:external`: required CI, GitHub permission, signing, notarization, or credential gate cannot be completed from the available environment.
