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

## In-app update prompt surfaces (inventory)

Transcripted suppresses Sparkle's own automatic pop-ups (only critical updates
hand back to the standard Sparkle UI), so every routine "an update is available"
prompt is native Transcripted copy. Each surface must show the version and read
unmistakably as *an update is available to install* — never as "you're done" or
"shipped". The surfaces are:

| Surface | Where | "Update available" copy | "Ready to install" copy |
|---------|-------|-------------------------|-------------------------|
| Menu bar footer row | `MenuBarPanelController.menuUpdatePresentation` | title `Update available: <version>`, detail `A new version is ready to install`, trailing `Install` | title `Restart to Update`, detail `Version <version> downloaded`, trailing `Restart` |
| Settings → About status card | `TranscriptedSettingsView.aboutUpdateStatus*` | title `Update available (<version>)`, detail `Version <version> is ready to install.` | title `Ready to restart (<version>)`, detail `Version <version> is downloaded.` |
| Settings → About primary button | `TranscriptedSettingsView.aboutUpdateButtonTitle` | `Install <version>` | `Restart to Update` |
| Menu bar status-item badge + tooltip | `TranscriptedApp.updateStatusItemBadge` | (badge hidden until staged) | tooltip `Transcripted - restart to update to <version>` |

When automatic downloads are enabled the available/downloading states stay quiet
(`Preparing Update` / `Downloading…`) and the only user-facing action is the
ready-to-install restart. The failure taxonomy behind these states lives in
`Sources/Observability/UpdateFailureKind.swift`.

If you add or rename an update prompt surface, update this table in the same
change so the inventory stays complete.

## Local tooling

`bash build-deps.sh --force` now downloads Sparkle's official pinned distribution and installs:

- `deps-frameworks/Sparkle.framework`
- `deps-tools/sparkle/bin/generate_appcast`
- `deps-tools/sparkle/bin/sign_update`
- `deps-tools/sparkle/bin/generate_keys`

For a no-publish UI smoke of the native Transcripted update surfaces, build the
app and run:

```bash
bash build.sh --no-open
swift run --package-path Tools/TranscriptedQA transcripted-qa sparkle-update-smoke --app build/Transcripted.app --output /tmp/transcripted-sparkle-update-smoke
```

Or through the QA bench:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode sparkle-update
```

This launches the built app in the existing launch-smoke harness with a fake
Sparkle `updateAvailable` state and a fake `downloading` state. It verifies the
menu update-available callout and the download-progress row from the app's own
menu snapshot, and writes local JSON evidence plus a fake appcast fixture under
the output directory. It does not contact the live feed, download an update,
verify a signature, install, relaunch, publish, update Homebrew, or prove an
existing installed app can upgrade.

## Release flow

1. Build a signed/notarized Transcripted archive, typically with `build-beta.sh`.
2. Before publishing, run the local packaged app smoke:

```bash
swift run --package-path Tools/TranscriptedQA transcripted-qa packaged-app-smoke --app build/Transcripted.app --dsym build/Transcripted.app.dSYM --run-ui-smoke
```

This checks the built app's Sparkle feed URL, public key, automatic update
flags, dSYM, DMG, optional menu bar launch, and local log privacy without
uploading or modifying `docs/appcast.xml`.
3. Run the read-only post-DMG audit so the expected GitHub asset URL, appcast,
   Homebrew cask, website/download routes, and release-health follow-ups are
   visible before anything is published:

```bash
python3 scripts/release/post-dmg-release-audit.py --version <version> --artifact build/Transcripted-<version>.dmg
```

Pre-publish GitHub, appcast, Homebrew, Sentry, and website rows may be
`PENDING`. That is the point: they stay explicit until the release surface is
actually live.
4. Put the release archive in a local updates folder.
5. Run:

```bash
bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder
```

6. The script keeps the current feed history, takes the newest generated item,
   rewrites its enclosure URL to the matching GitHub release asset, aligns the
   minimum macOS version with `Info.plist`, and then writes the merged result
   back to `docs/appcast.xml`.
7. Upload the release archive to GitHub Releases.
8. Verify the published update path:

```bash
bash scripts/release/verify-sparkle-release.sh <version>
```

9. Commit and push the updated `docs/appcast.xml`.
10. After the final appcast push and any expected Homebrew/Sentry release
   surfaces are live, run the strict live-surface gate:

```bash
python3 scripts/release/post-dmg-release-audit.py --version <version>
python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces
```

That live gate also checks the GitHub release asset size/digest against the
committed appcast and Homebrew cask.

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
