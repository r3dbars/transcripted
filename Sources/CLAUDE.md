# Sources Overview

## What `Sources/` owns

`Sources/` is the app target. On `main`, the live product is centered on:

- dictation capture and paste-back
- meeting capture, transcription, and transcript browsing
- menu bar controls, onboarding, settings, and agent-connect flows

## Important entry points

- `TranscriptedApp.swift` — app entry point, menu bar wiring, popover, overlays, onboarding, and detected-meeting prompt setup
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, wake recovery, and lazy `MeetingSessionController`
- `Capture/ContextCaptureEngine.swift` — global hotkeys, right-Option dictation trigger, and routing into dictation or meetings
- `UI/DictationSessionController.swift` — dictation session orchestration; removed draft-mode methods are compatibility stubs
- `Meeting/MeetingPromptDetector.swift` — Calendar-driven meeting-link detection used for one-tap meeting prompts
- `Meeting/MeetingSessionController.swift` — app-side bridge into `TranscriptedCore`, including single-flight transcription queueing
- `Speech/ParakeetEngine.swift` + `Speech/STTRouter.swift` — app-owned STT path used by dictation and the meeting adapter
- `Reliability/WakeRecoveryCoordinator.swift` — deduplicated wake recovery for hotkeys and runtime readiness

## Directory map

- `Accessibility/` — AX helpers for focused-element metadata and overlay positioning
- `API/` — beta-build config only
- `Capture/` — global triggers, hotkeys, and capture routing
- `Dictation/` — dictation artifact persistence
- `Meeting/` — app-side meeting adapters, storage, and transcript restyling
- `Observability/` — debug logging, events, diagnostics, crash reporting, and beta telemetry/update plumbing
- `Reliability/` — wake / hotkey recovery coordination
- `Speech/` — Parakeet STT and live recording plumbing
- `Style/` — small retained style heuristics
- `Text/` — small retained text utilities
- `TranscriptedCore/` — reusable meeting transcription library
- `UI/` — overlays, menu bar, settings, onboarding, and agent-connect surfaces

## Storage model to keep in mind

- captures live in the selected capture library
- default capture library: `~/Library/Application Support/Transcripted/captures/`
- app-owned state, cache, logs, and tmp stay under `~/Library/Application Support/Transcripted/`

Read `docs/storage-paths.md` before changing file-output assumptions.

## Read before editing

- touching dictation persistence: `Sources/Dictation/CLAUDE.md`
- touching meeting flow: `Sources/Meeting/CLAUDE.md`
- touching wake / hotkey recovery: `Sources/Reliability/CLAUDE.md`
- touching STT / recording lifecycle: `Sources/Speech/CLAUDE.md`
- touching the shared library: `Sources/TranscriptedCore/CLAUDE.md`
