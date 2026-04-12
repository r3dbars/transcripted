# Observability Directory

## What This Does

This directory contains the app's logging, diagnostics, crash reporting,
optional beta shipping, and Sparkle update plumbing.

## Key Files

- `AppLogger.swift` — developer-facing debug log writer
- `EventReporter.swift` — structured event capture
- `JSONLWriter.swift` — shared append-only JSONL writer
- `DiagnosticsTrail.swift` — lightweight high-signal diagnostics helper
- `CrashReporter.swift` — crash reporting setup
- `CrashReportingPreferences.swift` — Settings-backed crash reporting preference
- `SentryEventPolicy.swift` — explicit allowlist of non-fatal events permitted to reach Sentry
- `SentryPayloadSanitizer.swift` — strips obvious sensitive values before Sentry sends
- `EventTracker.swift` — lightweight analytics hook
- `BetaTelemetry.swift` — beta-only log/event shipping
- `SparkleUpdaterController.swift` — live Sparkle update controller used by the menubar app

## Current Notes

- Treat this directory as shared infrastructure for the current dictation +
  meetings app
- Sparkle is the live in-app update path on `main`; the older beta DMG
  self-update flow is no longer part of the app target
- Do not assume older draft/style/analysis event flows are still active just
  because they appear in historical docs or event logs
- `build.sh` and beta behavior can affect logs, signing, and permissions during
  local testing
- Sentry DSN/config is read from `Info.plist` (`TranscriptedSentryDSN`) or
  process environment for local testing, and crash reports must stay scrubbed of
  transcript/audio/title/path data
- Non-fatal error forwarding to Sentry is allowlisted. New `.error` events should
  not automatically assume they are safe to send off-device.

## Verification

After changing observability code:

```bash
bash build.sh
bash run-tests.sh
```

Useful files while testing:

- `~/Library/Application Support/Transcripted/logs/debug.log`
- `~/Library/Application Support/Transcripted/logs/events.jsonl`
