# Independent clipboard capture progress

## Cause and scope

Baseline: merged commit `f603b0082af107717e5a807bc5292db7d289141e`.

The clipboard service assigned a sequence to every asynchronous payload conversion and delivered results only after every preceding sequence completed. A synchronous Vision OCR request waiting for a system service could therefore prevent a later completed text capture from reaching persistence. Runtime sampling found two clipboard image conversions waiting inside Vision; a controlled regression independently reproduced the delivery dependency.

This repair addresses capture progress. It does not establish the cause of Apple's Universal Clipboard transport failure. The user confirmed wireless iPhone-to-Mac paste in another Mac app, but initially reported no visible ClipVault entry and failed outgoing paste from both TextEdit and ClipVault. The test marker subsequently appeared in All Clips; its exact arrival delay and device origin were not independently established. The app was displaying a custom collection when later inspected.

## Repair

- Run synchronous payload conversion on a concurrent Dispatch queue rather than blocking Swift's cooperative executor.
- Deliver completed captures independently; retain consent/lifecycle generation checks.
- Pass the time content was observed through the capture callback and both store implementations. Late completion preserves history chronology.
- An older duplicate increments its copy count without replacing newer payload content or moving its capture time backwards. Existing annotations remain intact.
- Sort the live workspace by capture time and preserve the newest selection when an older capture completes later.

The obsolete sequence counters and completed-result dictionary are removed. Clipboard contents are read without rewriting them. Sensitive-item classification and encrypted storage remain in the persistence path. There is no storage schema migration.

The public capture callback now includes observation time. Custom `ClipStoring` conformances must implement the time-aware save method; the existing two-argument save call remains available through the protocol extension.

## Verification

| Check | Observed result |
|---|---|
| `./script/test.sh`, baseline plus new stalled-payload regression | Exit 1: the completed newer text produced no callback while the earlier job remained unfinished. Other existing core tests, four app tests, four Rust tests and shell checks passed. |
| `./script/test.sh`, final source | Exit 0: 228 core tests, five app tests, four Rust tests and shell checks passed. |
| `cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml --check` | Exit 0. |
| `cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings` | Exit 0. |
| `cargo audit --file rust/SearchIndexCore/Cargo.lock` | Exit 0, no reported vulnerable dependency. |
| `swift build -c release -Xswiftc -warnings-as-errors` | Exit 0. Rust release library built first by the project test wrapper. |
| `./script/e2e_smoke.sh`, stable local signing identity | Exit 0: signed isolated capture, deduplication, persistence and restart recovery. Test namespace cleaned by the script. |
| `./script/build_and_run.sh --stage`, production candidate build 5 | Exit 0. No E2E probe marker, strict nested signatures verified, designated requirement matches the installed build. |
| Native signed candidate | Loaded the existing 835-clip library with capture active. Recopied harmless text through TextEdit's native Copy; the next UI observation showed the duplicate count advancing from one to two. |
| Independent review | Separate read-only reviewer found no reproducible merge blocker in the final six source/test files. |
| `git diff --check` | Exit 0. |

New assertions cover progress while an earlier job is unfinished, observation times across out-of-order completion, late duplicate content/recency, and live workspace/menu order, selection and reload.

## Remaining evidence and risks

- An indefinitely blocked Vision request still retains its work and snapshot. This patch prevents unrelated completed captures from waiting for it; it does not prove recovery of OCR itself.
- Pasteboard snapshot reads still occur on the main actor and may wait for an external representation.
- The asynchronous gate regression exercises delivery dependency. It does not reproduce a stalled native Vision implementation.
- Final physical iPhone capture and outgoing transfer checks against build 5 are pending a user receipt. Native TextEdit Copy was independently verified to populate the Mac clipboard with the exact harmless phrase and standard text/RTF representations. This does not prove device delivery.
- Current-host Handoff advertising and receiving preferences were both enabled. The native Handoff process reconnected to the restarted clipboard service; a stale-connection hypothesis was rejected without another restart.
- No account, security, network or pairing reset was performed. The company Mac is excluded at the user's request; a policy restriction is unverified.
- AppKit negative view geometry faults were observed in the prior running build. Their source and relevance remain unconfirmed; startup-only clean logs are not evidence of clean lifetime logs.

Apple documents that the general pasteboard participates automatically in Universal Clipboard and provides no separate macOS API for the feature: [NSPasteboard](https://developer.apple.com/documentation/appkit/nspasteboard). Its [change count](https://developer.apple.com/documentation/appkit/nspasteboard/changecount) tracks ownership changes. Apple's [Universal Clipboard guidance](https://support.apple.com/en-gb/102430) defines the device setup and transfer requirements; source and isolated tests cannot substitute for physical device receipts.
