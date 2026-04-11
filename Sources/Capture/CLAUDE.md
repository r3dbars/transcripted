# Capture

## What this directory owns

`Sources/Capture/` owns the global trigger layer for:

- dictation start / stop
- meeting start / stop
- optional right-Option tap dictation

It does not own a live screenshot-driven draft mode anymore.

## Important files

- `ContextCaptureEngine.swift` — Carbon hotkey registration, debounce, right-Option tap detection, and routing into dictation or meeting handlers
- `CapturedContext.swift` — legacy structured screenshot-context helper retained for compatibility and tests, not a primary runtime path

## Guardrails

- keep the Carbon callback tiny and bounce into `@MainActor` work
- keep meeting routing separate from dictation routing
- do not reintroduce screenshot or OCR assumptions unless the same change restores the full source path

## Verify

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- dictation hotkey starts and stops dictation
- meeting hotkey toggles meeting capture
- rapid repeat presses are ignored cleanly
