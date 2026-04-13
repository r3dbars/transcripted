# Release Packaging

`build.sh` is the local developer build.

Use `build-beta.sh` for anything you intend to hand to another machine. That is
the path that applies hardened runtime signing, builds a DMG, and optionally
submits it for notarization.

The distribution DMG now uses committed release art:

- app icon: `Resources/Transcripted.icns`
- DMG install background: `scripts/release/assets/dmg-background.png`

`build-beta.sh` uses that art for the preferred `create-dmg` path and also for
the built-in Finder-layout fallback, so polished install windows no longer
depend on `create-dmg` being present just to avoid a blank DMG.

`build-beta.sh` also treats the per-user beta token as sensitive build input:
it escapes the token before injecting it into `Sources/Beta/BetaConfig.swift`
and only prints a masked preview in build logs.

Transcripted's Sparkle update plumbing is documented in `docs/sparkle-updates.md`.
`build-deps.sh` now downloads the pinned Sparkle framework and release tools,
plus the pinned Sentry framework, into `deps-frameworks/` and
`deps-tools/sparkle/`.

The two build flows intentionally use separate committed entitlement files:

- `config/entitlements/local.plist`
- `config/entitlements/beta.plist`

`build.sh` now fails before it touches signing when the unified dependency
artifacts are missing or stale, and it also requires the app binary to exist
before signature validation runs.

## Prerequisites

1. Install a `Developer ID Application` certificate.
2. Store a notarytool profile in the login keychain.
3. Build the unified dependency bundle once with exact pinned versions.
4. Make sure local Parakeet models are present if you want them bundled into
   the app instead of downloaded at runtime.

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

## Release Flow

```bash
bash build-deps.sh --force
NOTARY_PROFILE=<profile-name> bash build-beta.sh <beta-token> <user-name>
```

If you expect existing installs of Transcripted to discover the new version
inside the app, do not stop after the DMG is built. You must also complete the
Sparkle steps in `docs/sparkle-updates.md`.

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
