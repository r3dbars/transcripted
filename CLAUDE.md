# CLAUDE.md

## Behavioral Guidelines
- **Implement, don't suggest.** If intent is unclear, infer the most useful action and proceed.
- **Read before answering.** Never speculate about code you haven't opened. This is critical given CoreAudio/Speech framework nuances.
- **Parallel tool calls.** When independent, make all calls in parallel.
- **No overengineering.** Only changes that are directly requested. Don't refactor surrounding code, add features, or clean up unless asked.
- **Work summaries.** After completing tool-based work, summarize what was done.
- **Check MEMORY.md first** when debugging any runtime issue.

## Project Summary
**Transcripted** — macOS app that records, transcribes, and organizes voice conversations. Uses Parakeet TDT V3 (STT) + Sortformer (diarization) via FluidAudio — 100% local, no cloud APIs. Outputs Markdown transcripts to `~/Documents/Transcripted/`.

## Build Commands
```bash
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Debug build
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Release build
xcodebuild -project Murmur.xcodeproj -scheme Murmur clean
```
Requires: macOS 14.2+, Xcode 15+, Swift 5.9+

## Agent Routing Table
Read the component CLAUDE.md in the relevant directory FIRST:

| Task / Issue | Read first |
|---|---|
| Audio capture, mic, recording | `Murmur/Core/CLAUDE.md` |
| System audio, process taps | `Murmur/Core/CLAUDE.md` |
| Transcription pipeline, saving | `Murmur/Core/CLAUDE.md` |
| Task queue, retries, progress | `Murmur/Core/CLAUDE.md` |
| STT model (Parakeet) | `Murmur/Services/CLAUDE.md` |
| Speaker diarization (Sortformer) | `Murmur/Services/CLAUDE.md` |
| Speaker matching, voice DB | `Murmur/Services/CLAUDE.md` |
| Speaker name inference (Qwen) | `Murmur/Services/CLAUDE.md` |
| Audio resampling | `Murmur/Services/CLAUDE.md` |
| Floating pill UI, state machine | `Murmur/UI/FloatingPanel/CLAUDE.md` |
| Transcript tray, speaker naming | `Murmur/UI/FloatingPanel/CLAUDE.md` |
| Settings window | `Murmur/UI/Settings/CLAUDE.md` |
| Design tokens, colors, animations | `Murmur/Design/CLAUDE.md` |
| Onboarding flow | `Murmur/Onboarding/CLAUDE.md` |
| App entry point, bootstrap | `Murmur/TranscriptedApp.swift` |
| Runtime debugging | `MEMORY.md` |

## Critical Invariants (All Changes)
- All classes use `@available(macOS 26.0, *)` — required for `AudioHardwareCreateProcessTap`
- **@MainActor classes:** Audio, Transcription, TranscriptionTaskManager, PillStateManager, ParakeetService, SortformerService, QwenService, StatsService, FailedTranscriptionManager
- **NOT @MainActor:** SystemAudioCapture (DispatchQueue + NSLock), SpeakerDatabase (DispatchQueue + SQLite), StatsDatabase (DispatchQueue)
- **CoreAudio I/O callbacks run on real-time threads** — NEVER do I/O, locks, allocations, or Objective-C calls inside them. Deep-copy buffers before async dispatch.
- System audio is 48kHz (tap reports 96kHz — always hardcode 48000.0)
- Mic format: use `inputFormat(forBus: 1)` (hardware), NEVER `outputFormat(forBus: 0)`
- Model states: `.notLoaded` → `.loading` → `.ready` | `.failed`
- App runs as LSUIElement (no dock icon), NSPanel floating UI

## Data Locations
| Data | Path |
|---|---|
| Transcripts | `~/Documents/Transcripted/` (customizable via UserDefaults `transcriptSaveLocation`) |
| Stats DB | `~/Documents/Transcripted/stats.sqlite` |
| Speaker DB | `~/Documents/Transcripted/speakers.sqlite` |
| Failed queue | `~/Documents/Transcripted/failed_transcriptions.json` |
| Speaker clips | `~/Documents/Transcripted/speaker_clips/` |
| Logs | `~/Library/Logs/Transcripted/app.jsonl` |
| Qwen cache | `~/Library/Caches/models/mlx-community/` |

## Logging
**File:** `~/Library/Logs/Transcripted/app.jsonl` — JSON Lines, rolling 2000 entries.

| Subsystem | Covers |
|---|---|
| `audio`, `audio.mic`, `audio.system` | Recording, mic, system audio |
| `transcription` | Model loading, STT, diarization |
| `pipeline` | Task lifecycle, saving, retries |
| `speaker-db` | Speaker matching, embeddings, merges |
| `services` | Qwen, service-level ops |
| `ui` | Pill state transitions, UI events |
| `stats` | Recording statistics, DB ops |
| `app` | App lifecycle, initialization |

**For ANY runtime issue:** Read the log file first.
