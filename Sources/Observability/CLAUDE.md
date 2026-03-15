# Observability — EventReporter

## What This Is

`EventReporter` is the centralized event tracking system. Every meaningful error, warning, and operational event across all engines flows through `EventReporter.shared.capture()` and is written to:

```
~/Library/Application Support/Draft/events.jsonl
```

Same directory as `feedback.jsonl` and `prompts.json`. Claude Code reads this file directly.

## Key Files

- `EventReporter.swift` (~164 lines) — Centralized JSONL event writer + Sentry stub (details below)
- `BetaTelemetry.swift` (~159 lines) — `#if BETA_BUILD` gated: batched event shipping to proxy Worker, incremental log/events.jsonl upload (60s timer), synchronous quit-time flush, crash-safe offset tracking, log redaction (paths, tokens)
- `UpdateManager.swift` (~225 lines) — DMG download, mount, staged app replacement with backup/rollback, version comparison via Info.plist, user-facing update prompts, team ID verification (XG6WL66WUQ)
- `AppLogger.swift` (~110 lines) — Debug logger writing to `~/draft-debug.log` with timestamps, actor-isolated file writer, throttled logging, log rotation (>500KB → last 1000 lines), session separators
- `JSONLWriter.swift` (~38 lines) — Shared actor for append-only JSONL file writes. Reuses FileHandle across appends to avoid open/seek/close overhead per write. Used by FeedbackStore and AnalysisEngine.

## File: EventReporter.swift (~164 lines)

Contains three components:

1. **`ObservabilityEvent`** — A `Codable` struct for the JSONL schema (timestamp, level, engine, event, message, context, appVersion, osVersion).
2. **`EventFileWriter`** — A private `actor` that serializes JSONL appends to `events.jsonl`. Creates the file on first write, reuses `FileHandle` for subsequent appends.
3. **`EventReporter`** — `@MainActor` singleton (`EventReporter.shared`). Merges caller context with live engine state (via `engineStateSummary` closure set by `DraftAppState`), then dispatches to `EventFileWriter` and `SentryTransport` via `Task.detached`.

Also includes `EventLevel` enum (`error`, `warning`, `info`) and a no-op `SentryTransport` stub.

## Event Schema

```json
{
  "timestamp": "2026-02-24T10:30:00.123Z",
  "level": "error",
  "engine": "parakeet",
  "event": "prewarm_failed",
  "message": "The operation couldn't be completed",
  "context": {"audio_device": "MacBook Pro Microphone"},
  "appVersion": "dev",
  "osVersion": "Version 15.3 (Build 24D60)"
}
```

### Fields

| Field | Type | Values |
|-------|------|--------|
| `level` | string | `"error"` \| `"warning"` \| `"info"` |
| `engine` | string | `app`, `parakeet`, `draft`, `capture`, `style`, `feedback`, `analysis`, `chat`, `overlay`, `imessage` |
| `event` | string | Machine-readable snake_case identifier (e.g., `prewarm_failed`, `draft_failed`) |
| `message` | string | Human-readable description (often `error.localizedDescription`) |
| `context` | dict? | Optional key-value pairs — error codes, device names, state flags |
| `appVersion` | string | From `CFBundleShortVersionString` or `"dev"` |
| `osVersion` | string | From `ProcessInfo.processInfo.operatingSystemVersionString` |

## Architecture

```
Any engine (MainActor)
  |
  +-> EventReporter.shared.capture(level:engine:event:message:context:)
      |
      +-> Merge caller context with live engine state (engineStateSummary closure)
      |
      +-> Task.detached(priority: .utility)
          |
          +-> EventFileWriter.append()  <- actor, thread-safe JSONL append
          |
          +-> SentryTransport.send()    <- no-op until DSN configured
```

- **EventFileWriter** is an `actor` — serializes all file writes automatically (same pattern as `AppLogFileWriter` in `AppLogger.swift`)
- **Fire-and-forget** — `capture()` never blocks the caller
- **Engine state enrichment** — every event gets live state from `DraftAppState` (parakeet loaded, style examples)

## Adding New Capture Points

1. Find the error/warning site in the target engine
2. Add one line alongside existing `print()` or `logger.log()` calls:

```swift
EventReporter.shared.capture(
    level: .error,
    engine: "parakeet",
    event: "prewarm_failed",
    message: error.localizedDescription,
    context: ["audio_device": deviceName]
)
```

3. Choose the right level:
   - `.error` — something broke, user may be affected (model failure, file write failed)
   - `.warning` — something degraded but has a fallback (vision timeout -> voice-only, empty transcription)
   - `.info` — notable operational event (app launched, refusal detected)

## Reading Events (Claude Code)

```bash
# Recent errors
tail -100 ~/Library/Application\ Support/Draft/events.jsonl | grep '"level":"error"'

# All events from a specific engine
grep '"engine":"parakeet"' ~/Library/Application\ Support/Draft/events.jsonl

# Pretty-print all events
cat ~/Library/Application\ Support/Draft/events.jsonl | python3 -m json.tool --json-lines

# Live tail during testing
tail -f ~/Library/Application\ Support/Draft/events.jsonl
```

## Sentry Integration

Optional. The `SentryTransport` is currently a no-op stub with `TODO(human)`. To enable:

1. Create a Sentry account at sentry.io and create a project
2. Copy the DSN string
3. Set it: `UserDefaults.standard.set("https://KEY@HOST/PROJECT_ID", forKey: "sentryDSN")`
4. Implement DSN parsing and HTTP POST in `SentryTransport.send()`

Only `.error` level events are forwarded to Sentry. Warnings and info stay local.

## Event Catalog

46 unique events across 10 engines (55 total capture call sites).

**Note:** The legacy `anthropic` engine events (`api_http_error`, `api_auth_failure`, `api_stream_error`) are no longer active since all inference runs locally via MLX. They are retained in the event definitions for backward compatibility with older `events.jsonl` entries but will not fire in current builds.

| Engine | Event | Level | Trigger |
|--------|-------|-------|---------|
| `app` | `app_launched` | info | DraftAppState.initialize() completes |
| `parakeet` | `prewarm_failed` | error | Audio engine won't start |
| `parakeet` | `mic_not_authorized` | error | Microphone permission denied/revoked |
| `parakeet` | `model_not_loaded` | warning | Recording attempted without model loaded |
| `parakeet` | `model_not_ready` | warning | STTRouter: Parakeet model not loaded when startRecording called |
| `parakeet` | `models_loaded` | info | Parakeet ASR models initialized |
| `parakeet` | `model_init_failed` | error | CoreML model initialization failed |
| `parakeet` | `transcription_empty` | warning | Parakeet returns no text |
| `parakeet` | `transcription_complete` | info | Successful transcription with word count and timing |
| `parakeet` | `transcription_failed` | error | AsrManager.transcribe() throws |
| `parakeet` | `audio_format_failed` | error | AVAudioFormat creation failed |
| `parakeet` | `audio_engine_start_failed` | error | AVAudioEngine.start() throws during recording |
| `parakeet` | `asr_manager_unavailable` | error | ASR manager not available for transcription |
| `parakeet` | `device_change_rewarm_failed` | error | Audio engine re-warm failed after device change |
| `parakeet` | `recording_interrupted` | warning | Audio device changed during recording |
| `draft` | `draft_failed` | error | Local model inference call fails |
| `capture` | `vision_extraction_failed` | error | OCR extraction fails |
| `style` | `style_refinement_failed` | error | Local model refinement call fails |
| `style` | `style_file_write_failed` | error | Can't write style.md |
| `style` | `style_file_read_failed` | warning | Can't read style.md |
| `feedback` | `feedback_encode_failed` | error | JSON encoding fails |
| `feedback` | `feedback_file_open_failed` | error | Can't open feedback.jsonl |
| `feedback` | `feedback_file_create_failed` | error | Can't create feedback.jsonl |
| `analysis` | `analysis_failed` | error | Local model analysis call fails |
| `analysis` | `prompt_write_failed` | error | Can't write updated prompt to prompts.json |
| `analysis` | `suggestion_write_failed` | warning | Can't write suggestion log entry |
| `analysis` | `file_watch_failed` | error | DispatchSource setup fails (can't open feedback.jsonl fd) |
| `chat` | `chat_api_failed` | error | Chat inference call fails |
| `chat` | `tool_parse_failed` | warning | Tool JSON parsing fails (propose_prompt_change input) |
| `overlay` | `stream_draft_failed` | error | Streaming draft throws |
| `overlay` | `draft_empty` | warning | Stream produced no text |
| `overlay` | `polish_failed` | warning | Dictation polish fails |
| `overlay` | `vision_timeout` | warning | Vision exceeded timeout |
| `overlay` | `refusal_detected` | info | Draft contained refusal pattern |
| `overlay` | `no_voice_input` | warning | Empty transcription after recording |
| `app` | `login_item_failed` | warning | SMAppService.register() failed for launch-at-login |
| `capture` | `hotkey_register_failed` | error | RegisterEventHotKey returned non-zero OSStatus |
| `capture` | `hotkey_already_registered` | warning | registerHotkey() called when hotkeys already registered |
| `overlay` | `cgevent_create_failed` | error | CGEvent creation returned nil during paste simulation |
| `chat` | `chat_followup_failed` | error | Follow-up turn after tool use threw an error |
| `imessage` | `imessage_db_open_failed` | error | Can't open chat.db |
| `imessage` | `imessage_query_failed` | error | SQLite query fails |

### Legacy Events (no longer active)

These events were used when the app relied on the Anthropic API. They remain in older `events.jsonl` files but are not emitted in current builds since all inference is local:

| Engine | Event | Level | Original Trigger |
|--------|-------|-------|------------------|
| `anthropic` | `api_http_error` | error | Non-200 HTTP response from Anthropic API |
| `anthropic` | `api_auth_failure` | error | 401 Unauthorized from Anthropic API |
| `anthropic` | `api_stream_error` | error | Streaming connection failure to Anthropic API |
| `draft` | `subscription_expired` | error | OAuth token expired during draft |
| `capture` | `capture_auth_missing` | warning | No auth credential configured |
| `overlay` | `auth_missing` | error | No credential when drafting |

---

## CrashReporter

Lightweight Sentry crash reporting via raw HTTP Store API — no SDK, no dependencies.

**Setup:** Paste Sentry DSN into `sentryDSN` constant at top of `CrashReporter.swift`. Call `CrashReporter.setup()` in `applicationDidFinishLaunching`.

**Usage:**
```swift
// Automatic: NSSetUncaughtExceptionHandler catches ObjC/SwiftUI runtime crashes
// Manual for caught Swift errors:
CrashReporter.shared.capture(error: error, context: "ParakeetEngine.startRecording")
CrashReporter.shared.capture(message: "Model load failed", level: "warning")
```

**Why no SDK:** Sentry's SDK requires SPM or CocoaPods. Draft uses raw swiftc. The Store API is stable and handles everything we need.

## Key Decisions

- **Fire-and-forget** — analytics and crash reports never block the UI thread. Tasks are `.detached`.
- **No batching** — events are written immediately. At our scale, one write per event is fine.
- **Fail silently** — if a file write fails, the event is lost. That's acceptable.
- **5s timeout** — crash reporters use a short timeout so they don't linger on bad connections.
- **Fully local inference** — all AI inference runs on-device via MLX (Qwen3.5-4B-4bit). No external API calls are made for drafting, style refinement, analysis, or chat. The only network activity is optional Sentry crash reporting and beta telemetry.
