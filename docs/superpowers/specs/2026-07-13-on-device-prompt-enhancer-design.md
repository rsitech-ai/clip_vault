# On-Device Prompt Enhancer and Protected Prompts Collection Design

## Status

Approved in conversation on 2026-07-13. This document is pending the required written-spec review before implementation planning begins.

## Goal

Add an **Enhance Prompt** action to the AI Workspace. It creates one upgraded prompt for each source clip, preserves every original, and atomically saves the generated clips to a protected default **Prompts** collection using Apple Foundation Models on-device.

## Product Decisions

- Prompts is a protected default collection with the stable identifier `prompts`.
- One source clip produces exactly one enhanced prompt. Multi-selection never combines source clips.
- The open clip is the source when no clips are explicitly AI-selected.
- The feature is on-device only. It introduces no OpenAI API call, SDK, API key, network entitlement, telemetry, or clipboard-content transmission.
- The OpenAI GPT-5.6 prompting guide informs the general transformation principles, but ClipVault does not call GPT-5.6 and does not label results as GPT-5.6 optimized.
- Apple Intelligence unavailability, cancellation, generation failure, validation failure, encryption failure, or persistence failure saves none of the batch.
- The existing source clips are never edited, moved, deleted, or overwritten.

Reference: [OpenAI prompting guidance for GPT-5.6](https://developers.openai.com/api/docs/guides/prompt-guidance-gpt-5p6).

## User Experience

### Prompts collection

Prompts appears with the other default collections in the Collections group. It uses a prompt-oriented system icon and its sidebar node cannot be renamed, moved, or removed. Prompts is a protected default **manual** collection, not a smart collection: users can move ordinary clips into it and move clips out to another manual collection. Clips inside it otherwise retain normal ClipVault behavior, including search, copy, pin, edit, and delete.

The collection is an explicit protected destination rather than a kind-derived smart filter. Only the prompt-enhancement workflow assigns new results to it automatically.

### Enhance Prompt action

**Enhance Prompt** joins Summarize, Explain, and Todos in the existing AI action group:

- the expanded action grid uses a labeled button and wand icon;
- the compact toolbar uses the same icon with a complete accessibility label, hint, and help text;
- the action is disabled when no source clip exists, another AI action is active, or Apple Intelligence is unavailable;
- disabled help text names the exact reason.

When the action begins, the result area shows deterministic batch progress such as `Enhancing 2 of 4` and provides **Cancel**. Generation proceeds sequentially to keep on-device resource use bounded. Cancellation discards all in-memory drafts and saves nothing.

Success shows `4 enhanced prompts saved to Prompts` with **Open Prompts** as the primary follow-up action. The workspace does not navigate automatically; the user remains in control of the current context.

Failure names the source without exposing its contents, for example: `Couldn’t enhance “Release checklist.” Nothing was saved.`

## Prompt Enhancement Contract

For each source, the on-device model must:

- preserve the original language, intent, factual claims, explicit values, artifact type, requested length, meaningful constraints, and required output format;
- remove repetition, contradictions, filler, and process instructions that do not affect behavior;
- state the desired outcome early;
- add only structure that changes behavior or makes completion objectively clearer;
- use Role, Personality, Goal, Context, Success Criteria, Constraints, Tools or Inputs, Output, and Stop Rules only when the section is relevant;
- reserve absolute language such as `always`, `never`, and `must` for genuine invariants;
- make unresolved ambiguity explicit rather than inventing requirements;
- return only the enhanced prompt, with no critique, preamble, score, or explanation;
- avoid expanding the prompt unless the added content materially improves behavior.

This is a transformation contract, not a fixed template. Short prompts should remain short when additional sections would add ceremony rather than clarity.

## Validation Contract

ClipVault validates every generated draft before persistence. A valid draft must:

- contain non-whitespace text;
- differ from its normalized source;
- pass the existing sensitive-content persistence rules;
- preserve deterministically observable source values such as numbers, URLs, email addresses, quoted literals, identifiers, and required formats;
- contain only the prompt rather than model commentary or wrapper text.

Prompt normalization trims leading and trailing whitespace, trims trailing whitespace on each line, and collapses repeated blank lines. If the normalized output equals the normalized source, ClipVault reports that the source is already well structured and saves none of the batch. The validator does not attempt semantic-equivalence scoring. It rejects known commentary wrappers such as `Here is the enhanced prompt:` but does not make unsupported claims about detecting every possible wrapper. Validation must remain deterministic and conservative. It must not attempt a second generative rewrite or silently weaken the preservation rules.

## Architecture

### Dedicated on-device enhancer

Introduce a small `PromptEnhancing` boundary with availability and single-source enhancement operations. `FoundationModelsPromptEnhancer` is the production implementation. It creates a fresh on-device language-model session for each source and does not route through `LocalClipAIActionProvider` or any cloud fallback.

The enhancer returns a draft containing the source clip identifier and enhanced text. It does not persist clips or mutate workspace state.

Tests use an injected deterministic enhancer to produce success, unchanged-output, unavailability, cancellation, and failure scenarios without requiring Apple Intelligence.

### Batch orchestration

The view model determines a stable source array when the action starts:

1. use AI-selected clips when that set is nonempty;
2. otherwise use the open clip;
3. reject an empty source array before starting work.

It enhances sources sequentially, validates each draft, and keeps all accepted drafts in memory. It checks task cancellation between sources and before persistence. The first failure stops the batch and discards every draft.

Only after all drafts pass validation does the view model call one store operation to persist the batch. On success it reloads the workspace, retains the current source selection, publishes the success result, and makes **Open Prompts** available.

### Atomic generated-prompt persistence

Extend the `ClipStoring` boundary with one generated-prompt batch operation shared by the SwiftData and in-memory implementations. Each draft becomes a normal encrypted text clip with:

- title `Enhanced — <source title>`, trimmed to the app's existing title-length boundary;
- enhanced text as both display and extracted text;
- explicit `prompts` collection membership in addition to applicable built-in kind membership;
- `sourceApp` set to `ClipVault AI`;
- metadata key `promptSourceClipID` containing only the local source clip identifier.

The operation validates the canonical Prompts destination, creates every clip, applies memberships, and commits once. SwiftData uses the existing rollback discipline so a failed save leaves memory and disk unchanged. The in-memory store stages changes in a copy and publishes them only after the whole operation succeeds.

Generated outputs still use the existing fingerprint and sensitive-content rules. A duplicate or rejected payload fails the batch rather than incrementing an unrelated source clip or reporting a false save.

## Default Collection Migration

The workspace-default reconciliation becomes additive and idempotent so existing stores receive newly introduced defaults without rebuilding the entire folder tree.

On startup:

1. Ensure exactly one collection with canonical identifier `prompts` exists under the default Collections root, creating it when absent.
2. Find every other manual collection node whose trimmed title equals `Prompts` case-insensitively.
3. Replace each matching collection membership on clips with `prompts`, preserving all other smart and manual memberships.
4. Remove only the adopted duplicate collection nodes after membership transfer succeeds.
5. If no matching collection exists, leave the canonical node empty.

Multiple matching custom Prompts collections are merged into the one canonical destination. Folder and membership changes occur in one rollback-protected transaction. A failure leaves the pre-migration folder tree and clip memberships intact. Re-running reconciliation after success performs no further mutation.

No collection is adopted solely because its identifier contains `prompt`; title matching is exact after whitespace trimming and case folding.

Move semantics distinguish smart membership from manual membership rather than treating every default identifier as smart. The protected Prompts node is a valid menu and drag/drop destination. Moving a clip from Prompts to another manual collection removes its `prompts` membership while preserving kind-derived smart memberships.

## State and Error Handling

- `idle`: action is available when a source and on-device model are available.
- `enhancing(current:total)`: all AI actions are disabled; progress and Cancel are visible.
- `saving`: cancellation is disabled once the atomic store commit begins.
- `success(count)`: result text and Open Prompts are visible.
- `failed(sourceTitle, reason)`: no drafts are saved; retry remains available when the model is available.
- `cancelled`: no drafts are saved and the prior source selection remains intact.

User-visible errors are stable and concise. Private model, encryption, and storage details remain in structured app logs. Error text never includes prompt bodies.

## Privacy and Safety

- Source and generated text stay on-device.
- Production enhancement is unavailable when Apple Foundation Models is unavailable; there is no heuristic or cloud fallback.
- Generated clips use the same encrypted payload and encrypted list-detail storage as ordinary clips.
- Source references contain only ClipVault-local clip identifiers.
- Existing sensitive-content exclusion applies before any generated draft is persisted.
- The feature does not change clipboard-capture consent or copy generated text to the pasteboard automatically.

## Accessibility and Motion

- The compact icon exposes `Enhance Prompt` as its accessibility label and explains that it creates one saved prompt per source clip.
- Progress is announced as a value with current and total counts.
- Cancel and Open Prompts are keyboard reachable.
- Success and failure are conveyed by text, not color alone.
- Existing Reduce Motion behavior applies; no new decorative or looping animation is introduced.

## Verification

### Enhancer and validation

- Builds one request per source and never combines selected clips.
- Preserves source language and explicit concrete values in representative fixtures.
- Rejects empty, unchanged, commentary-wrapped, sensitive, and value-dropping drafts.
- Reports Apple Intelligence unavailability without invoking persistence.

### View-model batch behavior

- AI selection takes precedence over the open clip.
- The open clip is used when AI selection is empty.
- Success produces one draft and one stored prompt per source.
- Generation, validation, cancellation, or store failure saves zero prompts.
- Processing order and progress counts are deterministic.
- Source selection remains stable after success and failure.
- Open Prompts selects the canonical collection only after successful persistence.

### Store and migration behavior

- Both stores atomically save generated prompt batches with encrypted payloads, canonical membership, and source metadata.
- Duplicate/rejected payloads and forced persistence failures roll back the entire batch.
- Fresh stores contain one protected Prompts collection.
- Existing stores gain the missing default without losing custom folders.
- One or multiple case-insensitive custom Prompts collections merge without losing clip memberships.
- Migration failure rolls back folders and memberships in memory and on disk.
- Re-running migration is idempotent.

### UI and runtime proof

- Verify full and compact Enhance Prompt controls, labels, hints, disabled reasons, progress, cancellation, success, failure, and Open Prompts.
- Exercise one source and multiple sources in the exact signed app on macOS 27.
- Verify generated prompts survive relaunch and originals remain unchanged.
- Run the complete Swift/Rust test suite, Release warnings-as-errors, strict Rust checks, signed launch verification, E2E smoke, codesign/privacy/linkage checks, and runtime-log review.

## Non-Goals

- OpenAI API integration, model selection, API-key storage, or cloud fallback.
- Combining several source clips into one prompt.
- Automatically replacing, moving, deleting, or copying the original clip.
- Editing the generated prompt before the successful atomic save.
- General-purpose prompt scoring, prompt-version history, or evaluation against downstream model outputs.
- Making Prompts a user-removable custom collection.
