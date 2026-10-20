# Linux and encrypted sharing verification

Date: 2026-10-20

**Verdict: code review PASS for a draft PR; HOLD merge and cross-device readiness.** The canonical Mac app has been upgraded locally and its complete prior history verified. The final x86_64 Linux package, protocol interoperability, isolated GNOME selection reads and actual-host staged relay restart checks pass. Updated installed Ubuntu capture and physical Mac–Ubuntu clipboard delivery still require acceptance. This report does not claim a published release, long-term uptime, or an error-free environment.

## Source, authority and scope

- Branch `feat/andrzej_linux_encrypted_sync`, base `ea4edf1`; canonical repository `rsitech-ai/clip_vault`.
- The user approved Linux/GNOME plus encrypted sharing, private relay setup, comprehensive fixes/restarts/review, a PR and conditional merge only after stability. The additional Mac-history preservation request was carried through a controlled local upgrade.
- Owner `AGENTS.md` is preserved and excluded from the PR. Docker Desktop was not restarted; unrelated workloads and the active Ubuntu desktop session were preserved.
- Mac remains SwiftUI/AppKit + SwiftData; Linux uses GTK4/libadwaita. Shared Rust owns protocol, encrypted local sync state, pairing and HTTP transport. The relay holds ciphertext and routing metadata.
- Existing history is not uploaded automatically. Notes, tags, pins, folders and file references remain local. Received clips enter history; explicit Copy changes the receiving clipboard.

## Final observed validation

| Check | Result and boundary |
| --- | --- |
| `./script/test_device_sync.sh` | PASS: 43 Rust tests, 1 intentionally ignored quota test; formatting and strict workspace/all-target Clippy. |
| `cargo test --manifest-path rust/DeviceSync/Cargo.toml -p clipvault-sync-relay --test relay mailbox_quota --locked -- --ignored` | PASS: explicit real 256 MiB mailbox test, including capacity after restart and acknowledgement recovery. An initial old fixture timestamp expired under the new startup maintenance; the corrected wall-clock fixture passes. No quota-store change was needed. |
| `./script/test.sh` | PASS: shell policies, original search Rust tests, 248 core Swift tests and 10 app Swift tests. |
| AMD64 `./script/test_linux.sh` with separate image/target volume and `LINUX_PLATFORM=linux/amd64` | PASS: 43 tests, GTK build and strict Clippy. Runs under x86_64 emulation on the ARM Mac. Final Linux UI refinements were then compiled again in the release package and passed strict Clippy. |
| `./script/build_linux.sh` inside the AMD64 builder | PASS: release `.deb`, x86_64 ELF, packaged GNOME adapter and bounded-transfer module, 281 dependency notices. Package SHA-256 `c798767a1c3d0fb480d4c8e7ae485c51744df3a3a744af7458e9b0f7252085ee`. |
| Final installed-package Ubuntu 26.10/Xvfb smoke | PASS: repeated activation keeps one window/worker, controlled text/PNG capture, exact Copy, consent toggles and rejection of an ordinary untrusted D-Bus caller. Screenshots inspected. This is a disposable virtual X11 session. |
| `python3 script/test_sync_interop.py --image clipvault-linux-amd64-validation --target-volume clipvault-linux-amd64-target --platform linux/amd64` | PASS: separate native Mac/Linux encrypted stores; pairing/comparison; text, exact PNG/RTF in both directions; applied receipts; duplicate suppression; offline process restart; pause; removal; controlled plaintext absent from pending relay envelopes. This uses test engines, not the two installed apps. |
| Genuine GNOME 51 target test | PASS: latest extension loaded ACTIVE in a separate headless Wayland Shell on the actual Ubuntu target. Actual Mutter selection reads passed exact text/PNG, exact-limit, oversize and cancellation checks. Private D-Bus/XDG state and synthetic clipboard fixtures were used; the real user clipboard was untouched. This does not qualify installed-session bridge capture or dbus-broker behavior. |
| Actual Ubuntu staged final relay/proxy | PASS: separate loopback ports and temporary test stores, native Linux test engines, pairing, pending ciphertext after SIGKILL/restart, one recipient application and sender acknowledgement. Proxy returned expected 413 for a declared 22 MiB body and 429 under a burst (45 success, 55 throttled). Test processes/stores were cleaned. |
| Installed older private relay | Both units active/enabled, `NRestarts=0`, `ExecMainStatus=0`; warning journal had no entries. Normal TLS `/health` returned 200/ok from both laptops. The installed Ubuntu relay/client predate the audit fixes; these are health observations, not proof the final source is deployed. |
| Mac staged/canonical build | PASS: project build script, Developer ID signature and canonical designated-requirement match, then local installation as 0.2.0. Original 0.1.1 app and a verified archive were retained. No signing-team mixture. |
| Actual Mac history upgrade | PASS: app-owned old-store snapshot and current-store logical comparison verified **895 clips and 12 folders**, including exact encrypted external payload bytes. All 895 primary/list payloads were readable. General settings displayed the receipt. A subsequent app restart still showed 895 clips, the 12-folder preservation receipt and cleanup paused. Sharing remains off. |
| Mac runtime logs | No app-specific storage/network failure was observed. A five-minute inspection did show AppKit geometry faults plus one BaseBoard task-port diagnostic. Symbolication traced every sampled geometry fault to `NSThemeFrame._positionSharingIndicator` / `NSWindowSharingSessionRecipientIndicator` during selective window sharing by UI inspection, not Settings frame arithmetic. These platform diagnostics are disclosed; logs are not called clean. |
| `cargo audit --file rust/DeviceSync/Cargo.lock` | Exit success, with three unmaintained warnings: `zbus_names` 3, `zvariant` 4, `zvariant_derive` 4. These optional Keyring branches are not selected by the configured synchronous Secret Service/macOS backends; target feature-tree check confirmed no selected `zvariant@4.2.0` path. Not described as a clean dependency audit. |
| `cargo deny --manifest-path rust/DeviceSync/Cargo.toml --config rust/DeviceSync/deny.toml check` | PASS: advisories, bans, licenses and sources. Duplicate-version advisory warnings remain visible. |
| GitHub workflows | Added/extended mandatory Mac and Linux checks. Their live status must be checked on the draft PR; local success does not establish CI success. |

Final logs and artifact receipts are retained locally under `dist/linux-deployment/20261020/`; package runtime screenshots are under `dist/linux-evidence/audit-final-amd64/`. Verification files are excluded from the [source manifest](linux-sync-source-manifest.json) to avoid recursion.

## Audit findings resolved

The independent whole-feature review and regression work found and fixed:

- Relay-origin/expiry substitution in pairing transcripts; credentials lost after a join response failure; non-atomic enrollment/invite consumption; terminal pending-state recovery; overwritten active invitations; paused pending joins re-enabled on reopen.
- Explicit disconnect/re-pair without deleting local history, with identity rotation and cancellation of old targets/platform outbox. It does not remotely revoke old membership; the old owner must remove it separately.
- Stale Mac consent responses and out-of-order persisted writes; queued FFI commands reopening pause; paused exports falsely completing; startup captures arriving before sharing consent was known.
- Linux duplicate activation windows/workers, stale queued sharing/capture consent, stale dialog state, asynchronous clipboard-owner changes and consent cycles, and unbounded compositor-side reads.
- Decoded RTF bytes bypassing the sensitive-content heuristic; permanently invalid Mac payloads retried every cycle; lifetime-row queue scans; escape-expanded JSON silently stuck behind the export batch cap.
- Unbounded lazy relay retention and pending storage; now startup/60-second maintenance, 30-day pending TTL, 37-day terminal metadata retention, recipient/global quotas and row caps. Sender first-attempt expiry prevents resubmission after metadata pruning. Invitation-ID tombstones have an explicit 100,000 lifetime capacity, with at most 16 workspaces.
- Oversized unauthenticated joins: 8 KiB request-body limit before JSON validation; proxy concurrency reduced to four under the service memory ceiling.
- Migration backup missing external assets; a damaged historical backup blocking later healthy starts; interrupted legacy-detail normalization before completion; and retention deleting pre-upgrade history on a later launch.

New migration tests use the exact legacy two-entity schema, AES-GCM payloads, annotations/tags/pins/folders/copy counts and large external data. They verify an immutable backup, all-field equality after adding sync entities, altered/missing/corrupt-asset rejection, and nonmutating readability across legacy detail formats. Receipt and durable cleanup hold are committed before normalizing reads. Cleanup requires explicit in-app confirmation to resume the unchanged retention setting.

The final independent source review found no remaining reproducible P1/P2 and approved a controlled canonical Mac upgrade. The actual app then passed the installed-history checks above. This is not a guarantee that arbitrary inputs or future environment changes contain no bugs.

## Logs and known limits

- Dependency maintenance warnings remain as stated above.
- macOS 27.0.1 AppKit selective-sharing indicator geometry faults were symbolicated to the OS window-sharing notification path (`audit-geometry-atos.log`), with no application source frame. No speculative Settings-size workaround or suppression of the privacy indicator was added. The old process had a separate pre-existing SwiftUI glass-effect diagnostic; its lack of geometry entries does not establish an interaction-matched baseline.
- Disposable Xvfb emitted expected Mesa DRI3/software-rendering warnings and D-Bus child-reaping messages. The genuine headless GNOME session emitted accessibility/GDM/geolocation/camera warnings associated with the isolated session. No adapter JavaScript exception was observed, but those environment logs are not called clean.
- Deliberate proxy limit tests produced expected error-level nginx entries for 413/429. Unexpected service errors were not observed in the staged relay flow.
- Laptop sleep/network loss makes the relay unavailable until it returns. Short tests and zero restart counters do not establish long-term reliability or reboot recovery.
- Secret detection is heuristic. Same-user process/credential compromise is outside the confidentiality boundary. Static key compromise has no forward-secrecy guarantee; no remote or physical-storage erasure claim is made.
- The pairing transcript changed during this unreleased preview; update all preview clients and relay together. No released protocol migration is claimed.

## Remaining merge and device gates

1. Update the installed Ubuntu client/relay to this reviewed source using local administrator authentication, preserving the existing private secret and SQLite data. The staged final source was tested; the installed old version was not silently replaced.
2. When the user can save their desktop work, obtain a fresh GNOME session and enable the installed extension. No forced logout/reboot is authorized.
3. Pair the actual Mac and Ubuntu apps through the private HTTPS relay. Record controlled bidirectional text/image/RTF, offline catch-up, duplicate suppression, busy-worker pause, removal and Secret Service lock/unlock behavior. Keep real old history local unless explicitly shared.
4. Inspect PR CI and review the final commit. Merge/main push remains held until these acceptance gates are satisfied.

## Recovery and preservation

The old Mac app, archive/signature receipt, private upgrade snapshot and original Keychain keys are retained. Do not assume restoring only the old app reverses a SwiftData schema change; database recovery must preserve the complete snapshot and external assets. Protected history was accessed by the signed app itself; CLI TCC denial was not bypassed. Local deletion later does not erase the recovery snapshot.

Only this task's isolated processes, containers and remote temporary roots were cleaned. Unrelated workloads, owner files, production relay data and authentication material were preserved. The feature branch must remain while the PR is on hold.

## Primary documentation checked

- [RFC 9180 HPKE](https://www.rfc-editor.org/rfc/rfc9180.html) and the published authenticated-mode test vector used by the tests.
- [Mutter 51 bounded selection transfer](https://gnome.pages.gitlab.gnome.org/mutter/meta/method.Selection.transfer_async.html), [finish](https://gnome.pages.gitlab.gnome.org/mutter/meta/method.Selection.transfer_finish.html), and [Mutter 51 source](https://gitlab.gnome.org/GNOME/mutter/-/tree/51.0). Runtime evidence is recorded separately above.
- [Apple nonwritable model configuration](https://developer.apple.com/documentation/swiftdata/modelconfiguration/allowssave), [external storage](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage), [ModelContainer migration](https://developer.apple.com/documentation/swiftdata/modelcontainer), and [SQLite online backup](https://www.sqlite.org/backup.html). Apple does not publish a stable external-asset backup layout; the store-copy tests and actual app comparison qualify this version.
- [Axum route-specific body limits](https://docs.rs/axum/0.8.9/axum/extract/struct.DefaultBodyLimit.html), [GNOME extension enablement](https://help.gnome.org/system-admin-guide/extensions-enable.html), and [Tailscale Serve](https://tailscale.com/kb/1312/serve).
