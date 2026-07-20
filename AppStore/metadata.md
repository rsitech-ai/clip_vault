# ClipVault App Store Metadata Draft

## App Information

- App name: ClipVault
- Subtitle: AI Clipboard Workspace
- Bundle ID: `com.andrzej.ClipVault`
- SKU: `clipvault-macos`
- Category: Productivity
- Age rating: owner must complete the App Store Connect questionnaire; no rating is asserted in this draft.
- Price model: owner decision required. The repository contains no purchases or subscriptions.

## Description Draft

ClipVault turns clipboard history into a private workspace.

Capture copied text, code, links, files, and screenshots. Search across clipboard content, notes, tags, and OCR text. Screenshots are kept as images while local OCR makes their text searchable. Add notes, tags, and cleaner titles to important clips, pin what matters, and remove noisy history in bulk.

ClipVault is local-first. Clipboard payloads are stored on device and encrypted locally. Obvious secrets are excluded before storage when detected.

Clipboard capture starts only after an explicit in-app disclosure is accepted, and it can be paused or revoked at any time.

## Keywords Draft

clipboard, history, snippets, screenshots, OCR, notes, search, code, productivity

## Support URL

`https://github.com/rsitech-ai/clip_vault/blob/main/SUPPORT.md`

Support contact: `info@rsitech.ai`

## Privacy Policy URL

`https://github.com/rsitech-ai/clip_vault/blob/main/PRIVACY.md`

## Review Notes Draft

ClipVault is a local-first clipboard manager. It uses the macOS pasteboard to capture clipboard items, stores payloads locally with encryption, and lets users search, annotate, copy back, pin, and delete clips. No account is required. No network service is used in the MVP. Cloud AI provider settings are disabled.

## Required Screenshots

Capture clean macOS App Store screenshots showing:

- Menu bar clipboard list with preview pane.
- Main workspace with collections/list/detail layout.
- Screenshot annotation panel with OCR, tags, and notes.
- Bulk cleanup view.

Two clean, truthful product screenshots are staged in `AppStore/Screenshots/` at the Apple-accepted 1280x800 size. They were captured from an isolated `.screenshots` bundle populated only with sanitized sample content:

- `01-main-workspace.jpg`
- `02-ai-workspace.jpg`

## Owner-confirmation fields

- Public support URL and support contact
- Public privacy policy URL
- Copyright holder and year
- Final category, price, territories, and release mode
- Age-rating, content-rights, privacy-label, DSA trader-status, and export-compliance answers
