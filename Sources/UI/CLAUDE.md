# UI

## What this directory owns

`Sources/UI/` contains the live app surfaces for:

- dictation overlay
- meeting overlay and detected-meeting prompt UI
- menu bar popover
- permissions onboarding
- settings, including capture-library selection
- agent-connect helpers
- speaker naming

Draft-mode UI is not an active product path in this worktree.

## Important areas

### Dictation overlay

- `DictationSessionController.swift` — dictation session orchestration; removed draft-mode methods are compatibility stubs
- `FloatingOverlayController.swift` / `FloatingOverlayPanel.swift` — non-activating overlay panel lifecycle
- `OverlayRootView.swift` and related `Overlay*View.swift` files — dictation listening, review, streaming, toast, and toolbar surfaces
- `ReviewTextView.swift` — editable NSTextView used during review
- `WaveformLayer.swift` — waveform rendering

### Meeting UI

- `MeetingOverlayController.swift` — non-activating panel for detected-meeting prompts, warmup, recording, and transcription status
- `SpeakerNamingSheet.swift` — speaker rename flow for completed meetings

### Menu bar

- `MenuBarPanelController.swift` — popover controller
- `MenuBarContentView.swift` — root popover content
- `MenuBarRecentMeetingsView.swift` — recent meetings list and retry / delete actions
- `MenuBarShortcutsView.swift` — keyboard shortcut summary
- `MenuBarSettingsView.swift` — popover footer actions

### Agent connect and settings

- `AgentConnectionGuide.swift` — smart prompt, MCP setup text, and folder fallback copy
- `AgentConnectionWindowController.swift` / `AgentConnectionWindowView.swift` — standalone agent-connect window
- `TranscriptedSettingsView.swift` — settings UI for shortcuts, permissions, and storage
- `TranscriptedSettingsWindowController.swift` — settings window lifecycle
- `PermissionsOnboardingView.swift` — first-run onboarding

## Patterns to preserve

- controllers own subscriptions and push explicit updates into AppKit surfaces
- views are mostly renderers, not long-lived shared state owners
- the capture-library setting belongs in the settings flow; app state, cache, logs, and tmp do not move with it

## Verify

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- dictation overlay starts, stops, and auto-pastes cleanly
- meeting prompts appear only when appropriate
- meeting overlay warms up and records cleanly
- menu bar popover renders recents, shortcuts, settings, and agent-connect correctly
- settings shows the current capture library and opens Finder links correctly
