# UI Directory

## What This Does

`Sources/UI/` contains the current app surfaces for Transcripted's active
features:

- dictation overlay
- meeting overlay
- menubar popover
- permissions onboarding
- settings
- speaker naming and agent-connect helpers

Draft-mode UI is not an active product path in this worktree.

## Files (37 Swift files)

### Dictation Overlay

- `DictationSessionController.swift` — dictation session orchestration; removed draft-mode methods are stubs
- `ReviewTextView.swift` — editable NSTextView for dictation preview
- `FloatingOverlayController.swift` — owns the overlay panel lifecycle and Combine subscriptions
- `FloatingOverlayPanel.swift` — non-activating NSPanel for the dictation overlay
- `OverlayDiffStripView.swift` — side-by-side diff indicator in review state
- `OverlayDraftingView.swift` — drafting/processing state view
- `OverlayHeaderView.swift` — overlay title bar with controls
- `OverlayListeningView.swift` — waveform and status during active dictation
- `OverlayReviewView.swift` — post-dictation review before paste
- `OverlayRootView.swift` — top-level SwiftUI container switching between overlay states
- `OverlayStreamingView.swift` — streaming transcript display during dictation
- `OverlayToastView.swift` — ephemeral toast notifications in the overlay
- `OverlayTokens.swift` — design tokens (colors, spacing, sizing) for overlay views
- `OverlayToolbarView.swift` — action buttons in the overlay footer
- `PanelDragView.swift` — drag handle for repositioning the overlay panel
- `WaveformLayer.swift` — Core Animation layer drawing the audio waveform

### Meeting Overlay

- `MeetingOverlayController.swift` — non-activating panel for meeting warmup, recording, and transcription status
- `SpeakerNamingSheet.swift` — sheet for renaming speakers in a completed meeting

### Menubar

- `MenuAgentConnectPageView.swift` — agent connection page in menubar popover
- `MenuBarContentView.swift` — root content view for the menubar popover
- `MenuBarHeaderView.swift` — popover header with app name and status
- `MenuBarModelDownloadView.swift` — model download progress in the menubar
- `MenuBarPanelController.swift` — NSPopover controller for the menubar
- `MenuBarRecentMeetingsView.swift` — recent meetings list in the popover
- `MenuBarSettingsView.swift` — settings actions in the popover footer
- `MenuBarShortcutsView.swift` — keyboard shortcut hints in the popover
- `MenuIconButton.swift` — icon-only button style for menubar items
- `MenuOutlineButton.swift` — outlined button style for menubar actions
- `MenuTokens.swift` — design tokens for menubar views
- `AgentConnectionWindowController.swift`
- `AgentConnectionGuide.swift`
- `AgentConnectionWindowView.swift` — main standalone agent-connect window

The current agent-connect surfaces should keep one simple mental model:

- start with the folder prompt
- offer MCP as the better supported-agent path
- keep CLI guidance clearly marked as advanced

### Settings and Onboarding

- `HotkeyRecorderAppKitView.swift` — AppKit view for recording custom hotkey bindings
- `PermissionsOnboardingView.swift` — first-launch permissions walkthrough
- `TranscriptedPermissionAccess.swift` — accessibility and screen recording permission checks
- `TranscriptedSettingsView.swift` — main settings view
- `TranscriptedSettingsWindowController.swift` — NSWindowController for settings

### Shared

- `AgentConnectionWindowController.swift` — standalone window for connecting to an agent
- `AgentConnectionWindowView.swift` — SwiftUI content for the agent connection window
- `AppSoundPlayer.swift` — UI sound preferences and playback helpers

## Observation Pattern

Controllers own Combine subscriptions and push explicit `update(...)` calls into
AppKit views. Views are renderers, not observable state owners.

## Verification

After changing UI code:

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- dictation overlay starts, stops, and auto-pastes cleanly
- meeting overlay warms up and records cleanly
- menubar popover renders shortcuts, recents, and settings actions
- permissions onboarding and settings window still open correctly
