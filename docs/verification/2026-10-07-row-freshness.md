# Stable clip row freshness verification

## Failure boundary

A signed release runtime with an existing 841-clip library reproduced a same-ID duplicate capture whose list row remained at four copies and the earlier time. Temporary tracing reported five copies and the new capture time in the saved clip, workspace section result, and indexed clip lookup. The selected detail showed the new time. Accessibility output and rendered inspection agreed on the stale row. Only one app process owned the library during this reproduction.

This isolates the stale display to the row's captured value and observation boundary; it does not establish a SwiftUI framework defect. Small isolated-library controls updated correctly and did not reproduce the failure.

## Correction

Each workspace row keeps its stable clip ID and resolves the current clip from the existing indexed workspace projection inside its own observed body. Presentation, selection, context actions, and drag preview consume that value. No additional cache, persistence authority, versioned view identity, timer, or clipboard rewrite is introduced. Temporary diagnostic tracing was removed.

This follows Apple's [model observation guidance](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app): a view tracks observable properties read in its body's execution scope.

## Observed validation

- `./script/test.sh`: exit 0; 228 core tests, six app tests, four Rust tests, and shell checks passed.
- The new app test checks same-ID duplicate observation notification, copy count, capture time, section/menu/detail/store agreement, title edits, pin state, missing IDs, and reload persistence. It does not render SwiftUI.
- A rebuilt signed release app using the same existing library updated the affected row from five to six to seven copies immediately on native TextEdit recopy, showing the new time without refresh or restart.
- Pin and unpin updates appeared immediately in the row; the original pin state was restored.
- Independent read-only source review found no confirmed blocker.
- `git diff --check`: exit 0.
- `swift build -c release -Xswiftc -warnings-as-errors`: exit 0 (Rust release library already built by the project test wrapper).

Final-head CI, installed exact-main identity, and restart persistence are recorded separately in delivery evidence; these are not implied by the checks above.

## Device limits

Incoming iPhone-to-Mac native paste was reported working earlier, while its capture and outgoing Mac-to-iPhone paste failed. A native TextEdit outgoing control also failed with ClipVault fully closed. Transfer timing for that earlier asynchronous control was not independently observed. A new fresh-copy control is pending.

This row correction does not claim to fix the system transfer failure, establish an OS root cause, or prove newest-build physical device capture. The second Mac was excluded by the user.
