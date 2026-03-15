# UI Components

## What This Does

SwiftUI views for the Draft app. The primary UI is a **floating overlay** (non-activating NSPanel) that appears over the user's current app for the hotkey -> speak -> draft -> review -> inject flow. A **menubar popover** hosts a single-pane layout with status, usage stats, shortcut pills, writing style, and agent section.

## Key Files

- `FloatingOverlayPanel.swift` (~37 lines) — NSPanel subclass (non-activating, dynamic key status)
- `FloatingOverlayController.swift` (~460 lines) — State machine, animations, panel lifecycle, global Escape monitor
- `OverlayContentView.swift` (~332 lines) — SwiftUI views for all 6 overlay states (idle/loading/listening/drafting/streaming/review)
- `DraftSessionController.swift` (~603 lines) — Session orchestration for draft mode (option+D) and dictation mode (option+Space)
- `OverlayTokens.swift` (~48 lines) — Design tokens: `OverlayTokens` for floating overlay (translucent dark), `MenuTokens` for menubar panel (system-adaptive colors, layout constants)
- `PanelDragView.swift` (~37 lines) — AppKit drag helper (mouseDown -> performDrag)
- `MenuBarPanel.swift` (~451 lines) — Single-pane menubar popover (440x520): header (status dot), usage stats, shortcut pills, writing style (compact/expandable), agent section, onboarding gate, settings gear
- `OnboardingView.swift` (~876 lines) — 8-step interactive onboarding: welcome -> permissions -> try dictation -> try drafting -> fake conversation -> try context draft -> style setup -> complete. The largest UI file.
- `OnboardingWindowController.swift` (~88 lines) — NSWindowController that hosts the onboarding SwiftUI view in a standalone window
- `PermissionsOnboardingView.swift` (~252 lines) — Permission checker for mic, speech, screen capture with live polling and System Settings deep links
- `HotkeyRecorderView.swift` (~142 lines) — Compact keyboard shortcut recorder for settings popover, uses NSEvent local monitor for key capture
- `AgentTab.swift` (~101 lines) — `AgentSection` struct: pending insight cards (Apply/Skip) from AnalysisEngine. Chat removed (low value relative to complexity for local inference)
- `StyleOnboardingView.swift` (~554 lines) — 5-step onboarding: intro -> source choice -> (iMessage/paste) -> result
- `ScrollingWaveformView.swift` (~147 lines) — Real-time scrolling waveform for overlay header bar, Canvas + TimelineView at 60fps, ring buffer for audio level samples
- `AnimatedTranscriptView.swift` (~81 lines) — Animated live transcript with word-by-word fade-in via custom `FlowLayout` (SwiftUI Layout protocol)

## Architecture Overview

```
FloatingOverlay (hotkey flow)          MenuBarPanel (configuration)
+----------------------------+        +-----------------------------+
| FloatingOverlayPanel       |        | Single-pane ScrollView      |
| (NSPanel, non-activating)  |        | +-- Header (status dot)     |
|                            |        | +-- Stats (words/msgs)      |
| States:                    |        | +-- Shortcuts (option+D/Space)|
| idle -> listening ->       |        | +-- Writing Style (card)    |
| drafting -> streaming ->   |        | +-- AgentSection (cards)     |
| review                     |        |                             |
+----------------------------+        | Onboarding gate:            |
| DraftSessionController     |        | StyleOnboardingView         |
| (orchestrates full flow)   |        +-----------------------------+
+----------------------------+
```

## FloatingOverlay — The Primary UI (v2)

### Panel Architecture

`FloatingOverlayPanel` is an NSPanel subclass with these key properties:
- **Non-activating** (`.nonactivatingPanel`) — the target app stays frontmost, so paste works without re-activation
- **Dynamic key status** — `canBecomeKey` returns `allowKeyStatus`, which is `false` during listening/drafting (keyboard stays with target app) and `true` during review (TextEditor needs keyboard input)
- **Floating level** — `.popUpMenu` level (above `.floating`), visible over Electron apps and status bars, across all spaces
- **Drag handle** — `PanelDragView` is added as a pure AppKit subview above the SwiftUI `NSHostingView`, not as an `NSViewRepresentable` bridge. This avoids executor isolation crashes during nested run loops

### Session Modes

`FloatingOverlayController.SessionMode` enum governs behavior differences:
- **`.draft`** (option+D) — screenshot + voice + AI rewrite + review
- **`.dictation`** (option+Space) — voice + batch transcribe + auto-paste

The `activeMode` is set by `DraftSessionController` before showing the overlay. `OverlayContentView` uses it to render mode-specific text (e.g., "Draft" vs "Dictate" header, "option+D to stop" vs "option+Space to stop" hints, "Drafting..." vs "Polishing..." spinner).

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
| `drafting` | option+D/Space (stop) | Spinner + "Drafting..."/"Polishing..." (mode-dependent), or error message | false | Global monitor -> cancel |
| `streaming` | First token from MLXEngine | Spinner + "Drafting..." header, tokens scrolling in content area | false | Global monitor -> cancel |
| `review` | Stream complete | Editable TextEditor + hint bar | true | SwiftUI .onKeyPress -> cancel |

**State transition guards:** `startStreaming()` requires `.drafting` or `.listening`, `appendStreamToken()` requires `.streaming`, `finishStreaming()` requires `.streaming`. This prevents the overlay from entering `.review` when not actually streaming.

### Auto-Focus in Review Mode

When the review view appears, `@FocusState` automatically transfers keyboard focus to the TextEditor via `.onAppear` with a 50ms delay (lets the panel finish becoming key first). This means the user can immediately hit Enter to inject or start editing — no clicking required.

### Positioning

`showPanel(near:)` uses `AccessibilityBridge.focusedTextFieldRect(for:)` to position the overlay above the user's focused text field in the target app. Falls back to mouse cursor position if no valid text field is detected (e.g., terminal emulators like iTerm2 that report oversized text areas). Screen-clamps the panel to the current monitor's visible frame to prevent off-screen positioning on multi-monitor setups.

### Dynamic Sizing

`resizePanel(to:)` grows the panel upward (bottom edge anchored) as streaming text grows. Height range: 160px (`panelMinHeight`) to 340px (`panelMaxHeight`).

## DraftSessionController — Session Orchestration

Lives in `DraftSessionController.swift`. Manages the complete flow:

### Property Safety

`appState` and `overlayController` are **Optional** (not IUOs). Every public method starts with:
```swift
guard let appState = appState, let overlayController = overlayController else { return }
```
This prevents crashes if a hotkey fires before `applicationDidFinishLaunching` wires them.

### Task Lifecycle

`visionTask` and `streamingTask` are always **cancelled before replacement**:
```swift
visionTask?.cancel()
visionTask = Task { ... }
```
Without this, rapid hotkey taps create orphaned tasks that both write to the overlay.

### Session Lifecycle

```
startSession()          — option+D first press: clear state, show overlay, start voice + vision in parallel
stopSessionAndDraft()   — option+D second press: stop voice, await vision, build prompt, stream draft
confirmAndInject()      — Enter in review: hide overlay (shrink animation), paste to target app, record training pair
cancelSession()         — Escape or option+D during any state: hide overlay (shake animation), discard draft
startDictation()        — option+Space first press: show overlay, start voice recording (no screenshot)
stopDictationAndPaste() — option+Space second press: stop voice, batch transcribe, paste directly
cancelDictation()       — Escape during dictation: hide overlay (shake animation), discard
```

### Vision Processing

Vision processing (`processVision()`) uses `LocalVisionExtractor` (Apple Vision OCR) to extract text from the screenshot. This runs in a parallel `Task` stored as `visionTask`. When the user stops speaking, `stopSessionAndDraft()` **awaits `visionTask?.value`** before checking `lastCapturedContext`. This ensures vision results are available even when the user speaks quickly. The vision call has a timeout via `DraftConstants.withTimeout()`.

### Streaming via MLXEngine

`DraftSessionController` calls `MLXEngine.generate()` for streaming token-by-token draft output. Tokens are fed to the overlay via `overlayController.appendStreamToken()` as they arrive. The first token triggers the `.streaming` state transition.

### Error Display

`FloatingOverlayController.showError()` briefly displays an error message in the overlay (reusing the `.drafting` state), then auto-hides after ~1.5 seconds with a cancel animation. Used for transient errors like "No speech detected", "Microphone unavailable", "Voice model loading...", and "Audio device changed". The dismiss task is cancelled before replacement to prevent stale timers.

### Audio Device Interruption

`DraftSessionController` subscribes to `STTRouter.recordingInterrupted` via Combine. When the audio device changes mid-session (e.g., headphones unplugged), it cancels all pending tasks (vision + streaming), clears session state, and calls `showError("Audio device changed")`.

### No-Context Fallback

If vision fails or times out, the fallback prompt asks the model to "clean up and polish the dictation" rather than "write a reply" — the latter confuses the model when there's no conversation context.

### Refusal Detection

`looksLikeRefusal()` checks if a draft contains phrases like "I need the actual message" or "could you provide". If detected, the training pair is NOT recorded to prevent poisoning the style profile.

### Clipboard Safety

`pasteWithClipboardRestore()` saves the user's clipboard contents before setting the draft text, simulates Cmd+V, then restores the original clipboard. Uses `NSPasteboard.changeCount` polling (every 50ms) with a 2-second timeout — some apps write back to the clipboard on paste, which triggers early restore. Falls back to the timeout for apps that don't modify the clipboard. The target app stays frontmost (overlay is non-activating), so no app activation polling is needed.

## Three-Way Hotkey Routing

The Carbon hotkey callback in `ContextCaptureEngine.swift` routes to `DraftSessionController`:

**option+D (Draft mode -- hotkey ID 1):**

| Session State | Action |
|---------------|--------|
| Not in session | `startSession(imageData:sourceApp:)` |
| Listening/drafting/streaming | `stopSessionAndDraft()` |
| Review | `cancelSession()` |

**option+Space (Dictation mode -- hotkey ID 2):**

| Session State | Action |
|---------------|--------|
| Not dictating | `startDictation(sourceApp:)` |
| Dictating | `stopDictationAndPaste()` |

## Keyboard Shortcuts (Overlay)

- **Enter** — Inject draft to target app (review mode)
- **Shift+Enter** — Insert newline (review mode)
- **Escape** — Cancel session/dictation (works in ALL states: listening, drafting, streaming, review)
- **option+D** — Start draft / stop recording / cancel during review
- **option+Space** — Start dictation / stop and paste

### Key Implementation Details

**Enter vs Shift+Enter:** Uses `.onKeyPress(keys: [.return], phases: .down)` (not the simpler `onKeyPress(.return)`) because the `keys:phases:` variant passes the full `KeyPress` object with `.modifiers` — needed to distinguish Enter from Shift+Enter.

**Escape in non-key states:** The panel is non-key during listening/drafting/streaming (`allowKeyStatus = false`), so SwiftUI `.onKeyPress` can't receive keyboard events. A **global event monitor** (`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`) intercepts Escape (keyCode 53) and routes to `cancelSession()`/`cancelDictation()` via the `onEscapeDuringSession` closure. The monitor is installed when the overlay shows and removed when it hides. In review mode, the panel is key-capable and SwiftUI's `.onKeyPress` handles Escape directly.

## Animation System

**Entrance:** Spring animation (scale 0.88 -> 1.0 via `CASpringAnimation`) + 200ms fade-in on `showPanel()`.

Two hide animations signal different outcomes:

- **Confirm** (`hideWithConfirmAnimation`) — Scale down + fade. Signals "your text was sent."
- **Cancel** (`hideWithCancelAnimation`) — Horizontal shake + fade. Signals "nothing happened."

Both set `panel.ignoresMouseEvents = true` before animating to prevent gesture dispatch crashes during teardown. Shake animation closures capture `[weak panel]` to prevent crashes if the panel deallocates during the ~340ms animation sequence.

### Double-Setup Guard

`FloatingOverlayController.setup()` guards with `panel == nil` — calling it twice would leak the old NSPanel and NSHostingView.

## MenuBarPanel — Configuration UI

Single-pane menubar popover (440x520, `MenuTokens` design tokens) with a continuous ScrollView. No tabs — all content is visible in one vertical flow:

1. **Header** — "Draft" title + status dot (green = model loaded, orange = loading)
2. **Stats** — Three-column HStack: words dictated, messages drafted, time saved. Data from `FeedbackStore.stats`, refreshed on `.onAppear`
3. **Shortcuts** — Pill-shaped badges showing `option+D Draft` and `option+Space Dictation`
4. **Writing Style** — Section header with example count badge + expandable card. Shows compact preview of `style.md` (extracted from "## Style Summary" section, up to 6 lines), expands to full scrollable content with "Show more/Show less" toggle. Empty state: "Accept a draft to start learning your style"
5. **Agent** — `AgentSection` (from `AgentTab.swift`): pending insight cards with Apply/Skip actions

Additional features:
- **Onboarding gate** — `StyleOnboardingView` overlay (no auth setup needed — all inference is local)
- **Settings gear** — top-right overlay button with popover: name field, transcription engine info (Parakeet CoreML with download progress), Quit button

### NSHostingController Lifecycle

The `NSHostingController` is **recreated on every popover open** inside `DraftAppDelegate.togglePopover()` in `DraftApp.swift`:

```swift
@objc func togglePopover() {
    guard let button = statusItem?.button, let popover = popover else { return }
    if popover.isShown {
        popover.performClose(nil)
    } else {
        // Recreate the hosting controller each time to guarantee a fresh SwiftUI
        // view tree. A long-lived NSHostingController accumulates stale observation
        // state across show/hide cycles, eventually crashing in body evaluation.
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(appState: appState)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

This guarantees a fresh SwiftUI view tree on each open. A long-lived `NSHostingController` accumulates stale observation state across show/hide cycles and can crash in body evaluation. Do NOT cache the hosting controller or use `.id()` tricks (e.g., a `popoverGeneration` counter) — a `.id()` change on the root view triggers an infinite `.onAppear` -> re-layout -> `.onAppear` loop. Just recreate the controller.

## AgentSection — Defensive Card ID Capture

`AgentSection` (in `AgentTab.swift`) captures the card's `id` value type into a local `let cardId` variable before the button closures, rather than closing over the full `card` struct:

```swift
let cardId = card.id
// ...
Button("Skip") {
    guard let live = orchestrator.insights.first(where: { $0.id == cardId }) else { return }
    orchestrator.skip(live)
}
Button(action: {
    guard let live = orchestrator.insights.first(where: { $0.id == cardId }) else { return }
    orchestrator.apply(live)
}) { ... }
```

**Why:** `orchestrator.insights` is a `@Published` array on an `ObservableObject`. When the array mutates (a card is applied/skipped, which triggers a re-render), button closures that closed over the full `card` struct may hold a reference to a now-stale or removed element. Capturing only the `id` and then doing a live lookup (`first(where:)`) inside the closure guarantees the button always acts on the current version of the card. The `guard let` protects against the card having already been removed between render and tap.

## StyleOnboardingView

5-step flow as a full-screen overlay (two branching paths after source choice):

```
.intro -> .sourceChoice -> .imessagePreview (if iMessage) -> .result
                         \ .samples (if manual paste)     -> .result
```

Takes `styleEngine: StyleEngine` and `localInference: LocalInferenceManager` parameters.

1. **Intro** — Welcome message, name input field (saved to UserDefaults for vision identity)
2. **Source Choice** — Two cards: "Import from iMessages" (recommended) or "Paste Samples Manually"
3a. **iMessage Preview** — Read-only ScrollView showing loaded messages via `iMessageReader`, privacy notice, "Analyze These Messages" button. Includes expandable "Add Slack, email, or other writing samples" section.
3b. **Samples** — Large TextEditor for pasting writing samples, word count indicator, "Build My Profile" button
4. **Result** — Shows generated profile (analyzed locally via MLXEngine), "Looks Good" to accept, "Add More & Regenerate" goes back

All analysis runs on-device via `StyleEngine.importBulkSamples(rawText:draftEngine:)` which uses `MLXEngine` for local inference. No external API calls.

## Verification

After modifying UI components, verify with these checks:

- **Full draft flow:** option+D over Slack -> speak -> option+D -> tokens stream -> draft appears editable -> Enter -> text pasted to Slack
- **Full dictation flow:** option+Space -> speak -> option+Space -> text pasted directly
- **Auto-focus:** After draft streams in, cursor should be blinking in the TextEditor without clicking
- **Enter/Escape:** Enter injects, Escape cancels, Shift+Enter inserts newline
- **Escape during listening:** option+D to start -> Escape -> overlay shakes and disappears (no crash)
- **Escape during dictation:** option+Space to start -> Escape -> overlay shakes and disappears
- **Escape during streaming:** option+D -> speak -> option+D -> while tokens streaming, Escape -> cancels cleanly
- **Double hotkey tap:** Rapidly press option+D twice -> should not create parallel streaming tasks
- **Vision context:** Check debug log — `"vision complete"` should appear BEFORE `"streaming draft"`, and `context: yes` in the streaming log
- **Cancel during review:** option+D while draft is showing -> overlay hides (shake animation), nothing injected
- **Paste-back:** Draft injected into correct target app (overlay is non-activating)
- **Stats section:** Opens menubar panel -> words dictated, messages drafted, time saved are visible
- **Style section:** Shows style.md preview in expandable card; "Show more" expands full content
- **Agent section:** Insight cards appear with Apply/Skip buttons
- **Rapid menubar clicking:** Click the menubar icon quickly multiple times -> should NOT cause hangs, spinning beachballs, or crashes. Each open recreates the hosting controller cleanly; closing before re-opening calls `performClose` which is synchronous and safe.
- **Debug log:** `tail -f ~/draft-debug.log | grep "SESSION\|DICTATION\|REVIEW"` shows all events
- **Build:** `bash build.sh` -- must compile cleanly (pre-existing warnings only: CGWindowListCreateImage deprecation, `_performHide()` actor isolation in animation callbacks)
