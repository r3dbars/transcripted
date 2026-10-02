# App shell

## What this directory does

`Sources/App/` is the composition root. `TranscriptedApp` and `TranscriptedAppDelegate` build every controller and wire the status item, popover, overlays and meeting prompts.

## Module

`AppShell` in `.agents/modules.json`.

- **Owns:** app entry, the delegate's stored state and launch wiring, detected-meeting prompts, the status item and popover, Quit, and the app-active command menus.
- **May depend on:** anything. Nothing may depend on it (the manifest check enforces that).
- **Tests:** `bash run-tests.sh --filter StatusItem`, `bash run-tests.sh --filter LabControlCommand`, `bash run-e2e-smoke.sh`.
- **Rules:** most source-pinned files in the repo, so run `python3 scripts/dev/check-source-pins.py --changed-only` first.

## Files

- `TranscriptedApp.swift` — app entry point and `TranscriptedAppDelegate` core: builds the controllers, overlay setup, and detected-meeting prompt wiring
- `TranscriptedAppDelegate+MenuBar.swift` — status item badge, popover, onboarding and Settings window, and activation-policy switching so active recordings stay visible in the macOS force-quit dialog
- `TranscriptedAppDelegate+SettingsActions.swift` — Settings actions, the audio-import queue, and the auto call detection preference
- `TranscriptedAppDelegate+Lifecycle.swift` — login-item launch detection and the Quit confirmation dialogs
- `TranscriptedAppDelegate+LaunchReports.swift` — launch UI smoke and first-run reliability reports for automated launches
- `TranscriptedMenuCommands.swift` — app-active macOS command menus for capture, import, navigation, and speaker search; additive window-scoped shortcuts that don't replace global physical triggers
- `TranscriptedAppState.swift` — module `AppState` (card in `Sources/AGENTS.md`): the service container
- `LabControlChannel.swift` — **lab builds only** (`#if TRANSCRIPTED_LAB_CONTROL`, set by `build.sh --lab`, never by `build-beta.sh`, which fails if the channel's env var name is in the binary). File-drop control channel the hill-climb lab uses to drive the real app (start/stop dictation and meetings, import audio, status) when launched with `TRANSCRIPTED_LAB_CONTROL_DIR`; refuses non-0700/foreign/symlinked control dirs, reads commands `O_NOFOLLOW|O_NONBLOCK` + `fstat`. Its hook is the one `#if` line at the end of `applicationDidFinishLaunching`. See `docs/lab-control-channel.md`
- `LabControlCommand.swift` — the pure, always-compiled half of the lab channel: command parsing/validation (`stop_dictation` paste defaults to false), meeting-state gates, response encoding, and `LabControlFilePolicy` (the stat-based dir/file accept rules). Must not contain the channel's env var name as a literal. Fast-tested by `Tests/LabControlCommandTests.swift`
- `TranscriptedSupportActions.swift` — Email Support and Send diagnostics: builds the diagnostics snapshot from `TranscriptedAppState` and hands it to `SupportDiagnosticsBundle`

Lab rule: the lab control channel must stay compiled out of beta/release builds. Keep everything that references its env var inside `LabControlChannel.swift`'s `#if`; `build-beta.sh` greps the built binary for that name and fails the release if it's there.
