# Release Packaging

Vacation/absence release hold: see `docs/release-guardrails.md` before doing
anything that could publish, notarize for shipment, update Sparkle/appcast,
update Homebrew, or move the live download surface.

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
The same `Info.plist` metadata also drives Sentry release reporting:
`transcripted@<CFBundleShortVersionString>` with dist set to
`CFBundleVersion`.

## Bundle Identifier Compatibility

`Info.plist` intentionally keeps the legacy bundle identifier
`com.justinbetker.draft` for now even though the product name is Transcripted.
Changing it would create a new macOS app identity for TCC permissions,
UserDefaults, login items, update state, and support debugging. Treat any bundle
identifier rename as a release migration, not a cleanup. A safe migration needs
explicit defaults migration, permission/support copy updates, Sparkle/Homebrew
coordination, and fresh QA on existing installs.

Distribution builds also generate `build/Transcripted.app.dSYM` so production
crashes can be symbolicated in Sentry. Keep that dSYM beside the release build
until Sentry registration has uploaded it.

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
SIGN_IDENTITY=<sha-or-name-fragment> bash build.sh --no-open
SIGNING_IDENTITY=<sha-or-name-fragment> bash build-beta.sh <beta-token> <user-name>
```

`build-beta.sh` bundles Parakeet and offline diarizer models by default for
distribution builds. That keeps the first dictation/meeting path local after
install.

If you deliberately want a thin local test artifact, make both opt-outs explicit:

```bash
REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 REQUIRE_BUNDLED_DIARIZER_MODELS=0 BUNDLE_DIARIZER_MODELS=0 bash build-beta.sh <beta-token> <user-name>
```

For a thin packaging smoke that also skips notarization, keep every opt-out visible:

```bash
SKIP_NOTARIZATION=1 REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 REQUIRE_BUNDLED_DIARIZER_MODELS=0 BUNDLE_DIARIZER_MODELS=0 bash build-beta.sh <beta-token> <user-name>
```

After `build-beta.sh` succeeds, run the packaged app smoke described below
before publishing anything. It checks the existing `build/Transcripted.app` and
versioned DMG for Sparkle config, signing, dSYM UUID evidence, optional UI
smoke, and local log privacy. For a stricter release-candidate report after
packaging, compose it with:

```bash
python3 scripts/ops/release-gate-report.py --qa-mode deep --strict-artifacts --include-packaged-app-smoke --require-release-debug-files
```

Yellow is expected when notarization is intentionally skipped or the appcast has
not yet been updated for a new version. Red means the package itself is broken.
When an agent runs this inside Codex's filesystem sandbox, `codesign`,
`hdiutil`, and packaged-app launch checks may need an approved unsandboxed rerun
before calling a package red.

Before publishing the DMG, run the read-only post-DMG audit:

```bash
python3 scripts/release/post-dmg-release-audit.py --version <version> --artifact build/Transcripted-<version>.dmg
```

This does not create a GitHub release, update Sparkle, rewrite the Homebrew
cask, register Sentry, or deploy the website. It compares the intended release
against the exact GitHub asset URL, committed appcast, Homebrew cask, live
download routes, live appcast, crawler-facing text, and optional local DMG
evidence. Missing post-publish surfaces are `PENDING` or `UNKNOWN`, not green.
Use it again after publishing, appcast/cask updates, and website deployment to
catch any surface that still points at the older release.

Rollback planning should use the same surfaces. Before changing release
metadata, note the previously live GitHub release tag, `docs/appcast.xml`
latest item, `Casks/transcripted.rb` version/sha, website `/download` target,
and live appcast target. A rollback is not just deleting a bad artifact; it
means restoring and pushing the appcast/cask/download surfaces, redeploying the
website when needed, then rerunning the post-DMG audit and strict live-surface
gate against the restored version.

## Release Flow

```bash
bash build-deps.sh --force
NOTARY_PROFILE=<profile-name> bash build-beta.sh <beta-token> <user-name>
```

Before you publish a user-facing release note, sanity-check the release state:

- compare `Info.plist` `CFBundleShortVersionString` against the latest GitHub release tag
- confirm the build output prints the expected Sentry release and dist
- review the merged PRs since that latest published release so the note reflects shipped changes, not just local branch state
- if `docs/appcast.xml` still points at the older release, say plainly that existing installs will not discover the new build in-app yet
- verify live release truth separately from source truth: live `/appcast.xml`, live `/download`, live `/download/latest.dmg`, crawler-facing release text, and Cloudflare Pages deployment status should all match the intended release before launch or outreach claims
- run `python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json` before publishing release notes or PR text that summarize QA, support, or observability work
- if you want a clean starting point, use `docs/release-notes-template.md`

Use the strict release-health gate when validating release surfaces:

```bash
python3 scripts/release/post-dmg-release-audit.py --version <version> --artifact build/Transcripted-<version>.dmg
python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces
python3 scripts/ops/nightly-security-check.py --strict --require-sentry-release-health
```

The live surface gate compares the committed appcast against the live appcast,
download routes, GitHub release asset size/digest, and Homebrew cask checksum.

After a packaging build, add local dSYM verification:

```bash
python3 scripts/ops/nightly-security-check.py --strict --require-release-debug-files
```

The packaged-app smoke above also checks the same local app/dSYM UUID pair when
`build/Transcripted.app.dSYM` is present. Use `--require-dsym` when missing
symbols should fail the package smoke instead of marking the release yellow.

If you expect existing installs of Transcripted to discover the new version
inside the app, do not stop after the DMG is built. You must also complete the
Sparkle steps in `docs/sparkle-updates.md`.

After the release is published on GitHub, register the matching Sentry release
so Sentry sees a real finalized release before production events arrive. This
also requires and uploads `build/Transcripted.app.dSYM` by default:

```bash
SENTRY_REQUIRE_DEBUG_FILES=1 bash scripts/release/register-sentry-release.sh <version>
```

For a no-upload prep pass before Justin approves the release cut, use the
read-only dry run instead:

```bash
python3 scripts/release/sentry-release-dry-run.py --version <version>
```

That checker validates the intended Sentry release name, local tooling/auth
surface, release-tag commit association readiness, and the local app/dSYM UUID
pair when the build artifacts exist. It does not create or finalize a Sentry
release, set commits, or upload debug files. Add `--check-sentry-release` only
when you want a read-only `sentry-cli releases info` probe, add
`--require-sentry-release` when the remote release must already exist, and use
`--require-debug-files` after packaging when a missing app/dSYM pair should block
the handoff.

Prefer this post-publish registration path. `build-beta.sh` also supports
`REGISTER_SENTRY_RELEASE=1`, but use that only when the tag, app binary, dSYM,
and release artifact are already final and match the GitHub release you intend
to ship.

The script creates/finalizes `transcripted@<version>` for the `r3dbars/apple-macos`
Sentry project, associates commits when Sentry can resolve the repo, and uploads
debug symbol files through `sentry-cli debug-files upload --no-sources`. Before
upload, it verifies the dSYM UUID matches the built app binary at
`build/Transcripted.app/Contents/MacOS/Transcripted`.

If you are registering a reused artifact, set both paths so they point at the
matching pair from that exact release build:

```bash
SENTRY_DEBUG_FILES_PATH=/path/to/Transcripted.app.dSYM \
SENTRY_APP_BINARY_PATH=/path/to/Transcripted.app/Contents/MacOS/Transcripted \
bash scripts/release/register-sentry-release.sh <version>
```

If symbols are intentionally unavailable for a one-off local registration, set
`SENTRY_UPLOAD_DEBUG_FILES=0` and call the release yellow; shipped releases
should not skip this because crash reports may lose app frames.

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

After the dry-run package exists, run the packaged app smoke before any upload,
appcast, cask, or Sentry release work:

```bash
swift run --package-path Tools/TranscriptedQA transcripted-qa packaged-app-smoke --app build/Transcripted.app --dsym build/Transcripted.app.dSYM --run-ui-smoke
```

Or use the QA bench wrapper:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode packaged
```

That smoke checks local app/package evidence only: app version/config parity,
Sparkle feed URL/public key/update flags, signing, bundled helper/framework
presence, dSYM UUID match, versioned DMG readability, optional menu bar UI, and
local log privacy patterns. It does not notarize, publish, register Sentry
releases, update `docs/appcast.xml`, or update the Homebrew cask. If the UI
portion is blocked by Accessibility/TCC, the result is incomplete/yellow rather
than green.

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
