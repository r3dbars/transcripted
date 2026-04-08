# UI

## What This Contains

AppKit-heavy UI for the current Draft-first desktop app: menu bar surfaces, floating overlays, permissions onboarding, settings, speaker naming, and connection windows.

Current Swift files: **37**

## File Groups

### Overlay / drafting surface
- `FloatingOverlayController.swift`
- `FloatingOverlayPanel.swift`
- `OverlayRootView.swift`
- `OverlayHeaderView.swift`
- `OverlayToolbarView.swift`
- `OverlayListeningView.swift`
- `OverlayDraftingView.swift`
- `OverlayStreamingView.swift`
- `OverlayReviewView.swift`
- `OverlayDiffStripView.swift`
- `OverlayToastView.swift`
- `OverlayTokens.swift`
- `PanelDragView.swift`
- `DraftSessionController.swift`
- `DraftTextView.swift`
- `WaveformLayer.swift`

### Menu bar and connection flow
- `MenuBarPanelController.swift`
- `MenuBarContentView.swift`
- `MenuBarHeaderView.swift`
- `MenuBarSettingsView.swift`
- `MenuBarShortcutsView.swift`
- `MenuBarRecentMeetingsView.swift`
- `MenuBarModelDownloadView.swift`
- `MenuAgentConnectPageView.swift`
- `AgentConnectionWindowController.swift`
- `AgentConnectionWindowView.swift`
- `MenuIconButton.swift`
- `MenuOutlineButton.swift`
- `MenuTokens.swift`

### Onboarding, settings, and permissions
- `PermissionsOnboardingView.swift` — current first-run checklist UI
- `TranscriptedPermissionAccess.swift` — permission-state helpers exposed to the UI layer
- `TranscriptedSettingsView.swift`
- `TranscriptedSettingsWindowController.swift`
- `HotkeyRecorderAppKitView.swift`

### Misc UI helpers
- `SpeakerNamingSheet.swift`
- `MeetingOverlayController.swift`
- `AppSoundPlayer.swift`

## Important Current-State Notes
- The active onboarding UI is now **`PermissionsOnboardingView.swift`**, a checklist-style first-run screen. Older docs that referenced a large multi-step `OnboardingView.swift` are stale.
- The floating overlay still has distinct listening, drafting, streaming, and review states, but recent copy/layout work landed in the individual `Overlay*View.swift` files.
- Menu-bar agent connection and settings surfaces live in this directory, not in a separate onboarding/settings module.

## Gotchas
- This directory mixes AppKit controllers and SwiftUI/AppKit-backed views, so keep state ownership clear when editing.
- If you need current user-facing copy for dictation or meeting overlays, inspect the concrete `Overlay*View.swift` files directly.
