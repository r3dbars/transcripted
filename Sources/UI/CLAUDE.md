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

## Main Groups

### Dictation Overlay

- `FloatingOverlayController.swift`
- `FloatingOverlayPanel.swift`
- `Overlay*View.swift`
- `DraftTextView.swift`
- `WaveformLayer.swift`
- `DraftSessionController.swift`

`DraftSessionController` now runs dictation and compatibility stubs. It does
not implement a live draft-generation pipeline in this tree.

### Meeting Overlay

- `MeetingOverlayController.swift`

Separate non-activating panel for meeting warmup, recording, and transcription
status.

### Menubar

- `MenuBarPanelController.swift`
- `MenuBarContentView.swift`
- `MenuBarHeaderView.swift`
- `MenuBarShortcutsView.swift`
- `MenuBarRecentMeetingsView.swift`
- `MenuBarSettingsView.swift`
- `MenuAgentConnectPageView.swift`

The current popover is organized around header, shortcuts, recent meetings, and
footer/settings actions.

### Settings And Onboarding

- `TranscriptedSettingsView.swift`
- `TranscriptedSettingsWindowController.swift`
- `PermissionsOnboardingView.swift`
- `TranscriptedPermissionAccess.swift`

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
