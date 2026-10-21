# ClipVault Privacy Policy

Last updated: 2026-10-21

ClipVault is a local-first clipboard workspace for macOS, with an experimental Ubuntu/GNOME client and optional encrypted device sharing.

## Data Collection

ClipVault has no developer-operated analytics or hosted clipboard service. It does not sell clipboard data. With sharing disabled, clipboard content stays on the device.

Clipboard items, screenshots, OCR text, titles, tags, notes, folders, and app settings are stored locally on the device. When available, ClipVault also records the name of the application that was frontmost when an item was copied so the clip can show its local source context.

Clip payloads and clip details, including source-application names and clipboard type metadata, are encrypted locally with a key stored in the macOS Keychain. Operational metadata such as clip identifiers, content kind, timestamps, fingerprints used for deduplication, copy counts, pin state, collection membership, and folder structure remains plaintext inside ClipVault's sandboxed local database. When encrypted sharing is enabled, portable clip content and source context are encrypted for paired devices before transmission. Local organizational state and settings are not shared in this preview.

ClipVault does not begin watching the clipboard until the user accepts an in-app disclosure. Capture can be paused or consent can be revoked in Settings at any time.

## Network Use

Sharing is disabled until explicitly configured. Pairing does not upload existing history. After pairing and enabling sharing, new portable text, rich text, code, links, and PNG clips pass through your configured relay. You may explicitly share a selected older Mac clip. Content, source device names, and source application context travel inside authenticated encrypted envelopes; the relay sees network addresses, opaque device/workspace identifiers, event identifiers, sequence/epoch routing data, timing, sizes, and delivery state. It can delay or drop delivery. No developer relay is configured automatically.

The self-hosted relay expires pending encrypted payloads after 30 days; startup/periodic maintenance removes them, with up to 60 seconds of delay while running. Recipient mailboxes are limited to 256 MiB and total pending ciphertext to 1 GiB. Delivery metadata is retained for up to 37 days after acknowledgement, rejection, revocation or expiry for idempotency and status. At the 100,000-row relay limit, the oldest acknowledged receipts may be reclaimed early; pending payloads and rejected, revoked or expired states are not evicted to make room. Retrying a missing acknowledgement or rejection is idempotent. Compact invitation identifiers remain as single-use tombstones, bounded to 100,000 lifetime IDs. Acknowledgement logically removes payload bytes; SQLite pages, filesystem snapshots and backups do not provide a physical-erasure guarantee. Sender and recipient stores retain minimal event receipts to prevent duplicate delivery or resurrection after deletion. Local sync queues and identities are encrypted with a device-local key in Keychain on macOS or GNOME Secret Service on Linux. Operational local sync identifiers and receipt state remain plaintext in the private database. Device encryption keys are not sent to the relay.

Pause sharing stops subsequent requests. A request already accepted cannot be recalled. Device removal prevents subsequent delivery once current membership is known; it does not erase copies already received. There is no claim of forward secrecy following static device-key compromise, or remote erasure.

Cloud or BYO AI providers remain disabled. Sharing does not enable cloud AI.

The file-sharing extension supports individual regular files without a fixed
product size cap. Available disk space, temporary storage for Save, and protocol
representation determine practical capacity. Transfers reserve space for active
files and retain 1 GiB of disk headroom. File contents, base filenames, hashes and
manifests are encrypted for paired devices. Source paths remain local. File chunks
are encrypted in local transfer staging; only a small descriptor enters history.
The relay can distinguish clip frames from file-transfer frames and observe their
sizes and timing. Local transfer identifiers, chunk indices, ciphertext lengths,
timestamps and transfer progress/state remain operational metadata in the private
database; filenames and whole-file hashes are encrypted there.
The receiving client verifies the whole file before offering an explicit Save.
Save creates a plaintext copy at the user's selected destination; ClipVault never
opens or executes received files automatically. Existing file-reference history is
not automatically read or uploaded. Devices must advertise file support before
files are sent; relay acknowledgement alone does not prove a verified file.

## Sensitive Content

ClipVault attempts to exclude obvious secrets before storage, including private keys, API tokens, and password-like values. Users can delete clips at any time.

File contents are not scanned for secrets. Copying or explicitly adding a file
while paired sharing is enabled shares its actual contents with the paired
devices. Pause sharing before copying a file you want to keep only on this device.

On Mac, OCR failure or a two-second OCR timeout does not discard an image capture. The image is kept locally with text recognition marked unavailable, and is excluded from automatic sharing. You can review and share it explicitly. OCR and secret detection are not guarantees that an image contains no sensitive information.

## Data Deletion

Disconnect/reset replaces local pairing keys, cancels queued shares and preserves local history. It does not remotely revoke old membership; remove the old device from the owner separately.

Users can delete individual clips or bulk-delete groups of clips inside the app. Deleting a clip removes its local payload and local details and cancels pending local exports. Minimal event/receipt identifiers are retained to prevent a network retry from restoring it. Copies already delivered remain on other devices. There is no Delete Everywhere action in this preview.

Before the device-sharing schema upgrade, the Mac app preserves a private local recovery snapshot of the previous database and external payload assets. That snapshot retains the previous store's encryption and metadata protections. Later deletion of a clip from the active database does not remove it from this recovery snapshot or other backups. Preserve the original Keychain keys if recovery is needed. Upgrade verification receipts contain counts and a digest, not clipboard contents. Automatic and manual retention cleanup stay paused across restarts until the user explicitly resumes the existing policy in General settings.

The Mac app retains ordinary clips for 30 days by default. The retention period can be changed in Settings. Pinned clips are not automatically removed.

## Contact

The canonical policy URL is `https://github.com/rsitech-ai/clip_vault/blob/main/PRIVACY.md`. General support uses the repository issue forms. For confidential privacy matters, contact [info@rsitech.ai](mailto:info@rsitech.ai). Do not disclose clipboard contents, credentials, personal data, private logs, vulnerabilities, or sensitive privacy failures in a public issue. See `SECURITY.md` for vulnerability reporting.
