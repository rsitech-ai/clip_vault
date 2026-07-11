# ClipVault Release Privacy Hardening Design

## Scope and decision

This release closes two validated privacy/App Review blockers without changing ClipVault's local-first product shape.

Clipboard content at rest will use an encrypted record-details envelope stored in the existing `encryptedListPayload` field. The envelope contains the list payload, display title, user note, tags, and source application. Existing plaintext SwiftData columns remain only as schema-compatible non-content placeholders. On first read, legacy records are decoded from their encrypted payload, migrated into the envelope, and their plaintext content columns are cleared in the same save. New saves and duplicate updates never persist clipboard-derived strings in plaintext.

The alternatives were rejected: narrowing the encryption claim would leave complete clipboard content exposed in the database, while replacing SwiftData with a custom encrypted database would be a disproportionate release rewrite.

## First-run consent

Capture defaults to paused until the user explicitly accepts a concise first-run disclosure. The disclosure states that ClipVault watches copied text, images, links, and file references; performs local OCR; stores encrypted content locally; applies a configurable retention policy; and may fail to recognize every secret. `Enable Clipboard Capture` persists consent and starts capture. `Not Now` keeps capture paused. Settings and the menu bar continue to provide an obvious pause/resume control; resuming after a decline presents the same consent requirement.

Automated local release scripts may preseed the consent preference in their controlled smoke profile. The production default remains no consent and no capture.

## Logging and packaging

Public unified-log messages contain stable operation categories only. Unpredictable framework descriptions are marked private. The release package script removes build-host Xcode RPATHs before signing, captures the dSYM matching the final executable, and asserts UUID equality. The release check inspects the actual package, expanded payload, signature, entitlements, RPATHs, and dSYM. Upload automation validates API key-file shape and supports validation without upload.

## Verification

Storage regressions inspect the SwiftData record and backing store for a unique marker, prove content recovery through the encrypted envelope, and prove legacy migration clears plaintext. Consent policy tests cover first launch, accept, decline, relaunch, and revoke. Script tests cover key-file validation, package UUID/RPATH checks, and CI syntax where local tooling permits. Full Rust/Swift tests, AddressSanitizer, warning-free Release build, two stateful E2E smokes, signed runtime/log checks, fresh package creation, strict signing inspection, and final diff review remain mandatory.

## External boundaries

No repository change can truthfully supply public support/privacy URLs, legal support contact, App Store Connect record, DSA trader status, age-rating answers, pricing/territories, content-rights answers, export-compliance determination, credentials, server validation, or App Review approval. These remain explicit owner/account blockers. `ITSAppUsesNonExemptEncryption` will not be guessed.
