# Clipboard Capture Correctness Implementation Plan

> **Execution:** Implement each behavior change test-first using the repository `tdd` and `diagnose` contracts. No subagent work is authorized for this task.

**Goal:** Make ordinary macOS copy actions—third-party Copy buttons and ⌘C—appear promptly and visibly in ClipVault with the exact full payload, and let ⌘C copy the selected ClipVault row when the list owns keyboard focus.

**Architecture:** Keep `NSPasteboard` as the single system boundary. Repair duplicate recapture semantics in both store implementations by treating a duplicate as a new capture event without creating a second record, reduce the default monitor interval to a bounded 250 ms, retain exact payload parsing/writing, and scope the new keyboard command to the focusable clip list.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit `NSPasteboard`, SwiftData, Swift Testing, SwiftPM, existing ClipVault scripts.

## Global Constraints

- Support macOS 15+ and map the user's "ctrl+c" wording to the native macOS ⌘C copy command.
- Add no dependency, entitlement, accessibility permission, event tap, schema migration, or global keyboard interception.
- Preserve clip identity, title override, note, tags, pin state, collections, and encrypted full payload when identical content is recopied.
- Use only isolated named pasteboards in automated tests; do not mutate the user's real clipboard or history for verification.
- A polling client cannot recover a clipboard value that another copy overwrites before the next poll. The supported contract is prompt capture of normal macOS copy actions while capture is enabled, not impossible recovery of every sub-interval transient value.
- Preserve all existing untracked audit and documentation directories. Do not push, merge, upload, publish, or change external Apple state.

---

### Task 1: Duplicate Recapture Becomes the Most Recent Clip

**Files:**
- Modify: `Tests/ClipVaultCoreTests/ClipEnhancementTests.swift`
- Modify: `Tests/ClipVaultCoreTests/ClipStorageEncryptionTests.swift`
- Modify: `Sources/ClipVaultCore/Services/ClipStore.swift`

- [x] Add an in-memory regression test that saves payload A, then B, then A again and requires one A record with the original ID, `copyCount == 2`, a refreshed full payload, and A first in `allClips()`.
- [x] Run the focused test and record RED: A remains below B because its original `createdAt` is unchanged.
- [x] Update only the in-memory duplicate branch so one captured `now` becomes both `createdAt` and `updatedAt`; retain identity and user metadata.
- [x] Add the equivalent encrypted SwiftData regression test, including exact payload retrieval and preservation of title/note/tags.
- [x] Run the persistent test and record RED, then apply the same event-time semantics to the SwiftData duplicate branch.
- [x] Run both focused suites and record GREEN.

### Task 2: Prompt Exact External Clipboard Capture

**Files:**
- Modify: `Tests/ClipVaultCoreTests/ClipboardCaptureServiceTests.swift`
- Modify: `Sources/ClipVaultCore/Services/ClipboardCaptureService.swift`

- [x] Add an async test using a unique named pasteboard and the production default `start()` that writes a long multiline Unicode string after capture starts and requires exact capture within 650 ms.
- [x] Run the focused test and record RED against the current 800 ms default.
- [x] Reduce the production default interval to 250 ms without changing lifecycle generation or stopped-capture behavior.
- [x] Run the focused capture suite and record GREEN, including start rebaseline and in-flight invalidation coverage.

### Task 3: Full Write-Back and Focused-List ⌘C

**Files:**
- Modify: `Tests/ClipVaultCoreTests/PasteboardWriterTests.swift`
- Modify: `Sources/ClipVault/Views/ClipListView.swift`

- [x] Strengthen the text writer characterization test with long multiline Unicode content and require exact equality on the isolated pasteboard.
- [x] Add a ⌘C key handler to the existing focusable clip list, guard on the Command modifier, copy `model.selectedClip`, and return `.ignored` otherwise so editor controls retain normal copy behavior.
- [x] Compile with warnings as errors to validate the SwiftUI key API and run the focused writer tests.

### Task 4: Verification, Evidence, and Focused Commit

- [x] Run focused store, capture, and writer test suites.
- [x] Run `swift build -Xswiftc -warnings-as-errors`, `./script/test.sh`, and `git diff --check`.
- [x] Run `./script/build_and_run.sh --verify`; verify the exact staged bundle, app launch, and clean targeted logs without placing a QA value on the general pasteboard.
- [x] Update this plan and `docs/reflections/2026-07-15-clipboard-capture-correctness.md` with exact evidence.
- [x] Stage and commit only the intentional source, test, repository plan, and reflection files on `feat/andrzej_agent_sota_lab`; the root HQ ExecPlan remains outside this Git repository.

## Execution Result — 2026-07-15

- Both recency regressions failed before implementation because the intervening record remained first. After the focused store change, the in-memory and encrypted SwiftData suites passed while retaining the original clip ID, `copyCount == 2`, refreshed full payload, and encrypted title/note/tag details.
- The production-default monitoring test failed before implementation with no payload after approximately 695 ms. With the 250 ms default, exact multiline Unicode capture passed in approximately 287 ms focused and 359 ms in the full parallel suite.
- Exact long multiline Unicode write-back passed on an isolated named pasteboard. The list-local ⌘C modifier compiled with warnings as errors and returns `.ignored` for non-Command key presses or no selection.
- `./script/test.sh` passed 161 Swift tests in 17 suites plus 4 Rust tests and all shell validation gates. `git diff --check` passed.
- `./script/build_and_run.sh --verify` produced and launched `<repository-root>/dist/ClipVault.app`; `codesign --verify --deep --strict --verbose=2` passed, the exact executable was running as PID 80721, and targeted current-process logs had no error, fault, assertion, or fatal signal.
- No QA content was placed on `NSPasteboard.general`; automated clipboard checks used unique named pasteboards, so the user's real clipboard and ClipVault history were not mutated by verification.
- The focused implementation and evidence were committed locally and the feature branch was preserved without push, merge, or cleanup.

## Rollback

Revert the focused commit. The implementation changes event timestamps, polling cadence, and list-local keyboard routing only; it requires no persistence migration and deletes or rewrites no existing clip.
