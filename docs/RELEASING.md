# Releasing ClipVault

ClipVault has three distinct release lanes. Evidence from one lane must not be used to claim another is complete.

## 1. Source release

A source release requires:

- an approved open-source license and copyright holder;
- a clean exact-commit secret/privacy/provenance review;
- all documented local checks passing;
- a successful GitHub-hosted CI run on the exact commit;
- accurate README, changelog, support, security, contribution, and release notes;
- public repository security settings and default-branch rules verified;
- an annotated `v0.1.0` tag and GitHub source release created only after explicit publication approval.

## 2. Direct-download macOS release

In addition to the source gate, a downloadable app requires:

- Developer ID Application signing;
- hardened-runtime verification for the app and nested Rust library;
- notarization and stapling;
- Gatekeeper assessment and launch on a clean account or machine;
- a ZIP created from the notarized app plus a published SHA-256 checksum;
- release notes that state the supported macOS version and architecture.

An ad-hoc or Apple Development signature is not a distributable release signature.

Verify credentials before doing build work:

```bash
DEVELOPER_ID_APPLICATION_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
NOTARY_KEYCHAIN_PROFILE="clipvault-notary" \
./script/package_direct_download.sh --preflight
```

After the source gate closes, create the notarized release artifacts with the same
environment variables and no argument:

```bash
DEVELOPER_ID_APPLICATION_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
NOTARY_KEYCHAIN_PROFILE="clipvault-notary" \
./script/package_direct_download.sh
```

The command fails closed unless the identity is installed and the notary profile
authenticates. It signs the nested Rust library and app with hardened runtime,
submits the ZIP for notarization, requires an `Accepted` result, staples and
validates the ticket, runs Gatekeeper assessment, and writes the final ZIP plus
its SHA-256 file under `dist/DirectDownload/`.

## 3. Mac App Store release

In addition to the applicable source/runtime gates, the App Store lane requires:

- Apple Distribution and Mac Installer Distribution identities;
- correct bundle ID, team, provisioning, sandbox entitlements, privacy manifest, and app metadata;
- a strictly validated `.pkg` and matching dSYM;
- App Store Connect record, privacy answers, age rating, accessibility declaration, export-compliance and DSA decisions, price/territories, support URL, and privacy URL;
- server-side validation, upload, review notes, and explicit submission approval.

Use these repository commands:

```bash
./script/test.sh
cargo fmt --manifest-path rust/SearchIndexCore/Cargo.toml --check
cargo clippy --manifest-path rust/SearchIndexCore/Cargo.toml --all-targets --all-features -- -D warnings
cargo audit --file rust/SearchIndexCore/Cargo.lock
swift build -c release -Xswiftc -warnings-as-errors
./script/build_and_run.sh --verify
./script/e2e_smoke.sh
./script/package_direct_download.sh --preflight
./script/app_store_check.sh
git diff --check
```

When distribution identities are available, package with the environment variables documented in [app-store-readiness.md](app-store-readiness.md), then run the strict package validator.

## Versioning

Before the first public tag, `0.1.0` is the proposed version. After release, use semantic versioning for the source/API contract and increment the macOS build number for every uploaded binary.

## Rollback

- Do not move or replace an existing tag. Publish a corrective version.
- Do not delete a broken public release until its artifacts and user impact are recorded.
- If a candidate fails after tagging but before publication, leave the tag unpublished only when it has not been pushed; otherwise create a new patch version.
- For a security incident, disable affected distribution assets, publish a private advisory first, rotate any compromised credentials, then issue a fixed release with clear upgrade instructions.
