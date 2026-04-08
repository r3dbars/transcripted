# Sources overview

## Current runtime

`Sources/` is the app target. On `main`, the app is centered on:

- dictation capture and paste-back
- meeting capture, transcription, and transcript browsing

Important entry points:

- `TranscriptedApp.swift` — app entry point, menubar wiring, popover, overlay setup
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, and lazy `MeetingSessionController`
- `Capture/ContextCaptureEngine.swift` — right-option dictation handling, keyboard hotkeys, meeting hotkey routing
- `UI/DictationSessionController.swift` — dictation session orchestration; removed draft-mode methods are stubs
- `Meeting/MeetingSessionController.swift` — Draft-side bridge into `TranscriptedCore`
- `Speech/ParakeetEngine.swift` + `Speech/STTRouter.swift` — local STT path used by dictation and by the meeting adapter

## Directory map

- `Accessibility/` — AX helpers for overlay positioning
- `API/` — beta-only config currently; older API docs are historical
- `Capture/` — hotkeys, context parsing, capture routing
- `Dictation/` — dictation transcript persistence
- `Draft/` — small pure utilities retained from the older draft flow
- `Meeting/` — Draft-side meeting bridge and transcript restyling
- `Observability/` — events, debug log, telemetry, beta updater, crash reporting
- `Speech/` — Parakeet STT and router
- `Style/` — pure text heuristics retained from the older style-learning system
- `TranscriptedCore/` — shared library boundary
- `UI/` — menubar, overlays, settings, recent meetings, speaker naming

## Read before editing

- touching dictation persistence: `Sources/Dictation/CLAUDE.md`
- touching meeting flow: `Sources/Meeting/CLAUDE.md`
- touching core library or meeting pipeline internals: `Sources/TranscriptedCore/CLAUDE.md`
- touching STT / recording lifecycle: `Sources/Speech/CLAUDE.md`
- touching tests or package boundaries: `Tests/README.md`

## Placeholder subdirectories

Some subdirectories now exist mainly as placeholders or retained utility areas.
Their local docs call this out directly:

- `API/`
- `Analysis/`
- `Feedback/`
- `Local/`
- `Prompts/`
- parts of `Draft/` and `Style/`

Prefer the local doc plus the actual Swift file list before assuming an older
Draft-era subsystem is still live.
