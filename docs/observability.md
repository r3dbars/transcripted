# Observability sink map

Transcripted writes diagnostics to disk through five distinct sinks. They
overlap in name and in shape (JSONL-ish, size- or count-bounded, owner-only
permissions) but serve different audiences and have different retention
policies. This page is the map. For the privacy/redaction contract (what may
never reach Sentry/PostHog), see `docs/privacy-first-observability.md`.

| Sink | Lives in | Writes to | Rotation |
| --- | --- | --- | --- |
| `AppLogger` | `Sources/TranscriptedCore/Logging/AppLogger.swift` | `~/Library/Application Support/Transcripted/logs/app.jsonl` (via `FileLogger`) + `os.Logger`/Console.app | Line-count gated: trims to 1500 lines once past 2000, checked every 100 writes |
| `AppLogSink` | `Sources/Observability/AppLogSink.swift` | `~/Library/Application Support/Transcripted/logs/debug.log` + in-app debug panel (`entries`) | Byte-size gated: trims to 1000 lines once past 500 KB, checked once at session start |
| `FileLogger` | `Sources/TranscriptedCore/Logging/FileLogger.swift` | `app.jsonl` (this is `AppLogger`'s file backend, not a separate log) | Same as `AppLogger` above — it's the same file |
| `EventReporter` | `Sources/Observability/EventReporter.swift` | `~/Library/Application Support/Transcripted/logs/events.jsonl` + optional Sentry forwarding (errors only, allowlisted) | Rename-based: `ObservabilityLogRotation` renames the active file to `events.jsonl.1` once past the shared JSONL threshold (`TranscriptedConstants.jsonlLogRotationThreshold`) |
| `ReliabilityPacketRecorder` | `Sources/Observability/ReliabilityPacketRecorder.swift` | `~/Library/Application Support/Transcripted/logs/reliability.jsonl` | Same rename-based `ObservabilityLogRotation` strategy as `EventReporter`, same threshold |

## Why there are two `AppLogger`-shaped types

`TranscriptedCore.AppLogger` and (the former) `Observability.AppLogger` were
two unrelated classes that happened to share a name, because they were built
independently for different audiences:

- **`AppLogger`** (`TranscriptedCore`) is the general-purpose, subsystem-scoped
  logger used throughout the engine and pipeline code (`AppLogger.transcription.info(...)`,
  `AppLogger.pipeline.error(...)`, etc). It fans out to `os.Logger` (so it shows
  up live in Console.app) and to `FileLogger`'s `app.jsonl` (so an agent or a
  support engineer can grep structured records after the fact).
- **`AppLogSink`** (`Sources/Observability/`, renamed from `AppLogger` in the
  2026-07 observability cleanup) is a `@MainActor` `ObservableObject` that
  backs the in-app debug panel and feeds recent log lines into user-submitted
  feedback emails (`TranscriptedSupportActions.feedbackEmailURL`). It writes a
  plain-text `debug.log`, not JSONL, and it is UI-observable — engine code
  should prefer `TranscriptedCore.AppLogger`; `AppLogSink` is for
  user-visible/user-submittable diagnostics.

Because both types lived in the same app target (no module boundary between
`Sources/Observability/` and `Sources/TranscriptedCore/`'s consumers), any
unqualified `AppLogger` reference in app-target code was ambiguous — Swift
resolves the same-target/local declaration first, so call sites that actually
wanted `TranscriptedCore.AppLogger` had to spell out the qualifier
(`Sources/Speech/*.swift`, `Sources/Meeting/MeetingModelDownloader.swift`).
The rename removes the collision; those call sites no longer need the
`TranscriptedCore.` prefix.

## Shared rotation code

Two different rotation strategies exist on purpose, not by accident, and both
are now implemented once:

- **Truncate-in-place** (`LogTailTrimmer`, `Sources/TranscriptedCore/Logging/LogTailTrimmer.swift`,
  public): read the file, keep only the newest N lines, atomically rewrite
  the same path, re-chmod to owner-only. Used by `FileLogger` (gated on line
  count, checked periodically during writes) and `AppLogSink` (gated on byte
  size, checked once at session start). The gating decision (when to trim)
  stays with each caller since the two sinks trigger on different signals;
  the mechanical read/keep-tail/rewrite/re-chmod step is the one shared
  implementation both call, replacing what used to be two hand-rolled copies
  of the same logic.
- **Rename-based** (`ObservabilityLogRotation`, `Sources/Observability/ObservabilityLogRotation.swift`):
  rename the active file to `<name>.1` once it exceeds a byte threshold. O(1),
  no read/rewrite of file contents, safe under a concurrent writer holding
  the old descriptor. Used by `EventReporter` and `ReliabilityPacketRecorder`,
  both append-only JSONL logs where a rename-and-keep-one-generation policy is
  a better fit than a truncate-and-rewrite.

Don't merge these two strategies — they were evaluated together during the
2026-07 observability cleanup and kept separate deliberately (truncate-in-place
suits the two line-oriented sinks that already special-case trimming as part of
a size-bounded "recent activity" log; rename-based suits the two append-only
JSONL sinks where a second on-disk generation is acceptable and cheaper to keep
correct under concurrent writers).

## `EventReporter` → `ReliabilityPacketRecorder`

`ReliabilityPacketRecorder` does not have its own capture call sites. Every
reliability packet is derived from an already-captured `ObservabilityEvent`:
`EventReporter.capture(...)` calls `ReliabilityPacketRecorder.record(event:)`
directly as part of handling every event (see
`Sources/Observability/EventReporter.swift`). `ReliabilityPacketRecorder` then
re-shapes a subset of events (via its own coarse, bucketed allowlist — see
`Sources/Observability/CLAUDE.md`) into `reliability.jsonl`, which is what gets
attached to user-submitted support diagnostics. If you're looking for where
reliability packets come from, start at `EventReporter.capture`, not at
`ReliabilityPacketRecorder`.

The recorder is handed the **raw** entry, not the copy that
`LocalObservabilityPayloadSanitizer` produced for `events.jsonl`. That is
deliberate: the recorder positive-allowlists every key and runs every value
through the text redactor itself, which is a stronger contract than the local
sink's substring blanking. Feeding it the blanked copy used to ship the literal
`[redacted-sensitive-value]` for `input_device_class` in support bundles and
erased the `audio_gaps` / `device_switches` / `system_file_present` inputs its
outcome derivation reads, so `recovered` was unreachable in production.

## Practical guidance

- Writing engine/pipeline code in `TranscriptedCore` or elsewhere in the app
  target? Use `AppLogger.<subsystem>.info/warning/error(...)`.
- Need something a user can see in a debug panel or attach to a feedback
  email? Use `AppLogSink` (via `TranscriptedAppState.logger`).
- Recording a structured, privacy-reviewed event for local diagnostics and
  possible Sentry forwarding? Use `EventReporter.shared.capture(...)` (often
  via `DiagnosticsTrail.record(...)`, which does both the `AppLogSink` line
  and the `EventReporter` capture in one call).
- Reliability packets are a derived view — don't write to `reliability.jsonl`
  directly; go through `EventReporter.capture`.
