# Observability

## What This Contains

Logging, telemetry, diagnostics, crash reporting, and update wiring for the current Draft-first app.

Current Swift files: **8**

| File | Purpose |
|---|---|
| `AppLogger.swift` | Central application logging entry point |
| `BetaTelemetry.swift` | Beta-specific telemetry helpers |
| `CrashReporter.swift` | Crash-report capture / submission hooks |
| `DiagnosticsTrail.swift` | Diagnostics trail / breadcrumb-style runtime tracing |
| `EventReporter.swift` | Event-level observability surface |
| `EventTracker.swift` | Event tracking coordination helpers |
| `JSONLWriter.swift` | JSONL persistence for structured logging output |
| `UpdateManager.swift` | Update-check and update-flow coordination |

## Notes
- This folder is the current home for operational instrumentation on `main`.
- Keep event tracking and on-disk logging aligned with `EventReporter.swift`, `EventTracker.swift`, and `JSONLWriter.swift`.
