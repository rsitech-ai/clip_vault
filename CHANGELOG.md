# Changelog

All notable user-visible changes to ClipVault will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). ClipVault is pre-1.0 and has not published a notarized binary release.

## [Unreleased]

No changes recorded after the preview candidate below.

## [0.2.0-preview.8] - 2026-10-21

Experimental source-and-Ubuntu release candidate. Public macOS binary distribution
remains blocked on notarization and clean-machine Gatekeeper proof.

### Added

- Ubuntu/GNOME clipboard workspace for Intel/AMD laptops, with explicit capture consent and a GNOME Shell 51 capture extension.
- Opt-in encrypted pairing and sharing for new text, rich text and images across Mac and Ubuntu clients.
- Actual file sharing without a fixed product size cap, bounded encrypted chunks, explicit receiver Save, disk reservations and restart recovery.
- Existing Mac history verification and a retained recovery snapshot during schema upgrade.

### Changed

- Reuse transport connections, overlap two fresh file chunks, remove redundant requests and keep receiving through short batch gaps.
- Stream proxy traffic and index relay cleanup/mailbox queries while preserving encryption, private HTTPS and SQLite durability.
- Align package defaults with the validated Mac 0.2.0 build 16 and Ubuntu preview 8, and include project licensing in Linux packages.

### Fixed

- Recover usable clipboard image bytes when a single background copied file advertises an inaccessible file URL; retain OCR privacy and capture-generation checks.

### Validation and limits

- Final installed 128 MiB test measured 4.869 MiB/s sustained versus 3.302 MiB/s baseline in equal progress windows; rates vary with Wi-Fi and recipient workload.
- All six text routes and six receiver Save/size/hash routes passed on three actual hosts, plus restart recovery and a 600 MiB integrity gate.
- Linux target is Ubuntu 26.10, x86_64, GNOME Shell 51; other GNOME versions, Intel Macs and mobile clients are not qualified.
- Sharing requires a self-hosted relay. No accounts, hosted sync service or cloud AI provider is supplied. macOS source builds target Apple silicon and macOS 15 or later.

## Earlier unreleased macOS work

### Added

- Local-first clipboard capture with explicit consent, menu-bar retrieval, workspace search, notes, tags, pinning, folders, and collections.
- Local AES-GCM encryption for clip payloads and user-authored details using a device-bound Keychain key.
- Sensitive-looking value exclusion before persistence.
- Image and screenshot previews with local OCR indexing.
- On-device prompt enhancement through Apple Foundation Models when available.
- Swift, Rust, shell, signed-app, persistence, and package-validation test lanes.
- Public Apache-2.0 source repository under RSI Tech with NOTICE, security policy, and contribution guide.
- Area, window, and scrolling-page screenshot capture from the menu bar and File menu.

### Changed

- Date-grouped clip rows show clock time (or "Just now") instead of repeating the full date already in the section header.
- Collection assignment and move operations update only the affected clips instead of reloading and decrypting the entire library.
- Pin toggles update only the affected clip instead of reloading and decrypting the entire library.
- Finder file and folder clipboard items use their file URLs directly, avoiding unnecessary rich-pasteboard decoding.

### Fixed

- The menu-bar surface consistently shows All Clips, independently of the collection selected in the main window.
- Moving or assigning the selected clip now reconciles the visible selection without triggering a full workspace reload.
- Deleting, clearing, or cleaning up clips now reconciles selection against the visible workspace results instead of the raw library order.
- Screenshot capture checks Screen Recording access before showing a picker and reports permission denial separately from cancellation.

### Security

- Capture cancellation and consent revocation invalidate in-flight work.
- Alternate bundle identities use isolated Keychain namespaces for E2E and QA flows.
- Distribution-package validation rejects debug probes, invalid signatures, unexpected load paths, mismatched architectures, and missing privacy or entitlement metadata.

### Known limitations

- The historical 0.1.0 candidate had no public tag or downloadable binary distribution.
- The current build is arm64-only and requires macOS 15 or later.
- Accounts, teams, a developer-hosted sync service and cloud AI providers are not available. Optional self-hosted encrypted sharing was added in the 0.2.0 preview.
- Direct-download publication remains blocked until a notarization Keychain profile and clean-account Gatekeeper proof are available.
