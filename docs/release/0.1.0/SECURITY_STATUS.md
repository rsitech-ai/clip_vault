# Security Status

Verdict: **NOT YET VERIFIED** for the formal native scan gate. Manual/source-focused review, dependency checks, and a fresh independent full-branch-plus-working-tree security review found no actionable finding, but the required native standard and final diff scans are not complete.

- Secrets/credentials: source and configuration inspected; no committed key, profile, ASC credential, or production secret found.
- Storage: versioned AES-GCM detail envelope, Keychain-held key, plaintext placeholders, legacy migration, future-version fail-closed behavior, and corrupt legacy recovery are regression-tested.
- Capture: explicit consent is required; stopping/revoking invalidates in-flight payload work; startup rebaselines the pasteboard.
- Logging: failure details are private OSLog values; raw clipboard content, keys, notes, OCR, and file paths are not intentionally logged.
- Sandbox: enabled; only user-selected read-only file access is added. Distribution entitlements include expected team/application identifiers.
- Supply chain: no external Swift dependency; Rust crate has no third-party dependency; format, Clippy, and RustSec audit pass.
- Native/FFI: the Rust dylib is arm64, nested-signed, hardened, and loaded only from the app Frameworks directory.
- Independent final review: production probe/pasteboard isolation, drag payload validation, move-store revalidation, consent lifecycle, unsafe FFI contracts, packaging rejection rules, and secret patterns were reviewed with no actionable finding.

Residual risks: upgraded historical databases may contain plaintext remnants in SQLite freelist/WAL/backups from pre-hardening builds; `/usr/sbin/screencapture` is an external command surface; App Store server-side provisioning validation is unavailable. Owners: engineering for future migration/command replacement; Apple account owner for server validation.
