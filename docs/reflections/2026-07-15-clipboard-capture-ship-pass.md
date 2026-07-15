# Clipboard Capture Ship-Pass Reflection

## Task
- **ID/Title:** Review, merge, and redeploy ClipVault clipboard/selection changes
- **Date:** 2026-07-15
- **Scope:** branch integration and local deployment

## Plan and Risks
- **Planned approach:** Compare the feature branch with fetched `origin/main`, classify all uncommitted content, inspect GitHub PR/CI state, review the complete true delta, run the repository CI matrix plus signed E2E and live UI smoke, then merge and deploy only after a positive ship decision.
- **Top failure hypotheses:** stale local `main` exaggerates the diff; user-owned untracked audit/monetization evidence is accidentally included; a zero-step GitHub failure is mistaken for a code failure; the built bundle differs from the running app.
- **Success criteria:** No unresolved review finding; complete local CI matrix and signed E2E pass; selection-mode UI smoke passes; untracked files remain unchanged; merged `main` passes fresh gates; exact installed bundle signature, executable, process, and logs are verified.

## Candidate Attempts
| Candidate | Summary | Outcome | Signals | Why selected / rejected |
|---|---|---|---|---|
| A | Reconcile fetched Git history, exclude unrelated untracked evidence, verify the four-commit true delta locally, then merge and redeploy. | Selected | `origin/main...HEAD` is 13 files; complete local CI and live UI smoke passed. | Preserves user work and evaluates the actual unmerged code. |
| B | Treat stale local `main` as the base and merge all untracked audit/monetization files. | Rejected | Produces a misleading 82-file review and mixes product code with separate evidence/strategy artifacts. | Violates scope and user-change preservation. |

## Reflection
- **Failure modes observed:** Local `main` was behind the already-merged PR #9, making the initial comparison appear to contain approximately 10.9k new lines. Historical GitHub jobs failed in four seconds with zero steps, so they supplied no repository failure signal.
- **Root cause:** Comparison and CI-state drift, not a source defect. `origin/main` contains merge commit `9bc9831`; only four local commits remained unmerged at review start.
- **Fix that resolved it:** Fetch before comparison, use `origin/main...HEAD`, inspect zero-step job metadata, and reproduce every CI command locally.
- **What improved score/quality:** Added independent Rust format/Clippy/audit coverage, full Swift and shell gates, isolated signed capture/dedupe/persistence/restart E2E, strict codesign, exact-PID launch, accessibility UI proof for Select Clips/Done, and error/fault log inspection.
- **Useful command-level evidence:** `gh pr list`, `gh run view`, `git rev-list`, Rust CI commands, `./script/test.sh`, warnings-as-errors Release build, `./script/e2e_smoke.sh`, `./script/build_and_run.sh --verify`, `codesign --verify --deep --strict`, exact `pgrep`, Computer Use accessibility inspection, and unified logs.
- **Branch comparison insight (if multiple attempts):** Fetched `origin/main` reduced the review surface from 82 accumulated files to the real 13-file, four-commit delta.

## Reusable Lesson
- **Pattern that worked:** Fetch and compare to the remote integration tip before measuring a long-lived feature branch; classify zero-step CI separately from executed-test failures.
- **Pattern to avoid:** Staging untracked audit or strategy artifacts during a functional merge solely because they share the repository root.
- **Where to apply next:** Any reused feature branch that continues after a prior PR merge.

## Decision
- **Final chosen approach:** Candidate A; ship decision is `ready with noted risk` because current GitHub-hosted CI cannot execute, while the complete equivalent local matrix is green.
- **Commit/rollback decision:** Preserve the feature branch; create a normal merge commit on current `main`; never rewrite published history. If merge-result gates fail, do not push.
- **Next step / follow-up:** Push the feature branch, confirm current CI classification, merge into fetched `main`, rerun gates, push `main`, and deploy the exact merged bundle.
