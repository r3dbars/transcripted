# Sources overview

## Current runtime

`Sources/` is the app target. On `main`, the app is centered on:

- dictation capture and paste-back
- meeting capture, transcription, and transcript browsing
- wake / sleep recovery for active recording flows

Important entry points:

- `TranscriptedApp.swift` — app entry point, menubar wiring, popover, overlay setup, and detected-meeting prompt wiring
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, wake-recovery coordination, and lazy `MeetingSessionController`
- `DraftPaths.swift` — app-support path helpers for the current Draft-named compatibility tree
- `HotkeyPreferences.swift` — persisted hotkey settings used by capture routing
- `TranscriptedConstants.swift` — shared timing and behavior constants used across the app target
- `Capture/ContextCaptureEngine.swift` — right-option dictation handling, keyboard hotkeys, meeting hotkey routing
- `UI/DictationSessionController.swift` — dictation session orchestration; removed draft-mode methods are stubs
- `Meeting/MeetingPromptDetector.swift` — Calendar and runtime-app meeting detection used to offer one-tap meeting capture prompts
- `Meeting/MeetingSessionController.swift` — app-side bridge into `TranscriptedCore`, including queued meeting transcription handoff
- `Speech/ParakeetEngine.swift` + `Speech/STTRouter.swift` — local STT path used by dictation and by the meeting adapter

## Directory map

- `Accessibility/` — AX helpers for overlay positioning
- `API/` — beta-only config currently; older API docs are historical
- `Capture/` — hotkeys, context parsing, capture routing
- `Dictation/` — dictation transcript persistence and timeout helpers
- `Meeting/` — app-side meeting bridge, prompts, storage, and transcript restyling
- `Observability/` — events, debug log, telemetry, beta updater, crash reporting
- `Reliability/` — wake / sleep recovery coordination
- `Speech/` — Parakeet STT, router, and recorded-audio buffering helpers
- `Style/` — pure text heuristics retained from the older style-learning system
- `Text/` — small pure text utilities retained from the earlier drafting flow
- `TranscriptedCore/` — shared library boundary
- `UI/` — menubar, overlays, settings, recent meetings, speaker naming, and agent-connect

The historical planning docs that used to live alongside older placeholder
areas were moved under `docs/archive/` so the source tree reads more like the
live app surface and less like a half-finished subsystem map.

## Read before editing

- touching dictation persistence: `Sources/Dictation/CLAUDE.md`
- touching meeting flow: `Sources/Meeting/CLAUDE.md`
- touching core library or meeting pipeline internals: `Sources/TranscriptedCore/CLAUDE.md`
- touching STT / recording lifecycle: `Sources/Speech/CLAUDE.md`
- touching tests or package boundaries: `Tests/README.md`

Prefer the local doc plus the actual Swift file list before assuming an older
Draft-era subsystem is still live.
