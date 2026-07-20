# Changelog

All notable user-visible changes to ClipVault will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). ClipVault is pre-1.0 and has not published a public release.

## [Unreleased]

### Added

- Local-first clipboard capture with explicit consent, menu-bar retrieval, workspace search, notes, tags, pinning, folders, and collections.
- Local AES-GCM encryption for clip payloads and user-authored details using a device-bound Keychain key.
- Sensitive-looking value exclusion before persistence.
- Image and screenshot previews with local OCR indexing.
- On-device prompt enhancement through Apple Foundation Models when available.
- Swift, Rust, shell, signed-app, persistence, and package-validation test lanes.

### Security

- Capture cancellation and consent revocation invalidate in-flight work.
- Alternate bundle identities use isolated Keychain namespaces for E2E and QA flows.
- Distribution-package validation rejects debug probes, invalid signatures, unexpected load paths, mismatched architectures, and missing privacy or entitlement metadata.

### Known limitations

- No public tag, GitHub release, or supported binary distribution exists yet.
- The current build is arm64-only and requires macOS 15 or later.
- Cloud sync, accounts, teams, and cloud AI providers are not available.
- GitHub-hosted CI and the public repository security/settings gates remain to be proven on the final release commit.
