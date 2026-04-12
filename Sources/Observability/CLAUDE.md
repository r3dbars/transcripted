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

## Verification

After changing observability code:

```bash
bash build.sh
bash run-tests.sh
```

Useful files while testing:

- `~/Library/Application Support/Transcripted/logs/debug.log`
- `~/Library/Application Support/Transcripted/logs/events.jsonl`
