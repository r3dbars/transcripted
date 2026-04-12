# Scripts

This repo keeps the live day-to-day command surface intentionally small.

## Active root entry points

- `build-deps.sh` — build and cache the shared dependency bundle
- `build.sh` — local app build
- `build-beta.sh` — signed beta/distribution build
- `run-tests.sh` — curated fast test runner
- `run-integration-smoke.sh` — app/core smoke verification

## Active helper scripts

- `scripts/release/generate-sparkle-appcast.sh` — generate a Sparkle appcast from an updates folder and copy it into `docs/appcast.xml`

## Legacy scripts

These are kept for historical or one-off reference, not as the primary workflow:

- `scripts/legacy/build-fluidaudio.sh` — older FluidAudio-only dependency build path, superseded by `build-deps.sh`
- `scripts/legacy/package-dmg.sh` — simple unsigned DMG packager, superseded by `build-beta.sh` for real distribution

## Rule of thumb

If a command is not listed above, do not assume it is part of the current app build or release contract.
