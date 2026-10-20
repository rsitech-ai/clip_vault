# Linux and encrypted sharing verification

Date: 2026-10-20

**Verdict: HOLD merge and file-sharing readiness.** The earlier clipboard-sync review passed, but the new 100 MiB attachment and Ubuntu UI scope is under validation and independent review. The canonical Mac app has been upgraded locally and its complete prior history verified. The audited Ubuntu client and relay are installed, and the actual Mac and Ubuntu apps are paired after a user-confirmed comparison code. Mac-to-Ubuntu Unicode text/Copy, client-offline catch-up and image display are verified. The genuine active Ubuntu GNOME capture path and Ubuntu-to-Mac automatic clipboard delivery still require acceptance. This report does not claim a published release, long-term uptime, or an error-free environment.

## Source, authority and scope

- Branch `feat/andrzej_linux_encrypted_sync`, base `ea4edf1`; canonical repository `rsitech-ai/clip_vault`.
- The user approved Linux/GNOME plus encrypted sharing, private relay setup, comprehensive fixes/restarts/review, a PR and conditional merge only after stability. The additional Mac-history preservation request was carried through a controlled local upgrade.
- Owner `AGENTS.md` is preserved and excluded from the PR. Docker Desktop was not restarted; unrelated workloads and the active Ubuntu desktop session were preserved.
- Mac remains SwiftUI/AppKit + SwiftData; Linux uses GTK4/libadwaita. Shared Rust owns protocol, encrypted local sync state, pairing and HTTP transport. The relay holds ciphertext and routing metadata.
- Existing history is not uploaded automatically. Notes, tags, pins, folders and file references remain local. Received clips enter history; explicit Copy changes the receiving clipboard.

## Clipboard-sync baseline validation

These results qualify the earlier clipboard preview. The later attachment scope, fixes and package/device gates are recorded separately below.

| Check | Result and boundary |
| --- | --- |
| `./script/test_device_sync.sh` | PASS: 44 Rust tests, 1 intentionally ignored quota test; formatting and strict workspace/all-target Clippy. |
| `cargo test --manifest-path rust/DeviceSync/Cargo.toml -p clipvault-sync-relay --test relay mailbox_quota --locked -- --ignored` | PASS: explicit real 256 MiB mailbox test, including capacity after restart and acknowledgement recovery. An initial old fixture timestamp expired under the new startup maintenance; the corrected wall-clock fixture passes. No quota-store change was needed. |
| `./script/test.sh` | PASS: shell policies, original search Rust tests, 253 core Swift tests and 10 app Swift tests. |
| AMD64 `./script/test_linux.sh` with separate image/target volume and `LINUX_PLATFORM=linux/amd64` | PASS: 44 tests, GTK build and strict Clippy. Runs under x86_64 emulation on the ARM Mac. Final Linux UI refinements were then compiled again in the release package and passed strict Clippy. |
| `./script/build_linux.sh` inside the AMD64 builder | PASS: release `.deb`, x86_64 ELF, packaged GNOME adapter and bounded-transfer module, 281 dependency notices. Package SHA-256 `c5c544bc952f0537d5a8589d66ef8350360ace5ec62d24e3db1f99daa94453ba`. |
| Final installed-package Ubuntu 26.10/Xvfb smoke | PASS: repeated activation keeps one window/worker, controlled text/PNG capture, exact Copy, consent toggles and rejection of an ordinary untrusted D-Bus caller. Screenshots inspected. This is a disposable virtual X11 session. |
| `python3 script/test_sync_interop.py --image clipvault-linux-amd64-validation --target-volume clipvault-linux-amd64-target --platform linux/amd64` | PASS: separate native Mac/Linux encrypted stores; pairing/comparison; text, exact PNG/RTF in both directions; applied receipts; duplicate suppression; offline process restart; pause; removal; controlled plaintext absent from pending relay envelopes. This uses test engines, not the two installed apps. |
| Genuine GNOME 51 target test | PASS: latest extension loaded ACTIVE in a separate headless Wayland Shell on the actual Ubuntu target. Actual Mutter selection reads passed exact text/PNG, exact-limit, oversize and cancellation checks. Private D-Bus/XDG state and synthetic clipboard fixtures were used; the real user clipboard was untouched. This does not qualify installed-session bridge capture or dbus-broker behavior. |
| Actual Ubuntu staged final relay/proxy | PASS: separate loopback ports and temporary test stores, native Linux test engines, pairing, pending ciphertext after SIGKILL/restart, one recipient application and sender acknowledgement. Proxy returned expected 413 for a declared 22 MiB body and 429 under a burst (45 success, 55 throttled). Test processes/stores were cleaned. |
| Installed audited private relay/client | Updated after local sudo authentication from a digest-pinned, root-frozen bundle. Installed client SHA-256 `7c7c075e070b24b0acf8193c570e219d2c0f02013827a563b981a3a1aa14a6e8`; relay `b13d6ab2fa2f96ecda41339f570e699116896652909539d8282a6a44c9c102fa`. Existing secret was unchanged, and stopped SQLite/WAL state plus old binaries/config were retained in a root-only rollback directory. Both units active, zero restart counters, TLS health successful; warning journal had no entries. |
| Mac staged/canonical build | PASS: project build script, Developer ID signature and canonical designated-requirement match, then local installation as 0.2.0. The subsequent bounded-OCR fix was installed as build 5 with the same designated requirement, preserving the preceding bundle, history and pairing. Original 0.1.1 app and a verified archive were retained. No signing-team mixture. |
| Actual Mac history upgrade | PASS: app-owned old-store snapshot and current-store logical comparison verified **895 clips and 12 folders**, including exact encrypted external payload bytes. All 895 primary/list payloads were readable. General settings displayed the receipt. A subsequent app restart still showed 895 clips, the 12-folder preservation receipt and cleanup paused. Sharing remains off. |
| Mac runtime logs | No app-specific storage/network failure was observed. A five-minute inspection did show AppKit geometry faults plus one BaseBoard task-port diagnostic. Symbolication traced every sampled geometry fault to `NSThemeFrame._positionSharingIndicator` / `NSWindowSharingSessionRecipientIndicator` during selective window sharing by UI inspection, not Settings frame arithmetic. These platform diagnostics are disclosed; logs are not called clean. |
| `cargo audit --file rust/DeviceSync/Cargo.lock` | Exit success, with three unmaintained warnings: `zbus_names` 3, `zvariant` 4, `zvariant_derive` 4. These optional Keyring branches are not selected by the configured synchronous Secret Service/macOS backends; target feature-tree check confirmed no selected `zvariant@4.2.0` path. Not described as a clean dependency audit. |
| `cargo deny --manifest-path rust/DeviceSync/Cargo.toml --config rust/DeviceSync/deny.toml check` | PASS: advisories, bans, licenses and sources. Duplicate-version advisory warnings remain visible. |
| GitHub workflows | Initial Linux run failed strict Clippy on Rust 1.99 because `AtomicU64::fetch_update` was deprecated (CODE_FAILURE). Replaced it with an equivalent compare-exchange retry loop preserving memory ordering and added an eight-thread/8,000-update generation test. Local Mac/AMD64 tests and lint pass; hosted rerun is pending (UNKNOWN). Mac check remains queued without a runner (UNKNOWN). CI and physical acceptance block merge; local success does not establish CI success. |

The Rust 1.99 compatibility correction was independently reviewed. Final portable/AMD64 checks, rebuilt package and installed-package smoke are recorded in `audit-rust-compat-*.log`; earlier `*-final.log` files qualify the immediately preceding source. The Mac executable and shared protocol/relay sources are unchanged by this Linux-only correction.

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

The independent clipboard-sync source review found no remaining reproducible P1/P2 and approved a controlled canonical Mac upgrade. The actual app then passed the installed-history checks above. This is not a guarantee that arbitrary inputs or future environment changes contain no bugs.

## Logs and known limits

- Dependency maintenance warnings remain as stated above.
- macOS 27.0.1 AppKit selective-sharing indicator geometry faults were symbolicated to the OS window-sharing notification path (`audit-geometry-atos.log`), with no application source frame. No speculative Settings-size workaround or suppression of the privacy indicator was added. The old process had a separate pre-existing SwiftUI glass-effect diagnostic; its lack of geometry entries does not establish an interaction-matched baseline.
- Disposable Xvfb emitted expected Mesa DRI3/software-rendering warnings and D-Bus child-reaping messages. The genuine headless GNOME session emitted accessibility/GDM/geolocation/camera warnings associated with the isolated session. No adapter JavaScript exception was observed, but those environment logs are not called clean.
- Deliberate proxy limit tests produced expected error-level nginx entries for 413/429. Unexpected service errors were not observed in the staged relay flow.
- Laptop sleep/network loss makes the relay unavailable until it returns. Short tests and zero restart counters do not establish long-term reliability or reboot recovery.
- Secret detection is heuristic. Same-user process/credential compromise is outside the confidentiality boundary. Static key compromise has no forward-secrecy guarantee; no remote or physical-storage erasure claim is made.
- The pairing transcript changed during this unreleased preview; update all preview clients and relay together. No released protocol migration is claimed.

## Remaining merge and device gates

1. Complete the newly requested 100 MiB file-sharing and Ubuntu UI changes, then repeat applicable source, package, runtime and device checks. The earlier audited Ubuntu update has completed; further builds require a separate verified update.
2. When the user can save their desktop work, obtain a fresh GNOME session and enable the installed extension. No forced logout/reboot is authorized.
3. The actual apps are paired and Mac-to-Ubuntu text/image/offline receipts are recorded. Finish the opposite direction plus physical RTF, busy-worker pause, removal and Secret Service lock/unlock acceptance. Keep real old history local unless explicitly shared.
4. Inspect PR CI and review the final commit. Merge/main push remains held until these acceptance gates are satisfied.


## Installed-app continuation and OCR correction

The actual apps are paired; the user confirmed the comparison code before the Mac approved Ubuntu. A controlled TextEdit copy with Polish characters reached Ubuntu, was acknowledged, and the user confirmed its visible text and Copy result. With only the Ubuntu client stopped, a second Mac copy remained pending; after relaunch it was imported and acknowledged. The user confirmed the offline clip and controlled purple/green image were visible. The active GNOME session remains the earlier session; the user cannot close it now, so Ubuntu-to-Mac automatic capture is not claimed.

The first image did not arrive during the initial 20-second check. Sampling the installed Mac traced a long wait inside Vision recognition before the image could be stored; the earlier copies eventually completed and arrived. A controlled CPU-device probe also exceeded its 15-second limit, so no speculative CPU workaround was shipped. The correction bounds the caller's OCR wait to two seconds after snapshot and image validation, admits at most one OCR operation, and leaves a timed-out worker occupied until it actually returns. There is no late callback that changes or shares a saved clip. Unavailable OCR is distinct from completed-empty OCR, and keeps the image out of automatic sharing until explicit review/share.

Five focused tests plus the full 253-core/10-app run passed. A new regression first reproduced a timeout-status label splitting one blank image into two history records, then passed in both capture orders after preserving the existing Image label and storing OCR outcome separately. The final signed build captured a fresh controlled image with completed OCR; Ubuntu acknowledged delivery and the user confirmed its preview. Current Mac history includes the original 895 clips plus controlled test captures, and the original 12-folder upgrade receipt/cleanup hold are retained. Logs and receipts are under `actual-image-*` locally. These tests do not establish a maximum duration for Vision itself or qualify the blocked GNOME capture direction.

The user subsequently requested actual file sharing up to 100 MiB and a simpler Ubuntu workspace. The preceding clipboard checks do not establish attachment support. The separate attachment evidence follows.

## Attachment and Ubuntu UI continuation

The source adds regular files up to **100 MiB (104,857,600 bytes)**, split into 1 MiB authenticated encrypted chunks. Descriptors enter history only after receiver assembly and whole-file SHA-256 verification. Save is explicit, private and refuses to overwrite an existing file. Clipboard payloads retain their separate 10 MiB limit. Existing local file references are not read or uploaded by this change. All paired clients must advertise attachment support before a new file is committed; waiting files must not block ordinary sync.

Current evidence, before final package and device qualification:

- A release-mode HTTP integration test transferred exactly 100 MiB, restarted the receiver partway through, resumed and verified the final hash. Direct execution passed in 30.79 seconds (30.88 seconds wall clock), with 364,101,632-byte maximum RSS and 559,580,096-byte peak footprint. This one process contains the relay and both test clients; those figures are not per-client memory measurements.
- The signed isolated Mac app added and saved an exact 100 MiB fixture through native Open/Save panels. The saved SHA-256 matched the source (`4cbf988462cc3ba2e10e3aae9f5268546aa79016359fb45be7dd199c073125c0`), with mode `0600`. A 100 MiB-plus-one fixture was rejected visibly without creating a history entry. This namespace has synthetic history; the canonical Mac app and its old history were preserved.
- Native Save first exposed a real sandbox failure: a Save-panel grant does not cover arbitrary sibling temporary files. The repaired flow uses Foundation's item-replacement directory on the destination volume, core streaming verification and atomic no-overwrite publication to the exact granted destination. The native signed-app retest passed. Local no-overwrite tests cover collisions; APFS and ext4 have been exercised, while FAT/exFAT are unqualified.
- Mac regression tests first reproduced rapid copies being dropped during staging and one unsupported file stopping ordinary export/import. The bounded capture queue and per-export failure continuation passed their regressions. The final complete `./script/test.sh` run passed 263 core and 15 app tests after those fixes, including shell policy checks and the linked Rust build.
- The simplified GTK workspace, native Add File picker, capture toggle, exact text/PNG Copy, URI-list file staging and untrusted bridge rejection passed a disposable X11 smoke. Screenshots were inspected. This does not qualify the user's current Wayland session or the receiving Save dialog.
- Independent review found additional file recovery and Linux ingress issues: failed incoming chunks retained quota, relay capacity failures blocked inbox work, mixed image/file MIME preference could lose file semantics, and GNOME consent cycles needed generation binding. The core recovery fixes passed full workspace tests, strict Clippy, formatting and independent source re-review. The real 256 MiB quota test confirmed ACK releases capacity; a separate HTTP-boundary 507 regression confirmed inbox progress and later file retry. Linux ingress corrections remain in progress. No merge approval is inferred from the earlier clipboard review.

The independent Linux review also found attachment Delete hiding the row without cancelling file jobs/chunks, and a pending-file retry loop bypassing network backoff. The Linux worker now resolves attachment IDs from stored history, deletes transfer state before hiding history, clears pending markers on delete/disconnect, and retries at most one due file after a successful network tick while honoring durable backoff. Focused Linux tests pass, and independent re-review found no remaining P1/P2 in the scoped source fixes. Earliest-deadline selection prevents retry starvation; an indexed authenticated event lookup avoids decrypting unrelated history during Delete. Staged local files are labelled On this device. The final full Linux workspace tests/build/strict Clippy passed (13 relay tests, two intentional large tests ignored); native chooser/capture/Copy GUI smoke passed. A final Unix FIFO-open regression then reproduced a three-second pre-validation stall and passed after adding O_NONBLOCK to source open; targeted Linux FIFO/unit/lint/build checks and final AMD64 package validation follow that narrow change. A proposed pause-before-send issue was retracted after verifying the core uses the same cancellation atomic and checks it before sending HTTP; it is not counted as a confirmed defect.

Attachment logs, hashes and native-app receipts are retained under `dist/linux-deployment/20261020/files-*` and UI screenshots under `dist/linux-evidence/ux-after/`. The signed canonical Mac build 6 was installed with the same designated requirement and retained rollback. Its live Settings still displayed the original 895-clip/12-folder preservation receipt and durable cleanup hold; pairing and sharing consent remained enabled. The accumulated local history had 900 clips before the controlled 89-byte Add File check and 901 afterward. The Ubuntu file-capable package and new relay are not installed yet. Cross-device file delivery, explicit Save, reconnect and reverse direction remain required.

The Mac update exposed an upgrade-order regression: capability advertisement against the old relay returned HTTP 404 before ordinary sync work. A new strict compatibility regression verifies ordinary bidirectional clips continue while file commit remains unsupported/local, and HTTP 500 remains visible. The strict fallback passed full Rust tests and independent review, and was rebuilt into the canonical Mac app. A subsequent live retry caught a Mac/Rust contract mismatch: the Mac attachment included source-app metadata that the typed Rust validator rejects. The Mac now omits it, strictly validates parity and normalizes previously queued preview exports on read without changing their identity or local history. The source-app regression first failed, then the full `./script/test.sh` passed 263 core and 15 app tests. Independent source review passed. Signed canonical build 8 was installed, and the same pending 89-byte fixture now reaches the correct update-needed/local-copy-retained status while the ordinary tick reports Up to date. The original history receipt, cleanup hold and pairing remained intact.

The hosted Mac check at `8207974` failed in Swift 6.3.3 IR generation (`SmallVector unable to grow`, actor/Bool reabstraction in DevicesSharingSettingsTab). This is an observed toolchain failure, classified INFRA_FAILURE, not a test assertion. The local Swift 6.4 full suite passes. An explicit Binding setter closure avoids the problematic method-reference conversion; hosted confirmation remains required. The same revision's Linux check passed.

## Frozen file-capable artifacts and installation gate

Product source commit: `b68e618631f0c6fcc0258985b580ccd8eb9b185e`. The scoped independent source reviews passed after the recorded corrections; this does not replace installed-device or CI acceptance.

| Artifact | SHA-256 | Observed state |
| --- | --- | --- |
| Mac build 9 executable | `2a730e84c0e5c12f10c2f372d944a459a2f095aa93ece379753cb33bcd3389ea` | Canonical signed app installed and launched; designated requirement unchanged. Live UI showed 903 accumulated clips and the original 895-clip/12-folder preservation receipt, cleanup hold and pairing. |
| Ubuntu preview2 AMD64 package | `585e2c5848855df21a5daca70750c9ffa001b92d655f846152d96792bb7ee4dc` | Installed with local sudo authentication; package version `0.2.0~preview2`, ELF x86-64. Root-owned executable hash matches the frozen build. |
| Packaged Linux executable | `4eb6a47f36733358482220fd994998ec3c0dd21bbbaa71db260da02e94ca1f09` | Mode 755 and byte-equal to the final AMD64 release build. |
| File-capable relay executable | `0cce005f9406f1898bc61e0185f345ed77b4ce55b54038207277dd328ee02799` | ELF x86-64, frozen with the package for the private relay update. |

The final Linux app/policy tests passed (8 binary tests, 4 policy tests), as did workspace strict Clippy, release build, formatting, shell syntax and extension syntax. The complete workspace suite passed the 100 MiB local round trip before the last source-open flag; all eight attachment integration tests then passed natively, and a separate Linux FIFO test passed after the flag. The final GTK smoke covered native Add/Save, exact text/PNG Copy and the URI/consent boundaries. The deliberately ignored large HTTP/restart and real 256 MiB quota tests have the separate receipts already described above.

The remote archive hash and unprivileged APT simulation passed: only ClipVault is upgraded, with no additional packages installed or removed. The root updater verifies the archive and current installed hashes, freezes a root-only copy, stops only ClipVault components, preserves stopped SQLite/WAL state, existing configuration/secret and old binaries/package, then updates and checks health. Local desktop sudo authentication completed, the updater exited 0, and installed hashes and active services were independently checked. The password was never requested in chat. The later proxy-buffer correction and file-delivery evidence are recorded below.

PR #27 remains draft. At documentation head `0751ae6`, hosted Linux passed; hosted Mac verification is still in progress. Final hosted outcomes, installed file Save/hash and reconnect in both directions, and the blocked genuine GNOME user-session capture remain merge gates. `main` is unchanged.

## Recovery and preservation

The old Mac app, archive/signature receipt, private upgrade snapshot and original Keychain keys are retained. Do not assume restoring only the old app reverses a SwiftData schema change; database recovery must preserve the complete snapshot and external assets. Protected history was accessed by the signed app itself; CLI TCC denial was not bypassed. Local deletion later does not erase the recovery snapshot.

Only this task's isolated processes, containers and remote temporary roots were cleaned. Unrelated workloads, owner files, production relay data and authentication material were preserved. The feature branch must remain while the PR is on hold.

## Primary documentation checked

- [RFC 9180 HPKE](https://www.rfc-editor.org/rfc/rfc9180.html) and the published authenticated-mode test vector used by the tests.
- [Mutter 51 bounded selection transfer](https://gnome.pages.gitlab.gnome.org/mutter/meta/method.Selection.transfer_async.html), [finish](https://gnome.pages.gitlab.gnome.org/mutter/meta/method.Selection.transfer_finish.html), and [Mutter 51 source](https://gitlab.gnome.org/GNOME/mutter/-/tree/51.0). Runtime evidence is recorded separately above.
- [Apple nonwritable model configuration](https://developer.apple.com/documentation/swiftdata/modelconfiguration/allowssave), [external storage](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage), [ModelContainer migration](https://developer.apple.com/documentation/swiftdata/modelcontainer), and [SQLite online backup](https://www.sqlite.org/backup.html). Apple does not publish a stable external-asset backup layout; the store-copy tests and actual app comparison qualify this version.
- [Axum route-specific body limits](https://docs.rs/axum/0.8.9/axum/extract/struct.DefaultBodyLimit.html), [GNOME extension enablement](https://help.gnome.org/system-admin-guide/extensions-enable.html), and [Tailscale Serve](https://tailscale.com/kb/1312/serve).


## Installed preview2 continuation: proxy buffer ownership

The Ubuntu update completed with exit 0. Independently read hashes match the
frozen preview2 app and relay above; both relay units are active with zero
restart counters and the client is active. The update preserved its existing
secret and stopped database backup. The small 89-byte attachment reached the
actual Ubuntu client in ready state. The 100 MiB manifest arrived, but chunk
uploads returned HTTP 500; full file success is not claimed.

The proxy journal reproduced EACCES opening its body buffer path. A root-level
nginx configuration preflight had created nested buffer directories as `nobody:clipvault-relay` with mode `0700`,
while the already-correct service-owned parent caused systemd's parent-only
ownership optimization to leave them unchanged. The corrected proxy unit names
all five buffer children explicitly in StateDirectory, retaining the same service
user and 0700 mode. The target's systemd-analyze verify and project shell checks
pass; independent source review passes. A pinned, rollback-protected one-unit
repair completed with local authentication. Its first one-shot health check raced
startup and rolled back the unit while leaving the corrected child ownership in
place. The corrected bounded readiness check then completed with exit 0: all five
children are `clipvault-relay:clipvault-relay` mode `0700`, the installed unit is
byte-equal to the reviewed unit (SHA-256
`75c4298a852d7a221f4eb52f787c38d9eece4b44a26e6780e56789159fbe1d96`),
and local and normal-certificate HTTPS health return `ok`. Both services have
zero restarts and exit status 0. The actual Ubuntu encrypted transfer metadata
now reports both incoming fixtures ready: 89 and 104857600 bytes. The canonical
Mac UI reports Up to date. Explicit Save/hash and the reverse direction remain
pending. Expected nginx temporary-body buffering warnings are present; the
previous permission error is resolved, so no claim of warning-free logs is made.

Primary references: [nginx request buffering](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_body_buffer_size)
and [systemd directory ownership](https://www.freedesktop.org/software/systemd/man/260/systemd.exec.html#RuntimeDirectory=).


The final private GNOME 51 harness started the genuine shell and installed client
on an isolated bus/display, but did not reach authenticated capture assertions.
The extracted private dbus-daemon served the session bus; AT-SPI's launcher still
required the absent absolute `/usr/bin/dbus-daemon`, GTK rejected the selected
accessibility backend, and the fixture extension did not load. Thus stale-token,
unauthorized-caller and authenticated file-ingress runtime assertions remain
unverified in this continuation. This is a harness ceiling, not a demonstrated
production capture failure. All four isolated process IDs were confirmed stopped;
the actual desktop session and its data were untouched. Receipt:
`dist/linux-deployment/20261020/gnome-capturefiles-headless-runtime-result.txt`.
