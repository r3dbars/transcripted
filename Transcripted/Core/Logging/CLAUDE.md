# Logging System

Dual-output logging: Console.app (os.Logger) + JSON Lines file (agent-readable). 2 Swift files.

## File Index

| File | Thread Safety | Purpose |
|------|---------------|---------|
| `AppLogger.swift` | @unchecked Sendable | Static subsystem loggers, dispatches to both os.Logger and FileLogger |
| `FileLogger.swift` | @unchecked Sendable | JSON Lines writer to ~/Library/Logs/Transcripted/app.jsonl |

## Architecture
```
AppLogger.audio.info("Started capture", ["sampleRate": "16000"])
  |
  ├── os.Logger (Console.app, system log)
  |   Level mapping: debug → .debug, info → .info, warning → .error, error → .fault
  |
  └── FileLogger (~/Library/Logs/Transcripted/app.jsonl)
      One JSON object per line, machine-readable
```

## Subsystem Table (AppLogger static properties)
| Property | Subsystem String | Usage |
|----------|-----------------|-------|
| `.audio` | audio | Audio engine lifecycle |
| `.audioMic` | audio.mic | Microphone capture, device recovery |
| `.audioSystem` | audio.system | System audio capture, process taps |
| `.transcription` | transcription | Pipeline orchestration |
| `.pipeline` | pipeline | Parakeet/diarization/Qwen steps |
| `.speakers` | speaker-db | Speaker matching, DB operations |
| `.services` | services | Model loading, service lifecycle |
| `.ui` | ui | UI state changes, window events |
| `.stats` | stats | StatsDatabase operations |
| `.app` | app | App lifecycle, setup, teardown |

## Log Levels
| Method | os.Logger Type | FileLogger Level | When to Use |
|--------|---------------|------------------|-------------|
| `.debug()` | `.debug` | "debug" | Verbose, only in Console.app debug mode |
| `.info()` | `.info` | "info" | Normal operations, state changes |
| `.warning()` | `.error` | "warning" | Recoverable problems |
| `.error()` | `.fault` | "error" | Failures requiring attention |

## File Log Format (JSON Lines)
```json
{"t":"2024-01-15T14:30:00.123Z","l":"info","s":"audio","m":"Started capture","d":{"sampleRate":"16000"}}
```
| Key | Type | Description |
|-----|------|-------------|
| `t` | String | ISO8601 timestamp with fractional seconds |
| `l` | String | Level: debug, info, warning, error |
| `s` | String | Subsystem (from table above) |
| `m` | String | Log message |
| `d` | Object? | Optional metadata dictionary (omitted if empty) |

## FileLogger Internals
- **Path**: `~/Library/Logs/Transcripted/app.jsonl`
- **Permissions**: 0o600 (owner-only read/write — may contain transcript snippets)
- **Thread safety**: `DispatchQueue(label: "com.transcripted.filelogger", qos: .utility)`
- **Cross-process locking**: POSIX `flock()` (advisory)
- **Rolling**: max 2000 entries, trims to 1500 every 100 writes
- **Trim mechanism**: Closes file handle, reads all lines, keeps last 1500, rewrites, reopens. Uses separate lock fd spanning close/reopen.
- **JSON building**: Manual string concatenation (no JSONEncoder) for per-line performance
- **Test mode**: Disabled when `XCTestConfigurationFilePath` env var is set
- **Escape**: Minimal escapeJSON (backslash, quotes, newline, CR, tab)

## Usage Pattern
```swift
AppLogger.audioMic.info("Device recovered", ["attempts": "\(count)", "elapsed": "\(ms)ms"])
AppLogger.pipeline.error("Parakeet failed", ["error": error.localizedDescription])
AppLogger.app.debug("Memory check", ["free": "\(freeMB)MB"])
```

## Relationships
- `AppLogger.flush()` called from `AppDelegate.applicationWillTerminate`
- Every module in Core/, Services/, and UI/ imports and uses AppLogger subsystems
- FileLogger output consumed by diagnostic export (Core/DiagnosticExporter.swift)

## Gotchas
- CoreAudio real-time threads must NOT call logger directly — dispatch to utility queue first (no I/O on audio thread)
- `flock()` is advisory only — another process could ignore the lock
- Trim temporarily closes and reopens file handle — concurrent writes during trim use the lock fd to prevent corruption
- `escapeJSON` is minimal (backslash, quotes, newline, CR, tab) — sufficient for log messages but won't handle all Unicode edge cases
- os.Logger level mapping is intentional: `.warning` → `.error` and `.error` → `.fault` (macOS convention for visibility in Console.app)
