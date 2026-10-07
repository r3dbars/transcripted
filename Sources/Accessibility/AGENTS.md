# Accessibility

One file, `AccessibilityBridge.swift`: the AX (AXUIElement) queries that find the focused text field in the target app. Part of the `Support` module in `.agents/modules.json` (with `Sources/Support/` and `Sources/Reliability/`), so it may depend only on Core's `core-vocab` tier. The module card is in `Sources/AGENTS.md`.

## What it does

- `AccessibilityBridge` is `@MainActor`. `focusedTextElement(for:)` returns the focused element only if AX is trusted and the role passes `AccessibilityFocusedTextPolicy`. `focusedTextFieldRect(for:)` returns its screen rect. `textValue(of:)` reads `kAXValueAttribute`.
- One caller: `focusedFieldRect()` in `Sources/UI/Overlay/NotchIslandController.swift`, which places the dictation island near the field. The rect is cosmetic; a nil falls back to the anchor rect, then the mouse.
- Other AX code does its own queries and doesn't go through this file: `Sources/Support/FocusedTextPasteConfirmation.swift` (did the paste land), `Sources/Meeting/BrowserWindowTitleReader.swift`, and the Writing Screen Memory readers in `Sources/TranscriptedWriting/Runtime/ScreenMemory/`.

## Rules

- **Secure fields are never exposed.** `AXSecureTextField` is rejected as role or subrole (some AppKit hosts report it as a subrole of `AXTextField`). Keep both checks.
- **Every AX round trip is time-bounded** (`messagingTimeout`, 2 s). Set it on the application element and again on the focused element; never on the system-wide element, where it would replace the process-wide default. A wedged target app must not stall the overlay's first pixel, because these calls run on the main actor.
- **Return nil, don't throw.** No AX permission, no focus, or an unsupported role all mean nil, and callers have placement fallbacks.
- Keep it small: read metadata here, put product logic in the caller.

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual: focus a normal text editor, start and stop dictation, and confirm the island sits near that editor, not a stale target. Check a password field too: the island must not anchor to it.
