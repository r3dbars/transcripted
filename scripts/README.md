# Scripts

This repo keeps the live day-to-day command surface intentionally small.

## Active root entry points

These stay at the repo root as thin wrappers so the public command surface stays
stable and the docs can keep pointing at the same commands:

- `build-deps.sh` — build and cache the shared dependency bundle
- `build.sh` — local app build
- `build-beta.sh` — signed beta/distribution build
- `run-tests.sh` — curated fast test runner
- `run-integration-smoke.sh` — app/core smoke verification

## Entrypoint implementations

The actual script bodies live under `scripts/entrypoints/` so the repo root does
not have to carry the full operational logic:

- `scripts/entrypoints/build-deps.sh`
- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `scripts/entrypoints/run-tests.sh`
- `scripts/entrypoints/run-integration-smoke.sh`

## Active helper scripts

- `scripts/release/generate-sparkle-appcast.sh` — generate a Sparkle appcast from an updates folder and copy it into `docs/appcast.xml`
- `scripts/release/update-cask.sh` — bump `Casks/transcripted.rb` to point at a newly published GitHub release
- `scripts/dev/onboarding.sh` — inspect, reset, or force the first-run onboarding state while iterating on copy and layout

## Rule of thumb

If a command is not listed above, do not assume it is part of the current app build or release contract.
