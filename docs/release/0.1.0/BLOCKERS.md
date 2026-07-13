# Release Blockers

| Blocker | Why external | Owner | Exact resolution |
| --- | --- | --- | --- |
| App Store Connect record, credentials, role, upload validation | Account-only state/secret | Apple account owner | Confirm app record and provide scoped API key; run validate-only/upload and inspect warnings |
| GitHub Actions billing/spending limit | Both push and PR jobs were rejected before runner assignment with GitHub's billing annotation | GitHub account owner | Resolve failed payment or raise the Actions spending limit, then rerun PR #9 checks |
| Provisioning confirmation | No embedded profile and server validation unavailable | Apple account owner | Confirm bundle provisioning/profile policy and pass ASC validation |
| Public support/privacy URLs | Public hosting/contact decision | Product owner | Publish HTTPS pages and enter URLs |
| Privacy labels, age rating, accessibility declaration | Truthful owner declarations in ASC | Product/legal owner | Complete questionnaires from `PRIVACY_DATA_MAP.md` and actual behavior |
| Export compliance | AES-GCM use requires owner/legal response | Legal/account owner | Answer ASC encryption questions; do not add plist exemption without confirmation |
| DSA trader, content rights | Legal/business declarations | Legal/account owner | Complete in ASC |
| Price, territories, release mode | Business decisions | Product owner | Select values in ASC |
| macOS 15 and clean-user proof | Runtime/environment unavailable | QA | Install and smoke the signed candidate on clean macOS 15+ environment |
| macOS 27 compatibility | Toolchain/runtime unavailable | QA | Test separately when Xcode/macOS 27 is available |
| Newest accepted production toolchain | Apple lists Xcode 26.6 as the latest stable Xcode; this host has only 26.5 | Engineering/QA | Install Xcode 26.6 and regenerate/revalidate the candidate before submission |

These external blockers plus the formal security-scan, newest-toolchain, and remaining manual-QA gaps prevent readiness. Screenshot assets are now locally complete.
