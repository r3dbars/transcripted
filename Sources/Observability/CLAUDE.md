# Observability

## What This Folder Owns

This folder holds the current diagnostics and beta-operations layer for Transcripted.

Active files:

- `EventReporter.swift` — structured JSONL event capture
- `DiagnosticsTrail.swift` — convenience bridge that logs and emits structured events together
- `AppLogger.swift` — rolling local debug log at `~/transcripted-debug.log`
- `JSONLWriter.swift` — append-only JSONL helper
- `CrashReporter.swift` — optional raw Sentry HTTP reporting
- `BetaTelemetry.swift` — beta-only event/log shipping
- `UpdateManager.swift` — beta update download/install flow
- `EventTracker.swift` — lightweight app event counters/hooks
- `AppLogger.swift` and `CrashReporter.swift` complement, not replace, `EventReporter`

## Primary Output Paths

- `~/Library/Application Support/{Draft|Transcripted}/events.jsonl`
- `~/transcripted-debug.log`
- beta logs and update artifacts under the normal app-support/update paths

`EventReporter` uses `FileManager.default.transcriptedAppSupportDir`, so legacy Draft installs still resolve to the old folder when it exists.

## Recommended Entry Point

For feature code, prefer `DiagnosticsTrail.record(...)` when you want both:

- a readable debug-log line
- a structured event in `events.jsonl`

Use `EventReporter.shared.capture(...)` directly when only structured telemetry is needed.

## Current Architecture

- `EventReporter` is the structured event sink.
- `DraftAppState` injects live engine state summaries for context enrichment.
- `DiagnosticsTrail` keeps feature call sites compact.
- `BetaTelemetry` periodically ships only incremental log/event bytes in beta builds.
- `CrashReporter` is opt-in and disabled unless a DSN is configured.

## What Changed From Older Docs

- event storage is Transcripted-first, not Draft-only
- this folder is no longer tied to feedback/prompt-analysis systems
- the debug log path is `~/transcripted-debug.log`
- the active engine set is dictation, meetings, capture, speech, wake recovery, and beta/update plumbing

## Verification

```bash
bash build.sh
bash run-tests.sh
```

Useful local inspection:

```bash
tail -f ~/transcripted-debug.log
tail -f ~/Library/Application\\ Support/Transcripted/events.jsonl
```
