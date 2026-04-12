# Transcripted Agent Guide

## Current repo truth

- `main` is the current Transcripted product, derived from the earlier Draft codebase.
- The current app on `main` supports **dictation** and **meetings**.
- The older draft / ghostwriting flow is not active on `main`. `DictationSessionController` keeps compatibility stubs for removed draft-mode entry points.
- `Sources/TranscriptedCore/` is an in-repo library consumed through `Sources/Meeting/`. Keep it as a library boundary.
- `build.sh` builds the app target. The root `Package.swift` exists for `TranscriptedCore` package tests and smoke coverage, not as the main app build.

## Read this first

1. `README.md`
2. `AGENTS.md`
3. `docs/agent-onboarding.md`
4. `Sources/CLAUDE.md`
5. `Sources/Dictation/CLAUDE.md` when touching dictation persistence
6. `Sources/Meeting/CLAUDE.md` when touching meeting capture or meeting UI
7. `Sources/TranscriptedCore/CLAUDE.md` when touching the shared library
8. `Tests/README.md`
9. `docs/storage-paths.md`
10. `docs/release-packaging.md` when touching packaging, signing, notarization, or user-facing releases
11. `docs/sparkle-updates.md` when touching app updates or cutting a release users should receive in-app

## Directory map

- `Sources/` — app shell, hotkeys, speech, dictation UI, meeting bridge, shared app paths
- `Sources/Dictation/` — markdown persistence for completed dictations
- `Sources/Meeting/` — app-side bridge into `TranscriptedCore`
- `Sources/TranscriptedCore/` — reusable meeting transcription library
- `Tests/` — fast custom Swift test runner plus `TranscriptedCore` package tests
- `SmokeTests/` — integration smoke for the bundled core library seam
- `Tools/TranscriptedCLI/` — standalone offline diarization CLI
- `Tools/TranscriptedMCP/` — read-only MCP server for saved meeting artifacts
- `Tools/TranscriptedQA/` — artifact validation CLI
- `archive/backend-beta-worker/` — archived beta proxy / telemetry backend

## Documentation status

The repo has both current docs and historical docs from the earlier drafting-focused codebase.

Current source-of-truth docs:

- `AGENTS.md`
- `CLAUDE.md`
- `docs/agent-onboarding.md`
- `Sources/CLAUDE.md`
- `Sources/Dictation/CLAUDE.md`
- `Sources/Meeting/CLAUDE.md`
- `Sources/TranscriptedCore/CLAUDE.md`
- `Tests/README.md`
- `docs/storage-paths.md`
- `Tools/TranscriptedCLI/CLAUDE.md`

Beta/distribution-only docs:

- `archive/backend-beta-worker/README.md`

Historical or planning-heavy docs:

- `docs/archive/`
- `.claude/skills/transcripted-qa/SKILL.md`

The remaining `Sources/*/CLAUDE.md` files describe either live subsystems or
small retained utility areas. The historical merge/todo docs now live under
`docs/archive/`, and the old placeholder-only source docs were removed.

## Build and test

```bash
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
```

Rules:

1. After changing Swift source, run `bash build.sh` and `bash run-tests.sh`.
2. If you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`.
3. If you touch `Package.swift`, `Sources/TranscriptedCore/`, or the public core seam, also run `swift test`.
4. `build.sh` must not compile `Sources/TranscriptedCore/` directly into the app target.

## Releases and Sparkle

When the task is a user-facing release, package handoff, or update-path change,
agents must treat Sparkle as part of the release contract, not as optional
follow-up work.

Rules:

1. Read `docs/release-packaging.md` and `docs/sparkle-updates.md` before changing release flow.
2. For builds intended for other machines, use `build-beta.sh`, not `build.sh`.
3. A release is not complete just because a DMG exists. For in-app updates to work, the release flow must also:
   - publish the signed archive where users can fetch it
   - update `docs/appcast.xml`
   - push the updated appcast to the branch that backs the live feed
4. If Sparkle metadata was not updated, say explicitly that existing installs will not discover the new release in-app yet.
5. If the release artifact URL, appcast URL, public key, or Sparkle tooling changes, update the docs in the same change.
6. Keep `Info.plist` Sparkle settings aligned with the actual release feed:
   - `SUFeedURL`
   - `SUPublicEDKey`
   - any automatic-check / automatic-download flags
7. Preferred release verification for Sparkle-related changes:
   - `bash build-deps.sh --force` when dependency tooling changes
   - `bash build.sh`
   - `bash run-tests.sh`
   - `SKIP_NOTARIZATION=1 bash build-beta.sh <token> <user-name>` for packaging smoke, or the full notarized path when cutting a real release

## Testing gotchas

- `run-tests.sh` is a custom `swiftc` runner, not XCTest.
- Adding a root `Tests/*Tests.swift` file is not enough by itself; it must be registered in `Tests/FastTests.manifest`.
- `Tests/TranscriptedCoreTests/` is a separate Swift Package target, run via `swift test` rather than `run-tests.sh`.

## Storage

Current persisted data on `main` uses Draft-named compatibility roots:

- app support root: `~/Library/Application Support/Draft/`
- dictations: `~/Library/Application Support/Draft/dictations/`
- meetings: `~/Library/Application Support/Draft/meetings/`

See `docs/storage-paths.md` for the full map, including `TranscriptedCore` standalone defaults.
