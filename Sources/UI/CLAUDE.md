# UI Components

## What This Does

Pure AppKit views for the Draft app. The primary UI is a **floating overlay** (non-activating NSPanel) that appears over the user's current app for the hotkey -> speak -> draft -> review -> inject flow. A **menubar popover** hosts a single-pane layout with status, usage stats, shortcut pills, writing style, and agent section. Both use pure AppKit (NSView subclasses) — no SwiftUI, no NSHostingView, no AttributeGraph.

Onboarding views (run once per install) still use SwiftUI temporarily.

## Key Files

### Floating Overlay (Pure AppKit)
- `FloatingOverlayPanel.swift` (~37 lines) — NSPanel subclass (non-activating, dynamic key status)
- `FloatingOverlayController.swift` (~500 lines) — State machine, animations, panel lifecycle, Combine subscriptions, global Escape monitor
- `OverlayRootView.swift` (~250 lines) — Root NSView compositor: header + content container + toolbar, lazy child views per state
- `OverlayHeaderView.swift` (~120 lines) — Header bar: mode label, spinner, waveform, chevron, shortcut hint
- `WaveformLayer.swift` (~180 lines) — CALayer waveform + WaveformRingBuffer + 30fps Timer
- `OverlayListeningView.swift` (~80 lines) — Live transcript display during recording
- `OverlayDraftingView.swift` (~80 lines) — Spinner/error/processing states
- `OverlayStreamingView.swift` (~60 lines) — Token streaming with NSTextView auto-scroll
- `DraftTextView.swift` (~100 lines) — NSTextView subclass: Enter (confirm), Shift+Enter (newline), Escape (cancel)
- `OverlayReviewView.swift` (~100 lines) — Editable draft + live diff strip
- `OverlayDiffStripView.swift` (~100 lines) — Word-level diff visualization (attributed string)
- `OverlayToolbarView.swift` (~60 lines) — Bottom status hints
- `OverlayToastView.swift` (~40 lines) — Training toast (brain icon + message)
- `PanelDragView.swift` (~37 lines) — AppKit drag helper (mouseDown -> performDrag)
- `DraftSessionController.swift` (~665 lines) — Session orchestration for draft mode (option+D) and dictation mode (option+Space)

### Menubar Panel (Pure AppKit)
- `MenuBarPanelController.swift` (~150 lines) — NSViewController with Combine subscriptions, created fresh per popover open
- `MenuBarContentView.swift` (~300 lines) — Root NSView with NSScrollView, composes all sections
- `MenuBarHeaderView.swift` (~40 lines) — "Draft" title + status dot
- `MenuBarStatsView.swift` (~50 lines) — Three-column stats display
- `MenuBarShortcutsView.swift` (~40 lines) — Pill-shaped shortcut badges
- `MenuBarStyleView.swift` (~80 lines) — Expandable style card with match score
- `MenuBarAgentView.swift` (~80 lines) — Insight cards with Apply/Skip
- `MenuBarModelDownloadView.swift` (~60 lines) — Download progress bars
- `MenuBarSettingsView.swift` (~120 lines) — Settings popover content
- `HotkeyRecorderAppKitView.swift` (~120 lines) — Keyboard shortcut recorder

### Design Tokens
- `OverlayTokens.swift` (~35 lines) — NSColor tokens for floating overlay (translucent dark)
- `MenuTokens.swift` (~35 lines) — NSColor (NS-suffixed) + SwiftUI Color tokens for menubar panel

### Onboarding (Still SwiftUI — Phase 3)
- `OnboardingView.swift` (~876 lines) — 8-step interactive onboarding
- `OnboardingWindowController.swift` (~88 lines) — NSWindowController host
- `StyleOnboardingView.swift` (~554 lines) — Style import/setup flow
- `PermissionsOnboardingView.swift` (~252 lines) — Permission checker

## Architecture Overview

```
FloatingOverlay (hotkey flow)          MenuBarPanel (configuration)
+----------------------------+        +-----------------------------+
| FloatingOverlayPanel       |        | MenuBarPanelController      |
| (NSPanel, non-activating)  |        | (NSViewController + Combine)|
|                            |        |                             |
| OverlayRootView (NSView)   |        | MenuBarContentView (NSView) |
|  ├── OverlayHeaderView     |        |  +-- MenuBarHeaderView      |
|  ├── content children:     |        |  +-- MenuBarStatsView       |
|  │   listening/drafting/   |        |  +-- MenuBarShortcutsView   |
|  │   streaming/review      |        |  +-- MenuBarStyleView       |
|  └── OverlayToolbarView    |        |  +-- MenuBarAgentView       |
+----------------------------+        +-----------------------------+
| DraftSessionController     |        | Onboarding gate:            |
| (orchestrates full flow)   |        | StyleOnboardingView (SwiftUI)|
+----------------------------+        +-----------------------------+
```

## State Observation Pattern

Engines remain `@MainActor ObservableObject` with `@Published` properties. AppKit views are **dumb renderers** — they don't subscribe to anything. **Controllers** hold Combine subscriptions and push data to views via explicit `update()` methods.

```swift
// FloatingOverlayController.setup():
sttRouter.$audioLevel
    .receive(on: RunLoop.main)
    .sink { [weak self] level in
        self?.rootView?.headerView.updateWaveformLevel(level)
    }
    .store(in: &subscriptions)
```

State changes on the controller use `didSet` to push to views:
```swift
var state: OverlayState = .idle {
    didSet { guard state != oldValue else { return }; pushStateToViews() }
}
```

## FloatingOverlay — The Primary UI

### Panel Architecture

`FloatingOverlayPanel` is an NSPanel subclass with these key properties:
- **Non-activating** (`.nonactivatingPanel`) — the target app stays frontmost, so paste works without re-activation
- **Dynamic key status** — `canBecomeKey` returns `allowKeyStatus`, which is `false` during listening/drafting (keyboard stays with target app) and `true` during review (DraftTextView needs keyboard input)
- **Floating level** — `.popUpMenu` level (above `.floating`), visible over Electron apps and status bars, across all spaces
- **Drag handle** — `PanelDragView` is added as a pure AppKit subview above the root view

### State Machine

```
idle -> listening -> drafting -> streaming -> review -> idle
  ^         |          |           |          |
  +-------- (Escape cancels from any active state) ---+
```

| State | Trigger | UI | Key Status | Escape Handling |
|-------|---------|-----|------------|-----------------|
| `idle` | Session end/cancel | Hidden | false | -- |
| `listening` | option+D/Space (start) | Waveform + live transcription | false | Global monitor -> cancel |
| `drafting` | option+D/Space (stop) | Spinner + "Drafting..."/"Polishing..." | false | Global monitor -> cancel |
| `streaming` | First token from MLXEngine | Tokens scrolling in content area | false | Global monitor -> cancel |
| `review` | Stream complete | Editable DraftTextView + hint bar | true | DraftTextView.keyDown -> cancel |

### Auto-Focus in Review Mode

When the review view appears, `FloatingOverlayController.showReview()` calls `panel.makeFirstResponder(draftTextView)`. This is synchronous — no delay needed. The user can immediately hit Enter to inject or start editing.

### Keyboard Handling

- **Review/DiffFlash mode:** `DraftTextView.keyDown(with:)` handles Enter (confirm), Shift+Enter (newline), Escape (cancel) via the responder chain
- **Non-key states (listening/drafting/streaming):** Global `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` intercepts Escape (keyCode 53) and routes to `onEscapeDuringSession` closure

### Lazy Child Views

Content child views (listening, drafting, streaming, review) are created lazily on first access via computed properties on `OverlayRootView` and reused across state transitions. Only one is visible at a time. This eliminates view lifecycle churn.

## DraftSessionController — Session Orchestration

Lives in `DraftSessionController.swift`. Same session lifecycle, task management, vision processing, streaming, clipboard safety, and refusal detection as before. The overlay interface is unchanged — `showPanel()`, `appendStreamToken()`, `showReview()`, `hideWithConfirmAnimation()` etc.

### Property Safety

`appState` and `overlayController` are **Optional** (not IUOs). Every public method starts with:
```swift
guard let appState = appState, let overlayController = overlayController else { return }
```

### reviewText Sync

`DraftTextView.onTextChange` callback syncs text back to `FloatingOverlayController.reviewText` so `DraftSessionController.confirmAndInject()` can read it.

## MenuBarPanel — Configuration UI

Pure AppKit menubar popover (440x520). `MenuBarPanelController` (NSViewController) is created fresh each time the popover opens, holds Combine subscriptions to all relevant engines, and pushes data to `MenuBarContentView` sections.

Sections:
1. **Header** — "Draft" title + status dot (green = ready, orange = loading)
2. **Model Download** — Progress bars for Parakeet + Qwen (shown during first launch)
3. **Stats** — Three-column: words dictated, messages drafted, time saved
4. **Shortcuts** — Pill badges: option+D Draft, option+Space Dictation
5. **Style** — Expandable card with style match score + profile text
6. **Agent** — Insight cards with Apply/Skip buttons (defensive card ID capture preserved)

### Settings Popover

Gear button opens an NSPopover with `MenuBarSettingsView`: name field, transcription engine info, `HotkeyRecorderAppKitView` (keyboard shortcut recorder using NSEvent local monitor), LLM status, feedback buttons, quit.

### Onboarding Gate

If `!styleEngine.hasCompletedOnboarding`, `togglePopover()` shows `StyleOnboardingView` via a temporary `NSHostingController` instead of `MenuBarPanelController`. This is acceptable because onboarding runs once per install (no AG accumulation).

## Animation System

All animations are pure AppKit (unchanged from before):

**Entrance:** Spring animation (scale 0.88 -> 1.0 via `CASpringAnimation`) + 200ms fade-in.
**Confirm exit:** Scale down (1.0 -> 0.93) + fade. Signals "your text was sent."
**Cancel exit:** Horizontal shake (5 steps) + fade. Signals "nothing happened."

Both set `panel.ignoresMouseEvents = true` before animating.

## Verification

After modifying UI components, verify with these checks:

- **Full draft flow:** option+D over Slack -> speak -> option+D -> tokens stream -> draft appears editable -> Enter -> text pasted to Slack
- **Full dictation flow:** option+Space -> speak -> option+Space -> text pasted directly
- **Auto-focus:** After draft streams in, cursor should be blinking in the DraftTextView without clicking
- **Enter/Escape:** Enter injects, Escape cancels, Shift+Enter inserts newline
- **Escape during listening:** option+D to start -> Escape -> overlay shakes and disappears
- **Escape during streaming:** While tokens streaming, Escape -> cancels cleanly
- **Cancel during review:** option+D while draft showing -> overlay hides (shake animation)
- **Paste-back:** Draft injected into correct target app
- **Waveform:** Animated bars during listening (30fps Timer-driven CALayer)
- **Panel drag:** Click and drag header to move panel
- **Menubar panel:** All sections render, stats correct, style expand/collapse works
- **Insight cards:** Apply/Skip buttons work
- **Settings:** Name field, hotkey recorder, quit button
- **Stability:** Run for 24+ hours with periodic sessions — no EXC_BAD_ACCESS crash (no AttributeGraph)
- **Build:** `bash build.sh && bash run-tests.sh`
