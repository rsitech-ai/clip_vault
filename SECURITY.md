# Security Policy

## Supported versions

ClipVault has not published a stable release. Security fixes are currently applied to the latest `main` branch and will be documented here when a supported public release exists.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability and do not include secrets, clipboard contents, private logs, personal data, or exploit details in public discussions.

GitHub private vulnerability reporting is the intended reporting channel for this repository. It must be enabled before public launch. Once enabled, use the repository's **Security** tab and choose **Report a vulnerability**.

The project cannot offer a safe private intake channel until that setting is enabled. This is a publication blocker, not an invitation to disclose a vulnerability publicly.

Include, when possible:

- the affected commit or version;
- the macOS and hardware version;
- the reachable source-to-impact path;
- a minimal reproduction using non-sensitive test data;
- the expected impact and any known mitigation.

Maintainers will acknowledge a valid private report, coordinate remediation, and publish details only after affected users have a reasonable upgrade path. No response-time guarantee is made before a public release and maintainer policy are established.

## Security boundaries

ClipVault is local-first, but local-first does not mean risk-free. The app handles clipboard content, Keychain-backed encryption, pasteboard access, files chosen by the user, OCR, SwiftData persistence, a Rust FFI library, and optional on-device Foundation Models. Review [PRIVACY.md](PRIVACY.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before evaluating a report.
