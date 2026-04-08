# UI Components

## What This Does

Mostly AppKit views and controllers for the current Transcripted app shell. The active UI is split into a floating dictation overlay, a separate meeting overlay, and a menubar popover. SwiftUI is still used for a few window contents such as settings, agent connection, and permissions onboarding, but the core overlay and popover chrome are AppKit.

## Key Files

### Floating Overlay
- `FloatingOverlayController.swift` - Dictation overlay state machine, animations, panel lifecycle, and live engine subscriptions
- `OverlayRootView.swift` - Header-first overlay layout with compact and expanded states
- `OverlayHeaderView.swift` - Mode label, waveform, spinner, and stop button
- `OverlayListeningView.swift` - Live transcript display while recording
- `OverlayDraftingView.swift` - Processing/error body for the compact overlay
- `OverlayStreamingView.swift` - Token streaming text view
- `OverlayReviewView.swift` - Editable draft view
- `OverlayDiffStripView.swift` - Word-level diff strip
- `OverlayToolbarView.swift` - Bottom status hints
- `OverlayToastView.swift` - Small transient training toast
- `DraftTextView.swift` - Review text editor responder handling
- `PanelDragView.swift` - AppKit drag helper
- `FloatingOverlayPanel.swift` - Non-activating `NSPanel`

### Meeting Overlay
- `MeetingOverlayController.swift` - Meeting overlay panel, root view, tokens, and controller in one file
- `MeetingSessionController.swift` - Meeting pipeline coordinator and UI-facing session state
- `MeetingCaptureBridge.swift` - MainActor bridge around Core audio capture
- `MeetingModelDownloader.swift` - Warmup gate for STT and diarization models
- `MeetingTranscriptStyler.swift` - Rewrites transcript artifacts into readable meeting notes

### Menubar Panel
- `MenuBarPanelController.swift` - Fresh controller per popover open with Combine wiring
- `MenuBarContentView.swift` - Root compositor for the popover pages
- `MenuBarRecentMeetingsView.swift` - Recent meetings scanner, failed meetings, and row actions
- `MenuBarShortcutsView.swift` - Shortcut pills and recording controls
- `MenuBarSettingsView.swift` - Settings content and hotkey recorder
- `MenuBarHeaderView.swift` - Top bar status
- `MenuBarModelDownloadView.swift` - Model warmup progress
- `MenuAgentConnectPageView.swift` - Agent connection help page
- `HotkeyRecorderAppKitView.swift` - Keyboard shortcut recorder

### Permissions
- `PermissionsOnboardingView.swift` - SwiftUI onboarding for the one-time permissions flow

### SwiftUI Windows
- `TranscriptedSettingsView.swift` - Settings window content
- `TranscriptedSettingsWindowController.swift` - AppKit window host for settings
- `AgentConnectionWindowView.swift` - Agent connection window content
- `AgentConnectionWindowController.swift` - AppKit window host for agent connection

### Design Tokens
- `OverlayTokens.swift` - Floating overlay colors and spacing
- `MeetingOverlayController.swift` - Contains the meeting overlay tokens inline
- `MenuTokens.swift` - Menubar colors and spacing

## Architecture Notes

Controllers own Combine subscriptions and push state into dumb AppKit views. Views do not observe model objects directly. That keeps the AppKit lifecycle predictable and makes the overlay and menubar easier to reason about.

`FloatingOverlayController` is intentionally narrower now than the old draft flow: the current user-facing path is compact dictation with loading and error expansion, not the old screenshot-plus-streaming compose flow.

`MenuBarRecentMeetingsView` does both scanning and rendering today. That is acceptable for now, but it is one of the clearest future split candidates.

## Verification

- `bash build.sh && bash run-tests.sh`
- If you change meeting UI or the Core bridge, also run `bash run-integration-smoke.sh`
