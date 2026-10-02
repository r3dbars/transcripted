# App shell

## What this directory does

`Sources/App/` is the composition root. `TranscriptedApp` and `TranscriptedAppDelegate` build every controller and wire the status item, popover, overlays and meeting prompts.

## Module

`AppShell` in `.agents/modules.json`.

- **Owns:** app entry, the delegate's stored state and launch wiring, detected-meeting prompts, the status item and popover, Quit, and the app-active command menus.
- **May depend on:** anything. Nothing may depend on it (the manifest check enforces that).
- **Grandfathered crossing:** `Support/LabControlChannel.swift` names `TranscriptedAppDelegate`; moving the lab-control files next to the shell fixes it.
- **Tests:** `bash run-tests.sh --filter StatusItem`, `bash run-e2e-smoke.sh`.
- **Rules:** most source-pinned files in the repo, so run `python3 scripts/dev/check-source-pins.py --changed-only` first.

## Files

- `TranscriptedApp.swift` — app entry point and `TranscriptedAppDelegate` core: builds the controllers, overlay setup, and detected-meeting prompt wiring
- `TranscriptedAppDelegate+MenuBar.swift` — status item badge, popover, onboarding and Settings window, and activation-policy switching so active recordings stay visible in the macOS force-quit dialog
- `TranscriptedAppDelegate+SettingsActions.swift` — Settings actions, the audio-import queue, and the auto call detection preference
- `TranscriptedAppDelegate+Lifecycle.swift` — login-item launch detection and the Quit confirmation dialogs
- `TranscriptedAppDelegate+LaunchReports.swift` — launch UI smoke and first-run reliability reports for automated launches
- `TranscriptedMenuCommands.swift` — app-active macOS command menus for capture, import, navigation, and speaker search; additive window-scoped shortcuts that don't replace global physical triggers
