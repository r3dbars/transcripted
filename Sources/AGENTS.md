# Sources overview

## Current runtime

`Sources/` is the app target. On `main`, the app is centered on:

- dictation capture and paste-back
- Writing (opt-in): autocomplete through its own keyboard, and Save my writing day files
- meeting capture, imported-audio transcription, and transcript browsing
- optional local-speaker review for people sharing the room mic
- wake / sleep recovery for active recording flows

Important entry points:

- `TranscriptedApp.swift` — app entry point and `TranscriptedAppDelegate` core: builds the controllers, overlay setup, and detected-meeting prompt wiring
- `TranscriptedAppDelegate+MenuBar.swift` — status item badge, popover, onboarding and Settings window, and activation-policy switching so active recordings stay visible in the macOS force-quit dialog
- `TranscriptedAppDelegate+SettingsActions.swift` — Settings actions, the audio-import queue, and the auto call detection preference
- `TranscriptedAppDelegate+Lifecycle.swift` — login-item launch detection and the Quit confirmation dialogs
- `TranscriptedAppDelegate+LaunchReports.swift` — launch UI smoke and first-run reliability reports for automated launches
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
- `UI/Overlay/DictationSessionController.swift` — dictation session orchestration; start, stop, paste-back, persistence, recovery, presses, the session cap and telemetry live in its `+*.swift` extensions
- `Meeting/MeetingPromptDetector.swift` — Calendar and runtime-app meeting detection used to offer one-tap meeting capture prompts
- `Meeting/MeetingSessionController.swift` — app-side bridge into `TranscriptedCore`: the recording lifecycle here, the class declaration and state in `+State.swift`, and imported-audio handoff, queued transcription, warnings and telemetry in the other `+*.swift` extensions
- `Speech/ParakeetEngine.swift` + `Speech/STTRouter.swift` — local STT path used by dictation and by the meeting adapter; model selection cancels only unclaimed background warmup, while any dictation, meeting, or import that joins the load promotes it to protected foreground work; Parakeet CoreAudio lookup and startup support live in the adjacent `ParakeetAudio*` support files, and the engine's input route, tap, recording start/teardown and transcription in its sibling `Parakeet*.swift` files

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
- `TranscriptedWriting/` — Writing's autocomplete library ported from Tilde (`Core/` pure policy, `Runtime/` model, helper, socket, Screen Memory, Personal History, Save my writing). `Core/` builds as its own static module, `TranscriptedWritingCore`; `Runtime/` compiles into the app module. Both are tested under `swift test`
- `TranscriptedKeyboard/` — Writing's IMKit input method, a separate bundle built by `scripts/entrypoints/lib/bundle-input-method.sh`; excluded from the app binary
- `UI/` — grouped app surfaces: `Overlay/`, `MenuBar/`, `Settings/`, and `Shared/`

Historical planning docs were removed from the live tree so it reads like the
current app surface. Git history remains the source for retired plans and
point-in-time reviews.


## Modules

Every Swift file here belongs to a module in `.agents/modules.json`, and `scripts/dev/check-module-boundaries.py` fails when a file names a type from a module its own may not depend on. The table is in `docs/repo-layout.md` ("Modules"); `--explain <file>` answers for one file. Each module's own `AGENTS.md` has its card (owns, public surface, may depend on, entry points, tests, rules). The cards below live here because these modules have no single folder of their own (AppShell, AppState) or their folder docs are file guides (Support, Observability). UIOverlay's card is `UI/Overlay/AGENTS.md`.

**AppShell** (`App/`, `TranscriptedApp.swift`, its `TranscriptedAppDelegate+*.swift` extensions, `TranscriptedMenuCommands.swift`). The composition root: `TranscriptedApp` and `TranscriptedAppDelegate` build every controller and wire the status item, popover, overlays and meeting prompts. It may depend on anything and nothing may depend on it (the manifest check enforces that). Most source-pinned file in the repo, so run `check-source-pins.py --changed-only` first. Tests: `bash run-tests.sh --filter StatusItem`, `bash run-e2e-smoke.sh`, `bash run-tests.sh --filter LabControlCommand`.

`App/` holds the shell's helpers that need the app delegate or the whole app state:

- `LabControlChannel.swift` — **lab builds only** (`#if TRANSCRIPTED_LAB_CONTROL`, set by `build.sh --lab`, never by `build-beta.sh`, which fails if the channel's env var name is in the binary). File-drop control channel the hill-climb lab uses to drive the real app (start/stop dictation and meetings, import audio, status) when launched with `TRANSCRIPTED_LAB_CONTROL_DIR`; refuses non-0700/foreign/symlinked control dirs, reads commands `O_NOFOLLOW|O_NONBLOCK` + `fstat`. Its hook is the one `#if` line at the end of `applicationDidFinishLaunching`. See `docs/lab-control-channel.md`
- `LabControlCommand.swift` — the pure, always-compiled half of the lab channel: command parsing/validation (`stop_dictation` paste defaults to false), meeting-state gates, response encoding, and `LabControlFilePolicy` (the stat-based dir/file accept rules). Must not contain the channel's env var name as a literal. Fast-tested by `Tests/LabControlCommandTests.swift`
- `TranscriptedSupportActions.swift` — Email Support and Send diagnostics: builds the diagnostics snapshot from `TranscriptedAppState` and hands it to `SupportDiagnosticsBundle`

Lab rule: the lab control channel must stay compiled out of beta/release builds. Keep everything that references its env var inside `LabControlChannel.swift`'s `#if`; `build-beta.sh` greps the built binary for that name and fails the release if it's there.

**AppState** (`TranscriptedAppState.swift`). The service container: owns `ContextCaptureEngine`, `STTRouter`, `WritingController`, the lazy `MeetingSessionController`, model warmup and wake recovery. Public surface: `TranscriptedAppState`. May depend on Capture, WritingBridge, Meeting, Dictation, Speech, UIShared, Support, Observability and Core `core-vocab`. The UI modules (Overlay, MenuBar, Settings) may take the container; nothing below the UI may. Grandfathered: `Speech/DictationSession.swift` takes it today; the fix is injecting the narrow dependencies it uses.

**Support** (`Support/`, `Accessibility/`, `Reliability/`). The base layer: preferences, storage paths, the capture library, permissions, constants, `AutomatedLaunchEnvironment`, clipboard paste-back, model-cache inventory, AX helpers and wake recovery. May depend only on Core `core-vocab`. Grandfathered: `TranscriptedPermissionAccess` naming `CoreAudioSystemAudioCapture`, and `ClaudeDesktopIntegrationInstaller` naming Observability types. Details: `Support/AGENTS.md`, `Accessibility/AGENTS.md`, `Reliability/AGENTS.md`.

**Observability** (`Observability/`). The sink every module may report into: `EventReporter`, `AnalyticsReporter`, `CrashReporter`, `DiagnosticsTrail`, the `*Telemetry` types, sanitizers and policies, `SupportDiagnosticsBundle`, and the Sparkle updater. May depend on Support and Core `core-vocab`. Grandfathered: `ActivationTelemetry` and `AnalyticsEventPolicy` name Dictation and Speech types (to be inverted by passing plain values). Details: `Observability/AGENTS.md`.

## Read before editing

- touching dictation persistence: `Sources/Dictation/AGENTS.md`
- touching meeting flow, imported-audio transcription, or meeting UI: `Sources/Meeting/AGENTS.md`
- touching core library or meeting pipeline internals: `Sources/TranscriptedCore/AGENTS.md`
- touching STT, recording lifecycle, audio recovery, or device handling: `Sources/Speech/AGENTS.md`
- touching app-wide support utilities: `Sources/Support/AGENTS.md`
- touching overlay, menubar, onboarding, settings, or agent-connect UI: `Sources/UI/AGENTS.md`; the Notch island, overlays, or `DictationSessionController`: also `Sources/UI/Overlay/AGENTS.md`
- touching the Settings window, Home, onboarding, or speaker settings files: also `Sources/UI/Settings/AGENTS.md`
- touching hotkeys or physical dictation trigger routing: `Sources/Capture/AGENTS.md`
- touching focused-editor AX metadata, overlay placement, or paste-back context: `Sources/Accessibility/AGENTS.md`
- touching wake / sleep recovery or hotkey recovery: `Sources/Reliability/AGENTS.md`
- touching crash reporting, analytics, logs, diagnostics, or Sparkle updates: `Sources/Observability/AGENTS.md`
- touching Writing (the tab's runtime, Save my writing, analytics): `Sources/Writing/AGENTS.md`; the library: `Sources/TranscriptedWriting/AGENTS.md`; the keyboard: `Sources/TranscriptedKeyboard/AGENTS.md`
- touching tests or package boundaries: `Tests/README.md`

Prefer the local doc plus the actual Swift file list before assuming an older
Draft-era subsystem is still live.
