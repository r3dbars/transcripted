# Observability

## What this directory owns

`Sources/Observability/` contains the app’s logging, diagnostics, crash
reporting, and beta-only shipping / update plumbing.

## Important files

- `AppLogger.swift` — app-facing debug log writer (`debug.log`)
- `EventReporter.swift` — structured event capture (`events.jsonl`)
- `JSONLWriter.swift` — shared append-only JSONL helper
- `DiagnosticsTrail.swift` — high-signal diagnostics recording
- `CrashReporter.swift` — crash reporting setup
- `EventTracker.swift` — lightweight analytics hook
- `BetaTelemetry.swift` — beta-only event / log shipping
- `UpdateManager.swift` — beta updater flow

## Current paths

- debug log: `~/Library/Application Support/Transcripted/logs/debug.log`
- structured events: `~/Library/Application Support/Transcripted/logs/events.jsonl`
- embedded core JSONL log: `~/Library/Application Support/Transcripted/logs/app.jsonl`

## Notes

- treat this directory as shared infrastructure for the current dictation + meetings app
- do not trust older draft-era docs or logs as proof that those product flows are still live
- `BETA_BUILD` changes behavior here more than anywhere else in the app target

## Verify

```bash
bash build.sh
bash run-tests.sh
```

Useful files while testing:

- `~/Library/Application Support/Transcripted/logs/debug.log`
- `~/Library/Application Support/Transcripted/logs/events.jsonl`
- `~/Library/Application Support/Transcripted/logs/app.jsonl`
