# Core Folder

Core owns the audio capture pipeline, transcription orchestration, file saving, and statistics tracking.

## Pipeline Flow

1. **Audio capture** → `SystemAudioCapture` captures system audio via CoreAudio process taps
2. **Audio recording** → `Audio` class manages AVAudioEngine, publishes audio levels and state
3. **Transcription** → `Transcription` orchestrates Parakeet → PyAnnote → WeSpeaker → Qwen pipeline
4. **Save** → `TranscriptSaver` writes Markdown + YAML output to disk

## Threading Rules

- **NO I/O in CoreAudio callbacks** — CoreAudio callbacks run on audio threads; all file I/O must be dispatched elsewhere
- **@MainActor for UI** — `Transcription` and all UI-related code uses `@MainActor`
- **Audio classes are NOT @MainActor** — `Audio` and `SystemAudioCapture` manage AVAudioEngine/CoreAudio which require synchronous access from audio threads
- **Explicit main thread dispatch** — Audio classes explicitly dispatch UI updates to main thread

## Key Files

- `Audio.swift` — Main audio recording class, manages microphone + system audio, publishes audio levels and recording state
- `SystemAudioCapture.swift` — Captures system-wide audio using CoreAudio process taps (macOS 14.2+), handles device switching and format negotiation
- `Transcription.swift` — @MainActor orchestration class, manages ParakeetService, DiarizationService, SpeakerDatabase, speaker mappings
- `TranscriptionTaskManager.swift` — Manages display status for UI with progress phases (gettingReady → transcribing → finishing), handles task queue
- `TranscriptSaver.swift` — Writes transcript output to disk in Markdown + YAML format

## Output Format

Transcripts are saved as Markdown with YAML frontmatter containing:
- Timestamps and speaker labels
- Identified speaker names from Qwen inference
- Confidence scores for name matches
- SQLite databases track speakers and statistics

## Databases

- **Speakers DB** — Stores speaker mappings and identified names
- **Stats DB** — Tracks transcription metrics and usage statistics

## Logging

CoreAudio may emit internal framework warnings during setup/teardown (e.g., `HALC_ShellObject::SetPropertyData`). These are harmless and don't affect functionality.
