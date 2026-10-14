# App shell

`Sources/App/` is the composition root. `TranscriptedApp` and `TranscriptedAppDelegate` build every controller and wire the status item, popover, overlays and meeting prompts.

## Module

`AppShell` in `.agents/modules.json`.

- **Owns:** app entry, the delegate's stored state and launch wiring, detected-meeting prompts, the status item and popover, Quit, the app-active command menus, the lab control channel, and the debug test control surface.
- **May depend on:** anything. Nothing may depend on it (the manifest check enforces that).
- **Tests:** `bash run-tests.sh --filter StatusItem`, `bash run-tests.sh --filter LabControlCommand`, `bash run-tests.sh --filter DebugControlCommand`, `bash run-e2e-smoke.sh`.
- **Start at:** `TranscriptedApp.swift`. It is the most source-pinned file in the repo, so run `python3 scripts/dev/check-source-pins.py --changed-only` before editing it or moving code between the delegate extensions.

## Rules

- Keep the delegate split by concern (extensions below). Don't add another responsibility to `TranscriptedApp.swift`; it is a hotspot (`Sources/AGENTS.md`, "Hotspots" in the root doc).
- The status item opens the same popover on left and right click; there is no separate right-click menu (owner decision).
- Active recordings must stay visible in the macOS force-quit dialog: the Dock toggle and recording state combine through `Sources/Support/ActivationPolicyController.swift`.
- The command menus are additive and only fire while the app is active. They never replace the global physical triggers (`Sources/Capture/AGENTS.md`).
- Lab rule: the lab control channel must stay compiled out of beta and release builds. Keep everything that names its env var inside `LabControlChannel.swift`'s `#if`. `build-beta.sh` greps the built binary for that name and fails the release if it's there.
- Debug-control rule: the test control surface is the same shape. Keep `TRANSCRIPTED_DEBUG_CONTROL_DIR` inside `DebugControlChannel.swift`'s `#if`. `build.sh` always compiles it; `build-beta.sh` never does and greps the binary. See `docs/debug-control-surface.md`.

## Files

- `TranscriptedApp.swift` - app entry and `TranscriptedAppDelegate` core: builds the controllers, overlay setup, detected-meeting prompt wiring.
- `TranscriptedAppDelegate+MenuBar.swift` - status item badge, popover, onboarding and Settings windows, activation-policy switching.
- `TranscriptedAppDelegate+SettingsActions.swift` - Settings actions, the audio-import queue, the auto call detection preference.
- `TranscriptedAppDelegate+Lifecycle.swift` - login-item launch detection and the Quit confirmation dialogs.
- `TranscriptedAppDelegate+LaunchReports.swift` - launch UI smoke and first-run reliability reports for automated launches.
- `TranscriptedMenuCommands.swift` - app-active command menus for capture, import, navigation, speaker search. The shortcut lists live in `Sources/UI/Settings/TranscriptedMenuCommandCatalog.swift`.
- `TranscriptedAppState.swift` - module `AppState` (card in `Sources/AGENTS.md`): the service container.
- `TranscriptedSupportActions.swift` - Email Support and Send diagnostics: builds the diagnostics snapshot from `TranscriptedAppState` and hands it to `SupportDiagnosticsBundle`.
- `LabControlChannel.swift` - lab builds only (`#if TRANSCRIPTED_LAB_CONTROL`, set by `build.sh --lab`, never by `build-beta.sh`). File-drop channel the hill-climb lab uses to drive the real app (start/stop dictation and meetings, import audio, status) when launched with `TRANSCRIPTED_LAB_CONTROL_DIR`. It refuses non-0700, foreign, or symlinked control dirs and reads commands `O_NOFOLLOW|O_NONBLOCK` plus `fstat`. Its hook is one `#if` line in `applicationDidFinishLaunching`. See `docs/lab-control-channel.md`.
- `LabControlCommand.swift` - the pure, always-compiled half: command parsing and validation (`stop_dictation` paste defaults to false), meeting-state gates, response encoding, `LabControlFilePolicy` (stat-based accept rules). Must not contain the env var name as a literal. Tested by `Tests/LabControlCommandTests.swift`.
- `DebugControlChannel.swift` - local `build.sh` only (`#if TRANSCRIPTED_DEBUG_CONTROL`, never `build-beta.sh`). File-drop + `transcripted-debug://` hook so a harness can start/stop dictation and meetings, import audio, open screens, set allowlisted bools, and read JSON state. Stays off unless `AutomatedLaunchEnvironment` is active and `TRANSCRIPTED_DEBUG_CONTROL_DIR` is an absolute path. See `docs/debug-control-surface.md`.
- `DebugControlCommand.swift` - the pure, always-compiled half: JSON / argv / URL parsing, settings and screen allowlists, session policy, dictation settle wait, state JSON (`schema_version` 1). Must not contain `TRANSCRIPTED_DEBUG_CONTROL_DIR`. Tested by `Tests/DebugControlCommandTests.swift`.
