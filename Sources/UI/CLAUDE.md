# UI Components

## What This Does

SwiftUI views for the Draft app. The primary UI is a **floating overlay** (non-activating NSPanel) that appears over the user's current app for the hotkey → speak → draft → review → inject flow. A **menubar popover** hosts a single-pane layout with status, usage stats, shortcut pills, writing style, and agent section.

## Key Files

- `FloatingOverlayPanel.swift` (~38 lines) — NSPanel subclass (non-activating, dynamic key status)
- `FloatingOverlayController.swift` (~363 lines) — State machine, animations, panel lifecycle, global Escape monitor
- `OverlayContentView.swift` (~253 lines) — SwiftUI views for all 5 overlay states (idle/listening/drafting/streaming/review)
- `DraftSessionController.swift` (~494 lines) — Session orchestration for draft mode (⌥D) and dictation mode (⌥Space)
- `OverlayTokens.swift` (~49 lines) — Design tokens: `OverlayTokens` for floating overlay (translucent dark), `MenuTokens` for menubar panel (system-adaptive colors, layout constants)
- `PanelDragView.swift` (~23 lines) — AppKit drag helper (mouseDown → performDrag)
- `MenuBarPanel.swift` (~335 lines) — Single-pane menubar popover (440x520): header (status dot), usage stats, shortcut pills, writing style (compact/expandable), agent section, onboarding gates, settings gear
- `StyleProfileView.swift` (~51 lines) — DEPRECATED: style display is now inlined in MenuBarPanel.swift. Kept for reference only.
- `AgentTab.swift` (~277 lines) — `AgentSection` struct: simplified insight cards (Apply/Skip) + streaming chat interface
- `StyleOnboardingView.swift` (664 lines) — 5-step onboarding: intro → source choice → (iMessage/paste) → result
- `APIKeyEntryView.swift` (231 lines) — Auth setup overlay: name + API key or subscription token
- `InsightCard.swift` (71 lines) — Model for insight cards + shared `toolDefinition` and `from()` factory (used by both StreamingChatEngine and AnalysisEngine)
- `AudioWaveformView.swift` (63 lines) — Animated waveform bars driven by `STTRouter.audioLevel`
- `ScrollingWaveformView.swift` (147 lines) — Real-time scrolling waveform for overlay header bar, Canvas + TimelineView at 60fps, ring buffer for audio level samples
- `AnimatedTranscriptView.swift` (81 lines) — Animated live transcript text display during recording
- `ChatMessage.swift` (32 lines) — Model for chat messages in AgentSection
- `AppLogger.swift` (92 lines) — Debug logger writing to `~/draft-debug.log` with timestamps
- `PreviousAppTracker.swift` (25 lines) — Tracks last non-Draft app for paste-back fallback

## Architecture Overview

```
FloatingOverlay (hotkey flow)          MenuBarPanel (configuration)
┌──────────────────────────┐          ┌───────────────────────────┐
│ FloatingOverlayPanel     │          │ Single-pane ScrollView    │
│ (NSPanel, non-activating)│          │ ├── Header (status dot)   │
│                          │          │ ├── Stats (words/msgs)    │
│ States:                  │          │ ├── Shortcuts (⌥D / ⌥Space)│
│ idle → listening →       │          │ ├── Writing Style (card)  │
│ drafting → streaming →   │          │ └── AgentSection (cards+chat)│
│ review                   │          │                           │
├──────────────────────────┤          │ Onboarding gates:         │
│ DraftSessionController   │          │ APIKeyEntryView (overlay) │
│ (orchestrates full flow) │          │ StyleOnboardingView       │
└──────────────────────────┘          └───────────────────────────┘
```

## FloatingOverlay — The Primary UI (v2)

### Panel Architecture

`FloatingOverlayPanel` is an NSPanel subclass with these key properties:
- **Non-activating** (`.nonactivatingPanel`) — the target app stays frontmost, so paste works without re-activation
- **Dynamic key status** — `canBecomeKey` returns `allowKeyStatus`, which is `false` during listening/drafting (keyboard stays with target app) and `true` during review (TextEditor needs keyboard input)
- **Floating level** — always above other windows, across all spaces

### State Machine

```
idle → listening → drafting → streaming → review → idle
  ↑         ↓          ↓           ↓          ↓
  └─────── (Escape cancels from any active state) ──┘
```

| State | Trigger | UI | Key Status | Escape Handling |
|-------|---------|-----|------------|-----------------|
| `idle` | Session end/cancel | Hidden | false | — |
| `listening` | ⌥D/⌥Space (start) | Waveform + live transcription | false | Global monitor → cancel |
| `drafting` | ⌥D/⌥Space (stop) | Spinner + "Drafting..." | false | Global monitor → cancel |
| `streaming` | First API token | Green dot + tokens appearing | false | Global monitor → cancel |
| `review` | Stream complete | Editable TextEditor + hint bar | true | SwiftUI .onKeyPress → cancel |

**State transition guards:** `startStreaming()` requires `.drafting` or `.listening`, `appendStreamToken()` requires `.streaming`, `finishStreaming()` requires `.streaming`. This prevents the overlay from entering `.review` when not actually streaming.

### Auto-Focus in Review Mode

When the review view appears, `@FocusState` automatically transfers keyboard focus to the TextEditor via `.onAppear` with a 50ms delay (lets the panel finish becoming key first). This means the user can immediately hit Enter to inject or start editing — no clicking required.

### Positioning

`show(near:)` uses `AccessibilityBridge.focusedTextFieldRect(for:)` to position the overlay near the user's cursor in the target app. Falls back to screen center if no text field is detected.

### Dynamic Sizing

`resizePanel(to:)` grows the panel upward (bottom edge anchored) as streaming text grows. Height range: 120px (listening) to 280px (review).

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
startSession()          — ⌥D first press: clear state, show overlay, start voice + vision in parallel
stopSessionAndDraft()   — ⌥D second press: stop voice, await vision, build prompt, stream draft
confirmAndInject()      — Enter in review: hide overlay (shrink animation), paste to target app, record training pair
cancelSession()         — Escape or ⌥D during any state: hide overlay (shake animation), discard draft
startDictation()        — ⌥Space first press: show overlay, start voice recording (no screenshot)
stopDictationAndPaste() — ⌥Space second press: stop voice, transcribe, polish, paste
cancelDictation()       — Escape during dictation: hide overlay (shake animation), discard
```

### Vision Race Condition Fix

Vision processing (`processVision()`) runs in a parallel `Task` stored as `visionTask`. When the user stops speaking, `stopSessionAndDraft()` **awaits `visionTask?.value`** before checking `lastCapturedContext`. This ensures vision results are available even when the user speaks quickly. The vision call has an 8-second timeout via `AnthropicAPI.withTimeout(seconds: 8)`.

### No-Context Fallback

If vision fails or times out, the fallback prompt asks Claude to "clean up and polish the dictation" rather than "write a reply" — the latter confuses Claude when there's no conversation context.

### Refusal Detection

`looksLikeRefusal()` checks if a draft contains phrases like "I need the actual message" or "could you provide". If detected, the training pair is NOT recorded to prevent poisoning the style profile.

### Clipboard Safety

`pasteWithClipboardRestore()` saves the user's clipboard contents before setting the draft text, simulates Cmd+V, then restores the original clipboard after 500ms. The target app stays frontmost (overlay is non-activating), so no app activation polling is needed.

## Three-Way Hotkey Routing

The Carbon hotkey callback in `ContextCaptureEngine.swift` routes to `DraftSessionController`:

**⌥D (Draft mode — hotkey ID 1):**

| Session State | Action |
|---------------|--------|
| Not in session | `startSession(imageData:sourceApp:)` |
| Listening/drafting/streaming | `stopSessionAndDraft()` |
| Review | `cancelSession()` |

**⌥Space (Dictation mode — hotkey ID 2):**

| Session State | Action |
|---------------|--------|
| Not dictating | `startDictation(sourceApp:)` |
| Dictating | `stopDictationAndPaste()` |

## Keyboard Shortcuts (Overlay)

- **Enter** — Inject draft to target app (review mode)
- **Shift+Enter** — Insert newline (review mode)
- **Escape** — Cancel session/dictation (works in ALL states: listening, drafting, streaming, review)
- **⌥D** — Start draft / stop recording / cancel during review
- **⌥Space** — Start dictation / stop and paste

### Key Implementation Details

**Enter vs Shift+Enter:** Uses `.onKeyPress(keys: [.return], phases: .down)` (not the simpler `onKeyPress(.return)`) because the `keys:phases:` variant passes the full `KeyPress` object with `.modifiers` — needed to distinguish Enter from Shift+Enter.

**Escape in non-key states:** The panel is non-key during listening/drafting/streaming (`allowKeyStatus = false`), so SwiftUI `.onKeyPress` can't receive keyboard events. A **global event monitor** (`NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`) intercepts Escape (keyCode 53) and routes to `cancelSession()`/`cancelDictation()` via the `onEscapeDuringSession` closure. The monitor is installed when the overlay shows and removed when it hides. In review mode, the panel is key-capable and SwiftUI's `.onKeyPress` handles Escape directly.

## Animation System

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
3. **Shortcuts** — Pill-shaped badges showing `⌥D Draft` and `⌥Space Dictation`
4. **Writing Style** — Section header with example count badge + expandable card. Shows compact preview of `style.md` (extracted from "## Style Summary" section, up to 6 lines), expands to full scrollable content with "Show more/Show less" toggle. Empty state: "Accept a draft to start learning your style"
5. **Agent** — `AgentSection` (from `AgentTab.swift`): insight cards + streaming chat interface

Additional features:
- **Onboarding gates** — sequential ZStack overlays: `APIKeyEntryView` → `StyleOnboardingView`
- **Settings gear** — top-right overlay button with popover: name field, transcription engine info (Parakeet CoreML with download progress), auth mode display + "Switch Auth Method", Quit button

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

This guarantees a fresh SwiftUI view tree on each open. A long-lived `NSHostingController` accumulates stale observation state across show/hide cycles and can crash in body evaluation. Do NOT cache the hosting controller or use `.id()` tricks (e.g., a `popoverGeneration` counter) — a `.id()` change on the root view triggers an infinite `.onAppear` → re-layout → `.onAppear` loop. Just recreate the controller.

## InsightCard

Model struct for agent-proposed prompt changes. The card UI in `AgentSection` is simplified: shows only the `promptKeyLabel`, `changeDescription`, and Apply/Skip buttons (no SAW/WHY/CHANGE labels). The full data (saw, why, currentValue, proposedValue) is still stored for programmatic use by `AnalysisEngine.apply()`.

Key addition: **shared `toolDefinition` and `from()` factory** used by both `StreamingChatEngine` and `AnalysisEngine` — eliminates tool definition duplication.

```swift
static let toolDefinition: [String: Any]                    // Anthropic tool schema for propose_prompt_change
static func from(toolId: String, input: [String: Any]) -> InsightCard?  // Parse tool call into card
```

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
.intro → .sourceChoice → .imessagePreview (if iMessage) → .result
                       ↘ .samples (if manual paste)     → .result
```

1. **Intro** — Welcome message, name input field (saved to UserDefaults for vision identity)
2. **Source Choice** — Two cards: "Import from iMessages" (recommended) or "Paste Samples Manually"
3a. **iMessage Preview** — Read-only ScrollView showing loaded messages, privacy notice, "Analyze These Messages" button. Includes expandable "Add Slack, email, or other writing samples" section.
3b. **Samples** — Large TextEditor for pasting writing samples, word count indicator, "Build My Profile" button
4. **Result** — Shows generated profile, "Looks Good" to accept, "Add More & Regenerate" goes back

## Auth Setup Flow

1. On launch, if `drafter.hasCredential` is false → `APIKeyEntryView` overlay appears
2. Overlay shows name input + segmented picker (API Key / Claude Subscription)
3. API Key tab: `SecureField` for `sk-ant-...` with prefix validation
4. Subscription tab: step-by-step instructions for `claude setup-token` + paste field
5. "Connect" saves to Keychain → overlay dismisses
6. Gear icon → popover shows current auth mode + "Switch Auth Method" → clears Keychain → overlay reappears

## PreviousAppTracker

Observes `NSWorkspace.didDeactivateApplicationNotification` to remember the last non-Draft app. Used as fallback for source app in paste-back. Hardcoded bundle ID fallback (`com.justinbetker.draft`) since `Bundle.main.bundleIdentifier` can be nil for swiftc-built apps.

## Verification

After modifying UI components, verify with these checks:

- **Full draft flow:** ⌥D over Slack → speak → ⌥D → tokens stream → draft appears editable → Enter → text pasted to Slack
- **Full dictation flow:** ⌥Space → speak → ⌥Space → text pasted directly
- **Auto-focus:** After draft streams in, cursor should be blinking in the TextEditor without clicking
- **Enter/Escape:** Enter injects, Escape cancels, Shift+Enter inserts newline
- **Escape during listening:** ⌥D to start → Escape → overlay shakes and disappears (no crash)
- **Escape during dictation:** ⌥Space to start → Escape → overlay shakes and disappears
- **Escape during streaming:** ⌥D → speak → ⌥D → while tokens streaming, Escape → cancels cleanly
- **Double hotkey tap:** Rapidly press ⌥D twice → should not create parallel streaming tasks
- **Vision context:** Check debug log — `"vision complete"` should appear BEFORE `"streaming draft"`, and `context: yes` in the streaming log
- **Cancel during review:** ⌥D while draft is showing → overlay hides (shake animation), nothing injected
- **Paste-back:** Draft injected into correct target app (overlay is non-activating)
- **Onboarding gates:** Gear → "Switch Auth Method" → auth overlay appears
- **Stats section:** Opens menubar panel → words dictated, messages drafted, time saved are visible
- **Style section:** Shows style.md preview in expandable card; "Show more" expands full content
- **Agent section:** Insight cards appear with Apply/Skip buttons; chat interface works
- **Rapid menubar clicking:** Click the menubar icon quickly multiple times — should NOT cause hangs, spinning beachballs, or crashes. Each open recreates the hosting controller cleanly; closing before re-opening calls `performClose` which is synchronous and safe.
- **Debug log:** `tail -f ~/draft-debug.log | grep "SESSION\|DICTATION\|REVIEW"` shows all events
- **Build:** `bash build.sh` — must compile cleanly (pre-existing warnings only: CGWindowListCreateImage deprecation, `_performHide()` actor isolation in animation callbacks)
