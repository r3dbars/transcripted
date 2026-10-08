# Sources overview

`Sources/` is the app target (one Swift target), plus three folders that build separately: `TranscriptedCore/` (library), `TranscriptedWriting/Core/` (static module) and `TranscriptedKeyboard/` (input-method bundle). Read the root `AGENTS.md` first; this file maps the folders and holds the module cards that have no folder of their own.

The app does: dictation with paste-back, Writing (opt-in autocomplete through its own keyboard, plus Save my writing day files), meeting capture, imported-audio transcription and transcript browsing, optional local-speaker review, and wake / sleep recovery for active recordings. If a doc or file name sounds like an older "Draft"-era subsystem, check the file list here before trusting it.

## Directory map

- `Accessibility/` — AX helpers for overlay positioning and focused-editor metadata
- `App/` — app shell: `TranscriptedApp`, the `TranscriptedAppDelegate+*` extensions, command menus, `TranscriptedAppState`, the lab control channel, support actions
- `Capture/` — the global physical triggers (dictation key, meeting key) and their routing. Not the capture *library*, which is `Support/CaptureLibrary*.swift`
- `Dictation/` — dictation transcript and kept-audio persistence, stop/finalization policies, session cap and timeout helpers
- `Meeting/` — app-side meeting bridge, call detection and prompts, imported-audio prep, live captions, failed-meeting recovery, transcript restyling
- `Observability/` — events, diagnostics, analytics, Sentry crash reporting, Sparkle updater
- `Reliability/` — wake / sleep recovery coordination
- `Speech/` — local STT engines (Parakeet, Whisper, Apple Speech), `STTRouter`, audio engine and device handling, dictation audio recovery
- `Support/` — preferences, storage paths, the capture library, permissions, constants, clipboard paste-back, model-cache inventory, companion socket
- `TranscriptedCore/` — the shared library: audio capture, meeting pipeline, speaker identity, storage. Built into a prebuilt archive, never compiled into the app target
- `Writing/` — app side of Writing: `WritingController`, day files, the Writing tab's model, count-only analytics
- `TranscriptedWriting/` — Writing's autocomplete library ported from Tilde. `Core/` is pure policy and builds as `TranscriptedWritingCore`; `Runtime/` compiles into the app module. Both are tested under `swift test`
- `TranscriptedKeyboard/` — Writing's IMKit input method, a separate bundle built by `scripts/entrypoints/lib/bundle-input-method.sh`; excluded from the app binary
- `UI/` — `Overlay/`, `MenuBar/`, `Settings/`, `Shared/`

## Where things start

- `App/TranscriptedApp.swift` — entry point and the `TranscriptedAppDelegate` core: builds controllers, overlay setup, detected-meeting prompt wiring. The delegate's other halves: `+MenuBar` (status item, popover, Settings window, activation policy so active recordings stay in the force-quit dialog), `+SettingsActions` (Settings actions, audio-import queue), `+Lifecycle` (login-item launch detection, Quit confirmations), `+LaunchReports` (launch smoke and first-run reports for automated launches).
- `App/TranscriptedAppState.swift` — the service container (card below).
- `App/TranscriptedMenuCommands.swift` — app-active menu commands. They are window-scoped additions; they don't replace the global physical triggers.
- `Capture/ContextCaptureEngine.swift` (+`+DictationKeys`) — the CGEvent tap, trigger routing, `hotkeyError`. Detail: `Capture/AGENTS.md`.
- `UI/Overlay/DictationSessionController.swift` — dictation session orchestration; start, stop, paste-back, persistence, recovery, presses, the session cap and telemetry live in its `+*.swift` extensions.
- `Meeting/MeetingSessionController.swift` — app-side bridge into `TranscriptedCore`; state in `+State.swift`, the rest in `+*.swift` extensions. `Meeting/MeetingPromptDetector.swift` offers one-tap meeting capture from Calendar and running-app evidence.
- `Speech/STTRouter.swift` + `Speech/ParakeetEngine.swift` — the local STT path for dictation, and for meetings through `Meeting/MeetingSTTAdapter.swift`. Model selection cancels only unclaimed background warmup; any dictation, meeting, or import that joins a load promotes it to protected foreground work.
- Preferences in `Support/` (each is a stateless enum or small store over `UserDefaults`):
  - `HotkeyPreferences.swift` — `DictationKeyBehavior` (Hold or tap, the default; Hold only; Tap to toggle), right-Option enable, the Carbon-era bindings kept for compatibility.
  - `PhysicalDictationTriggerPreferences.swift` — the physical bindings: one dictation key (Right Option, not Fn, which also opens emoji) and the meeting key (Option-M). The old hands-free and paste-last-dictation bindings are still stored but unused; the one-key migration is `migrateToOneDictationKeyIfNeeded`.
  - `MicrophoneProcessingPreferences.swift` — mic processing mode for meetings and dictation; default is software AGC, with raw input and Apple voice processing as options. The in-meeting boost prompt and Home's "Boost mic next meeting" arm voice processing for one meeting and never save the mode. A one-time migration moves Boosts saved by 1.1.62 and older back to software AGC.
  - `TranscriptionModelPreferences.swift` — one local model choice shared by dictation and meetings: Parakeet TDT V3 / V2, Whisper Large V3 Turbo / V3, Apple Speech, and the experimental Parakeet Ultra (never downloaded; it exists only once `scripts/models/parakeet-ultra` has installed it).
  - Others (dictionary, Dock, local speaker, onboarding, storage paths, `TranscriptedConstants.swift`): read the file name; `Support/AGENTS.md` lists them.
- Dictation limits live in `Support/TranscriptedConstants.swift` (take cap `dictationSessionMaxDuration`, 15 minutes). Kept dictation audio is `Dictation/DictationAudioArchive.swift` (30 days by default).

## Modules

Every Swift file here belongs to a module in `.agents/modules.json`. `scripts/dev/check-module-boundaries.py` fails when a file names a type from a module its own may not depend on; the table is in `docs/repo-layout.md` ("Modules") and `--explain <file>` answers for one file. Each module's `AGENTS.md` holds its card (owns, public surface, may depend on, entry points, tests, rules). The cards below are the ones with no single folder (AppState) or whose folder doc is a file guide (Support, Observability). UIOverlay's card is `UI/Overlay/AGENTS.md`; AppShell's is `App/AGENTS.md`.

**AppState** (`App/TranscriptedAppState.swift`). Owns `ContextCaptureEngine`, `STTRouter`, `WritingController`, the lazy `MeetingSessionController`, quiet launch-time warmup of the dictation and meeting models (re-run on model switch and wake), and wake-recovery coordination. Public surface: `TranscriptedAppState`. May depend on Capture, WritingBridge, Meeting, Dictation, Speech, UIShared, Support, Observability and Core `core-vocab`. The UI modules (Overlay, MenuBar, Settings) may take the container; nothing below the UI may. Speech receives a narrow `DictationSessionHost` protocol implemented at this composition root.

**Support** (`Support/`, `Accessibility/`, `Reliability/`). The base layer: preferences, storage paths, the capture library, permissions, constants, `AutomatedLaunchEnvironment`, clipboard paste-back, model-cache inventory, AX helpers, wake recovery. May depend only on Core `core-vocab`. Meeting supplies the live system-audio permission backend, and installation receives plain analytics configuration values. Details: `Support/AGENTS.md`, `Accessibility/AGENTS.md`, `Reliability/AGENTS.md`.

**Observability** (`Observability/`). The sink every module may report into: reporters, `DiagnosticsTrail`, the `*Telemetry` types, sanitizers and policies, `SupportDiagnosticsBundle`, the Sparkle updater. May depend on Support and Core `core-vocab`. Telemetry consumes plain values; shared route and policy vocabulary lives in the permitted lower modules. Details: `Observability/AGENTS.md`.

Module boundaries are absolute: every forbidden crossing fails. Move the type down, pass plain values, or use a Meeting-owned seam; new dependency grants require a reviewed human edit.

## Read before editing

- dictation persistence: `Sources/Dictation/AGENTS.md`
- meeting flow, imported-audio transcription, meeting UI: `Sources/Meeting/AGENTS.md`
- Core library or meeting pipeline internals: `Sources/TranscriptedCore/AGENTS.md`
- STT, recording lifecycle, audio recovery, device handling (and anything that touches `inputNode`): `Sources/Speech/AGENTS.md`
- app-wide support utilities: `Sources/Support/AGENTS.md`
- overlay, menubar, onboarding, settings, agent-connect UI: `Sources/UI/AGENTS.md`; the Notch island, overlays, `DictationSessionController`: also `Sources/UI/Overlay/AGENTS.md`; Settings window, Home, onboarding, speaker settings: also `Sources/UI/Settings/AGENTS.md`
- hotkeys and physical dictation trigger routing: `Sources/Capture/AGENTS.md`
- focused-editor AX metadata, overlay placement, paste-back context: `Sources/Accessibility/AGENTS.md`
- wake / sleep recovery, hotkey recovery: `Sources/Reliability/AGENTS.md`
- crash reporting, analytics, logs, diagnostics, Sparkle: `Sources/Observability/AGENTS.md`
- Writing: the tab's runtime, Save my writing, analytics: `Sources/Writing/AGENTS.md`; the library: `Sources/TranscriptedWriting/AGENTS.md`; the keyboard: `Sources/TranscriptedKeyboard/AGENTS.md`
- tests or package boundaries: `Tests/README.md`

A new `Sources/` folder needs a module entry in `.agents/modules.json` and its own `AGENTS.md`.
