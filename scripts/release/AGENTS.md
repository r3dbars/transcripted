# scripts/release

Packaging helpers for shipping a build: version bump, Sparkle appcast, Homebrew cask, Sentry release, and post-release audits. Release flow and policy: `docs/release-packaging.md`, `docs/sparkle-updates.md`, `docs/release-guardrails.md`. Root rules still apply.

## Safety

- **Never publish, tag, notarize, upload the appcast, or touch the cask without the owner saying so.** A DMG alone is not a release. The release, its `appcast.xml` asset (the Sparkle feed), the download redirect, and `Casks/transcripted.rb` must agree. `docs/appcast.xml` is the legacy feed; after `freeze-legacy-appcast.py` ran it never changes again.
- **Notarized builds come from `.github/workflows/release-candidate.yml`**, not this Mac. There is no local notary profile; a local `build-beta.sh` makes un-notarized test DMGs only.
- **Never print or write secrets** (`SPARKLE_PRIVATE_KEY`, `SENTRY_AUTH_TOKEN`, signing identities). Credential setup: `docs/ops-credentials.md`.
- Dry-run and audit scripts are read-only. Keep them that way; they are how you prove a release without changing it.

## What each script does

- `bump-release-version.py`: edits source version metadata only. It never touches release surfaces.
- `generate-sparkle-appcast.sh <updates-dir>`: wraps Sparkle's `generate_appcast` (override with `SPARKLE_APPCAST_TOOL`) and merges the new item into the feed copy named by `REPO_APPCAST_PATH` (required; never `docs/appcast.xml`). Release Candidate runs it and retries without deltas if delta generation fails.
- `sign-appcast.sh <appcast.xml>`: embeds the EdDSA feed signature with `sign_update` and reads it back. Always the last edit to the feed.
- `fetch-sparkle-tools.sh`: downloads the pinned, sha256-checked Sparkle tools. The signing job uses it instead of `build-deps.sh`.
- `sign-release.sh --app <app> --version <x.y.z>`: signs an unsigned app, builds and signs the DMG. Needs a Developer ID identity; never ad-hoc. Shares `scripts/entrypoints/lib/release-package.sh` with `build-beta.sh`.
- `freeze-legacy-appcast.py`: run once, for the first release on the release-asset feed; writes the final legacy entry and `config/release/legacy-appcast-freeze.*`. `--dry-run` first.
- `mark-appcast-critical.py`: marks the newest appcast item critical for old builds (1.1.22 to 1.1.62) whose reminder window can't install. Sparkle only reads the newest item, so it always marks that one. Don't remove the marker without checking those builds.
- `verify-sparkle-release.sh <version>`: checks the live feed (`releases/latest/download/appcast.xml`, or `VERIFY_APPCAST_FILE`) against the published GitHub release (URL, minimum macOS from `Info.plist`, arm64, feed signature present). Needs `gh`.
- `post-dmg-release-audit.py`: read-only audit across the release surfaces after the DMG exists.
- `test-staged-sparkle-update.py`: real Sparkle upgrade proof; hosted CI only (`docs/staged-sparkle-update-test.md`).
- `update-cask.sh <version>`: downloads the published `Transcripted-<version>.dmg`, hashes it, rewrites `version` and `sha256` in `Casks/transcripted.rb`. Run it only after the release is public; then commit the cask.
- `register-sentry-release.sh`, `sentry-release-metadata.py`, `sentry-release-dry-run.py`: create and finalize the Sentry release for the `Info.plist` version and upload the matching dSYM. Defaults `SENTRY_ORG=r3dbars`, `SENTRY_PROJECT=apple-macos`.
- `provision-release-models.sh <models-dir>`: places the Nemotron 3 diarizer and ReDimNet2 b4 models exactly as `build-beta.sh` expects to bundle them. Release builds fail or ship without models if this drifts.
- `generate-dmg-background.swift`, `assets/dmg-background.png`: DMG window art.

## Before you change one

- Run `python3 scripts/dev/agent-context.py scripts/release/<file>` for the proof checks.
- Several scripts have an installed-app or live-feed side. A passing unit run is not proof; say what you did not verify (clean-machine install, live feed).
- `Info.plist` `SUFeedURL` and `SUPublicEDKey` must keep matching the real feed.
- The Release Candidate workflow's signing job (the only one with secrets) may run only the scripts listed above plus notarytool; `Tests/CIWorkflowContractTests.swift` fails if it runs a build script. Keep it that way: anything that compiles belongs in the unsigned build job.
