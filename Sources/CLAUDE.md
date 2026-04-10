# App Bootstrap And Shared Paths

## What This Folder Owns

The root of `Sources/` contains the app entry point and the shared objects that survive window or panel lifecycle changes:

- `DraftApp.swift` — `@main` app entry plus `DraftAppDelegate`
- `DraftAppState.swift` — long-lived engine ownership and wake-recovery orchestration
- `DraftPaths.swift` — Application Support paths and Draft-to-Transcripted compatibility aliasing
- `HotkeyPreferences.swift` — persisted dictation/meeting shortcut settings
- `DraftConstants.swift` — cross-feature timeouts, thresholds, and shared constants

## Current Boot Sequence

`DraftAppDelegate.applicationDidFinishLaunching()` does the important wiring in this order:

1. Set up crash reporting and accessory-app behavior.
2. Create and wire `DraftSessionController` with `DraftAppState` and `FloatingOverlayController`.
3. Set up the dictation overlay.
4. If available, set up the meeting overlay and meeting hotkey callback.
5. Build the menu bar status item and popover.
6. Register wake handling via `NSWorkspace.didWakeNotification`.
7. Start async runtime preparation with `await appState.initialize()`.
8. Register hotkeys only after initialization starts.

That ordering matters because wake recovery, hotkeys, dictation, and meeting warmup all depend on `DraftAppState` owning the live engines first.

## What `DraftAppState` Actually Owns

Active app-level state today:

- `logger`
- `contextCapture`
- `sttRouter`
- beta-only `updateManager`
- lazy `meetingSession`
- `WakeRecoveryCoordinator`

Notably absent now: the older prompt/style/local-inference engines that previous docs described.

## Runtime Readiness

`DraftAppState.initialize()` kicks off shared warmup once:

- Parakeet prewarm
- Parakeet initialization
- meeting-model preparation when macOS 14 meeting mode is available

Wake recovery reuses that readiness path instead of duplicating setup logic.

## Paths

`DraftPaths.swift` is the source of truth for user-owned app data:

- `transcriptedAppSupportDir`
- compatibility alias `draftAppSupportDir`
- `meetingSupportDir`
- `dictationSupportDir`

Fresh installs use `~/Library/Application Support/Transcripted/`. If a legacy Draft folder already exists, it wins so older installs keep seeing the same data.

## Settings And Popovers

- The menu bar popover swaps between `PermissionsOnboardingView` and `MenuBarPanelController`.
- The settings window is separate from the popover and is hosted by `TranscriptedSettingsWindowController`.
- `MenuBarPanelController` is reused and refreshed on open rather than recreated from scratch each click.

## Verification

After touching files in this layer:

```bash
bash build.sh
bash run-tests.sh
```

Also run:

```bash
bash run-integration-smoke.sh
```

if the change touches wake recovery or meeting initialization behavior.
