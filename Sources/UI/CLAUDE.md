# UI Components

## What This Does

SwiftUI views for the Draft app — input area, voice controls, Draft button, polished output display, and API key entry.

## Key Files

- `ContentView.swift` — Main app view with all controls and layout
- `APIKeyEntryView.swift` — Overlay shown on first launch to enter Anthropic API key

## Design Principles

- **Dead simple** — one screen, no navigation, no tabs
- **Input on top, output on bottom** — natural reading flow
- **Voice indicator** — red dot + blue text shows live speech below the input area
- **Purple accent for Draft** — visually distinct from blue (Record) and red (Stop)

## Layout Structure

```
┌─────────────────────────────────┐
│ Draft                    ⚙️     │  ← Header + settings gear
├─────────────────────────────────┤
│                                 │
│  [Editable TextEditor]          │  ← Type, paste, or voice-filled
│                                 │
├─────────────────────────────────┤
│ 🔴 "listening text here..."     │  ← Voice indicator (when recording)
├─────────────────────────────────┤
│ [Record] [✨ Draft]    [Clear]  │  ← Controls
├─────────────────────────────────┤
│ Drafted Message          [Copy] │
│ "Polished text from Haiku..."   │  ← Output area (purple tint)
└─────────────────────────────────┘
```

## Keyboard Shortcuts

- **Space** — Toggle Record/Stop
- **⌘+Return** — Draft (send to Haiku)

## State Coordination

ContentView owns both `SpeechEngine` and `DraftEngine` as `@StateObject`. Speech output syncs to the editable `inputText` via `.onChange(of:)` — when `finalTranscript` updates, `inputText` is refreshed. The user can also type/paste directly into the TextEditor.

## API Key Flow

1. On launch, if `drafter.hasAPIKey` is false → `APIKeyEntryView` overlay appears
2. User enters key → saved to Keychain → overlay dismisses automatically
3. Gear icon in header → popover with "Reset API Key" button → clears Keychain → overlay reappears
