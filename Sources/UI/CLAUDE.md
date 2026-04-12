# UI Directory

## What This Does

`Sources/UI/` contains the current app surfaces for Transcripted's active features.
The directory is grouped by surface so the live UI tree is easier to scan:

- `Overlay/`
- `MenuBar/`
- `Settings/`
- `AgentConnect/`
- `Shared/`

Draft-mode UI is not an active product path in this worktree.

## Files (32 Swift files)

### Overlay/

- `Overlay/DictationSessionController.swift` — dictation session orchestration; removed draft-mode methods are stubs
- `Overlay/FloatingOverlayController.swift` — owns the dictation overlay panel lifecycle and Combine subscriptions
- `Overlay/FloatingOverlayPanel.swift` — non-activating NSPanel for the dictation overlay
- `Overlay/OverlayDraftingView.swift` — drafting/processing state view
- `Overlay/OverlayHeaderView.swift` — overlay title bar with controls
- `Overlay/OverlayRootView.swift` — top-level AppKit view switching between overlay states
- `Overlay/OverlayTokens.swift` — design tokens (colors, spacing, sizing) for overlay views
- `Overlay/PanelDragView.swift` — drag handle for repositioning the overlay panel
- `Overlay/WaveformLayer.swift` — Core Animation layer drawing the audio waveform
- `Overlay/MeetingOverlayController.swift` — non-activating panel for detected-meeting prompts, model warmup, recording, and transcription status

The overlay area holds both live transient recording surfaces: the compact
dictation overlay and the meeting prompt / recording overlay.

### MenuBar/

- `MenuBar/MenuAgentConnectPageView.swift` — agent connection page in the menubar popover
- `MenuBar/MenuBarContentView.swift` — root content view for the menubar popover
- `MenuBar/MenuBarHeaderView.swift` — popover header with app name and status
- `MenuBar/MenuBarPanelController.swift` — NSPopover controller for the menubar
- `MenuBar/MenuBarRecentMeetingsView.swift` — recent meetings list in the popover
- `MenuBar/MenuBarSettingsView.swift` — settings actions in the popover footer
- `MenuBar/MenuBarShortcutsView.swift` — keyboard shortcut hints in the popover
- `MenuBar/MenuIconButton.swift` — icon-only button style for menubar items
- `MenuBar/MenuOutlineButton.swift` — outlined button style for menubar actions
- `MenuBar/MenuTokens.swift` — design tokens for menubar views

### AgentConnect/

- `AgentConnect/AgentConnectionWindowController.swift` — `AgentConnectionWindowCoordinator` and `NSWindowController` for the standalone agent-connect window
- `AgentConnect/AgentConnectionWindowView.swift` — SwiftUI content for the standalone agent-connect window

The current agent-connect surfaces should keep one simple mental model:

- lead with one smart copy-paste prompt
- let that prompt prefer MCP when available and fall back to folders when not
- keep manual folder paths and MCP setup secondary, not primary

### Settings/

- `Settings/HotkeyRecorderAppKitView.swift` — AppKit view for recording custom hotkey bindings
- `Settings/PermissionsOnboardingView.swift` — first-launch permissions walkthrough
- `Settings/SpeakerNamingSheet.swift` — sheet for renaming speakers in a completed meeting
- `Settings/SpeakerPeopleSettingsSection.swift` — settings section and view model for browsing, naming, merging, previewing, and deleting saved speaker profiles
- `Settings/TranscriptedSettingsView.swift` — main settings view
- `Settings/TranscriptedSettingsWindowController.swift` — NSWindowController for settings

### Shared/

- `Shared/AgentConnectionGuide.swift` — shared smart-prompt, MCP setup, and folder fallback copy for the agent-connect flow
- `Shared/AppSoundPlayer.swift` — UI sound preferences and playback helpers
- `Shared/SpeakerClipPlayback.swift` — reusable audio-preview helper for persisted speaker sample clips

Cross-cutting permission checks now live in `Sources/Support/TranscriptedPermissionAccess.swift`
so the meeting prompt detector and the settings/onboarding flows share the same
app-level permission logic outside the UI tree.

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
- detected-meeting prompts appear only when appropriate and can start or snooze a meeting cleanly
- meeting overlay warms up and records cleanly
- menubar popover renders shortcuts, recents, settings actions, and the agent-connect page cleanly
- speaker settings can preview clips and rename / merge people cleanly
- permissions onboarding and settings window still open correctly
