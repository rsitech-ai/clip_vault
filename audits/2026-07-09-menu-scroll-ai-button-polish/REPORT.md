# ClipVault Menu Scroll And AI Button Polish Audit

Date: 2026-07-09
Branch: `feat/andrzej_menu_scroll_ai_button_polish`
Installed app: `/Applications/ClipVault.app`

## Issue
- Menu-bar scrolling was still unreliable. Source review confirmed that hover changed `statusMenuFocusIndex`, and every focus-index change triggered `ScrollViewReader.scrollTo(...)`. That meant normal pointer scrolling could be pulled back toward the hovered/selected row.
- A larger result cap initially exposed another popover-specific problem: `LazyVStack` could render a blank list after wheel scrolling inside `MenuBarExtra`.
- Inline AI Workspace action buttons were icon-only and visually flat, so their purpose relied too much on memory.

## Fix
- Menu popover:
  - Increased available menu results from 18 to 80 so scrolling has meaningful depth without trying to render an unbounded history in the popover.
  - Replaced `LazyVStack` with `VStack` for the capped menu results to avoid blank lazy-row rendering in the status popover.
  - Stopped auto-scrolling on every hover/focus change.
  - Added a `keyboardScrollTargetID` so only keyboard navigation requests `scrollTo(...)`.
- AI Workspace:
  - Added per-action colors:
    - Summarize: cyan.
    - Explain: indigo.
    - Email: teal.
    - Todos: green.
    - Ask: accent color.
  - Added centralized action hints in `ClipVaultDesign`.
  - Added action-specific tooltips and accessibility hints for the AI controls.

## Visual Evidence
The repo ignores audit screenshots, so these are local verification artifacts:
- Initial menu popover with rendered rows: `audits/2026-07-09-menu-scroll-ai-button-polish/screenshots/menu-eager-initial.png`
- Menu after wheel scroll leaves the original selected row: `audits/2026-07-09-menu-scroll-ai-button-polish/screenshots/menu-eager-after-scroll-positive.png`
- Final colored AI controls: `audits/2026-07-09-menu-scroll-ai-button-polish/screenshots/ai-buttons-colored-final.png`

## Verification
- `swift build -Xswiftc -warnings-as-errors` passed.
- `./script/test.sh` passed:
  - Rust search index: 2 tests.
  - Swift test run: 23 tests across 10 suites.
- `./script/build_and_run.sh --verify` passed and produced a signed production bundle.
- Replaced `/Applications/ClipVault.app` from `dist/ClipVault.app`.
- Installed-app menu smoke:
  - Popover rows render with the 80-result cap.
  - Wheel scrolling moves the visible list away from the initially selected row.
  - The list no longer blanks after scroll.
- Installed-app AI visual smoke:
  - Colored AI action buttons are visible in the inline workspace.
  - Ask field and button remain visible at 900 x 572.
- App-authored error/fault logs were clean:
  - predicate: `subsystem == "com.andrzej.ClipVault" AND (messageType == error OR messageType == fault)`.

## Notes
- Synthetic reverse wheel events did not consistently move the secondary-display popover back in automation. The positive wheel event did prove the important regression point: the list can now leave the selected row instead of snapping back or blanking.
- The menu remains capped for speed and stability. Users should search to reach older clips beyond the first 80 visible results.

## Readiness
Smoke-clean for the menu-bar scroll regression and AI action-button polish.
