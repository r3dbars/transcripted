# UI Components

## What This Does

SwiftUI views for the Draft app — input area, voice controls, context capture, Draft button, polished output display, style profile viewer, and API key entry.

## Key Files

- `ContentView.swift` — Main app view with TabView (Draft tab + Style tab), wires all engines together
- `APIKeyEntryView.swift` — Overlay shown on first launch to enter Anthropic API key
- `PreviousAppTracker.swift` — Tracks which app the user was in before switching to Draft
- `AppLogger.swift` — Debug logger with in-app log panel and file output

## Layout Structure

```
┌─────────────────────────────────────────┐
│ Draft           [Capturing...]    ⚙️    │  ← Header + capture status + settings
├─────────────────────────────────────────┤
│ Context              [Capture Screen]   │  ← Context label + capture button + ⌃⌥D hint
├─────────────────────────────────────────┤
│                                         │
│  [Editable TextEditor]                  │  ← Type, paste, voice, or capture-filled
│                                         │
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

- **⌘R** — Toggle Record/Stop
- **⌘+Return** — Draft (send to Haiku)
- **Ctrl+Option+D** — Global hotkey: capture screen context (works from any app)

## State Coordination

ContentView owns all engines as `@StateObject`: SpeechEngine, DraftEngine, StyleEngine, AppLogger, PreviousAppTracker, ContextCaptureEngine.

- Speech output syncs to `inputText` via `.onChange(of:)` — `finalTranscript` and `volatileText` both update the TextEditor
- Context capture fills `inputText` via `onContextCaptured` callback, clears previous input and draft
- `@FocusState` on TextEditor ensures cursor lands in input after capture
- Style examples recorded when user hits Copy or "Paste to Last App"
- Style summary auto-regenerates every 5 accepted examples

## PreviousAppTracker

Observes `NSWorkspace.didDeactivateApplicationNotification` to remember the last non-Draft app. Used for:
- "Paste to Last App" button (activates previous app + sends ⌘V)
- Manual capture button (captures previous app's window)

Hardcoded bundle ID fallback (`com.justinbetker.draft`) since `Bundle.main.bundleIdentifier` can be nil for swiftc-built apps.

## API Key Flow

1. On launch, if `drafter.hasAPIKey` is false → `APIKeyEntryView` overlay appears
2. User enters key → saved to Keychain → overlay dismisses
3. Gear icon → popover with "Reset API Key" → clears Keychain → overlay reappears
