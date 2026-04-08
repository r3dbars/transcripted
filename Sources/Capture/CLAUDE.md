# Capture Directory

## What This Does

`Sources/Capture/` owns the active global-trigger layer for:

- dictation start/stop
- meeting start/stop
- optional right-Option tap dictation

It no longer owns a live screenshot-driven draft mode.

## Key Files

- `ContextCaptureEngine.swift` — Carbon hotkey registration, hotkey debounce,
  right-Option tap detection, and routing into dictation or meeting handlers
- `CapturedContext.swift` — legacy structured screenshot-context helper retained
  for tests and compatibility code; not the center of the current runtime path

## Current Hotkey Flow

- Hotkey id `2` routes dictation toggles into `DraftSessionController`
- Hotkey id `3` routes meeting toggles through the app-provided meeting closure
- Rapid repeats are ignored using `DraftConstants.hotkeyActionDebounceInterval`
- Right-Option tap can act as an alternate dictation trigger

## Guardrails

- Keep the C-level Carbon callback tiny and bounce into `@MainActor` work
- Keep meeting routing separate from dictation routing
- Do not reintroduce screenshot/OCR assumptions here unless the source files
  come back in the same change

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
