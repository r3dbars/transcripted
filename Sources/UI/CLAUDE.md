# UI Components

## What This Does

SwiftUI views for the Draft app — input area, voice controls, context capture, Draft button, polished output display, style profile viewer, style onboarding, and API key entry.

## Key Files

- `ContentView.swift` — Main app view with `ContentView` (owns all engines, onboarding gates) and `DraftTab` (the primary drafting interface)
- `StyleOnboardingView.swift` — 3-step onboarding flow: intro (name) → paste writing samples → profile result
- `APIKeyEntryView.swift` — Overlay shown on first launch to enter Anthropic API key
- `PreviousAppTracker.swift` — Tracks which app the user was in before switching to Draft
- `AppLogger.swift` — Debug logger with in-app log panel and file output

## App Launch Flow (Sequential Gates)

```
Launch
  ↓
Has API key? ──No──→ APIKeyEntryView (overlay)
  │ Yes
  ↓
Completed style onboarding? ──No──→ StyleOnboardingView (overlay)
  │ Yes
  ↓
Main App (TabView: Draft tab + Style tab)
```

Both gates are overlays on top of the TabView. Once cleared, they don't reappear (API key in Keychain, onboarding flag in UserDefaults).

## ContentView Structure

`ContentView` owns all engines as `@StateObject` and wires them together:
- `SpeechEngine`, `DraftEngine`, `StyleEngine`, `AppLogger`, `PreviousAppTracker`, `ContextCaptureEngine`

`DraftTab` is an extracted struct that receives all engines as `@ObservedObject` and contains the main drafting UI.

## Layout Structure

```
┌─────────────────────────────────────────┐
│ Draft           [Capturing...]    ⚙️    │  ← Header + capture status + settings
├─────────────────────────────────────────┤
│ Context              [Capture Screen]   │  ← Context label + capture button + ⌃⌥D hint
├─────────────────────────────────────────┤
│ PLATFORM: Slack                         │
│ TALKING TO: Sarah Graham                │
│ FORMALITY: casual                       │  ← Input TextEditor with labeled context sections
│                                         │
│ CONVERSATION:                           │
│ Sarah: Hey, are you free for lunch?     │
│ You: ...                                │
│                                         │
│ YOUR INSTRUCTIONS:                      │
│ [voice transcription / typed text]      │
├─────────────────────────────────────────┤
│ 🔴 "listening text here..."             │  ← Voice indicator (when recording)
├─────────────────────────────────────────┤
│ [⌘R Record] [✨ Draft]        [Clear]  │  ← Controls
├─────────────────────────────────────────┤
│ Drafted Message     [Copy] [Paste to…] │
│ "Polished text from Haiku..."           │  ← Output area (purple tint, editable)
├─────────────────────────────────────────┤
│ ▶ Debug Log (N)                         │  ← Collapsible debug panel
└─────────────────────────────────────────┘
```

Second tab: **Style Profile** — shows style.md contents (summary + examples).

## Keyboard Shortcuts

- **Enter** (in input area) — Triggers Draft (sends to Haiku)
- **Enter** (in output area) — Pastes drafted message to source app
- **Shift+Enter** — Inserts newline (in both text areas)
- **⌘R** — Toggle Record/Stop voice input
- **Ctrl+Option+D** — Global hotkey: capture screen context (works from any app)

### Enter Key Implementation

Uses `.onKeyPress(keys: [.return], phases: .down)` on both TextEditors. The `keys:phases:` variant is required (not the simpler `onKeyPress(.return)`) because it passes the full `KeyPress` object with `.modifiers` — needed to distinguish Enter from Shift+Enter.

Input and output TextEditors are extracted into `inputAreaView` and `outputAreaView` `@ViewBuilder` computed properties. This was necessary because Swift's type-checker couldn't handle the complexity of inline `.onKeyPress` closures within the main `body`.

### Auto-Focus Output

When `drafter.draftedText` changes (draft completes), `isOutputFocused` is set to `true` via `.onChange(of:)`, moving the cursor into the output TextEditor automatically. This enables the flow: speak → Enter → (draft appears) → cursor is already in output → edit → Enter → pasted.

## Source App Paste-Back

### How It Works

1. **Hotkey callback** stores `contextCapture.sourceApp` (the exact `NSRunningApplication` that was screenshotted)
2. **`pasteTargetApp`** computed property: returns `contextCapture.sourceApp ?? previousAppTracker.previousApp`
3. **Button label** shows the actual app name: "Paste to Messages", "Paste to Slack", etc.
4. **Paste flow:**
   - Copy text to `NSPasteboard`
   - Activate the target app via `app.activate()`
   - **Poll for activation** via `waitForActivation(of:attempt:then:)` — checks `app.isActive` every 100ms, up to 15 attempts (1.5s timeout)
   - Once active, simulate ⌘V via `CGEvent`
5. **Record example** — After pasting, calls `styleEngine.recordExample()` to save for style learning

### Why Polling Instead of Fixed Delay

A fixed 300ms delay was unreliable — app activation timing varies by system load, app state, and whether the app needs to come to the foreground from minimized. Polling `app.isActive` at 100ms intervals adapts to the actual activation speed.

## Parallel Voice + Vision Pipeline

When the hotkey fires:
1. `onHotkeyFired` callback starts voice recording immediately
2. Vision processing runs in parallel (takes 1-3 seconds)
3. When context arrives via `onContextCaptured`, it's injected into `inputText` as labeled sections
4. Voice transcription continues appending after "YOUR INSTRUCTIONS:" label
5. User can speak their instructions while Haiku is still analyzing the screenshot

## State Coordination

- Speech output syncs to `inputText` via `.onChange(of:)` — `finalTranscript` and `volatileText` both update the TextEditor
- Context capture fills `inputText` via `onContextCaptured` callback, prepends labeled sections
- `@FocusState` on both TextEditors for cursor management
- Style examples recorded when user hits Copy or "Paste to [App]"
- Style summary auto-regenerates every 5 accepted examples

## StyleOnboardingView

3-step flow as a full-screen overlay:

1. **Intro** — Welcome message, name input field (saved to UserDefaults for vision identity)
2. **Samples** — Large TextEditor for pasting writing samples, word count indicator, "Build My Profile" button, "Skip for Now" option
3. **Result** — Shows generated profile, "Looks Good" to accept, "Add More & Regenerate" to iterate

Uses `StyleEngine.importBulkSamples()` for analysis and `StyleEngine.completeOnboarding()` on accept/skip.

## PreviousAppTracker

Observes `NSWorkspace.didDeactivateApplicationNotification` to remember the last non-Draft app. Used as fallback when no source app is stored from a hotkey capture:
- Manual capture button (captures previous app's window)
- Paste fallback if no hotkey capture happened

Hardcoded bundle ID fallback (`com.justinbetker.draft`) since `Bundle.main.bundleIdentifier` can be nil for swiftc-built apps.

## API Key Flow

1. On launch, if `drafter.hasAPIKey` is false → `APIKeyEntryView` overlay appears
2. User enters key → saved to Keychain → overlay dismisses
3. Gear icon → popover with "Reset API Key" → clears Keychain → overlay reappears
