# App Entry Point & Initialization

## What This Does

Bootstrap and centralized state management for the Draft macOS app. Three files at the root of `Sources/` handle app launch, engine wiring, and shared filesystem paths.

## Key Files

- `DraftApp.swift` (146 lines) — `@main` entry point: SwiftUI App struct + `DraftAppDelegate` (NSApplicationDelegate) for menubar setup, popover lifecycle, and engine initialization
- `DraftAppState.swift` (122 lines) — `@MainActor ObservableObject` that owns all engine instances and coordinates initialization/shutdown
- `DraftPaths.swift` (13 lines) — `FileManager` extension providing `draftAppSupportDir` (`~/Library/Application Support/Draft/`)
- `HotkeyPreferences.swift` (193 lines) — Stores/loads custom hotkey bindings (UserDefaults), Carbon modifier conversion, display strings for shortcut hints
- `DraftConstants.swift` (148 lines) — Centralized configuration constants (timeouts, thresholds, limits, buffer sizes)

## Initialization Order (Critical)

The boot sequence in `DraftAppDelegate.applicationDidFinishLaunching()` has strict ordering requirements:

```
1. Engine construction (all happen in DraftAppState.init — synchronous)
   └→ DraftEngine, StyleEngine, PromptStore, FeedbackStore, AppLogger,
      PreviousAppTracker, ContextCaptureEngine, AnalysisEngine,
      LocalInferenceManager, STTRouter

2. Wiring (in applicationDidFinishLaunching — order matters)
   ├→ sessionController.appState = appState           // Session needs all engines
   ├→ sessionController.overlayController = overlayController  // Session needs overlay
   └→ appState.contextCapture.sessionController = sessionController  // Hotkey → session routing

3. Overlay setup
   └→ overlayController.setup(sttRouter: appState.sttRouter)  // Creates NSPanel + hosting view

4. Menubar setup
   └→ NSStatusBar item + empty NSPopover (NO contentViewController — created on-demand in togglePopover())

5. Async initialization (in Task { @MainActor })
   ├→ appState.initialize()     // Engine cross-wiring, analysis start, Parakeet model load
   └→ appState.contextCapture.registerHotkey()  // Carbon global hotkeys (must be LAST)
```

### Why Order Matters

- **Step 2 before Step 5:** `initialize()` starts the analysis engine which may fire events. Session controller must be wired first or hotkey callbacks hit nil optionals.
- **Step 5: `initialize()` before `registerHotkey()`:** Hotkeys trigger `DraftSessionController.startSession()` which accesses `appState.sttRouter`, `appState.styleEngine`, etc. All engines must be initialized before hotkeys are live.
- **`initialize()` is idempotent:** Protected by `isInitialized` flag. Safe to call multiple times but only the first call takes effect.

## DraftAppState.initialize() — Engine Cross-Wiring

```
initialize() [guarded by isInitialized flag]
├→ drafter.styleEngine = styleEngine            // DraftEngine needs style prompts
├→ drafter.promptStore = promptStore            // DraftEngine needs model config
├→ styleEngine.promptStore = promptStore        // StyleEngine needs fallback prompts
├→ analysisEngine.start()                       // Start feedback file watcher
├→ NotificationCenter observer: .promptsDidChange → promptStore.reload()
├→ Task { sttRouter.parakeetEngine.initialize() + prewarm() }  // Non-blocking model load
├→ EventReporter.shared.setEngineStateSummary { ... }  // Context enrichment
└→ EventReporter.shared.capture(app_launched)
```

## DraftAppState.shutdown()

Called from `applicationWillTerminate()`:
```
├→ analysisEngine.stop()           // Stop file watcher + cancel debounce task
├→ sttRouter.parakeetEngine.cleanup()  // Release CoreML models
├→ contextCapture.unregisterHotkey()   // Remove Carbon hotkeys
└→ Remove NotificationCenter observer
```

## NSHostingController Lifecycle

The menubar popover's `NSHostingController` is **recreated on every open** in `togglePopover()`. A long-lived `NSHostingController` accumulates stale SwiftUI observation state across show/hide cycles and eventually crashes. Do NOT cache it or use `.id()` tricks.

## DraftPaths

Single computed property: `FileManager.default.draftAppSupportDir` returns `~/Library/Application Support/Draft/`. Used by StyleEngine, PromptStore, FeedbackStore, EventReporter, and AnalysisEngine for all persistent storage. Falls back to `~/Library/Application Support` if the system API returns empty (defensive, never observed in practice).

## Adding a New Engine

When adding a new engine to the app:

1. Add the property to `DraftAppState` (constructed in `init`)
2. Add cross-wiring in `initialize()` (after the `isInitialized` guard)
3. Add cleanup in `shutdown()` if the engine holds OS resources
4. If the engine needs session access, wire it in `applicationDidFinishLaunching()` step 2
5. **Do NOT register hotkeys or start listeners before `initialize()` completes**

## Verification

- **Launch:** `bash build.sh` → app launches, menubar icon appears, debug log shows `APP LAUNCHED`
- **Initialization order:** Check `~/draft-debug.log` for `APP LAUNCHED` with example count
- **Shutdown:** Quit app → green mic dot disappears, no crash
- **Popover:** Click menubar icon rapidly → no hang or crash (NSHostingController recreated each time)
