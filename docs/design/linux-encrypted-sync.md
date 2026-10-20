# Linux client and encrypted device sync

Date: 2026-10-20

Status: written specification approved; implementation in progress on feat/andrzej_linux_encrypted_sync. See docs/verification/linux-sync.md for observed evidence and outstanding device gates.

## Outcome and accepted brief

The user wants ClipVault on an Ubuntu laptop with GNOME, with clips copied on either that laptop or their Mac available in ClipVault on the other. They approved a separate Linux client, the existing native Mac interface, device pairing, end-to-end encrypted relay delivery, offline history, and received clips appearing in history without automatically replacing the system clipboard.

Success requires actual Ubuntu-to-Mac and Mac-to-Ubuntu text and image receipts, including delivery after an offline interval. Building the clients or passing protocol tests alone does not establish this outcome.

The original approval authorized implementation and isolated checks. Subsequent explicit instructions authorized the private Ubuntu relay/client setup and then a comprehensive audit, fixes, scoped service restarts, commit/push, a PR, and merge to main only after review approval and stable validation. Preserve the existing untracked AGENTS.md and unrelated work. Do not restart Docker Desktop or force a desktop logout/reboot. Keep feature work on feat/andrzej_linux_encrypted_sync until the merge gate is satisfied. Public service/release publication is not included.

## Existing system

- Sources/ClipVault is the SwiftUI/AppKit interface and application orchestration.
- Sources/ClipVaultCore combines domain models with macOS clipboard capture, SwiftData persistence, Keychain-backed AES-GCM encryption, consent, sensitive-content filtering, and search bridging.
- rust/SearchIndexCore is reusable Rust normalization and lexical search.
- Local file clips contain device-specific references, not portable file contents.
- The application currently promises local-only processing and has no enabled sync transport. Privacy copy, consent, and network entitlements must change together with the feature.
- The Mac store already supports payload preservation, mutation rollback, and lazy clip rows. Preserve these behaviors and their existing tests.

## Delivery scope

The first release covers new clipboard captures containing text, code, SQL, links, errors, portable rich-text representations, and PNG images/screenshots. Send the actual image bytes, not only the list thumbnail. Preserve plain-text fallback for rich text; do not render incoming HTML as executable content.

Shared content includes its portable payload, capture time, source device, clip kind, and source application when available. Device names and source application names are encrypted. Search is local after decryption.

Existing history stays local unless the user explicitly selects clips to share. Pairing does not upload the existing archive. Shared capture is automatic after enabling it. Capture consent and sharing consent are distinct. Pause capture controls new collection; pause sharing stops uploads and downloads. Disabling sync cancels sync work and preserves local history.

Titles edited by the user, notes, tags, pins, folders, collection membership, retention, and copy counts remain local in the first release. Device-local file paths do not sync as usable attachments. File transfer, full workspace editing synchronization, mobile clients, cloud AI, and parity for macOS screenshot gestures are outside this delivery. Explain these boundaries in the clients rather than silently omitting data.

Automatic replacement of the system clipboard is deferred. The initial copy action is explicit on the receiving device. This preserves the agreed default and avoids an additional clipboard feedback mechanism.

## Architecture

### Shared Rust engine

Add rust/SyncCore for versioned portable payloads, encryption, pairing state, device membership, replay detection, bounded queues, relay transport, and durable sync bookkeeping. It depends on SearchIndexCore where normalization is useful. Content identity in sync uses a cryptographic digest, never the existing 64-bit lexical fingerprint as an authentication primitive.

Expose a narrow C-compatible boundary for Swift. No SwiftUI, AppKit, GNOME, or platform credential APIs belong in the portable protocol layer. Document buffer ownership, byte lengths, error mapping, and cancellation. Secret-bearing handles must release and zeroize key material where supported; errors must not include payloads or pairing secrets.

### Mac integration

Keep SwiftData and the current local payload key. Add encrypted outbox and inbox receipt records in the same store rather than sending a database file. A successful local capture and its pending-share marker must commit atomically. A successful receive and its receipt must also commit atomically. Failure to prepare an export cannot silently discard the clip or claim it was shared: retain a visible pending export state and retry from the local payload.

Stage received items through an explicit store import operation. Import preserves remote event identity and original capture time; it does not impersonate a fresh local clipboard capture, increment a local copy count, or enqueue another export. The Rust engine handles protocol identity; SwiftData remains the Mac persistence authority.

Add Devices and Sharing settings, one-time pairing, per-device delivery state, and an encrypted-sync disclosure. Add outbound network entitlement to every applicable packaging path, including the separately generated distribution entitlements. Test consistency across the build scripts.

### Ubuntu client

Use Rust with GTK4/libadwaita for the GNOME desktop interface, SearchIndexCore for search, SyncCore for sharing, SQLite for local data, and GNOME Secret Service for the local data-encryption key and sync credentials. A locked or unavailable credential store pauses access and presents an actionable error; never fall back to plaintext key files.

Provide a searchable history, full-width title/snippet rows with time on the metadata row, image preview, Copy, local Delete, capture consent, pause controls, and Devices and Sharing settings. Local payloads are authenticated-encrypted before SQLite storage. Metadata exposure must be explicitly documented.

Use an X11 clipboard adapter where available. On GNOME Wayland, capability-detect supported background access and provide a version-matched GNOME Shell extension when needed. The extension is a clipboard adapter, not an encryption-key holder or network client. Use a push-only user-session-bus bridge: the extension sends capture events to the registered ClipVault service, and exposes no clipboard-read method. Check the destination owner's bus credentials and installed service executable before sending; the service checks that incoming capture events originate from GNOME Shell's current bus owner and process. Clear these bindings on owner change and require validation again. Package the service under a fixed installed executable identity rather than trusting an arbitrary process that claims its bus name. Processes able to modify the installed executable or control GNOME Shell itself are outside this application's confidentiality boundary. Test impersonation, process replacement, owner changes, and malformed events before release.

Capture only the regular clipboard, not the primary selection. Ignore password-manager/sensitive clipboard markers where available, apply content filtering before persistence and transmission, and prevent re-capture of explicit app copy-back. Extension disablement or desktop incompatibility must produce a clear capture-unavailable state while history and explicit Copy remain usable.

Package a .deb and a separate GNOME extension with declared Shell versions. The user confirmed Ubuntu 26.10 with GNOME on Intel/AMD x86_64; its published default is GNOME 51. Target the preview extension at Shell 51 and qualify it on that desktop before claiming support. Do not claim general Linux or all GNOME-version support from Ubuntu-only checks. Measure the installed GNOME Shell version and session type before installing anything on that laptop.

### Relay

Add a small self-hostable Rust service with durable opaque mailboxes, authenticated device enrollment, per-device credentials, idempotent submission, bounded pagination, acknowledgement, expiry, and membership revocation. It does not decrypt clips or implement content search. Start with polling and bounded backoff; a live connection is unnecessary for correctness.

Use TLS for non-loopback endpoints. Plain HTTP is allowed only for explicit isolated loopback tests. Validate TLS normally; no ignore-certificate-errors option. Relay URLs are configuration, never inferred from copied text. Disable cross-origin redirects for authenticated requests and never forward mailbox credentials to a different origin.

The repository will contain deployment instructions and an isolated two-client smoke. A running, reachable production relay and its operating cost remain deployment decisions. Do not invent a hosted service or treat localhost tests as proof of different-network availability.

## Encryption and trust

Use an existing Rust implementation of RFC 9180 HPKE with X25519, HKDF-SHA256, and ChaCha20-Poly1305. Use authenticated mode to bind the sender's registered X25519 key. Encrypt separately for each recipient; there is no shared workspace content key to rotate or accidentally copy from the Mac Keychain.

An owner device has a separate Ed25519 membership-signing key. It approves enrollments and signs a versioned roster containing the workspace ID, monotonically increasing membership epoch, member identifiers, encryption public keys, and revocations. Clients pin the owner public key during pairing, persist the largest accepted epoch, reject rollback, and require the sender to be present in the applicable roster. Use established cryptographic libraries and their known-answer vectors. Do not implement cryptographic primitives.

Bind protocol version, workspace ID, sender and recipient IDs, event ID, sender sequence, membership epoch, and message type into the authenticated encryption context. Interpret unknown versions, nonfinite or invalid fields, oversize values, malformed ciphertext, recipient mismatch, and authentication failure as explicit rejection.

The relay can see network addresses, timing, opaque device/mailbox identifiers, sizes, recipient routing, and delivery state. It can delay, drop, duplicate, or reorder delivery. Encryption protects content, not availability or all metadata. Static recipient-key compromise may expose retained ciphertext; do not claim forward secrecy against that compromise.

Relay transport credentials are distinct from encryption keys. Store them in platform credential stores, redact them from logs, and send them only in authenticated request headers. Server-side storage contains one-way credential verifiers, not usable raw tokens.

## Pairing and device removal

1. The first device creates the workspace, its encryption identity, and the owner signing identity in the platform credential store.
2. Add Device creates a single-use, ten-minute invite with a cryptographically random secret of at least 128 bits and the pinned owner fingerprint. Display a transferable pairing string; QR is optional, not required to pair two laptops.
3. The second device creates its own keys and proves possession of the invite secret while binding both device identities and the complete enrollment transcript. Show matching verification words on both devices and require owner confirmation before adding the new member. Rate-limit attempts and invalidate the invite after success or cancellation. The relay does not receive the invite secret in plaintext.
4. The owner signs the updated roster. Devices accept delivery only after the roster and key bindings validate. No existing history is automatically sent to the newcomer.

Only the owner can add/remove devices in this release. If that device is lost, surviving devices keep local history but cannot administer the old workspace; creating a new workspace and re-pairing is the explicit recovery flow. Do not silently change ownership or export private keys as recovery tokens.

Removing a device revokes its relay credentials, advances the signed roster, deletes its pending relay mailbox, and prevents new exports addressed to it once the remaining clients learn the change. Clients refresh membership before flushing queued exports and regenerate recipients against that roster. Offline clients must refresh before resuming uploads. Removal cannot erase clips already decrypted by that device. A malicious relay withholding a newer signed roster may delay revocation discovery; do not promise immediate cryptographic revocation on a stale or offline client.

## Events, deduplication, and offline delivery

Each capture event has a random globally unique ID, origin device ID, persisted monotonically increasing sender sequence, original capture time, schema version, and portable payload. Treat IDs and sequences as protocol fields rather than trusting clocks for identity or ordering.

The relay assigns durable delivery cursors. Receipt application and cursor advancement commit atomically; failed processing does not advance past a valid undelivered item. Persist authenticated rejection receipts for malformed/unsupported items so one poison item cannot stall every later message. Rejections show a bounded actionable status; no plaintext logging.

Retries use stable event IDs and recipients. Duplicate ciphertext or a reconnect must not create another history entry. UI grouping of identical content is separate from event receipt identity. Both clients must agree on canonical payload encoding and digest rules through shared fixtures. A remote import never emits another capture event. Explicit Copy may later be copied by another app; only a new real user capture can become a new event.

The durable local outbox survives restarts and has a 256 MiB byte limit. A single portable payload is limited to 10 MiB after decoding; enforce ciphertext/request limits before allocation and validate decoded image dimensions before preview. At the outbox limit, keep capturing locally, report sharing backlog full, and require retry or explicit discard. Never silently delete unsent clips to make space. Retry transient failures with capped exponential backoff and cancellation; invalid credentials require re-pairing or administrator action.

Relay delivery expires after 30 days, with startup/60-second periodic cleanup, and is capped at 256 MiB per recipient mailbox and 1 GiB globally. Delivery/status metadata expires 37 days after terminal acknowledgement/rejection/revocation/expiry. Persisted sender attempt times stop retransmission after 37 days from first attempt, preventing replay after pruning. Delivery rows and lifetime invitation-ID tombstones are each capped at 100,000, and workspaces at 16. This promises logical retention limits, not physical erasure from storage or backups. Return a visible capacity error rather than evicting unacknowledged content silently. An acknowledged ciphertext can be deleted from the relay. The sender retains pending status until delivery is acknowledged; expiry is a visible failed delivery, not success.

Local Delete and retention remain local. Deleting or expiring an item preserves a minimal event receipt so a retry cannot resurrect it. A queued local share deleted before upload is cancelled. Content already delivered remains on the other device; the UI must say so. Delete Everywhere and editing conflicts are outside the initial capture-sharing protocol.

## Privacy and error presentation

Update README, PRIVACY.md, architecture, first-run disclosures, and Settings at the same milestone that enables networking. Describe content encryption and relay metadata separately. With sync disabled, do not start relay connections or transmit existing local records. Keep Apple Foundation Models behavior unchanged.

Show unpaired, sharing off, connecting, up to date, pending delivery, paused, credential locked, incompatible desktop, capacity full, and failed delivery states with actionable text. Distinguish relay acceptance from recipient acknowledgement. Do not call a clip delivered until the receiving client has committed it.

## Verification gates

1. Protocol: shared fixtures, HPKE published vectors, authenticated sender/recipient binding, altered headers/ciphertext, wrong keys, unknown versions, roster rollback, invite expiry/reuse, removed senders, and input-size rejection.
2. Durable state: duplicate/out-of-order events, crashes around local save/export and remote import/receipt, reconnect, acknowledged deletion, capacity limits, poison-item progress, locked credential store, and cancellation.
3. Relay: unauthenticated access, cross-workspace access, revoked credentials, redirects, idempotency, pagination, expiry, restart persistence, and bounded request bodies. Demonstrate plaintext clip strings are absent from stored relay messages and captured transport payloads.
4. Mac regression: ./script/test.sh and ./script/build_and_run.sh --verify with isolated configuration and explicit staged-bundle identity. Exercise pairing/settings and a received text/image in the rebuilt app. Do not replace the installed production app.
5. Ubuntu: native compilation, actual GTK window interaction, regular clipboard capture and Copy, GNOME Wayland bridge authorization, X11 where supported, image fidelity, desktop restart, and Secret Service lock/unlock. Record exact Ubuntu, GNOME, architecture, and display-session versions. A headless container proves build/protocol behavior only.
6. Device end to end: pair the real Mac and Ubuntu clients; record bidirectional unique text and image tokens, restarts, one device offline then reconnecting, no duplicate after retries, pause, and removal. Record test times, revisions, executable identities, and relay endpoint without secrets.

Implementation is complete only when the relevant source and isolated runtime checks pass. Cross-device availability remains unverified until gate 6. No deployment, installation, publication, or security-audit claim is implied by this document.

## Alternatives and reasons

- A complete cross-platform UI rewrite would replace working Mac interactions and broaden migration risk. Retain SwiftUI/AppKit and add the Linux client.
- LAN-only peer transfer avoids a relay but cannot deliver across unrelated networks or while the receiver is offline. Use opaque relay mailboxes.
- Sharing the current database would combine concurrent database access with device-specific encryption and platform-specific persistence. Transfer portable authenticated events instead.
- A shared content key simplifies envelopes but complicates revocation and exposes all paired history to every member. Use per-recipient encryption.

## References

- HPKE specification: https://www.rfc-editor.org/info/rfc9180/
- GNOME credential service: https://gnome.pages.gitlab.gnome.org/libsecret/class.Service.html
- GTK4 API: https://gnome.pages.gitlab.gnome.org/gtk/gtk4/
- GNOME Shell clipboard API: https://gnome.pages.gitlab.gnome.org/gnome-shell/st/class.Clipboard.html
- Clipboard portal session boundary: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.Clipboard.html

## Review and next step

Self-review completed for platform boundaries, atomic delivery, pairing trust, credential storage, revocation limits, ciphertext metadata, retention/deduplication, queue limits, authority, and separation of build/runtime/device evidence. The Ubuntu release and session details are required before claiming or installing a compatible package; they do not block portable protocol work after approval.

The user approved the written specification and authorized inline implementation without another routine confirmation. The ExecPlan is maintained outside this public repository under the HQ plan convention. Later session instructions extend delivery authority as recorded above. Real desktop acceptance and review remain mandatory gates before declaring the requested cross-laptop outcome complete.

## Additional upgrade-preservation acceptance

The user explicitly requires all existing Mac history to survive this update. Preserve the existing bundle identifier, sandbox and Keychain namespace. Before current-schema open, create the app-owned SQLite-plus-external-assets backup and take a logical legacy snapshot through the exact two-entity schema in a nonwritable configuration. Compare every clip/folder field and actual encrypted external Data against the new context before reconciliation or pruning. Then verify every preserved payload is readable with the existing encryption service, persist only local counts/digest, and show the receipt in General settings. Failure pauses capture and cleanup; the backup remains for recovery. Pause automatic and manual retention cleanup across restarts until the user explicitly resumes the existing retention policy after a clear confirmation. Saved retention settings and opt-in sharing remain separate; no existing history is implicitly sent to another device.
