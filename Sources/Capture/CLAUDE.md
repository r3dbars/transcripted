# Capture Directory

## What This Does

`Sources/Capture/` owns the active global-trigger layer for:

- dictation start/stop
- meeting start/stop
- optional right-Option tap dictation

## Key Files

- `ContextCaptureEngine.swift` — Carbon hotkey registration, hotkey debounce,
  right-Option tap detection, and routing into dictation or meeting handlers

## Current Hotkey Flow

- Hotkey id `2` routes dictation toggles into `DictationSessionController`
- Hotkey id `3` routes meeting toggles through the app-provided meeting closure
- Rapid repeats are ignored using `TranscriptedConstants.hotkeyActionDebounceInterval`
- Right-Option tap can act as an alternate dictation trigger

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

- dictation hotkey starts and stops dictation
- meeting hotkey toggles meeting capture
- rapid repeat presses are ignored cleanly
