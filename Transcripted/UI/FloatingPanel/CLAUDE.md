# FloatingPanel

Floating panel UI that morphs between states like Apple's Dynamic Island.

## Key Files

- **PillStateManager.swift** - State machine for pill states (idle → recording → processing → idle). Handles animation timing, timeout recovery, and sound feedback.
- **FloatingPanelView.swift** - SwiftUI view that renders the pill and tray overlays. Manages tray state (none/transcripts/speakerNaming).
- **FloatingPanelController.swift** - NSWindowController that creates the floating panel window, handles position persistence, and wires state bindings.

## Pill States

1. **idle** (40x20px) - Dormant waveform, capsule shape
2. **recording** (180x40px) - Live visualizer + timer + stop button
3. **processing** (180x40px) - Status text + progress indicator

## Rules

- **@MainActor** - All state changes happen on main thread
- **No I/O in CoreAudio callbacks** - Audio callbacks only update state flags
- **Timeout recovery** - If transition stuck >2s, force-reset to idle
- **Sound feedback** - PillSounds plays system sounds on state transitions (Pop/Tink/Glass/Basso)
- **Position persistence** - Saves x/y coordinates to UserDefaults, centers above dock on first launch

## Connections

- **PillStateManager** receives `isRecording` from `Audio` class and `displayStatus` from `TranscriptionTaskManager`
- **FloatingPanelView** embeds `TranscriptTrayView` and `SpeakerNamingView` as overlays
- **FloatingPanelController** wires up Combine subscriptions to react to audio/task changes

## Tray States

- **none** - Pill only, no overlay
- **transcripts** - Expands upward to show transcript history
- **speakerNaming** - Shows naming dialog for unidentified speakers (mutually exclusive with transcripts)
