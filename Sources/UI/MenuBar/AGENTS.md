# UI/MenuBar module

Module `UIMenuBar` in `.agents/modules.json`. The file-by-file notes stay in `Sources/UI/AGENTS.md` ("MenuBar/"); this page is the module card.

## Owns

The status item and its popover: the glyph, the header status line, the Record and Dictate buttons, the utility rows, and the Paste Last Dictation toast.

## Public surface

`MenuBarPanelController`, `MenuBarContentView`, `MenuBarGlyph`, `StatusItemPresentation`, `MenuBarMeetingCapturePhase`, `PasteLastDictationFeedbackPresenter`, `MenuTokens`, `MenuBarAutomationID` (the AX ids external automation looks up).

## May depend on

UIShared, UIOverlay, UISettings, AppState, Capture, Meeting, Dictation, Speech, Support, Observability, and Core's `core-vocab` tier. Nothing in the app may depend on UIMenuBar except AppShell. `.agents/modules.json` is the source of truth.

Grandfathered crossing: `UI/Settings/HotkeyRecorderAppKitView.swift` names `MenuTokens`, which makes Settings reach up into the menu bar. Moving `MenuTokens.swift` to `UI/Shared/` fixes it; that move waits for #1946.

## Entry points

- `MenuBarPanelController.swift` builds and shows the popover. Left-click and right-click on the status item open the same popover (a product-surface rule in the root `AGENTS.md`).
- `StatusItemPresentation.swift` picks the glyph and label for each capture state and writes them onto the status item button, at launch and on every refresh.
- `MenuBarGlyph.swift` draws the icon; its geometry mirrors `docs/assets/menu-bar-icon/make_menu_bar_icons.py`, and `StatusItemPresentationTests` fails when they drift.

## Tests

`bash run-tests.sh --filter MenuBar`, `--filter PasteLastDictationFeedback`, `--filter StatusItemPresentation`.

## Rules

- Don't bring back a separate right-click menu.
- Colors are dynamic so the popover follows light and dark; layer colors re-resolve through `NSView.menuResolvedCGColor(_:)`.
