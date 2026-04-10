# UI Components

## Current UI Surface

The app has three main UI surfaces:

1. A non-activating floating overlay for dictation
2. A separate non-activating meeting overlay
3. A menu bar popover plus a standalone settings window

There is no live screenshot-to-draft review flow anymore, even though some file names still reflect that older shape.

## Key Files

### Dictation Overlay

- `FloatingOverlayController.swift` — owns overlay state and panel lifecycle
- `FloatingOverlayPanel.swift` — non-activating panel shell
- `OverlayRootView.swift`
- `OverlayHeaderView.swift`
- `OverlayListeningView.swift`
- `OverlayDraftingView.swift`
- `OverlayStreamingView.swift`
- `OverlayReviewView.swift`
- `OverlayDiffStripView.swift`
- `OverlayToolbarView.swift`
- `OverlayToastView.swift`
- `DraftTextView.swift`
- `WaveformLayer.swift`
- `DraftSessionController.swift` — dictation orchestration plus removed draft-mode compatibility stubs

### Meeting Overlay

- `MeetingOverlayController.swift` — dedicated panel/controller for meeting state, warmup, levels, and stop action
- `SpeakerNamingSheet.swift`
- `SpeakerClipPlayback.swift`

### Menu Bar And Settings

- `MenuBarPanelController.swift`
- `MenuBarContentView.swift` — main page plus agent-connect page
- `MenuBarHeaderView.swift`
- `MenuBarShortcutsView.swift`
- `MenuBarRecentMeetingsView.swift`
- `MenuBarSettingsView.swift`
- `MenuAgentConnectPageView.swift`
- `MenuBarModelDownloadView.swift`
- `TranscriptedSettingsWindowController.swift`
- `TranscriptedSettingsView.swift`
- `PermissionsOnboardingView.swift`

## Current Interaction Model

### Dictation

- start from right Option tap or fallback shortcut
- overlay shows listening, transcribing, and review states
- final text is pasted or copied back to the source app
- dictation transcripts are saved to markdown artifacts

### Meetings

- separate overlay and controller from dictation on purpose
- recording can start while prior transcription work continues in the background
- speaker naming and recent meetings surface through the UI

### Menu Bar

The popover is now a compact control surface focused on:

- current shortcuts
- recent meetings
- settings
- agent-connect guidance for local artifacts

It is not the old stats/style/agent-insight dashboard described in previous docs.

## Important Notes

- `DraftSessionController` still contains removed draft-mode entry points as compatibility stubs that show an error instead of launching the old flow.
- The meeting overlay is intentionally isolated from the dictation overlay so regressions do not cross-contaminate features.
- Some windows are SwiftUI-hosted (`TranscriptedSettingsView`, onboarding), while the main overlays and menu bar surfaces are primarily AppKit-driven.

## Verification

```bash
bash build.sh
bash run-tests.sh
```

Manual checks:

- right Option or fallback shortcut toggles dictation
- meeting shortcut toggles the meeting overlay
- recent meetings page renders
- settings window opens from the menu bar
- agent connect page opens from the menu bar
