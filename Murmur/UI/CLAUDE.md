# UI — CLAUDE.md

## Purpose
Settings window, action item review workflow, and failed transcription management UI. The main floating pill UI lives in `FloatingPanel/` (see its own CLAUDE.md).

## Key Files

| File | Responsibility |
|------|---------------|
| `Settings/SettingsWindowController.swift` | NSWindowController, 800x600 fixed settings window |
| `Settings/SettingsContainerView.swift` | Single-page scrolling layout (stats, speakers, preferences) |
| `Settings/SettingsSidebarView.swift` | Left sidebar navigation tabs |
| `Settings/Models/SettingsNavigationState.swift` | Tab state enum (Dashboard, Preferences, Speakers) |
| `Settings/Components/SettingsSectionCard.swift` | Reusable card wrapper |
| `ActionItemReviewView.swift` | Task approval/rejection workflow |
| `FailedTranscriptionsView.swift` | Retry queue management |

## Data Flow

```
Settings:
  SettingsWindowController → SettingsContainerView (single-page layout)

Action Items:
  TranscriptionTaskManager publishes pendingReview state
    → FloatingPanel shows ReviewTrayView
    → ActionItemReviewView for full approval workflow
    → Approved items sent to Reminders/Todoist

Failed Transcriptions:
  FailedTranscriptionManager (Core) → FailedTranscriptionsView
    → User triggers retry → TranscriptionTaskManager.retryFailedTranscription()
```

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Add settings section | `SettingsContainerView.swift` | Single-page scrolling layout |
| Fix settings layout | `SettingsContainerView.swift` | 800x600 fixed window |
| Fix action item review | `ActionItemReviewView.swift` | Reads from TranscriptionTaskManager state |
| Fix failed transcription UI | `FailedTranscriptionsView.swift` | Binds to FailedTranscriptionManager |

## Dependencies

**Imports from Core/**: TranscriptionTaskManager, FailedTranscriptionManager, StatsService
**Imports from Design/**: DesignTokens (colors, spacing, animations)

## Logging

Subsystem: `ui` — covers pill transitions, retry actions, review events.
