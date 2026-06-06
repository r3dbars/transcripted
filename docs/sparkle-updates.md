# Sparkle Updates

Transcripted now uses Sparkle for in-app update checks.

The live app now targets macOS 26+ only. When cutting a new release, the
generated appcast entry for that release should advertise the same 26+ floor.

Future agents should treat this as a release requirement:

- if a build is meant to reach existing users through the app's updater, the
  release is not done until `docs/appcast.xml` has been updated and pushed to
  the branch that serves the live feed
- uploading a DMG to GitHub Releases by itself is not enough for current
  installs to discover the update

## What is configured in the app

- `Info.plist` points Sparkle at `https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml`
- `SUEnableAutomaticChecks` is enabled by default
- `SUScheduledCheckInterval` is set to 4 hours so automatic checks happen
  more often than Sparkle's default daily cadence
- `SUAllowsAutomaticUpdates` is enabled so users can opt in to background
  downloads from Settings
- the app triggers a background update check on launch when automatic checks are enabled
- scheduled update reminders are handled quietly inside Transcripted instead of
  showing automatic Sparkle pop-ups
- the orange menubar badge is reserved for a downloaded, Sparkle-verified update
  that is ready to install on restart
- when automatic downloads are enabled, Transcripted keeps available/downloading
  states quiet; the user-facing action appears only when the update is ready as
  `Restart to Update`
- the menu bar footer includes a manual `Check for updates` action; without
  automatic downloads, a prominent install action can still appear when Sparkle
  finds a newer release
- the settings sidebar footer becomes an update-ready restart action only after
  Sparkle has staged the update
- the About settings page exposes `Check automatically` and `Download
  automatically`; if Sparkle has already downloaded an update, the primary
  action becomes `Restart to Update`

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
bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder
```

4. The script keeps the current feed history, takes the newest generated item,
   rewrites its enclosure URL to the matching GitHub release asset, aligns the
   minimum macOS version with `Info.plist`, and then writes the merged result
   back to `docs/appcast.xml`.
5. Upload the release archive to GitHub Releases.
6. Verify the published update path:

```bash
bash scripts/release/verify-sparkle-release.sh <version>
python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces
```

7. Commit and push the updated `docs/appcast.xml`.

If the final push has not happened yet, Sparkle clients will keep seeing the old
version.

Do not replace `docs/appcast.xml` wholesale with Sparkle's raw generated output.
That can drop older feed history and leave the latest item pointing at the wrong
URL shape instead of the real GitHub release asset.

Sparkle will then discover the new version from the appcast URL on the next app launch.

## Signing key

The current public EdDSA key in `Info.plist` is:

```xml
<key>SUPublicEDKey</key>
<string>Ib6MHm4eeZYjhsZblNT0DEo3LzK9fYvBLkmqvw/Vo7Q=</string>
```

The matching private key stays in the local macOS keychain and is not stored in this repo.
