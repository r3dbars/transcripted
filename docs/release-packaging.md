# Release Packaging

`build.sh` is the local developer build.

Use `build-beta.sh` for anything you intend to hand to another machine. That is
the path that applies hardened runtime signing, builds a DMG, and optionally
submits it for notarization.

Transcripted now targets macOS 26+ for app builds and packaged releases. If a
build is meant to ship to users, keep the bundle metadata, build targets, and
Sparkle release metadata aligned with that floor.

The distribution DMG now uses committed release art:

- app icon: `Resources/Transcripted.icns`
- DMG install background: `scripts/release/assets/dmg-background.png`

If you refresh the install-window art, regenerate the committed PNG with:

```bash
swift scripts/release/generate-dmg-background.swift
```

`build-beta.sh` uses that art for the preferred `create-dmg` path and also for
the built-in Finder-layout fallback, so polished install windows no longer
depend on `create-dmg` being present just to avoid a blank DMG.

`build-beta.sh` still accepts a positional beta-token argument for
backwards-compatible invocations, but the value is no longer injected into the
binary. See `Sources/Beta/BetaConfig.swift` for the rationale. The packaged
release archive is versioned from `Info.plist`, so published artifacts keep the
stable `Transcripted-<version>.dmg` name expected by Sparkle and Homebrew.

Transcripted's Sparkle update plumbing is documented in `docs/sparkle-updates.md`.
`build-deps.sh` now downloads the pinned Sparkle framework and release tools,
plus the pinned Sentry framework, into `deps-frameworks/` and
`deps-tools/sparkle/`.

The two build flows intentionally use separate committed entitlement files:

- `config/entitlements/local.plist`
- `config/entitlements/beta.plist`

Both app build flows also build the release `transcripted-mcp` helper and
bundle it at `Transcripted.app/Contents/Helpers/transcripted-mcp`. The helper is
signed with the rest of the app so the in-app Claude Desktop installer can copy
and self-test it without asking users to install Swift or clone the repo.

`build.sh` and `build-beta.sh` now fail before they touch signing when the
unified dependency artifacts are missing or older than the current
`Sources/TranscriptedCore/`, `Package.swift`, or `build-deps.sh` inputs. They
also require the app binary to exist before signature validation runs.

## Prerequisites

1. Install a `Developer ID Application` certificate.
2. Store a notarytool profile in the login keychain.
3. Build the unified dependency bundle once with exact pinned versions.
4. Make sure the local Parakeet models are installed. Distribution builds
   bundle them by default so first launch does not depend on a runtime model
   download.

Useful checks:

```bash
security find-identity -v -p codesigning
xcrun notarytool store-credentials <profile-name> ...
```

To force a specific certificate for either build flow:

```bash
SIGN_IDENTITY=<sha-or-name-fragment> bash build.sh
SIGNING_IDENTITY=<sha-or-name-fragment> bash build-beta.sh <beta-token> <user-name>
```

`build-beta.sh` bundles Parakeet by default for distribution builds. That keeps
the first dictation/meeting path local after install.

If you deliberately want a thin local test artifact, make both opt-outs explicit:

```bash
REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 bash build-beta.sh <beta-token> <user-name>
```

## Release Flow

```bash
bash build-deps.sh --force
NOTARY_PROFILE=<profile-name> bash build-beta.sh <beta-token> <user-name>
```

Before you publish a user-facing release note, sanity-check the release state:

- compare `Info.plist` `CFBundleShortVersionString` against the latest GitHub release tag
- review the merged PRs since that latest published release so the note reflects shipped changes, not just local branch state
- if `docs/appcast.xml` still points at the older release, say plainly that existing installs will not discover the new build in-app yet
- if you want a clean starting point, use `docs/release-notes-template.md`

If you expect existing installs of Transcripted to discover the new version
inside the app, do not stop after the DMG is built. You must also complete the
Sparkle steps in `docs/sparkle-updates.md`.

If you expect `brew install` or `brew upgrade` to pick up the new version, do
not stop after the GitHub release is published. You must also refresh and push
the Homebrew cask update.

After the release is published on GitHub, refresh the Homebrew cask so `brew
upgrade` picks the new DMG up:

```bash
bash scripts/release/update-cask.sh <version>
```

The script downloads the published `Transcripted-<version>.dmg`, computes its
sha256, and rewrites `Casks/transcripted.rb` in place. Commit and push that
change with the rest of the release bookkeeping.

If you skip this step, the GitHub release exists, but Homebrew users will still
install or upgrade to the older version.

Even after a DMG is properly signed, notarized, and stapled, users should still
expect the normal macOS first-open confirmation for an app downloaded from the
Internet. The healthy path is the standard one-click confirmation dialog, not a
Gatekeeper rejection or “developer cannot be verified” block.

For a dry run that still validates the signed app and DMG assembly:

```bash
SKIP_NOTARIZATION=1 bash build-beta.sh <beta-token> <user-name>
```

## Expected Validation

`build-beta.sh` should complete all of the following:

- `codesign --verify --deep --strict` passes for the `.app`
- the DMG is signed when a Developer ID identity is available
- notarized runs staple a ticket, pass `spctl` checks for the app, and pass `xcrun stapler validate` for the DMG
- the release process updates `docs/appcast.xml` if users should receive the build through Sparkle

Some local `spctl -t open` checks against a stapled DMG can still report
`source=Insufficient Context`. Treat a successful `xcrun stapler validate` on
the DMG as the reliable release gate for the archive itself.

If notarization is intentionally skipped, Gatekeeper rejection for the signed
app is expected until the artifact is notarized and stapled.
