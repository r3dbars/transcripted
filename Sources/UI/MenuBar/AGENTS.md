# UI/MenuBar module

Module `UIMenuBar` in `.agents/modules.json`. Parent: `Sources/UI/AGENTS.md`.

## Owns

The status item and its popover: the glyph, the header status line, the Record and Dictate buttons, the utility rows, and the Paste Last Dictation toast.

## Public surface

`MenuBarPanelController`, `MenuBarContentView`, `MenuBarGlyph`, `StatusItemPresentation`, `MenuBarMeetingCapturePhase`, `PasteLastDictationFeedbackPresenter`, `MenuBarAutomationID` (the AX ids external automation looks up).

## May depend on

UIShared, UIOverlay, UISettings, AppState, Capture, Meeting, Dictation, Speech, Support, Observability, and Core's `core-vocab` tier. Nothing in the app may depend on UIMenuBar except AppShell. `.agents/modules.json` is the source of truth.

## Files

Shell:

- `MenuBarPanelController.swift` builds and shows the popover (`NSPopover`). While a meeting records, the meeting row's trailing slot shows the live timer instead of the start shortcut.
- `MenuBarPopoverPresentation.swift` shows the transient popover and focuses its window without app-wide activation (activating the app can disturb a fullscreen app's Space). Left and right clicks share one toggle action.
- `StatusItemPresentation.swift` picks the glyph and label for each capture state and writes them onto the button, at launch and on every refresh.
- `MenuBarGlyph.swift` draws the icon as a template image (outline idle, filled dictating, filled with a dot while a meeting records). Geometry mirrors `docs/assets/menu-bar-icon/make_menu_bar_icons.py`; `StatusItemPresentationTests` fails when they drift.
- `MenuBarContentView.swift` is the transparent root, so the popover's native material is the surface. `MenuBarKeyViewLoop.swift` builds the explicit Tab order (update callout, primary buttons, utility rows), matching `FocusOrderContract.menuBarPopoverOrder`.
- `MenuBarAutomationID.swift` holds stable AX identifiers. UISmoke in `Tools/TranscriptedQA`, the `build.sh` launch smoke and `scripts/ops/packaged-app-smoke.py` find controls by them, so change a raw value only in lockstep with those.

Header and rows:

- `MenuBarHeaderView.swift` has no title: hidden when idle and ready; shows a status line for warmup, a transcript being made, and starting/saving a meeting (a steady recording has no line; the red Stop button with its timer says it), plus hotkey warnings, clickable when they have a fix to open. `MenuBarHeaderStatusPresentation` picks text and tone (recording wins over ready/warmup), `MenuBarHeaderLayoutPolicy` the layout, `MenuBarMeetingCapturePhase` the starting/recording/saving phase.
- `MenuBarShortcutWarningPresentation.swift` is the shortcut warning's copy and click action (Accessibility access). The macOS Fn key conflict is not shown here; it lives in Settings > Shortcuts.
- `MenuBarPrimaryActionsView.swift` is the Record and Dictate buttons side by side. `MenuBarPrimaryButtonTitle` gives short titles ("Record", "Stop", "Dictate", "Done"; the full title stays the accessibility label and the launch smoke's snapshot title). `MenuBarShortcutLabel` shows the full shortcut, then only the first key of a `A / B` pair when it doesn't fit. Paste Last Dictation keeps its shortcut but has no row.
- `MenuBarUtilityActionsView.swift` is the Open Transcripted, Check for Updates and Quit rows (Settings lives inside Open Transcripted). `MenuBarActionRowView` is the AppKit control behind the buttons and rows.
- `PasteLastDictationFeedback.swift` is the toast model (title, detail, tone, dismiss delay) and presenter for pasted, copied-fallback ("Paste not confirmed"), failed and no-saved-dictation outcomes. Its panel is excluded from screen capture.

## Tests

`bash run-tests.sh --filter MenuBar`, `--filter PasteLastDictationFeedback`, `--filter StatusItemPresentation`. `FocusOrderContractTests` checks the Tab order against the views, and `UIAutomationSurfaceContractTests` the AX ids. For automation-facing changes run `bash scripts/ops/transcripted-qa-bench.sh --mode ui`.

## Rules

- **Left and right click open the same popover.** Don't bring back a separate right-click menu (owner decision, root `AGENTS.md`).
- **Colors are dynamic** so the popover follows light and dark; layer colors re-resolve through `NSView.menuResolvedCGColor(_:)` (tokens in `Shared/MenuTokens.swift`).
- **Views are renderers.** The controller pushes `update(...)`; Foundation-pure `*Presentation` / `*Policy` files decide copy and tone.
