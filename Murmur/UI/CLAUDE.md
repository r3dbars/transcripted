# UI — CLAUDE.md

## Purpose
Settings window and failed transcription management UI. The main floating pill UI lives in `FloatingPanel/` (see its own CLAUDE.md).

## Key Files

| File | Responsibility |
|------|---------------|
| `Settings/SettingsWindowController.swift` | NSWindowController, 800x600 fixed settings window |
| `Settings/SettingsContainerView.swift` | Single-page scrolling layout (stats, speakers, preferences) |
| `Settings/SettingsSidebarView.swift` | Left sidebar navigation tabs |
| `Settings/Models/SettingsNavigationState.swift` | Tab state enum (Dashboard, Speakers, Preferences) |
| `Settings/Components/SettingsSectionCard.swift` | Reusable card wrapper |
| `FailedTranscriptionsView.swift` | Retry queue management |

## Data Flow

```
Settings:
  SettingsWindowController → SettingsContainerView (single-page layout)

Failed Transcriptions:
  FailedTranscriptionManager (Core) → FailedTranscriptionsView
    → User triggers retry → TranscriptionTaskManager.retryFailedTranscription()
```

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Add settings section | `SettingsContainerView.swift` | Single-page scrolling layout |
| Fix settings layout | `SettingsContainerView.swift` | 800x600 fixed window |
| Fix failed transcription UI | `FailedTranscriptionsView.swift` | Binds to FailedTranscriptionManager |

## Dependencies

**Imports from Core/**: TranscriptionTaskManager, FailedTranscriptionManager, StatsService
**Imports from Design/**: DesignTokens (colors, spacing, animations)

## Logging

Subsystem: `ui` — covers pill transitions, retry actions.
