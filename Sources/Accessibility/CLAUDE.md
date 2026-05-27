# Accessibility

## What this directory owns

`Sources/Accessibility/` is the small AX bridge used to understand the
currently focused editor so Transcripted can place UI near it and recover text
context safely.

## Important file

- `AccessibilityBridge.swift` — AXUIElement queries for focused-element metadata, text values, bounds, and related accessibility helpers

## Guardrails

- keep this directory small and focused
- prefer reading focused-element metadata over adding product logic here
- changes here can affect overlay placement and paste-back behavior across the app

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual check:

- focus a normal text editor, start/stop dictation, and confirm paste-back plus
  overlay placement still use the focused editor rather than a stale target
