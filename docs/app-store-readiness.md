# ClipVault App Store Readiness

## Current State

- SwiftPM package with executable product `ClipVault`.
- App bundle is staged by `script/build_and_run.sh`.
- App Store package flow is defined in `script/package_app_store.sh`.
- Sandbox entitlements are defined in `Packaging/ClipVault.entitlements`.
- Privacy manifest is defined in `Resources/PrivacyInfo.xcprivacy`.
- App metadata draft is in `AppStore/metadata.md`.

## Required Apple Account Work

1. Create App Store Connect app record.
2. Register bundle ID `com.andrzej.ClipVault` or change `APP_BUNDLE_ID` in scripts before packaging.
3. Create/install Mac App Store distribution signing assets:
   - Apple Distribution / Mac App Distribution application signing identity.
   - Mac Installer Distribution / 3rd Party Mac Developer Installer identity for `.pkg` upload.
   - Matching provisioning profile if required by your account configuration.
4. Publish a public HTTPS privacy policy URL.
5. Publish a public support URL with contact information.

Official Apple references:

- App Store Connect upload flow: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- Certificate signing request creation: https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request/
- Privacy manifest files: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- App Sandbox: https://developer.apple.com/documentation/security/app-sandbox

## Local Validation Commands

```bash
./script/test.sh
./script/build_and_run.sh --verify
./script/e2e_smoke.sh
./script/app_store_check.sh
```

`app_store_check.sh` exits with code `3` when the local bundle is valid but
distribution signing identities are missing.

## Package Command

After distribution identities are installed:

```bash
APP_SIGNING_IDENTITY="Apple Distribution: <Name> (<TEAMID>)" \
INSTALLER_SIGNING_IDENTITY="3rd Party Mac Developer Installer: <Name> (<TEAMID>)" \
APPLE_TEAM_ID="<TEAMID>" \
PROVISIONING_PROFILE_PATH="/path/to/profile.provisionprofile" \
APP_BUNDLE_ID="com.andrzej.ClipVault" \
APP_VERSION="0.1.0" \
APP_BUILD="1" \
./script/package_app_store.sh
```

The package will be written to `dist/AppStore/ClipVault-0.1.0-1.pkg`.

If your account does not require a manually embedded provisioning profile for
this Mac App Store target, omit `PROVISIONING_PROFILE_PATH`. Keep
`APPLE_TEAM_ID` explicit so App Store distribution entitlements include the
team and application identifier.

## Upload Command

After the package is created and you have an App Store Connect API key:

```bash
ASC_API_KEY="<KEY_ID>" \
ASC_API_ISSUER="<ISSUER_ID>" \
ASC_API_KEY_PATH="/path/to/AuthKey_<KEY_ID>.p8" \
APP_VERSION="0.1.0" \
APP_BUILD="1" \
./script/upload_app_store.sh
```

The script uses `xcrun altool --upload-app` and refuses to run unless the
package exists and API key values are supplied.

## Known App Review Risks

- Clipboard managers can be scrutinized for privacy. Keep the product copy explicit that capture is local and user-controllable.
- App Sandbox is enabled. Re-test pasteboard capture under a distribution-signed sandboxed build before upload.
- Cloud/BYO AI is disabled in MVP. Do not mention active cloud AI features on the App Store page until implemented and disclosed.
