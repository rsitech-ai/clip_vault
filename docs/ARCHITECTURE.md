# ClipVault Architecture

## System shape

ClipVault is a macOS SwiftPM application with a SwiftUI/AppKit shell, a reusable Swift core, SwiftData persistence, and a bundled Rust search library.

```text
macOS pasteboard
      |
      v
capture consent -> sensitive-value filter -> encrypted ClipPayload/details
      |                                           |
      |                                           v
      |                                      SwiftData store
      |                                           |
      +-----------------> Rust normalization/search <----+
                                                  |
                                                  v
                                menu bar / workspace / copy-back
```

## Modules

### `Sources/ClipVault`

Owns application scenes, the menu-bar extra, windows, Settings, view composition, and app-level orchestration. `ClipVaultViewModel` coordinates user actions and delegates persistence and platform work to core services.

### `Sources/ClipVaultCore`

Owns domain models and boundaries for clipboard capture, consent, sensitive-value classification, encrypted persistence, pasteboard write-back, search bridging, retention, thumbnails, and prompt enhancement.

### `rust/SearchIndexCore`

Owns deterministic normalization, fingerprints, lexical ranking, and the C-compatible FFI exports consumed by Swift. Swift scripts build the release library before SwiftPM links the app or tests.

## Data and trust boundaries

- Clipboard capture is disabled until the user accepts the in-app disclosure.
- Sensitive-looking content is rejected before the persistence boundary.
- Payloads, display titles, notes, tags, source-application names, and clipboard type metadata are stored in an AES-GCM envelope.
- The encryption key is generated locally and stored in macOS Keychain under a bundle-scoped service.
- Operational metadata needed for identity, ordering, deduplication, retention, and collection membership remains plaintext inside the sandboxed SwiftData database. The privacy policy documents this boundary.
- The app has no enabled cloud provider. Apple Foundation Models run on-device when available; unavailable model states fail closed and do not trigger a cloud fallback.
- The Rust dynamic library is bundled inside the app and loaded through an app-relative path.

## Persistence and migration

Existing stored records are migrated only when a persistent store existed before launch and contains clip rows. Alternate bundle IDs and test probes use separate Keychain namespaces. Future encrypted-envelope versions fail closed rather than interpreting unknown data.

## Release boundaries

A successful source build does not prove signing, notarization, App Store provisioning, GitHub settings, or runtime interaction. [RELEASING.md](RELEASING.md) records the separate gates.

## Optional encrypted device sharing

`rust/DeviceSync` is a separate Cargo workspace: `core` owns authenticated HPKE envelopes, signed membership, bounded encrypted queues and relay transport; `relay` stores authenticated opaque mailboxes; `bridge` exposes the bounded synchronous JSON C ABI used on a Swift background queue; `linux` provides a GTK/libadwaita client and clipboard adapters. The original Rust search library keeps its existing build paths.

Mac capture creates a SwiftData export record in the same transaction as a local clip. Export preparation failures retain retryable references to local content. Rust queue submission uses a stable event identifier. Remote import uses its own SwiftData method and receipt, without increasing local copy counts or producing another export. Only after the SwiftData import commits does the controller mark that event applied for acknowledgement. Invalid platform payloads create durable negative acknowledgements; storage failures remain retryable.

The Linux client uses encrypted SQLite payloads and GNOME Secret Service credentials. GNOME Wayland capture uses a push-only, consent-gated Shell bridge; X11 capture uses bounded clipboard streams. Both clients retain local history while offline. HTTPS is required outside explicit loopback tests, and disabled sharing starts no relay connection. See [Linux and sync](LINUX_AND_SYNC.md) and the [design](design/linux-encrypted-sync.md) for trust and compatibility boundaries.


Attachments use separate versioned authenticated manifest/chunk/outcome frames,
with 1 MiB chunks and a 100 MiB per-file limit. The platform history and C ABI
carry only a small descriptor; encrypted file bytes stay in the portable store.
Outgoing data is staged before a history descriptor/outbox is committed. Every
paired device must advertise file support before transmission. Incoming chunks
are acknowledged after encrypted persistence; a separate authenticated outcome
confirms complete length/hash verification before history publication. Explicit
Save streams and verifies again, then publishes without overwriting a destination.
Ordinary clip work and incoming mail continue while an attachment is waiting for
an update or recipient capacity. See the [file design](design/file-sharing-and-linux-ui.md)
for resource bounds, consent generations, sandbox access and recovery behavior.
