# Capture And Hotkeys

## What This Folder Owns

This folder now owns input routing, not screenshot-based drafting.

Active files:

- `ContextCaptureEngine.swift` — Carbon hotkey registration, right-option tap detection, dictation toggle routing, meeting toggle routing
- `CapturedContext.swift` — legacy structured screenshot-context helper retained for compatibility/tests

## Active Hotkey Flows

`ContextCaptureEngine` currently drives two live actions:

1. Dictation toggle
   - default fallback shortcut: `⌥Space`
   - optional right-option tap shortcut enabled by default
   - routes to `DraftSessionController.startDictation()` / `stopDictationAndPaste()`
2. Meeting toggle
   - default shortcut: `⌥M`
   - routes through `onMeetingToggle` to the meeting UI/controller

The old screenshot-to-draft flow is not the active product path anymore.

## Right Option Tap Detector

`RightOptionTapDetector` treats a quick press-and-release of the right Option key as dictation start/stop when enabled. It also watches for chord usage so holding Option as a modifier does not accidentally trigger dictation.

Important behavior:

- start tap window is short
- stop tap window is more forgiving while already dictating
- pressing any other key while Option is down disqualifies the tap

## Debounce Rules

Carbon hotkeys can fire faster than the UI state updates. `shouldAcceptHotkeyAction()` debounces rapid repeats so start/stop/cancel transitions stay single-shot.

## Current Hotkey IDs

- hotkey id `2` — dictation fallback shortcut
- hotkey id `3` — meeting shortcut

There is still a stored `draft` shortcut preference for compatibility, but the removed draft-mode flow is not wired through this handler.

## `CapturedContext`

`CapturedContext.swift` is still present and tested, but it is no longer the center of the live interaction model. Treat it as compatibility code unless a caller proves otherwise.

## Verification

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- right Option starts/stops dictation when enabled
- `⌥Space` still works as the fallback dictation shortcut
- `⌥M` toggles the meeting overlay/session
- hotkey re-registration still works after wake or settings changes
