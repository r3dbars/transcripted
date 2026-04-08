# App Entry Point & Initialization

## What This Does

Bootstrap and centralized state management for the current Transcripted macOS app shell. The root `Sources/` files handle app launch, hotkey wiring, shared filesystem paths, and the app-wide controller graph.

## Key Files

- `DraftApp.swift` - `@main` entry point: SwiftUI `App` wrapper plus `DraftAppDelegate` for menubar setup, popover lifecycle, and top-level wiring
- `DraftAppState.swift` - `@MainActor ObservableObject` that owns the shared logger, capture engine, STT router, beta update plumbing, and optional meeting session
- `DraftPaths.swift` - `FileManager` compatibility helper for the app support directory used by this transition build
- `HotkeyPreferences.swift` - Stores and formats custom hotkey bindings
- `DraftConstants.swift` - Shared timing, retry, and buffer constants

## Initialization Order

`DraftAppDelegate.applicationDidFinishLaunching()` is intentionally ordered:

1. Construct `DraftAppState`, `FloatingOverlayController`, and `DraftSessionController`.
2. Wire `DraftSessionController` into `DraftAppState.contextCapture` and attach the meeting hotkey closure.
3. Set up the floating overlay with `overlayController.setup(sttRouter:)`.
4. Create the status item and menubar popover.
5. Run `appState.initialize()` on the main actor, then register hotkeys last.

## Why Order Matters

- The session controller must be wired before hotkeys are live, or Carbon callbacks can hit nil state.
- `initialize()` prewarms the speech model and prepares the meeting pipeline, so it must run before `registerHotkey()`.
- `initialize()` is idempotent and guarded by an `isInitialized` flag.

## DraftAppState.initialize()

```
initialize() [guarded by isInitialized flag]
├→ Task { sttRouter.parakeetEngine.initialize(); sttRouter.parakeetEngine.prewarm() }
├→ if available, Task { meetingSession.prepareModels(showLoadingUI: false) }
├→ EventReporter.shared.setEngineStateSummary { ... }
└→ EventReporter.shared.capture(app_launched)
```

## DraftAppState.shutdown()

Called from `applicationWillTerminate()`:

```
├→ BetaTelemetry.shared.stopPeriodicShipping()   // beta builds only
├→ sttRouter.parakeetEngine.cleanup()
├→ contextCapture.unregisterHotkey()
└→ remove wake observers
```

## DraftPaths

`FileManager.default.transcriptedAppSupportDir` resolves to `~/Library/Application Support/Draft/` for compatibility during the transition. `meetingSupportDir` and `dictationSupportDir` hang off the same root.

## Adding A New Subsystem

1. Add the shared object to `DraftAppState`.
2. Wire it in `applicationDidFinishLaunching()` if it needs session access.
3. Start it in `initialize()` if it has a warmup phase.
4. Clean it up in `shutdown()` if it owns OS resources.
5. Do not register hotkeys or long-lived listeners before `initialize()` completes.

## Verification

- `bash build.sh`
- `bash run-tests.sh`
- If you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run `bash run-integration-smoke.sh`
