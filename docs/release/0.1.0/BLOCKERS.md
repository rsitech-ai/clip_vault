# ClipVault 0.1.0 Blockers

Date: 2026-07-20

| Blocker | Owner | Exact resolution |
| --- | --- | --- |
| No project license or approved copyright holder | Project owner | Select a license and copyright holder; add `LICENSE` and matching Cargo metadata. |
| Personal author email in all 122 historical commits | Project owner | Explicitly approve publishing it, authorize a history rewrite to an approved no-reply address, or authorize a curated/orphan public-source history. |
| Repository visibility remains private | Project owner | Make `rsitech-ai/clip_vault` public only after license, history privacy, confidential reporting, and exact-head verification gates close. |
| Confidential conduct route missing | Project owner | Approve a private conduct contact distinct from vulnerability reporting. |
| Private vulnerability reporting unavailable | Repository owner | Enable GitHub private vulnerability reporting before public launch, or approve another private security route. |
| Hosted CI not proven on exact candidate | GitHub account owner | Resolve Actions billing/spending state and rerun the final commit successfully. |
| Default-branch rules and required checks missing | Repository owner | Configure branch/ruleset protection after the required workflow is able to run. |
| No publishable tag or release artifact | Project owner / Apple account owner | Close source gates and obtain Developer ID signing/notarization before publishing the direct-download asset. |
| No distribution identities or expected Team ID | Apple account owner | Install scoped application/installer distribution identities and provide the expected Team ID, then rerun package checks. |
| Developer ID/notarization proof absent | Apple account owner | Install a valid Developer ID Application identity, store a scoped `notarytool` keychain profile, run `package_direct_download.sh`, then smoke the stapled app on a clean account/machine. Current preflight exits 2 at the missing identity gate. |
| App Store Connect record/validation and declarations absent | Apple/product/legal owners | Complete record, credentials, support/privacy URLs, privacy labels, age/accessibility, export, DSA, rights, price, territories, server validation, and upload. |

The formal Codex Security scan was waived for this pass. That waiver removes the workflow from this task; it is not evidence that a formal scan ran.
