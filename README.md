# ClipVault

ClipVault is a macOS-first private AI clipboard workspace. It captures clipboard items, excludes sensitive-looking content before storage, encrypts payloads locally, groups clips into smart collections, and exposes selected-clip AI actions through provider boundaries.

## Run

```bash
./script/build_and_run.sh
```

## Test

```bash
./script/test.sh
./script/e2e_smoke.sh
```

The scripts build the Rust search/index core before Swift so the SwiftPM target can link the local static library.

## App Store Readiness

```bash
./script/app_store_check.sh
```

When Apple distribution and installer certificates are installed, create a Mac App Store package with:

```bash
APP_SIGNING_IDENTITY="Apple Distribution: <Name> (<TEAMID>)" \
INSTALLER_SIGNING_IDENTITY="3rd Party Mac Developer Installer: <Name> (<TEAMID>)" \
APPLE_TEAM_ID="<TEAMID>" \
APP_BUNDLE_ID="com.andrzej.ClipVault" \
APP_VERSION="0.1.0" \
APP_BUILD="1" \
./script/package_app_store.sh
```

See `docs/app-store-readiness.md` for the full checklist.
