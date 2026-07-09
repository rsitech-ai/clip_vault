# ClipVault AI Workspace Response UX Audit

Date: 2026-07-09
Branch: `feat/andrzej_ai_workspace_response_ux`
Installed app: `/Applications/ClipVault.app`

## Issue
The inline AI Workspace could still hide most of an Ask response at a normal 900 x 572 workspace size. The previous layout placed the response below a tall multi-row action area and capped the panel height, so the answer behaved like a short footer instead of the main content.

## Fix
- Reworked inline AI Workspace layout into a chat-like structure:
  - header at the top;
  - scrollable answer pane in the middle with real vertical expansion;
  - compact action and Ask controls pinned at the bottom.
- Kept the inspector placement behavior separate so the older compact inspector layout is not forced onto the inline workspace.
- Changed inline action controls from large labeled buttons to 32 px icon buttons with tooltips and accessibility labels.
- Removed the 360 px cap from the inline AI panel and adjusted the detail/AI split sizing so the response pane gets more vertical room at small window heights.
- Kept the Ask button label visible by giving the button a fixed intrinsic width.

## Visual Evidence
The repo intentionally ignores screenshots under audit folders, so these are local verification artifacts:
- Empty-state layout at 900 x 572: `audits/2026-07-09-ai-workspace-response-ux/screenshots/workspace-final-empty-labelled-ask.png`
- Ask response layout at 900 x 572: `audits/2026-07-09-ai-workspace-response-ux/screenshots/workspace-final-ask-response.png`

## Verification
- `swift build -Xswiftc -warnings-as-errors` passed.
- `./script/test.sh` passed:
  - Rust search index: 2 tests.
  - Swift test run: 23 tests across 10 suites.
- `./script/build_and_run.sh --verify` passed and produced a signed production bundle.
- Replaced `/Applications/ClipVault.app` from `dist/ClipVault.app`.
- `codesign --verify --deep --strict --verbose=2 /Applications/ClipVault.app` passed.
- Installed-app smoke at 900 x 572:
  - AI Workspace answer pane is readable and scrollable.
  - action controls remain visible below the response pane.
  - Ask field accepts a prompt.
  - Ask button enables and returns a response.
- App-authored error/fault logs were clean:
  - predicate: `subsystem == "com.andrzej.ClipVault" AND (messageType == error OR messageType == fault)`.
- Idle installed process sample: 0.0% CPU at the time of sampling.

## Readiness
Smoke-clean for the AI Workspace response UX surface. The app is installed locally with the fix.
