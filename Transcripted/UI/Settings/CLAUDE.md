# Settings — CLAUDE.md

## Purpose
Settings window: stats dashboard, speaker voice fingerprints management, app preferences, and transcript migration.

## Files

| File | Responsibility |
|---|---|
| `SettingsWindowController.swift` | NSWindowController, 800×600 fixed window, dark aqua appearance |
| `SettingsContainerView.swift` | Single-page scrolling layout: stats → failed transcriptions → speakers → preferences |
| `SettingsSidebarView.swift` | Left sidebar navigation (Dashboard, Speakers, Preferences tabs) |
| `Models/SettingsNavigationState.swift` | Tab state, migration progress tracking |
| `Components/SettingsSectionCard.swift` | Reusable card wrapper, CoralToggle, SettingsToggleRow, SettingsTextField |

## Key Types

**SettingsWindowController** (NSWindowController): Creates 800×600 window with `.titled`, `.closable`, `.miniaturizable`, `.resizable`. Dark Aqua appearance. `showWindow()` refreshes stats and checks migration on focus.

**SettingsContainerView** (SwiftUI View):
- `@ObservedObject`: statsService, navigationState
- `@AppStorage` keys: `transcriptSaveLocation`, `userName`, `useAuroraRecording`, `enableQwenSpeakerInference`
- `@State`: speakers list, editingId, retryingIds, speakersExpanded, qwenModelCached

**SettingsTab** (enum): `.dashboard` (chart.bar.fill) | `.speakers` (person.2.fill) | `.preferences` (gearshape.fill)

**SettingsNavigationState** (@MainActor, ObservableObject):
- `@Published selectedTab`, `isMigrating`, `migrationProgress`, `migrationStatus`
- `startMigration()` — calls TranscriptScanner to migrate existing transcripts to StatsDB
- `checkMigrationNeeded()` — checks if DB empty but transcript files exist

**Components**: `SettingsSectionCard` (card wrapper), `CoralToggle` (44×24 capsule toggle with coral accent), `SettingsToggleRow`, `SettingsTextField`

## Layout Sections (in scroll order)
1. **Stats**: Total meetings, total hours, Open Folder button, Refresh
2. **Failed Transcriptions**: (if any) Retry queue with individual + retry all
3. **Voice Fingerprints**: Collapsible speaker list with edit name, delete, play clip
4. **Profile**: User name text field, transcript save location
5. **Appearance**: Aurora recording toggle, UI sounds toggle
6. **Speaker Intelligence**: Qwen toggle, model cache status
7. **AI Services**: External service integrations

## @AppStorage Keys Used
- `transcriptSaveLocation` (String) — custom output folder
- `userName` (String) — user's name for speaker attribution
- `useAuroraRecording` (Bool) — aurora animation enabled
- `enableQwenSpeakerInference` (Bool) — Qwen speaker name inference enabled
- `enableUISounds` (Bool) — recording sounds enabled
- `autoRecordMeetings` (Bool) — auto-start recording when meeting app detects active call

## Modification Recipes

| Task | Files to touch |
|---|---|
| Add new preference | `SettingsContainerView.swift` — add `@AppStorage` + UI row in appropriate section |
| Add settings section | `SettingsContainerView.swift` — new section in ScrollView VStack |
| Change window size | `SettingsWindowController.swift` — windowWidth/Height constants |
| Fix speaker editing | `SettingsContainerView.swift` — `speakersSection` computed property |
| Fix migration | `SettingsNavigationState.swift` — `startMigration()` uses TranscriptScanner |
| Add toggle component | `Components/SettingsSectionCard.swift` — follow CoralToggle pattern |

## Dependencies
**From Core/**: StatsService, TranscriptionTaskManager, FailedTranscriptionManager, TranscriptScanner
**From Services/**: SpeakerDatabase (.shared), QwenService (model cache check), SpeakerClipExtractor
**From Design/**: DesignTokens, PremiumComponents

## Logging
Subsystem: `ui`
