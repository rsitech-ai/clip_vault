# Reflection Entry: ClipVault Release Polish Audit

## Task
- **ID/Title:** 2026-06-29 release polish and end-to-end audit
- **Date:** 2026-06-29
- **Scope:** repo-wide

## Plan and Risks
- **Planned approach:** Inspect app architecture, run automated tests and bundle smoke, audit persistence/capture/pasteback/OCR/UI/AI fallback paths, fix concrete issues, then rerun release checks and document remaining blockers.
- **Top failure hypotheses:** Durable storage may not survive relaunch reliably; menu bar pasteback or image/OCR capture may work only in partial cases; release packaging may pass local checks while hiding sandbox/signing or performance problems.
- **Success criteria:** Tests pass, app bundle launches, persisted clips survive restart, clipboard pasteback is verified for text/image paths where possible, release scripts give clear blockers, and any remaining App Store gaps are explicit.

## Candidate Attempts
| Candidate | Summary | Outcome | Signals | Why selected / rejected |
|---|---|---|---|---|
| A | Static code audit plus current unit/build checks. | Passed after targeted fixes. | `./script/test.sh`, `swift build -c release`, `git diff --check`. | Selected as the baseline because it is reproducible. |
| B | Real app smoke with pasteboard mutation, app relaunch, and storage inspection. | Passed after making the smoke poll for real app persistence. | `./script/e2e_smoke.sh`. | Selected because the user asked for end-to-end behavior beyond tests. |

## Reflection
- **Failure modes observed:** Storage startup used `fatalError`; custom collection headers/assignment were incomplete; the first E2E smoke used fixed sleeps and failed before the app had persisted the capture; workspace windows can restore to stale offscreen coordinates in multi-display states.
- **Root cause:** Prototype defaults optimized for initial scaffold speed instead of release recovery; the smoke harness assumed capture timing; SwiftUI window restoration can keep old display coordinates.
- **Fix that resolved it:** Added non-crashing storage fallback, faster SwiftData fingerprint lookup, selected-clip assignment to custom collections, collection title restoration from folder records, privacy-safe logging, polling E2E smoke, production plan, and offscreen-window recovery after workspace open paths.
- **What improved score/quality:** The app now has evidence for real pasteboard capture, dedupe, persistence, and restart recovery; custom collections are usable for selected clips; storage failure reports a recoverable status instead of crashing.
- **Useful command-level evidence:** `./script/test.sh` passed 15 Swift tests plus Rust tests; `swift build -c release` passed; `./script/e2e_smoke.sh` passed; `./script/app_store_check.sh` passed local checks and exited 3 only for missing installer identity; `git diff --check` passed.
- **Branch comparison insight (if multiple attempts):** Not applicable.

## Reusable Lesson
- **Pattern that worked:** Release smoke should drive the real `.app`, mutate the real pasteboard, and inspect durable state after restart.
- **Pattern to avoid:** Fixed sleep-only smoke checks for asynchronous clipboard capture.
- **Where to apply next:** App Store packaging flow after the Mac installer distribution certificate is installed.

## Decision
- **Final chosen approach:** Keep the menu-bar-plus-window architecture, harden recovery and persistence paths, and treat Mac App Store upload as blocked only on account/signing assets.
- **Commit/rollback decision:** No commit unless explicitly requested.
- **Next step / follow-up:** Install `Mac Installer Distribution` / `3rd Party Mac Developer Installer` certificate, decide final App Store name and bundle ID, then run `./script/package_app_store.sh`.
