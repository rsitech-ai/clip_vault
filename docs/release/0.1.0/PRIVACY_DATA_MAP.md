# Privacy Data Map

| Data | Source/purpose | Storage/retention/deletion | Recipient/tracking/linkage | Disclosure |
| --- | --- | --- | --- | --- |
| Clipboard text, links, rich text, file references | User pasteboard; history/search/copy-back | Local SwiftData; encrypted payload/details; ordinary clips 30 days by default; user delete/bulk delete | None; no tracking; not linked to developer identity | First-run capture disclosure and `PRIVACY.md` |
| Screenshots and OCR text | User screenshot/pasteboard; preview/search | Local encrypted payload; same retention; deletion in app | OCR runs locally; no third party | Capture disclosure and privacy policy |
| Titles, tags, notes | User organization | Local encrypted clip details; retained with clip and deleted with it | None | In-app and public privacy policy |
| Source application name and clipboard type identifiers | Frontmost app and pasteboard metadata; local source context and payload reconstruction | Source app and type identifiers are stored in encrypted clip details/payloads; same retention and deletion as the clip | None | In-app and public privacy policy |
| Clip ID, content kind, timestamps, deduplication fingerprint, copy count, folder names/relationships, pin state, collection membership | Local operation, deduplication, ordering, retention, and organization | Local plaintext SwiftData metadata inside the sandbox container; deleted or updated through app controls | None | In-app and public privacy policy |
| Settings and consent | User choices; app behavior | UserDefaults; until changed/reset | None | Settings and privacy policy |
| Encryption key | Generated locally; decrypt local content | macOS Keychain; local device | None | Privacy policy |

The app has no account, analytics, advertising, ATT flow, backend, remote AI, purchases, or third-party SDK. `PrivacyInfo.xcprivacy` declares no collected data, no tracking, and UserDefaults reason `CA92.1`. App Store privacy-label answers and the public policy URL require owner confirmation; they are not invented here.
