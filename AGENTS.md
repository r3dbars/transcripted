# Transcripted Agent Guide

## Current repo truth

- `main` is the current Transcripted product, derived from the earlier Draft codebase.
- The current app on `main` supports **dictation** and **meetings**.
- The older draft / ghostwriting flow is not active on `main`. `DictationSessionController` keeps compatibility stubs for removed draft-mode entry points.
- `Sources/TranscriptedCore/` is an in-repo library consumed through `Sources/Meeting/`. Keep it as a library boundary.
- `build.sh` builds the app target. The root `Package.swift` exists for `TranscriptedCore` package tests and smoke coverage, not as the main app build.

## Response voice

- Write like a real person texting a friend, not like a presentation.
- Keep things simple, direct, and useful.
- Use short, punchy sentences most of the time.
- Vary the rhythm. Short punch. Then a little more detail when it helps.
- Use casual connectors when they fit: "so", "anyway", "plus", "also".
- Be honest when something is weird, unclear, or unknown.
- Use light natural hesitation sparingly: "I think maybe", "probably", "not sure but".
- Avoid marketing speak, corporate buzzwords, stiff transitions, and obvious AI phrases like "dive into", "delve into", or "let's explore".
- Avoid piling on adjectives.
- Keep capitalization normal.
- Be relaxed, but still clear. Real, not sloppy.

## Read this first

1. `README.md`
2. `AGENTS.md`
3. `docs/repo-layout.md`
4. `docs/agent-onboarding.md`
5. `Sources/CLAUDE.md`
6. `Sources/Dictation/CLAUDE.md` when touching dictation persistence
7. `Sources/Meeting/CLAUDE.md` when touching meeting capture or meeting UI
8. `Sources/TranscriptedCore/CLAUDE.md` when touching the shared library
9. `Tests/README.md`
10. `docs/storage-paths.md`
11. `Sources/Reliability/CLAUDE.md` when touching wake / sleep recovery or hotkey recovery
12. `Sources/Observability/CLAUDE.md` when touching crash reporting, event forwarding, anonymous analytics, or app updates
13. `docs/release-packaging.md` when touching packaging, signing, notarization, or user-facing releases
14. `docs/sparkle-updates.md` when touching app updates or cutting a release users should receive in-app

Use `docs/repo-layout.md` as the canonical directory map and doc hierarchy.

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

## Releases, Sparkle, and Homebrew

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
4. If the release should also be installable or upgradeable through Homebrew, the release flow must also:
   - run `bash scripts/release/update-cask.sh <version>` after the GitHub release is published
   - commit the updated `Casks/transcripted.rb`
   - push that cask update so `brew install` and `brew upgrade` see the new version
5. If Sparkle metadata was not updated, say explicitly that existing installs will not discover the new release in-app yet.
6. If the Homebrew cask was not updated, say explicitly that `brew install` / `brew upgrade` will still point at the older release.
7. If the release artifact URL, appcast URL, public key, Sparkle tooling, or Homebrew install path changes, update the docs in the same change.
8. Keep `Info.plist` Sparkle settings aligned with the actual release feed:
   - `SUFeedURL`
   - `SUPublicEDKey`
   - any automatic-check / automatic-download flags
9. Preferred release verification for release-path changes:
   - `bash build-deps.sh --force` when dependency tooling changes
   - `bash build.sh`
   - `bash run-tests.sh`
   - `SKIP_NOTARIZATION=1 bash build-beta.sh <token> <user-name>` for packaging smoke, or the full notarized path when cutting a real release

## Observability and Sentry

Treat Sentry as an explicitly bounded integration, not a generic log sink.

Rules:

1. Read `Sources/Observability/CLAUDE.md` before changing crash reporting, event forwarding, or update plumbing.
2. Runtime Sentry config lives in `Info.plist` under:
   - `TranscriptedSentryDSN`
   - `TranscriptedSentryEnvironment`
3. Local overrides for testing can come from process environment:
   - `SENTRY_DSN`
   - `SENTRY_ENVIRONMENT`
4. The user-facing crash reporting preference is stored by `CrashReportingPreferences` and defaults to enabled until the user changes it in Settings.
5. `EventReporter` does not forward every `.error` event to Sentry. Off-device forwarding is gated by the explicit allowlist in `Sources/Observability/SentryEventPolicy.swift`.
6. Keep Sentry payloads privacy-safe. Do not send raw transcript text, audio references, meeting titles, speaker names, emails, tokens, or absolute file paths. If payload shape changes, update `SentryPayloadSanitizer.swift` and its tests in the same change.
7. Preserve the user verification path when touching the integration:
   - Settings should still expose the crash-reporting toggle
   - Settings should still expose the `Send Test Sentry Event` action when Sentry is configured
8. Preferred verification for Sentry-related changes:
   - `bash build.sh`
   - `bash run-tests.sh`
   - confirm `Tests/SentryEventPolicyTests.swift` and `Tests/SentryPayloadSanitizerTests.swift` still pass through `run-tests.sh`

## Testing gotchas

- `run-tests.sh` is a custom `swiftc` runner, not XCTest.
- Adding a root `Tests/*Tests.swift` file is not enough by itself; it must be registered in `Tests/FastTests.manifest`.
- `Tests/TranscriptedCoreTests/` is a separate Swift Package target, run via `swift test` rather than `run-tests.sh`.

## Storage

Current app builds on `main` default to Transcripted-named Application Support paths:

- app support root: `~/Library/Application Support/Transcripted/`
- capture library: `~/Library/Application Support/Transcripted/captures/`
- meetings: `~/Library/Application Support/Transcripted/captures/meetings/`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations/`

The user can relocate the capture library in Settings via
`transcriptSaveLocation`. App-owned state, cache, logs, and temp files stay
under `~/Library/Application Support/Transcripted/`.

Historic `Draft` paths still exist for migration and standalone-tool fallback.

See `docs/storage-paths.md` for the canonical storage map, including legacy fallbacks and `TranscriptedCore` standalone defaults.
