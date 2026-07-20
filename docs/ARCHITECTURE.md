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
