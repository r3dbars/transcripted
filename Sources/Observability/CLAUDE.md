# Observability Directory

## What This Does

This directory contains the app's logging, diagnostics, crash reporting,
optional beta shipping, and update plumbing.

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
- `UpdateManager.swift` — beta updater flow

## Current Notes

- Treat this directory as shared infrastructure for the current dictation +
  meetings app
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

- `~/draft-debug.log`
- `~/Library/Application Support/Draft/events.jsonl`
