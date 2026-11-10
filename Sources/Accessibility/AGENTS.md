# Accessibility

Two files: `AccessibilityBridge.swift`, the AX (AXUIElement) queries that find the focused text field in the target app, and `AccessibilityBridge+Caret.swift`, which reads that field's text and cursor position for Next Sentence. Part of the `Support` module in `.agents/modules.json` (with `Sources/Support/` and `Sources/Reliability/`), so it may depend only on Core's `core-vocab` tier. The module card is in `Sources/AGENTS.md`.

## What it does

- `AccessibilityBridge` is `@MainActor`. `focusedTextElement(for:)` returns the focused element only if AX is trusted and the role passes `AccessibilityFocusedTextPolicy`. `focusedTextFieldRect(for:)` returns its screen rect.
- `AccessibilityBridge+Caret.swift`: `focusedText(for:)` returns the focused field's full text (`kAXValueAttribute`), and `focusedCaretRect(for:)` the cursor's rect, falling back to the field's first line (`NextSentenceCaretFallback`). Both go through `focusedTextElement(for:)`, so secure fields still return nil. Callers: `Sources/Writing/NextSentence/NextSentenceContext.swift` (the draft text, scrubbed there, and the caret) and `NextSentenceController.swift` (the caret).
- Overlay caller: `focusedFieldRect()` in `Sources/UI/Overlay/NotchIslandController.swift`. On a dictation opening with multiple displays, `NotchIslandScreenChoice.screenFrame` uses the field's center to choose its display, then the mouse display, then the main or first display. The island anchors on the chosen display; it does not position itself beside the field.
- Other AX code does its own queries and doesn't go through this file: `Sources/Support/FocusedTextPasteConfirmation.swift` (did the paste land), `Sources/Meeting/BrowserWindowTitleReader.swift`, and the Writing Screen Memory readers in `Sources/TranscriptedWriting/Runtime/ScreenMemory/`.

## Rules

- **Secure fields are never exposed.** `AXSecureTextField` is rejected as role or subrole (some AppKit hosts report it as a subrole of `AXTextField`). Keep both checks.
- **Every AX round trip is time-bounded** (`messagingTimeout`, 2 s). Set it on the application element and again on the focused element; never on the system-wide element, where it would replace the process-wide default. A wedged target app must not stall the overlay's first pixel, because these calls run on the main actor.
- **Return nil, don't throw.** No AX permission, no focus, or an unsupported role all mean nil, and callers have placement fallbacks.
- Keep it small: read AX values here, put product logic (and any scrubbing of field text) in the caller.

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual: with more than one display, focus a normal text editor, start and stop dictation, and confirm the island opens on the display that holds that editor, not a stale target. Check a password field too: it must not be read or used to pick the display.
