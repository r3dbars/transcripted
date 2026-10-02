# Sources overview

## Current runtime

`Sources/` is the app target. On `main`, the app is centered on:

- dictation capture and paste-back
- Writing (opt-in): autocomplete through its own keyboard, and Save my writing day files
- meeting capture, imported-audio transcription, and transcript browsing
- optional local-speaker review for people sharing the room mic
- wake / sleep recovery for active recording flows

Important entry points:

- `TranscriptedApp.swift` — app entry point, menubar wiring, popover, overlay setup, detected-meeting prompt wiring, and activation-policy switching so active recordings stay visible in the macOS force-quit dialog
- `TranscriptedAppState.swift` — owns `ContextCaptureEngine`, `STTRouter`, `WritingController`, quiet launch-time warmup of the dictation and meeting models (re-run on model switch and wake), wake-recovery coordination, and lazy `MeetingSessionController`
- `TranscriptedMenuCommands.swift` — app-active macOS command menus for capture, import, navigation, and speaker search; these are additive window-scoped shortcuts and do not replace global physical triggers
- `Support/TranscriptedStoragePaths.swift` — app-support path helpers for the Transcripted capture-library, state, cache, logs, and tmp layout
- `Support/HotkeyPreferences.swift` — persisted dictation shortcut mode, meeting shortcut compatibility, and legacy hotkey migration helpers
- `Support/PermissionsOnboardingPreferences.swift` — persisted completion and forced-rerun state for the first-run permissions onboarding flow
- `Support/PhysicalDictationTriggerPreferences.swift` — canonical physical key / modifier bindings used by capture routing for push-to-talk, hands-free dictation, paste-last-dictation, and meeting shortcuts
- `Support/CustomDictionaryPreferences.swift` — persisted custom spoken-term replacements applied to final dictation and meeting transcript text
- `Support/DockVisibilityPreferences.swift` — persisted General toggle for whether Transcripted keeps a Dock icon while idle
- `Support/LocalSpeakerPreferences.swift` — persisted toggle that decides whether meeting transcription should split the local mic into multiple named speakers or keep it as a single "You" track
- `Support/MicrophoneProcessingPreferences.swift` — persisted mic processing mode for meetings and dictation, defaulting to software AGC while also exposing raw/off input and optional Apple voice processing for the WebRTC-specific recovery path through Settings. The in-meeting boost prompt and the Home "Boost mic next meeting" row arm voice processing for one meeting only and never save the mode; a one-time launch migration moves Boosts saved by 1.1.62 and older back to software AGC
- `Support/TranscriptionModelPreferences.swift` — persisted local model selection shared by dictation and meetings (Parakeet TDT V3 / V2, Whisper Large V3 Turbo, Whisper Large V3, Apple Speech, and the experimental Parakeet Ultra)
- `Support/ActivationPolicyController.swift` — main-actor policy for combining the Dock toggle with recording-state safety so active capture stays force-quit-visible
- `Support/TranscriptedConstants.swift` — shared timing and behavior constants used across the app target
- `Capture/ContextCaptureEngine.swift` — configurable physical-key dictation handling, meeting trigger routing, and trigger error surfacing
- `UI/Overlay/DictationSessionController.swift` — dictation session orchestration
- `Meeting/MeetingPromptDetector.swift` — Calendar and runtime-app meeting detection used to offer one-tap meeting capture prompts
- `Meeting/MeetingSessionController.swift` — app-side bridge into `TranscriptedCore`, including live capture, imported-audio handoff, queued meeting transcription, and local-speaker-split settings
- `Speech/ParakeetEngine.swift` + `Speech/STTRouter.swift` — local STT path used by dictation and by the meeting adapter; model selection cancels only unclaimed background warmup, while any dictation, meeting, or import that joins the load promotes it to protected foreground work; Parakeet CoreAudio lookup and startup support live in the adjacent `ParakeetAudio*` support files

## Directory map

- `Accessibility/` — AX helpers for overlay positioning
- `Capture/` — physical dictation trigger capture, meeting trigger routing, context parsing, and capture routing
- `Dictation/` — dictation transcript persistence and timeout helpers
- `Meeting/` — app-side meeting bridge, prompts, imported-audio prep, storage, and transcript restyling
- `Observability/` — events, debug log, anonymous analytics, Sparkle updater, and crash reporting
- `Reliability/` — wake / sleep recovery coordination
- `Speech/` — local STT engines, router, recorded-audio buffering, and dictation audio recovery helpers
- `Support/` — app-wide path, storage, permission metadata, onboarding-state, physical trigger bindings, shortcut-mode preferences, clipboard paste, custom-dictionary, auto-send, local-speaker, and transcription-model preference helpers
- `TranscriptedCore/` — shared library boundary
- `Writing/` — the app side of Writing: `WritingController` hosts the runtime, Save my writing day files, the Writing tab's model, count-only analytics
- `TranscriptedWriting/` — Writing's autocomplete library ported from Tilde (`Core/` pure policy, `Runtime/` model, helper, socket, Screen Memory, Personal History, Save my writing); compiled into the app module, tested under `swift test`
- `TranscriptedKeyboard/` — Writing's IMKit input method, a separate bundle built by `scripts/entrypoints/lib/bundle-input-method.sh`; excluded from the app binary
- `UI/` — grouped app surfaces: `Overlay/`, `MenuBar/`, `Settings/`, and `Shared/`

Historical planning docs were removed from the live tree so it reads like the
current app surface. Git history remains the source for retired plans and
point-in-time reviews.


## Read before editing

- touching dictation persistence: `Sources/Dictation/AGENTS.md`
- touching meeting flow, imported-audio transcription, or meeting UI: `Sources/Meeting/AGENTS.md`
- touching core library or meeting pipeline internals: `Sources/TranscriptedCore/AGENTS.md`
- touching STT, recording lifecycle, audio recovery, or device handling: `Sources/Speech/AGENTS.md`
- touching app-wide support utilities: `Sources/Support/AGENTS.md`
- touching overlay, menubar, onboarding, settings, or agent-connect UI: `Sources/UI/AGENTS.md`
- touching the Settings window, Home, onboarding, or speaker settings files: also `Sources/UI/Settings/AGENTS.md`
- touching hotkeys or physical dictation trigger routing: `Sources/Capture/AGENTS.md`
- touching focused-editor AX metadata, overlay placement, or paste-back context: `Sources/Accessibility/AGENTS.md`
- touching wake / sleep recovery or hotkey recovery: `Sources/Reliability/AGENTS.md`
- touching crash reporting, analytics, logs, diagnostics, or Sparkle updates: `Sources/Observability/AGENTS.md`
- touching Writing (the tab's runtime, Save my writing, analytics): `Sources/Writing/AGENTS.md`; the library: `Sources/TranscriptedWriting/AGENTS.md`; the keyboard: `Sources/TranscriptedKeyboard/AGENTS.md`
- touching tests or package boundaries: `Tests/README.md`

Prefer the local doc plus the actual Swift file list before assuming an older
Draft-era subsystem is still live.
