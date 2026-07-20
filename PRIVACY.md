# ClipVault Privacy Policy

Last updated: 2026-07-20

ClipVault is a local-first clipboard workspace for macOS.

## Data Collection

ClipVault does not collect, track, sell, or transmit personal data to the developer or third parties.

Clipboard items, screenshots, OCR text, titles, tags, notes, folders, and app settings are stored locally on the device. When available, ClipVault also records the name of the application that was frontmost when an item was copied so the clip can show its local source context.

Clip payloads and clip details, including source-application names and clipboard type metadata, are encrypted locally with a key stored in the macOS Keychain. Operational metadata such as clip identifiers, content kind, timestamps, fingerprints used for deduplication, copy counts, pin state, collection membership, and folder structure remains plaintext inside ClipVault's sandboxed local database. None of this data is transmitted to the developer or third parties.

ClipVault does not begin watching the clipboard until the user accepts an in-app disclosure. Capture can be paused or consent can be revoked in Settings at any time.

## Network Use

The MVP does not send clipboard content to cloud services. Cloud or BYO AI providers are disabled unless a future version adds explicit opt-in settings.

## Sensitive Content

ClipVault attempts to exclude obvious secrets before storage, including private keys, API tokens, and password-like values. Users can delete clips at any time.

## Data Deletion

Users can delete individual clips or bulk-delete groups of clips inside the app. Deleting a clip removes its stored payload, notes, tags, and metadata from ClipVault's local store.

Ordinary clips are retained for 30 days by default. The retention period can be changed in Settings. Pinned clips are not automatically removed.

## Contact

The canonical policy URL is `https://github.com/rsitech-ai/clip_vault/blob/main/PRIVACY.md`. General support will use the repository issue forms after public launch. Do not disclose clipboard contents, credentials, personal data, private logs, vulnerabilities, or sensitive privacy failures in a public issue. See `SECURITY.md` for the planned private vulnerability-reporting route.
