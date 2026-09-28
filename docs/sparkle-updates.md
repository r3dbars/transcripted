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
- `SUAllowsAutomaticUpdates` is enabled so background downloads are allowed
- `SUAutomaticallyUpdate` is enabled, so by default Sparkle downloads a found
  update in the background and installs it when the app quits. This is only the
  default: anyone who picked a setting in About keeps their choice, because
  Sparkle reads the saved user default before `Info.plist`
- with automatic downloads on, Sparkle's background checks (scheduled and
  launch) don't start while the Mac is busy (meeting capture, dictation,
  transcription or imports in the queue) or on an expensive or constrained
  network (phone hotspot, Low Data Mode). The rule is
  `BackgroundUpdateDeferralPolicy`. A deferred check still reads the feed with
  a small probe, so a waiting update shows as `Install` with the badge; only
  the automatic download waits, until Sparkle's next interval. Sparkle cannot
  pause a download that already started, so a meeting that starts mid-download
  does not stop it. `Check for Updates` is never deferred. Until macOS reports
  the network, it counts as expensive, so a launch-time download never starts
  on a hotspot by racing that report. A deferred check skips the probe when a
  downloaded update is already waiting as `Restart to Update`
- the app triggers a background update check on launch when automatic checks
  are enabled. It waits up to 3 seconds for the first network report first,
  so a normal network downloads right away instead of deferring
- scheduled update reminders are handled quietly inside Transcripted instead of
  showing automatic Sparkle pop-ups
- the orange menubar badge shows whenever an update needs a click: a
  downloaded update waiting for a restart, or a found update Sparkle will not
  download on its own (automatic downloads off, a failed background download,
  or an update Sparkle hands back as a reminder). The rule lives in
  `UpdateAttentionPolicy`
- when automatic downloads are enabled, Transcripted keeps available/downloading
  states quiet; the user-facing action appears only when the update is ready as
  `Restart to Update`. If a background download fails, or the install prep
  after it fails (unpacking, signature, disk space), the update switches to
  the normal `Install` action instead of showing `Preparing Update` until the
  next scheduled check. The same happens when a probe (not a background
  check) finds the update, since nothing downloads after a probe
- "Skip This Version" clears the badge (`updater(_:userDidMake:...)`), and a
  later check that no longer offers a found update clears it too. "Remind Me
  Later" keeps the badge; that is the reminder. Dismissing an already
  downloaded update reads as `Restart to Update`, since Sparkle keeps it and
  installs it on quit
- an `Install` click that lands while Sparkle is still reading the feed is
  kept and runs when Sparkle holds the update or finishes that check, instead
  of doing nothing
- the menu bar footer includes a manual `Check for updates` action; without
  automatic downloads, a prominent install action can still appear when Sparkle
  finds a newer release
- the settings sidebar footer becomes an update action under the same rule as
  the badge: `Update ready` once Sparkle has staged the update, `Update
  available` when the person has to start the install
- the About settings page exposes one `Automatic updates` control with three
  positions — `Check on launch` / `Notify me` / `Download automatically` —
  backed by the same two Sparkle booleans (`Download automatically` is hidden
  when Sparkle reports automatic downloads unavailable). `Check on launch`
  disables Sparkle's scheduled checks but preserves the app's launch-time
  availability refresh and the manual button. If Sparkle has already downloaded
  an update, the primary action becomes `Restart to Update`
- every update click goes through `UpdateClickRoutingPolicy` and must do
  something visible (#1830). A downloaded update with Sparkle's immediate
  install callback installs right away. An update Sparkle already holds or
  shows (a quiet reminder, or its window hidden behind other apps) is brought
  forward through Sparkle's standard update controller. With no session open,
  the click starts Sparkle's own check. Before handing off, the app activates
  itself with `NSApp.activate(ignoringOtherApps:)`, because Sparkle's
  cooperative `NSApp.activate()` can leave its window behind the frontmost
  app. In any case Sparkle would silently ignore (no valid feed, or a
  session that isn't showing anything), the app shows an alert with the
  download page and the `brew upgrade --cask transcripted` command instead

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
| Menu bar status-item badge + tooltip | `TranscriptedApp.updateStatusItemBadge` | badge shown when the update needs a click, tooltip `Transcripted - update <version> available` | tooltip `Transcripted - restart to update to <version>` |
| Settings sidebar footer | `TranscriptedSettingsView.settingsFooterShowsUpdateBadge` | `Update available` (same rule as the badge) | `Update ready` |

When automatic downloads are enabled the available/downloading states stay quiet
(`Preparing Update` / `Downloading…`) and the only user-facing action is the
ready-to-install restart, unless the background download failed, in which case
the available copy and `Install` action come back. The failure taxonomy behind these states lives in
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
4. Put the release archive in a local updates folder, plus the DMGs of the
   last few releases (see "Delta updates" below).
5. Run:

```bash
bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder
```

6. The script keeps the current feed history, takes the newest generated item,
   checks it is the version in `Info.plist`, rewrites its enclosure and delta
   URLs to the matching GitHub release assets, aligns the minimum macOS version
   with `Info.plist`, and then writes the merged result back to
   `docs/appcast.xml`. It lists the delta files to upload in
   `<updates-folder>/sparkle-deltas.txt`.
   - If the owner said yes to reaching old versions (see "Reaching people on old
     versions" below), run `python3 scripts/release/mark-appcast-critical.py`. The
     tool's only change is one `<sparkle:criticalUpdate ... />` line in the new item.
     Either way, run `python3 scripts/release/mark-appcast-critical.py --check`: it
     fails if the previous release was marked and this one isn't.
7. Upload the release archive and every delta file to the same GitHub release.
   The Release Candidate workflow artifact holds the deltas under
   `build/sparkle-deltas/`; in the local flow they sit in the updates folder,
   named in `sparkle-deltas.txt`. From the downloaded artifact folder:
   `gh release create v<version> build/Transcripted-<version>.dmg $(find build/sparkle-deltas -name '*.delta')`
   (the `find` keeps the command working in bash and zsh when there are no
   deltas). Any publish helper script must upload the deltas too; a DMG-only
   upload leaves every delta URL a 404, so every client silently downloads the
   full DMG again.
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

## Reaching people on old versions

Builds 1.1.22 through 1.1.62 answer `standardUserDriverShouldHandleShowingScheduledUpdate`
with `update.isCriticalUpdate`, ship without automatic downloads, and their own
Install action does nothing while Sparkle's held reminder is open. On those
installs a check that finds a normal update shows nothing useful (PostHog,
2026-09-24: 1.1.56 installs clicked Install Update 105 times on 14 devices in 21
days and almost none downloaded). Installed apps can't be patched, but the feed
can mark the newest item critical for anything older:

```bash
python3 scripts/release/mark-appcast-critical.py --dry-run   # show what it would do
python3 scripts/release/mark-appcast-critical.py             # write docs/appcast.xml
python3 scripts/release/mark-appcast-critical.py --check     # state; fails if the previous release is marked and the newest isn't
python3 scripts/release/mark-appcast-critical.py --remove    # undo
```

It adds `<sparkle:criticalUpdate sparkle:version="X" />` to the newest item, and
refuses to write a feed that ElementTree wouldn't round-trip byte for byte (a
comment or CDATA), so the published diff is always that one line. Apps
whose `CFBundleVersion` is below X then get Sparkle's own update window on the
next check (at launch if the last check was over 4 hours ago, then every 4 hours).
Right after launch it shows with focus. Later in a session it waits until the app
is next brought to the front (Dock icon shown), or shows right away behind any
focused window (Dock icon hidden). The window has Install Update, the
"Automatically download and install" checkbox, and no Skip or Remind Me Later
button; closing it brings it back on the next check. People who turned automatic
downloads on get a silent download and install on quit instead, and people who
turned automatic checks off never see it.

Who it reaches: 1.1.22 to 1.1.62. Builds 1.1.17 to 1.1.21 hard-code `false` in
that delegate, so nothing in the feed can make them prompt. Builds up to 1.1.16
have no such delegate and already show Sparkle's normal window.

X defaults to the newest item's version, capped at 1.1.63. 1.1.63 is the first
build with automatic downloads on and a working Install action, so later releases
stay quiet for anyone already on 1.1.63 or newer. Don't raise `--below` past 1.1.63
without a reason: those builds still hand critical updates to Sparkle's no-Skip
window.

Only the newest item counts, and `generate-sparkle-appcast.sh` adds each new item
unmarked. So it is part of release step 6 above, repeated each release
while builds older than 1.1.63 are still active. Markers left on older items are
inert (the feed still has bare ones on 1.1.22 and 1.1.23 from April). Pushing the
marked appcast is publishing and needs the owner's explicit go, like the rest of
the appcast.

Old builds don't guard Sparkle-driven installs during a recording. If someone
opens the menu mid-meeting, the pending window can come up then, and Install
starts the full download. Install and Relaunch still goes through the app's quit
confirmation (Keep Recording is the default), so a recording isn't lost.

## Delta updates

A full update is the whole ~510 MB DMG, and about 505 MB of that is the
bundled speech models (Parakeet alone is ~483 MB). The models are byte-for-byte
the same from release to release, because the Release Candidate workflow
copies them out of the previous release's DMG. So Sparkle delta updates, which
carry only the files that changed, are about 1-3 MB for someone on a recent
version.

How it works:

- the Release Candidate workflow downloads the DMGs of the last
  `SPARKLE_MAXIMUM_DELTAS` (5) published releases into the updates folder next
  to the new DMG
- `generate_appcast` builds and signs one `Transcripted<new>-<old>.delta` per
  older DMG and adds a `<sparkle:deltas>` block to the new item, after the
  full-DMG enclosure
- `generate-sparkle-appcast.sh` points each delta URL at the same GitHub
  release as the DMG and refuses to write the appcast if a listed delta file is
  missing or unsigned
- the workflow copies the listed deltas to `build/sparkle-deltas/` in its
  artifact and lists them in the run summary; they are uploaded to the release
  with the DMG
- `verify-sparkle-release.sh` HEAD-checks each delta URL, and the post-DMG
  audit checks each delta is on the release with the right size

No app change is needed: Sparkle 2 clients pick a delta whose
`sparkle:deltaFrom` matches their installed version. Anyone older than the
last five releases gets the full DMG. If a delta 404s or fails to apply (for
example, the installed app was modified), Sparkle falls back to the full DMG,
so a missed delta upload costs download size, not a broken update. If building
deltas fails in CI, the workflow warns and publishes full-download metadata
instead, exactly like releases before deltas.

The metadata step deletes the old DMGs and Sparkle's unpack cache when it is
done (they add several GB on the runner), prints `df -h`, and gives up on
deltas after 45 minutes when `timeout` is available.

Update analytics can't tell a delta from a full download. When a delta fails
and Sparkle falls back, `update_download_started` fires twice for one update,
and GitHub asset download counts now include delta files.

Keep the models copied from the previous release. If the model bytes ever
change (a new model version), that one update's deltas grow to the size of the
changed model files.

## Signing key

The current public EdDSA key in `Info.plist` is:

```xml
<key>SUPublicEDKey</key>
<string>Ib6MHm4eeZYjhsZblNT0DEo3LzK9fYvBLkmqvw/Vo7Q=</string>
```

The matching private key stays in the local macOS keychain and is not stored in this repo.

## Install telemetry

`update_installed` fires once, on the first launch of a newer version, and
carries `install_kind`:

- `restart`: the in-app `Restart to Update`, or Sparkle's own install-and-relaunch
- `quit`: Sparkle installed a background-downloaded update when the app quit
- `unattributed`: the version went up with no in-app install on record (a new
  DMG, Homebrew, or an older build's updater)

The highest launched version is stored under `Transcripted.LastLaunchedAppVersion`
(so switching between an old stray copy and a new one counts the upgrade once),
so the first launch of the build that adds this has no baseline and only counts
installs recorded by the old relaunch marker. Counts are complete from the next
update onward. The decision logic is `UpdateInstallDetection`.
