# Observability — EventReporter

## What This Is

`EventReporter` is the centralized event tracking system. Every meaningful error, warning, and operational event across all 12 engines flows through `EventReporter.shared.capture()` and is written to:

```
~/Library/Application Support/Draft/events.jsonl
```

Same directory as `feedback.jsonl` and `prompts.json`. Claude Code reads this file directly.

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
| `engine` | string | `parakeet`, `speech`, `anthropic`, `draft`, `capture`, `style`, `feedback`, `analysis`, `chat`, `overlay`, `imessage`, `app` |
| `event` | string | Machine-readable snake_case identifier (e.g., `prewarm_failed`, `api_http_error`) |
| `message` | string | Human-readable description (often `error.localizedDescription`) |
| `context` | dict? | Optional key-value pairs — error codes, device names, state flags |
| `appVersion` | string | From `CFBundleShortVersionString` or `"dev"` |
| `osVersion` | string | From `ProcessInfo.processInfo.operatingSystemVersionString` |

## Architecture

```
Any engine (MainActor)
  │
  └─→ EventReporter.shared.capture(level:engine:event:message:context:)
      │
      ├─→ Merge caller context with live engine state (engineStateSummary closure)
      │
      └─→ Task.detached(priority: .utility)
          │
          ├─→ EventFileWriter.append()  ← actor, thread-safe JSONL append
          │
          └─→ SentryTransport.send()    ← no-op until DSN configured
```

- **EventFileWriter** is an `actor` — serializes all file writes automatically (same pattern as `AppLogFileWriter` in `AppLogger.swift`)
- **Fire-and-forget** — `capture()` never blocks the caller
- **Engine state enrichment** — every event gets live state from `DraftAppState` (parakeet loaded, auth mode, style examples)

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
   - `.error` — something broke, user may be affected (API failure, file write failed)
   - `.warning` — something degraded but has a fallback (vision timeout → voice-only, empty transcription)
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

| Engine | Event | Level | Trigger |
|--------|-------|-------|---------|
| `app` | `app_launched` | info | DraftAppState.initialize() completes |
| `parakeet` | `prewarm_failed` | error | Audio engine won't start |
| `parakeet` | `mic_not_authorized` | error | Microphone permission denied/revoked |
| `parakeet` | `model_not_ready` | warning | Recording attempted before model loaded |
| `parakeet` | `models_loaded` | info | Parakeet ASR models initialized |
| `parakeet` | `model_init_failed` | error | CoreML model initialization failed |
| `parakeet` | `transcription_empty` | warning | Parakeet returns no text |
| `parakeet` | `audio_format_failed` | error | AVAudioFormat creation failed |
| `parakeet` | `audio_engine_start_failed` | error | AVAudioEngine.start() throws during recording |
| `parakeet` | `asr_manager_unavailable` | error | ASR manager not available for transcription |
| `parakeet` | `recording_interrupted` | warning | Audio device changed during recording |
| `speech` | `audio_engine_start_failed` | error | AVAudioEngine.start() throws |
| `speech` | `recognizer_unavailable` | error | SFSpeechRecognizer not available |
| `speech` | `recognition_error` | warning | Recognition task error callback |
| `anthropic` | `api_http_error` | error | Non-200 HTTP response |
| `anthropic` | `api_auth_failure` | error | 401 Unauthorized |
| `anthropic` | `api_stream_error` | error | Streaming connection fails |
| `anthropic` | `api_timeout` | warning | Request exceeds timeout |
| `draft` | `draft_failed` | error | DraftEngine API call fails |
| `draft` | `subscription_expired` | error | OAuth token expired |
| `capture` | `vision_extraction_failed` | error | Vision API call fails |
| `capture` | `capture_auth_missing` | warning | No auth credential configured |
| `capture` | `hotkey_registration_failed` | error | Carbon RegisterEventHotKey fails |
| `style` | `style_refinement_failed` | error | Sonnet refinement call fails |
| `style` | `style_file_write_failed` | error | Can't write style.md |
| `style` | `style_file_read_failed` | warning | Can't read style.md |
| `feedback` | `feedback_encode_failed` | error | JSON encoding fails |
| `feedback` | `feedback_file_open_failed` | error | Can't open feedback.jsonl |
| `feedback` | `feedback_file_create_failed` | error | Can't create feedback.jsonl |
| `analysis` | `analysis_failed` | error | Sonnet analysis call fails |
| `analysis` | `suggestion_write_failed` | warning | Can't write suggestion log |
| `analysis` | `file_watch_failed` | error | DispatchSource setup fails |
| `chat` | `chat_api_failed` | error | Chat API call fails |
| `chat` | `tool_parse_failed` | warning | Tool JSON parsing fails |
| `overlay` | `stream_draft_failed` | error | Streaming draft throws |
| `overlay` | `draft_empty` | warning | Stream produced no text |
| `overlay` | `polish_failed` | warning | Dictation polish API fails |
| `overlay` | `vision_timeout` | warning | Vision exceeded 8s timeout |
| `overlay` | `refusal_detected` | info | Draft contained refusal pattern |
| `overlay` | `no_voice_input` | warning | Empty transcription after recording |
| `overlay` | `auth_missing` | error | No API credential when drafting |
| `imessage` | `imessage_db_open_failed` | error | Can't open chat.db |
| `imessage` | `imessage_query_failed` | error | SQLite query fails |
