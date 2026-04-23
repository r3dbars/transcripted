# Capture Directory

## What This Does

`Sources/Capture/` owns the active global-trigger layer for:

- dictation start/stop
- meeting start/stop
- configurable physical-key dictation triggers (default: right Option)

## Key Files

- `ContextCaptureEngine.swift` — Carbon meeting-hotkey registration, hotkey debounce,
  accessibility-backed physical dictation trigger detection, and routing into dictation or meeting handlers

## Current Hotkey Flow

- The physical dictation trigger routes into `DictationSessionController`
- Dictation can run as hands-free toggle or push-to-talk, based on `HotkeyPreferences`
- `PhysicalDictationTriggerPreferences` stores the configurable trigger binding, defaulting to right Option and supporting modifier-only or keyed chords
- Hotkey id `3` routes meeting toggles through the app-provided meeting closure
- Rapid press repeats are ignored using `TranscriptedConstants.hotkeyActionDebounceInterval`
- Accessibility-backed trigger registration failures surface through `hotkeyError` so the menubar can explain why dictation trigger capture is unavailable

## Guardrails

- Keep the C-level Carbon callback tiny and bounce into `@MainActor` work
- Keep meeting routing separate from dictation routing
- Do not reintroduce screenshot/OCR assumptions here unless that feature
  returns in the same change

## Verification

After changing this directory:

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- hands-free dictation hotkey starts and stops dictation
- push-to-talk starts dictation on press and stops/pastes on release
- meeting hotkey toggles meeting capture
- the configured physical dictation trigger starts/stops dictation in the expected shortcut mode
- rapid repeat presses are ignored cleanly
