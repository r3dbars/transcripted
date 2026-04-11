# Sparkle Updates

Transcripted now uses Sparkle for in-app update checks.

## What is configured in the app

- `Info.plist` points Sparkle at `https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml`
- `SUEnableAutomaticChecks` is enabled by default
- the app triggers a background update check on launch when automatic checks are enabled
- the menu bar footer includes a manual `Check for updates` action

## Local tooling

`bash build-deps.sh --force` now downloads Sparkle's official pinned distribution and installs:

- `deps-frameworks/Sparkle.framework`
- `deps-tools/sparkle/bin/generate_appcast`
- `deps-tools/sparkle/bin/sign_update`
- `deps-tools/sparkle/bin/generate_keys`

## Release flow

1. Build a signed/notarized Transcripted archive, typically with `build-beta.sh`.
2. Put the release archive in a local updates folder.
3. Run:

```bash
bash scripts/generate-sparkle-appcast.sh /path/to/updates-folder
```

4. The script copies the generated `appcast.xml` back into `docs/appcast.xml`.
5. Upload the release archive to GitHub Releases.
6. Commit and push the updated `docs/appcast.xml`.

Sparkle will then discover the new version from the appcast URL on the next app launch.

## Signing key

The current public EdDSA key in `Info.plist` is:

```xml
<key>SUPublicEDKey</key>
<string>Ib6MHm4eeZYjhsZblNT0DEo3LzK9fYvBLkmqvw/Vo7Q=</string>
```

The matching private key stays in the local macOS keychain and is not stored in this repo.
