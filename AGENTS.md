# Transcripted Agent Guide

## Current repo truth

- `main` is the current Transcripted product, derived from the earlier Draft codebase.
- The current app on `main` supports **dictation** and **meetings**.
- Meeting capture includes local mic + system audio, imported-audio transcription, optional local-speaker review, and agent-readable Markdown output.
- The older draft / ghostwriting flow is not active on `main`. `DictationSessionController` keeps compatibility stubs for removed draft-mode entry points.
- `Sources/TranscriptedCore/` is an in-repo library consumed through `Sources/Meeting/`. Keep it as a library boundary.
- `Sources/Speech/` owns the app-owned local STT path. Meetings reuse that path through `Sources/Meeting/MeetingSTTAdapter.swift`.
- `Sources/Reliability/` owns wake / sleep recovery for hotkeys and active capture flows.
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
5. `CLAUDE.md`
6. `Sources/CLAUDE.md`
7. the nearest local `CLAUDE.md` for the area you are changing
8. `Sources/Dictation/CLAUDE.md` when touching dictation persistence
9. `Sources/Meeting/CLAUDE.md` when touching meeting capture or meeting UI
10. `Sources/TranscriptedCore/CLAUDE.md` when touching the shared library
11. `Sources/Speech/CLAUDE.md` when touching dictation STT, audio recovery, or device handling
12. `Sources/Support/CLAUDE.md` when touching shared preferences, permissions, paths, or Claude Desktop install flow
13. `Sources/UI/CLAUDE.md` when touching overlay, menubar, onboarding, settings, or agent-connect UI
14. `Sources/Capture/CLAUDE.md` when touching hotkeys or physical dictation trigger routing
15. `Tests/README.md`
16. `docs/storage-paths.md`
17. `Sources/Reliability/CLAUDE.md` when touching wake / sleep recovery or hotkey recovery
18. `Sources/Observability/CLAUDE.md` when touching crash reporting, event forwarding, anonymous analytics, or app updates
19. `docs/release-packaging.md` when touching packaging, signing, notarization, or user-facing releases
20. `docs/sparkle-updates.md` when touching app updates or cutting a release users should receive in-app
21. `Tools/*/CLAUDE.md` when touching standalone CLI, MCP, or QA tools

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

## Observability, Sentry, and Analytics

Treat Sentry and PostHog as explicitly bounded integrations, not generic log
sinks.

Rules:

1. Read `Sources/Observability/CLAUDE.md` before changing crash reporting, event forwarding, anonymous analytics, file logging, or update plumbing.
2. Runtime Sentry config lives in `Info.plist` under:
   - `TranscriptedSentryDSN`
   - `TranscriptedSentryEnvironment`
   - optional: `TranscriptedSentryAppHangTrackingEnabled`
3. Local overrides for testing can come from process environment:
   - `SENTRY_DSN`
   - `SENTRY_ENVIRONMENT`
   - `SENTRY_ENABLE_APP_HANG_TRACKING`
4. Runtime PostHog config lives in `Info.plist` under:
   - `TranscriptedPostHogAPIKey`
   - `TranscriptedPostHogHost`
5. Local overrides for analytics testing can come from process environment:
   - `POSTHOG_API_KEY`
   - `POSTHOG_HOST`
6. The user-facing crash reporting and anonymous analytics preferences are stored by `CrashReportingPreferences` and `AnalyticsPreferences`. Both default to enabled until the user changes them in Settings or onboarding.
7. `EventReporter` does not forward every `.error` event to Sentry. Off-device forwarding is gated by the explicit allowlist in `Sources/Observability/SentryEventPolicy.swift`.
8. PostHog events and properties are gated by `Sources/Observability/AnalyticsEventPolicy.swift`.
9. Keep off-device payloads privacy-safe. Do not send raw transcript text, audio references, meeting titles, speaker names, emails, tokens, or absolute file paths. If payload shape changes, update the relevant sanitizer and tests in the same change:
   - `Sources/Observability/SentryPayloadSanitizer.swift`
   - `Sources/Observability/AnalyticsPayloadSanitizer.swift`
10. Test and smoke runs should keep local production logs clean with `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` when invoking binaries directly.
11. Preserve the user verification path when touching the integrations:
   - Settings should still expose the crash-reporting toggle
   - Settings should still expose the anonymous analytics toggle
   - Settings should still expose the `Send Test Sentry Event` action when Sentry is configured
12. Preferred verification for observability-related changes:
   - `bash build.sh`
   - `bash run-tests.sh`
   - confirm Sentry, analytics, and observability preference tests still pass through `run-tests.sh`

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
