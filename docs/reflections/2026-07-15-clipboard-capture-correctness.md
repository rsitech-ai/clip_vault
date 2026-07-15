# Clipboard Capture Correctness Reflection

## Task
- **ID/Title:** ClipVault clipboard capture correctness
- **Date:** 2026-07-15
- **Scope:** multi-file

## Plan and Risks
- **Planned approach:** Reproduce at the pasteboard/store seams, repair duplicate recency and polling latency test-first, characterize exact full-payload write-back, then scope ⌘C to the focused clip list.
- **Top failure hypotheses:** (1) duplicate capture succeeds but retains stale ordering; (2) 0.8-second polling makes external copies appear missing; (3) parsing or write-back truncates or deprioritizes text; (4) an overly broad keyboard handler steals copy from editors.
- **Success criteria:** Normal external copies are captured exactly within 650 ms in an isolated production-default test; duplicate recapture keeps one identity and returns to the top; selected-list ⌘C writes the full stored payload; full strict, test, signing, and bounded runtime gates pass.

## Candidate Attempts
| Candidate | Summary | Outcome | Signals | Why selected / rejected |
|---|---|---|---|---|
| A | Refresh duplicate capture time, poll every 250 ms, preserve exact payload paths, and add list-focused ⌘C. | Passed | RED/GREEN store ordering; 287–359 ms exact capture; full suite and signed bundle green. | Selected as the smallest change aligned with macOS pasteboard semantics. |
| B | Store every duplicate as a separate row or install a global keyboard event tap. | Rejected | Adds clutter, permissions, privacy risk, and competing copy ownership. | Unnecessary for the stated behavior and inconsistent with existing deduplication. |

## Reflection
- **Failure modes observed:** Both stores captured duplicates but left them below a newer clip. Production-default monitoring captured nothing within approximately 695 ms. The first inline SwiftUI key closure also exceeded the compiler's type-check budget, and the single-key overload did not expose modifier data.
- **Root cause:** Duplicate captures refresh `updatedAt` and `copyCount` but not the `createdAt` field used for recency ordering; the 0.8-second timer also creates an avoidably large visibility/overwrite window.
- **Fix that resolved it:** Assign one capture timestamp to duplicate `createdAt` and `updatedAt`, reduce default polling from 800 ms to 250 ms, preserve exact payload parsing/writing, and isolate the modifier-aware key handler in a small list-local `ViewModifier` using the multi-key overload.
- **What improved score/quality:** Tests now exercise the actual default timer, encrypted and in-memory stores, exact multiline Unicode round-trip, identity preservation, copy count, ordering, and user-detail preservation. Verification never touched the general pasteboard.
- **Useful command-level evidence:** Focused RED failures at `ClipEnhancementTests.swift:51`, `ClipStorageEncryptionTests.swift:129`, and 695 ms clipboard timeout; focused GREEN capture at 287 ms; `./script/test.sh` passed 161 Swift plus 4 Rust tests; warnings-as-errors build, `git diff --check`, signed release build, strict codesign, exact PID launch, and clean targeted logs passed.
- **Branch comparison insight (if multiple attempts):** Candidate A retains existing architecture and rollback simplicity.

## Reusable Lesson
- **Pattern that worked:** Test the OS boundary with an isolated named pasteboard and test persistence semantics in both store implementations.
- **Pattern to avoid:** Treating a successful deduplication count increment as proof the user can see a recaptured item.
- **Where to apply next:** Any recency-sorted deduplicating capture or import workflow.

## Decision
- **Final chosen approach:** Candidate A.
- **Commit/rollback decision:** One focused local commit; rollback is a single commit revert with no migration.
- **Next step / follow-up:** Keep the feature branch intact after the focused local commit; do not push or merge without owner direction.
