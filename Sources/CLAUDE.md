# Sources overview

## Current runtime

`Sources/` is the app target. On `main`, the app is centered on:

- dictation capture and paste-back
- meeting capture, transcription, and transcript browsing
- wake / sleep recovery for active recording flows

Important entry points:

- `TranscriptedApp.swift` — app entry point, menubar wiring, popover, overlay setup, and detected-meeting prompt wiring
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, wake-recovery coordination, and lazy `MeetingSessionController`
- `Support/TranscriptedStoragePaths.swift` — app-support path helpers for the Transcripted capture-library, state, cache, logs, and tmp layout
- `Support/HotkeyPreferences.swift` — persisted hotkey settings used by capture routing
- `Support/LocalSpeakerPreferences.swift` — persisted toggle for splitting local mic participants into multiple named speakers during meeting transcription
- `Support/TranscriptedConstants.swift` — shared timing and behavior constants used across the app target
- `Capture/ContextCaptureEngine.swift` — right-option dictation handling, keyboard hotkeys, meeting hotkey routing
- `UI/Overlay/DictationSessionController.swift` — dictation session orchestration
- `Meeting/MeetingPromptDetector.swift` — Calendar and runtime-app meeting detection used to offer one-tap meeting capture prompts
- `Meeting/MeetingSessionController.swift` — app-side bridge into `TranscriptedCore`, including queued meeting transcription handoff
- `Speech/ParakeetEngine.swift` + `Speech/STTRouter.swift` — local STT path used by dictation and by the meeting adapter

## Directory map

- `Accessibility/` — AX helpers for overlay positioning
- `Beta/` — beta-only config currently; older API docs are historical
- `Capture/` — hotkeys, context parsing, capture routing
- `Dictation/` — dictation transcript persistence and timeout helpers
- `Meeting/` — app-side meeting bridge, prompts, storage, and transcript restyling
- `Observability/` — events, debug log, anonymous analytics, Sparkle updater, and crash reporting
- `Reliability/` — wake / sleep recovery coordination
- `Speech/` — Parakeet STT, router, and recorded-audio buffering helpers
- `Support/` — app-wide path, storage, permission, hotkey, local-speaker, and shared constant helpers
- `TranscriptedCore/` — shared library boundary
- `UI/` — grouped app surfaces: `Overlay/`, `MenuBar/`, `Settings/`, `AgentConnect/`, and `Shared/`

The historical planning docs that used to live alongside older placeholder
areas were moved under `docs/archive/` so the source tree reads more like the
live app surface and less like a half-finished subsystem map.

Some older drafting-era utility folders have now been trimmed out of the live
app target entirely. If a historical doc still mentions `Sources/Text/` or
`Sources/Style/`, prefer the current file tree.

## Read before editing

- touching dictation persistence: `Sources/Dictation/CLAUDE.md`
- touching meeting flow: `Sources/Meeting/CLAUDE.md`
- touching core library or meeting pipeline internals: `Sources/TranscriptedCore/CLAUDE.md`
- touching STT / recording lifecycle: `Sources/Speech/CLAUDE.md`
- touching tests or package boundaries: `Tests/README.md`

Prefer the local doc plus the actual Swift file list before assuming an older
Draft-era subsystem is still live.
