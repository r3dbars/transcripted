# UI Components

## What This Does

SwiftUI views for the Draft app. The primary UI is a **floating overlay** (non-activating NSPanel) that appears over the user's current app for the hotkey → speak → draft → review → inject flow. A **menubar popover** hosts the Style Profile and Agent tabs for configuration.

## Key Files

- `FloatingOverlay.swift` (609 lines) — The core v2 UI: `FloatingOverlayPanel` (NSPanel), `FloatingOverlayController` (state machine), `OverlayContentView` (SwiftUI views for listening/streaming/review), `DraftSessionController` (full session orchestration)
- `MenuBarPanel.swift` (98 lines) — Menubar popover with TabView (Style + Agent), onboarding gates, settings gear
- `StyleProfileView.swift` (49 lines) — Extracted style tab showing style.md contents
- `AgentTab.swift` (423 lines) — Agent insight cards (Apply/Skip) + streaming chat interface
- `StyleOnboardingView.swift` (664 lines) — 5-step onboarding: intro → source choice → (iMessage/paste) → result
- `APIKeyEntryView.swift` (231 lines) — Auth setup overlay: name + API key or subscription token
- `InsightCard.swift` (71 lines) — Model for insight cards + shared `toolDefinition` and `from()` factory (used by both StreamingChatEngine and AnalysisEngine)
- `AudioWaveformView.swift` (27 lines) — Animated waveform bars driven by `SpeechEngine.audioLevel`
- `ChatMessage.swift` (32 lines) — Model for chat messages in AgentTab
- `AppLogger.swift` (92 lines) — Debug logger writing to `~/draft-debug.log` with timestamps
- `PreviousAppTracker.swift` (25 lines) — Tracks last non-Draft app for paste-back fallback

## Architecture Overview

```
FloatingOverlay (hotkey flow)          MenuBarPanel (configuration)
┌──────────────────────────┐          ┌───────────────────────────┐
│ FloatingOverlayPanel     │          │ TabView                   │
│ (NSPanel, non-activating)│          │ ├── StyleProfileView      │
│                          │          │ └── AgentTab              │
│ States:                  │          │                           │
│ idle → listening →       │          │ Onboarding gates:         │
│ drafting → streaming →   │          │ APIKeyEntryView (overlay) │
│ review                   │          │ StyleOnboardingView       │
├──────────────────────────┤          └───────────────────────────┘
│ DraftSessionController   │
│ (orchestrates full flow) │
└──────────────────────────┘
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
                                              ↓
                                           (cancel)
                                              ↓
                                            idle
```

| State | Trigger | UI | Key Status |
|-------|---------|-----|------------|
| `idle` | Session end/cancel | Hidden | false |
| `listening` | ⌥Space (start) | Waveform + live transcription | false |
| `drafting` | ⌥Space (stop) | Spinner + "Drafting..." | false |
| `streaming` | First API token | Purple dot + tokens appearing | false |
| `review` | Stream complete | Editable TextEditor + hint bar | true |

### Auto-Focus in Review Mode

When the review view appears, `@FocusState` automatically transfers keyboard focus to the TextEditor via `.onAppear` with a 50ms delay (lets the panel finish becoming key first). This means the user can immediately hit Enter to inject or start editing — no clicking required.

### Positioning

`show(near:)` uses `AccessibilityBridge.focusedTextFieldRect(for:)` to position the overlay near the user's cursor in the target app. Falls back to screen center if no text field is detected.

### Dynamic Sizing

`resizePanel(to:)` grows the panel upward (bottom edge anchored) as streaming text grows. Height range: 120px (listening) to 280px (review).

## DraftSessionController — Session Orchestration

Lives inside `FloatingOverlay.swift`. Manages the complete flow:

### Session Lifecycle

```
startSession()          — ⌥Space first press: clear state, show overlay, start voice + vision in parallel
stopSessionAndDraft()   — ⌥Space second press: stop voice, await vision, build prompt, stream draft
confirmAndInject()      — Enter in review: hide overlay, paste to target app, record training pair
cancelSession()         — Escape or ⌥Space during review: hide overlay, discard draft
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

| Session State | ⌥Space Action |
|---------------|---------------|
| Not in session | `startSession(imageData:sourceApp:)` |
| Listening/drafting/streaming | `stopSessionAndDraft()` |
| Review | `cancelSession()` |

## Keyboard Shortcuts (Overlay)

- **Enter** — Inject draft to target app (review mode)
- **Shift+Enter** — Insert newline (review mode)
- **Escape** — Cancel session (review mode)
- **⌥Space** — Start session / stop recording / cancel during review

### Key Implementation Detail

Uses `.onKeyPress(keys: [.return], phases: .down)` (not the simpler `onKeyPress(.return)`) because the `keys:phases:` variant passes the full `KeyPress` object with `.modifiers` — needed to distinguish Enter from Shift+Enter.

## MenuBarPanel — Configuration UI

Menubar popover with:
- **Style tab** (`StyleProfileView`) — read-only display of style.md contents
- **Agent tab** (`AgentTab`) — insight cards from AnalysisEngine, streaming chat interface
- **Onboarding gates** — sequential overlays: `APIKeyEntryView` → `StyleOnboardingView`
- **Settings gear** — popover with name field, auth switch, quit button

## InsightCard

Model struct for agent-proposed prompt changes. Key addition: **shared `toolDefinition` and `from()` factory** used by both `StreamingChatEngine` and `AnalysisEngine` — eliminates tool definition duplication.

```swift
static let toolDefinition: [String: Any]                    // Anthropic tool schema for propose_prompt_change
static func from(toolId: String, input: [String: Any]) -> InsightCard?  // Parse tool call into card
```

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

- **Full overlay flow:** ⌥Space over Slack → speak → ⌥Space → tokens stream → draft appears editable → Enter → text pasted to Slack
- **Auto-focus:** After draft streams in, cursor should be blinking in the TextEditor without clicking
- **Enter/Escape:** Enter injects, Escape cancels, Shift+Enter inserts newline
- **Vision context:** Check debug log — `"vision complete"` should appear BEFORE `"streaming draft"`, and `context: yes` in the streaming log
- **Cancel during review:** ⌥Space while draft is showing → overlay hides, nothing injected
- **Paste-back:** Draft injected into correct target app (overlay is non-activating)
- **Onboarding gates:** Gear → "Switch Auth Method" → auth overlay appears
- **Style tab:** Shows style.md contents in menubar popover
- **Agent tab:** Insight cards appear with Apply/Skip buttons; chat interface works
- **Debug log:** `tail -f ~/draft-debug.log | grep "SESSION\|REVIEW"` shows all events
- **Build:** `bash build.sh` — must compile cleanly (only warning: CGWindowListCreateImage deprecation)
