# Support helpers

## What this directory does

`Sources/Support/` holds app-wide infrastructure that many features depend on but no single feature owns: storage paths, permission checks, hotkey settings, local-speaker preferences, clipboard paste-back, and shared constants.

## Files

- `ClipboardRestoringTextPaster.swift` — pastes dictated text into the target app by borrowing the clipboard briefly and restoring prior contents after Cmd+V completes
- `HotkeyPreferences.swift` — data model, persistence, display, and validation for customizable keyboard shortcuts (dictation, meeting, draft hotkeys and right-Option tap-to-dictate)
- `LocalSpeakerPreferences.swift` — persisted toggle that decides whether meeting transcription runs mic-channel diarization to split local speakers or keeps a single "You" track (default: off)
- `TranscriptedConstants.swift` — centralized configuration constants: timeouts, audio buffer sizes, sample rates, Parakeet thresholds, dictation limits, and pipeline version
- `TranscriptedPermissionAccess.swift` — cross-cutting permission checks for microphone, accessibility, system audio recording, and calendar; surfaces required-on-first-launch vs optional gates
- `TranscriptedStoragePaths.swift` — app-support path helpers for the Transcripted capture library, state, cache, logs, and tmp layout; includes user-configurable capture library location

## Agent notes

- These files are imported across the app target. Changes here can affect dictation, meeting, capture, and UI code.
- `TranscriptedConstants` is the right place for shared timing and threshold values. Animation durations and UI dimensions stay in their respective token files (`OverlayTokens`, `MenuTokens`).
- `TranscriptedStoragePaths` owns the canonical app-support directory layout. If you need a new storage subdirectory, add it here.
- `HotkeyPreferences` is a stateless enum backed by UserDefaults. Keep it side-effect-free for testability.
