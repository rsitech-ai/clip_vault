# ClipVault 0.1.0 Blockers

Date: 2026-07-20

| Blocker | Owner | Exact resolution |
| --- | --- | --- |
| No publishable tag or release artifact | Project owner / Apple account owner | Close source gates and obtain Developer ID signing/notarization before publishing the direct-download asset. |
| App Store distribution identities are not usable locally | Apple account owner | Xcode reports Apple Distribution as not in Keychain and Mac Installer Distribution as missing its private key. Install usable identity/private-key pairs before App Store packaging. Do not mix Apple Development and Distribution/Developer ID teams. |
| Notarization profile absent | Apple account owner | Developer ID Application signing works when the Distribution-team identity is installed. Store a scoped `notarytool` keychain profile named `clipvault-notary`, run `package_direct_download.sh`, then smoke the stapled app on a clean account/machine. Current preflight exits 2 at the missing/unauthenticated profile gate. |
| App Store Connect record/validation and declarations absent | Apple/product/legal owners | Complete record, credentials, support/privacy URLs, privacy labels, age/accessibility, export, DSA, rights, price, territories, server validation, and upload. |
| Historical agent/plan paths still in older commits | Release lead | Tree cleanup removes them from HEAD. A full history purge requires temporarily relaxing the `Protect main` non-fast-forward ruleset, then `git filter-repo` and `--force-with-lease`. |

The formal Codex Security scan was waived for this pass. That waiver removes the workflow from this task; it is not evidence that a formal scan ran.
