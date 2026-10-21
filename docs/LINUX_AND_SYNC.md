# Linux preview and encrypted sharing

ClipVault now includes an experimental Ubuntu/GNOME client and opt-in encrypted device sharing. The source-and-Ubuntu preview is prepared as `v0.2.0-preview.8`; check the [releases page](https://github.com/rsitech-ai/clip_vault/releases) for publication and checksums. This is an experimental self-hosted preview, with no hosted sync service or notarized macOS download. Existing Mac history remains local until explicitly shared.

## Existing Mac history during upgrade

The update keeps the canonical Mac bundle identifier and existing sandbox/Keychain namespace. Before opening the new schema, the app creates a one-time SQLite snapshot plus external SwiftData payload assets inside its own private storage. It reads that preserved store with the two-entity legacy schema and compares every clip/folder field, including the actual encrypted external payload bytes, against the upgraded context. It then checks that each preserved payload can still be read through the normal local encryption service. General settings shows the verified clip and folder counts; only counts and a digest are saved in the local upgrade receipt.

A mismatch or missing payload blocks capture and automatic cleanup. Automatic cleanup stays paused across restarts so all prior items can be inspected. After reviewing the verified history, explicitly choose **Resume scheduled cleanup** in General settings to resume the unchanged retention policy; its confirmation explains that older unpinned clips may be deleted by future cleanup. The backup and original Keychain keys must be retained for recovery. Deleting a clip from the active store later does not erase it from this preserved recovery snapshot. SwiftData's external-asset layout is not a published stable backup format; exact store-copy migration tests and the app-owned comparison qualify this version rather than guaranteeing future SDK layouts. Existing history is not uploaded as part of this upgrade.

## What syncs

New text, code, links, rich text with a plain-text fallback, and PNG image clips can be shared after pairing. Received clips appear in history; Copy places one on the receiving laptop's clipboard. Existing clips are not uploaded automatically. Mac's Devices settings can share a selected old clip explicitly.

On Mac, image capture waits at most two seconds for OCR after taking and validating the clipboard snapshot. If Vision stalls or fails, the image is still saved, with text recognition marked unavailable. Only one OCR operation can remain in flight; later images do not accumulate blocked OCR workers. Images with unavailable OCR stay out of automatic sharing because their text could not be checked for sensitive content. Review the image and use **Share selected clip** to share it explicitly. A late OCR result does not change or share a saved clip.

Notes, tags, pins, folders, retention settings, old local file references, and application settings remain local. The file-sharing extension adds actual regular files without a fixed product size cap, with 1 MiB encrypted chunks and explicit Save on the receiving device. Available disk space (including active reservations, encryption overhead and 1 GiB headroom) determines practical capacity; the wire format can represent about 4 PiB per file. File contents are not screened for secrets. Both clients and the relay require file-support updates. Files above the legacy 100 MiB limit wait locally until all peers and the current relay advertise large-file support. Use Add File to grant file access if Finder clipboard URLs cannot be opened by the sandbox, or while Ubuntu's background capture extension is unavailable. Folders, symlinks, remote file URLs, mobile clients and automatic replacement of the system clipboard are not included. See the [file sharing design](design/file-sharing-and-linux-ui.md) and [validation status](verification/linux-sync.md); design/source support does not establish installed-app acceptance.

Capture consent and sharing consent are separate. Pause sharing to stop subsequent network operations. A request already accepted by a relay cannot be undone. Delete locally affects that laptop; it does not erase copies already delivered to another device.

Linux capture OFF closes the clipboard-read gate even while synchronization is busy. Background sync retries transient failures after increasing delays of 5, 10, 20, 40, then at most 60 seconds. Retry state survives reopening the client; an explicit pause/resume starts a fresh attempt.

## Ubuntu build

The requested target is Ubuntu 26.10 with GNOME on an Intel/AMD (x86_64) laptop. Ubuntu's [26.10 release notes](https://documentation.ubuntu.com/release-notes/26.10/) identify GNOME 51, so the preview extension declares Shell 51. Its clipboard and selection calls were checked against the published GNOME 51 APIs. This declares the intended target; GNOME 51 Wayland capture was subsequently exercised on the target desktop, with the extension ACTIVE. Other Shell versions are not declared. See the [current verification report](verification/file-transfer-performance.md) for installed and isolated test boundaries.

The portable engine and GTK client have a separate Linux build lane. Its Ubuntu 24.04 CI runner and Debian 12 virtual-display checks cover the GTK baseline; neither establishes compatibility with the requested Ubuntu 26.10 desktop. Disposable Ubuntu 26.10 package/runtime checks are recorded separately in the verification report. The target laptop was measured as Ubuntu 26.10 x86_64, GNOME Shell 51.0 on Wayland. A fresh desktop session was used to discover and activate the extension on the target laptop. New installations may also need to sign out and back in once before enabling it.

Install a current Rust toolchain and the build libraries:

```bash
sudo apt install build-essential pkg-config libgtk-4-dev libadwaita-1-dev libdbus-1-dev
./script/build_linux.sh
```

The script stages a `.deb` in `dist/linux/` and does not install it. Its architecture matches the Linux build host. The client requires GTK 4.8 or later, libadwaita, a session bus, and an unlocked GNOME Secret Service. It does not write keys to plaintext files when that service is unavailable.

Package installation is a separate user action. On GNOME Wayland, enable the packaged `clipvault-capture@rsitech.ai` extension and enable capture inside ClipVault. On X11 the client observes the regular clipboard directly. Primary selection is not captured. If the Wayland extension is absent or incompatible, history and explicit Copy remain available while background capture is unavailable.

The extension sends clipboard changes only to the verified installed `/usr/bin/clipvault-linux` service after capture consent. It has no network client, encryption keys, or callable clipboard-read method. Executable/process checks provide defense in depth, not isolation from arbitrary code running as the same user. Processes able to control GNOME Shell, inject into trusted processes, or access the user's unlocked credential service are outside this boundary. Selection transfers use Mutter's native byte cap before buffering; stale clipboard generations are discarded.

For isolated build and UI checks on a Mac with Docker:

```bash
./script/test_linux.sh
```

This uses a separate container and named build caches. It does not install anything on a laptop. A virtual X11 desktop does not prove GNOME Wayland operation.

To check Intel/AMD Linux from an Apple Silicon Mac, use a separate image and target cache:

```bash
LINUX_PLATFORM=linux/amd64 \
LINUX_VALIDATION_IMAGE=clipvault-linux-amd64-validation \
LINUX_TARGET_VOLUME=clipvault-linux-amd64-target \
./script/test_linux.sh
```

The runtime-only `Packaging/linux/Dockerfile.ubuntu-smoke` can validate the resulting package against Ubuntu 26.10 libraries. `script/smoke_linux_ui.sh` runs in an isolated session bus/Xvfb desktop and exercises controlled text/PNG capture, capture toggling, exact Copy bytes, and rejection of an ordinary bridge caller. Set `CLIPVAULT_LINUX_BINARY=/usr/bin/clipvault-linux` when testing an installed package inside that disposable container. These test installations do not authorize installation on a real laptop.

## Relay setup

The repository supplies a self-hostable opaque relay. You must operate a reachable relay to share across different networks; there is no developer-operated endpoint configured by default.

```bash
cargo build --manifest-path rust/DeviceSync/Cargo.toml --release -p clipvault-sync-relay --locked
```

Generate a random provisioning secret with at least 32 random bytes, store it in a private service environment file, and set `CLIPVAULT_RELAY_REGISTRATION_TOKEN` for the service. Do not commit that file or put the secret in a command-line argument. Then run:

```bash
rust/DeviceSync/target/release/clipvault-sync-relay /private/service-data/relay.sqlite 127.0.0.1:8742
```

The service deliberately binds only to loopback. For remote use, place it behind a TLS reverse proxy on a chosen host. The proxy must enforce a request-body limit of 21 MiB, bounded connection/request rate, connection timeouts, and an appropriate service resource limit; do not expose an unbounded public development service. HTTP loopback is for isolated tests only. Clients reject remote HTTP, embedded URL credentials, arbitrary URL paths, and redirects.

Back up the relay database if pending delivery availability matters. It contains ciphertext and operational routing metadata, never device encryption private keys. Pending payloads expire after 30 days; startup and periodic maintenance remove expired bytes, with up to 60 seconds of maintenance delay while running. Delivery/status metadata is retained for up to 37 days after acknowledgement, rejection, revocation, or expiry. When the 100,000-row cap is reached, the oldest acknowledged receipts may be reclaimed early; pending payloads and rejected, revoked, or expired states are preserved. Missing positive-cursor ACK/REJECT retries are idempotent. Sender retry identities expire locally 37 days after their first delivery attempt, preventing resubmission after relay metadata has been pruned. Mailboxes have a 256 MiB recipient limit, with a 1 GiB global pending-ciphertext limit and 100,000 delivery rows. The relay supports at most 16 workspaces and 100,000 lifetime invitation IDs; compact invitation tombstones prevent reusing consumed IDs. Pending-ciphertext or unreclaimable row limits return capacity errors; active clients drain acknowledged frames and retry without reserving a whole file in the relay. Acknowledged payload bytes are removed logically; physical erasure from SQLite, filesystem snapshots, or backups is not promised. Capacity and expiry produce delivery failures rather than silent success. Relay acceptance and recipient acknowledgement are distinct.

For a private Ubuntu installation, the [dedicated systemd service and bounded proxy configuration](../Packaging/linux/relay/README.md) provide a boot-persistent relay behind Tailscale Serve HTTPS. The installer requires a verified private bundle in a root-owned staging directory and refuses existing installations. It does not publish HTTPS by itself. The guide records partial-install recovery, rollback, and the need to maintain the separately copied Ubuntu nginx executable. Hosting on a laptop makes relay availability depend on that laptop remaining awake and connected.

## Pair devices

1. In the first client's Devices and Sharing settings, enter your relay's HTTPS origin, provisioning secret, and a local device name. Create the private workspace.
2. Create a ten-minute invitation (with 60 seconds of clock-skew tolerance) and transfer it privately to the second client. The invitation contains a pairing secret; do not post it in chat logs or a public issue.
3. Join from the second client. Compare the displayed verification code on both devices, then approve on the owner device.
4. Enable capture on each client if desired. New portable clips are then encrypted for the currently paired recipients.

Repeated invitation creation reuses the current unexpired invitation so an in-progress request remains approvable. Pending joins and approval transactions are encrypted and persisted before network publication. Retrying a lost response preserves the same credentials; terminal rejection permits a new invitation or approval attempt. Enrollment publication and invitation consumption commit together. The authenticated comparison transcript binds the relay origin and invitation expiry as well as device identities.

The owner device approves membership and removes devices. A removed device cannot receive newly addressed clips once other clients learn the signed roster update; removal does not erase existing copies. Offline clients refresh membership before sending. A relay maliciously withholding an update can delay discovery, and static device-key compromise may expose previously retained ciphertext. Do not claim forward secrecy or remote erasure.

Use **Disconnect and reset pairing** to recover from stale pairing or a removed device without deleting local clip history. This replaces local pairing keys and cancels queued shares, including the Mac platform outbox; it does not revoke the old device on the relay or erase clips already delivered. The owner must remove old membership separately. Disconnecting an owner loses administration of that workspace.

If the owner device is lost, surviving clients retain their local history. Administration of that workspace cannot be recovered by guessing a password: establish a new workspace and pair the surviving devices again. Preserve local data and export desired clips explicitly before clearing old pairing configuration.

The authenticated pairing transcript changed during this unreleased preview. Update preview clients and relay together; older preview pairing strings are incompatible. There is no released protocol migration claim.

## Verification

```bash
./script/test_device_sync.sh
./script/test.sh
./script/build_and_run.sh --verify
```

The Mac build script stages and launches a bundle; use an alternate bundle ID and `DIST_DIR` for isolated testing. Do not replace an installed app or reuse its consent grants implicitly. The Rust bridge build helper sets the macOS deployment target to match Swift's macOS 15 floor.

For a native macOS engine talking to a separate x86_64 Linux engine through a disposable relay, first run the Intel/AMD Linux checks above and build the Mac test driver:

```bash
cargo build --manifest-path rust/DeviceSync/Cargo.toml -p clipvault-sync-relay --example interop_probe --locked
python3 script/test_sync_interop.py \
  --image clipvault-linux-amd64-validation \
  --target-volume clipvault-linux-amd64-target \
  --platform linux/amd64
```

The driver uses temporary encrypted stores, random test credentials exchanged through subprocess pipes, and a container port published only on host loopback. It checks pairing, text/PNG/RTF in both directions, pending ciphertext, applied receipts, duplicate suppression, offline process restart, pause, and removal. It does not use the real clipboard, application history, platform credential stores, or a deployed relay. The test driver is an example target and is not included in either app package. This establishes engine/transport interoperability; the Swift and GTK application flows and real-device delivery require their own evidence.

Before calling the feature ready for your laptops, record the exact Ubuntu release, GNOME version, CPU architecture, and Wayland/X11 session; test text and image transfer in both directions on the real devices, offline catch-up, pause, duplicate suppression, and removal. Source tests and virtual-display screenshots are separate evidence.

Protocol references: [RFC 9180 HPKE](https://www.rfc-editor.org/info/rfc9180/), [GNOME Secret Service](https://gnome.pages.gitlab.gnome.org/libsecret/class.Service.html), and [clipboard portal session limits](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.Clipboard.html).
