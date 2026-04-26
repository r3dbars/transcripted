# Observability Directory

## What This Does

This directory contains the app's logging, diagnostics, crash reporting,
anonymous analytics, and Sparkle update plumbing.

## Key Files

- `AppLogger.swift` — developer-facing debug log writer
- `EventReporter.swift` — structured event capture
- `JSONLWriter.swift` — shared append-only JSONL writer
- `DiagnosticsTrail.swift` — lightweight high-signal diagnostics helper
- `CrashReporter.swift` — crash reporting setup
- `CrashReportingPreferences.swift` — Settings-backed crash reporting preference
- `AnalyticsReporter.swift` — privacy-first anonymous usage analytics to PostHog
- `AnalyticsPreferences.swift` — Settings-backed anonymous analytics preference
- `AnalyticsEventPolicy.swift` — explicit allowlist of PostHog events + properties
- `AnalyticsPayloadSanitizer.swift` — strips sensitive analytics properties before send
- `SentryEventPolicy.swift` — explicit allowlist of non-fatal events permitted to reach Sentry
- `SentryPayloadSanitizer.swift` — strips obvious sensitive values before Sentry sends
- `SentryRuntimeConfiguration.swift` — resolves Sentry DSN, environment, release, and dist from `Info.plist` or process environment
- `SparkleUpdaterController.swift` — live Sparkle update controller used by the menubar app

## Current Notes

- Treat this directory as shared infrastructure for the current dictation + meetings app
- Sparkle is the live in-app update path on `main`; the older beta DMG self-update flow is no longer part of the app target
- Do not assume older draft/style/analysis event flows are still active just because they appear in historical docs or event logs
- `build.sh` and beta behavior can affect logs, signing, and permissions during local testing
- `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` disables `app.jsonl` writes for test and smoke runs so local production logs stay clean
- Sentry runtime config is resolved by `SentryRuntimeConfiguration` from `Info.plist` (`TranscriptedSentryDSN`, `TranscriptedSentryEnvironment`) or process environment (`SENTRY_DSN`, `SENTRY_ENVIRONMENT`), and crash reports must stay scrubbed of transcript/audio/title/path data
- `SentryRuntimeConfiguration` rejects non-HTTPS DSNs, so insecure local overrides fail closed instead of downgrading crash transport
- PostHog config is read from `Info.plist` (`TranscriptedPostHogAPIKey`, `TranscriptedPostHogHost`) or process environment (`POSTHOG_API_KEY`, `POSTHOG_HOST`), and anonymous analytics must stay event-allowlisted and bucketed rather than sending raw payloads
- Non-fatal error forwarding to Sentry is allowlisted. New `.error` events should not automatically assume they are safe to send off-device.

## Verification

After changing observability code:

```bash
bash build.sh
bash run-tests.sh
```

Useful files while testing:

- `~/Library/Application Support/Transcripted/logs/debug.log`
- `~/Library/Application Support/Transcripted/logs/events.jsonl`
- `~/Library/Application Support/Transcripted/logs/app.jsonl` for embedded `TranscriptedCore` JSONL logs and QA validation
