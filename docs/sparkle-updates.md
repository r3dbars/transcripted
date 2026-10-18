# Sparkle Updates

Transcripted now uses Sparkle for in-app update checks.

The live app now targets macOS 26+ only. When cutting a new release, the
generated appcast entry for that release should advertise the same 26+ floor.

Future agents should treat this as a release requirement:

- if a build is meant to reach existing users through the app's updater, the
  release is not done until its signed `appcast.xml` is an asset of the GitHub
  release that is marked latest. Nothing commits an appcast to main any more;
  `docs/appcast.xml` is the frozen legacy feed ("Legacy feed" below)
- uploading a DMG to GitHub Releases by itself is not enough for current
  installs to discover the update

## What is configured in the app

- `Info.plist` points Sparkle at `https://github.com/r3dbars/transcripted/releases/latest/download/appcast.xml`
  (see "Feed hosting" below)
- `SUVerifyUpdateBeforeExtraction` is on, so Sparkle checks an update archive's
  EdDSA signature before it unpacks anything
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

## Feed hosting

The feed installed apps read is the `appcast.xml` asset of the latest GitHub
release. GitHub answers `releases/latest/download/appcast.xml` with a 302 to its
asset store. Sparkle fetches feeds and archives through `URLSession`, whose
default is to follow redirects, and the app sets nothing that turns that off, so
the redirect needs no app change. `verify-sparkle-release.sh` fetches the URL
with `curl -L`, which follows it the same way. That is read from Sparkle's
documented behavior and a curl run, not from a Sparkle check against the real
feed: the first real upgrade (see "Not done yet") is the proof.

Why not main: a feed on main is edited by a normal commit, so anyone who can
land a commit there can redirect every install to a different archive. A release
asset only changes when someone with release permissions uploads one, and the
file is signed.

What the release flow does with it:

- the Release Candidate workflow downloads the `appcast.xml` of the current
  latest release (the first release on this feed starts from the legacy
  `docs/appcast.xml` instead), merges the new item into it with
  `generate-sparkle-appcast.sh`, optionally marks it critical, signs it with
  `sign-appcast.sh`, and uploads it in the candidate artifact as
  `build/appcast.xml`
- the owner uploads it to the release with the DMG and deltas, as a draft that
  is flipped to published and latest afterwards, so `releases/latest` never
  holds a release with no feed
- every release carries the full history, so the latest release's file is the
  whole feed. Items are never edited after publishing; a bad item is fixed by a
  new release

Prereleases and betas: `releases/latest` skips prereleases and drafts, so a
build published as a prerelease is invisible to this feed. Transcripted has no
separate Sparkle beta channel (no `allowedChannels`, no channel tags in the
feed), so there is nothing to lose today. Do not publish a shipping release as a
prerelease. If a beta channel is wanted later, put it in the same feed with
`<sparkle:channel>` on the beta items and set `allowedChannels` in the app's
updater delegate for opted-in users; that keeps one URL and needs no second
feed.

## Signed feed

`sign-appcast.sh` runs `sign_update` on the finished `appcast.xml`, which embeds
an EdDSA signature as a trailing `<!-- sparkle-signatures: ... -->` comment (and
a warning comment), then reads it back with the same key. Any edit after that,
including `mark-appcast-critical.py`, invalidates it, so signing is the last
step. The signature is made with the same key whose public half is
`SUPublicEDKey`.

Sparkle 2.9.1 is the pinned version (`build-deps.sh`). What it does and does not
give us:

- the framework has both `SUVerifyUpdateBeforeExtraction` (Sparkle 2.7.3+) and
  `SURequireSignedFeed` (Sparkle 2.9+), plus `SUSignedFeedFailureExpirationInterval`
  (found in the vendored binary's strings; its headers are not shipped in
  `deps-frameworks/`, and Sparkle's customization docs describe all three)
- `SUVerifyUpdateBeforeExtraction` is on. `SURequireSignedFeed` is **not** on
  yet, on purpose. Sparkle's docs say that with it on, external release notes
  must be signed too, and every item's `sparkle:releaseNotesLink` points at a
  GitHub release page (`releases/tag/v<version>`), which is HTML GitHub renders
  and nobody can sign. How Sparkle 2.9.1 treats an unsigned release-notes link
  under that key is not documented, so turning it on today could break the
  update window on the first build that has it. To turn it on: switch new items
  to embedded release notes (`<description>`) or a static, signed notes file,
  add the key to `Info.plist`, and prove it with the staged upgrade test
  (`docs/staged-sparkle-update-test.md`) before the release ships. The key only
  affects builds that carry it, so it can land in any later release.
- with `SURequireSignedFeed` off, nothing here proves Sparkle checks the
  embedded feed signature, or refuses an unsigned or stripped feed. Don't claim
  either. The signature still pays off: `sign-appcast.sh` and
  `verify-sparkle-release.sh` check it, and it is in place for the day the key
  is on. Sparkle's docs also say that once the key is on, a feed that keeps
  failing validation shows updates again after 20 days
  (`SUSignedFeedFailureExpirationInterval`), as a failsafe for a lost key
- archives and deltas are already EdDSA-signed in the feed; with
  `SUVerifyUpdateBeforeExtraction` on, that check happens before the archive is
  unpacked
- builds before the one that introduces this `Info.plist` keep the old behavior,
  and they read the legacy feed, which is why it is frozen and not deleted

## Legacy feed

Installs older than the first build with the new `SUFeedURL` still read
`https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml`.
They need one last hop. When the first release on the new feed ships:

1. publish it as above, with its signed `appcast.xml`
2. run, once, from a checkout whose `Info.plist` is that release's:

```bash
python3 scripts/release/freeze-legacy-appcast.py \
    --new-appcast build/appcast.xml --info-plist Info.plist [--mark-critical]
```

   It copies the release's feed item to the top of `docs/appcast.xml`, optionally
   marks it critical for 1.1.22-1.1.62 (same owner decision as "Reaching people
   on old versions"), and writes `config/release/legacy-appcast-freeze.*`
   with the file's sha256. It refuses unless the item is the version in that
   `Info.plist`, that `Info.plist` has the new `SUFeedURL`, the item is signed,
   and the freeze file does not exist yet. `--dry-run` shows the plan.
3. commit both files and land them on main in the same change as that release's
   `Info.plist` version bump and cask (release step 4 in
   `docs/release-packaging.md`); `ReleaseMetadataContractTests` expect the
   legacy feed's newest item to match `Info.plist` until the freeze record
   exists. That push is publishing and needs the owner's explicit go. Old installs see the new item on their next check,
   update to the build that reads the new feed, and never read the legacy file
   again.

After that nothing may edit `docs/appcast.xml`. `scripts/dev/check-known-traps.py`
(`legacy-appcast`) fails if its hash no longer matches the freeze file or if the
freeze file differs from `origin/main`. `generate-sparkle-appcast.sh` and
`sign-appcast.sh` refuse to write to it. Deleting the file would strand every
install that has not updated yet, so it stays.

Nothing is frozen yet: the first new-feed release does not exist, and the freeze
entry cannot be written before it. Until then `docs/appcast.xml` is still the
live feed for every shipped build.

## Not done yet

- no release has shipped on the new feed, and no old install has been taken
  through the hop. The real proof is an RC, a staged upgrade from an old build
  against the published feed, and a check that the signed feed and redirect work
  from a clean machine. None was run here.
- `scripts/ops/nightly-security-check.py` (live release surfaces),
  `scripts/ops/release-health-card.py` and `scripts/ops/release-watch.py` still
  read "latest release" from `docs/appcast.xml`. Once it is frozen they report
  the frozen entry. They need to read the release-asset feed before the second
  release on the new feed. Until the freeze exists the nightly check skips the
  new feed URL, since it would only 404.
- the website's `/appcast.xml` route (in `r3dbars/transcripted-webapp`) should
  point at the release-asset feed after the first release.

## Release flow

1. Build a signed/notarized Transcripted archive with the Release Candidate
   workflow (`docs/release-packaging.md`). A local `build-beta.sh` only makes
   un-notarized test DMGs.
2. Before publishing, run the local packaged app smoke:

```bash
swift run --package-path Tools/TranscriptedQA transcripted-qa packaged-app-smoke --app build/Transcripted.app --dsym build/Transcripted.app.dSYM --run-ui-smoke
```

This checks the built app's Sparkle feed URL, public key, automatic update
flags, dSYM, DMG, optional menu bar launch, and local log privacy without
uploading an appcast.
3. Run the read-only post-DMG audit so the expected GitHub asset URL, appcast,
   Homebrew cask, website/download routes, and release-health follow-ups are
   visible before anything is published:

```bash
python3 scripts/release/post-dmg-release-audit.py --version <version> --artifact build/Transcripted-<version>.dmg --appcast build/appcast.xml
```

Pre-publish GitHub, appcast, Homebrew, Sentry, and website rows may be
`PENDING`. That is the point: they stay explicit until the release surface is
actually live.
4. The workflow's signing job puts the release archive and the DMGs of the
   last few releases (see "Delta updates" below) in an updates folder.
5. It runs, against a scratch copy of the current feed:

```bash
REPO_APPCAST_PATH=/path/to/feed-copy/appcast.xml INFO_PLIST_PATH=<shipped Info.plist> \
    bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder
```

6. The script keeps the current feed history, takes the newest generated item,
   checks it is the version in `Info.plist`, rewrites its enclosure and delta
   URLs to the matching GitHub release assets, aligns the minimum macOS version
   with `Info.plist`, points the feed's self link at the release-asset URL, and
   then writes the merged result back to the scratch copy. It has no default
   feed path and refuses `docs/appcast.xml` once that is frozen. It lists the
   delta files to upload in `<updates-folder>/sparkle-deltas.txt`.
   - If the owner said yes to reaching old versions (see "Reaching people on old
     versions" below), dispatch with `mark_critical_for_old_builds=true`; the
     workflow runs `python3 scripts/release/mark-appcast-critical.py --appcast <feed>`.
     Either way it runs `--check` and warns if the previous release was marked
     and this one is not.
   - `scripts/release/sign-appcast.sh <feed>` signs the feed last.
7. Upload the release archive, every delta file and the signed feed to the same
   GitHub release. The Release Candidate workflow artifact holds the deltas under
   `build/sparkle-deltas/` and the feed at `build/appcast.xml`. From the
   downloaded artifact folder, create the release as a draft, then publish it:
   `gh release create v<version> --draft build/Transcripted-<version>.dmg build/appcast.xml $(find build/sparkle-deltas -name '*.delta')`
   then `gh release edit v<version> --draft=false --latest` (the `find` keeps the
   command working in bash and zsh when there are no deltas). Any publish helper
   script must upload the deltas and the feed too; a DMG-only upload leaves
   every delta URL a 404 and the feed on the previous release.
8. Verify the published update path (it fetches the live feed through the
   redirect; `VERIFY_APPCAST_FILE=build/appcast.xml` checks the artifact copy
   before publishing):

```bash
bash scripts/release/verify-sparkle-release.sh <version>
```

9. For the first release on the new feed only, freeze the legacy feed ("Legacy
   feed" above).
10. After the release is published and any expected Homebrew/Sentry release
   surfaces are live, run the strict live-surface gate:

```bash
python3 scripts/release/post-dmg-release-audit.py --version <version>
python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces
```

That live gate also checks the GitHub release asset size/digest against the
feed and Homebrew cask.

If the release is not the latest one, or has no `appcast.xml` asset, Sparkle
clients keep seeing the previous version.

Do not replace the feed wholesale with Sparkle's raw generated output.
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
python3 scripts/release/mark-appcast-critical.py             # write docs/appcast.xml (frozen legacy feed only; releases use --appcast <feed>)
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
