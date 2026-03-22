# Settings

Single-page scrolling settings dashboard. 18 Swift files across root, Components/, Sections/, and Models/.

## File Index

### Root (4 files)

| File | Purpose |
|------|---------|
| `SettingsContainerView.swift` | Main scrolling view, composes all sections + migration overlay |
| `SettingsTopBar.swift` | Branding header ("Transcripted" + waveform icon) + audio device name |
| `SettingsWindowController.swift` | NSWindow management, triggers migration check on show |
| `MigrationOverlayView.swift` | Progress overlay for transcript migration (dark scrim + progress bar) |

### Sections/ (7 files) — see Sections/CLAUDE.md

| File | Purpose |
|------|---------|
| `StatsSection.swift` | "ALL TIME" stats (total recordings + hours), Open Folder + Refresh buttons |
| `FailedTranscriptionsSection.swift` | Failed transcription list with retry/delete, "Retry All" button |
| `SpeakersSection.swift` | Voice fingerprints list: play clip, edit name inline, delete with confirmation |
| `ProfileSection.swift` | User name text field, save location path picker |
| `MeetingDetectionSection.swift` | Auto-record toggle, supported apps info |
| `SpeakerIntelligenceSection.swift` | Qwen toggle, model status/download, progress bar |
| `AIServicesSection.swift` | Parakeet + Sortformer status badges, "100% local" info |

### Components/ (6 files) — see Components/CLAUDE.md

| File | Purpose |
|------|---------|
| `SettingsSectionCard.swift` | Dark card container with uppercase header icon + title |
| `SettingsToggleRow.swift` | Toggle + label + optional description row (uses CoralToggle) |
| `SettingsTextField.swift` | Input field with focus border and optional verification |
| `SettingsPathRow.swift` | Folder picker row with ~ display and default path |
| `SettingsRadioGroup.swift` | Generic radio button group |
| `SettingsButtonStyles.swift` | 4 button styles: Primary (coral), Secondary (gray), Destructive (red), Icon (28x28 circle) |

### Models/ (1 file)

| File | Purpose |
|------|---------|
| `SettingsNavigationState.swift` | Migration state tracking + unused SettingsTab enum (vestigial tabbed design) |

## @AppStorage Keys
| Key | Type | Default | UI Element |
|-----|------|---------|------------|
| `transcriptSaveLocation` | String | "" (-> ~/Documents/Transcripted/) | Path picker (ProfileSection) |
| `userName` | String | "" | Text field (ProfileSection) |
| `enableQwenSpeakerInference` | Bool | true | Toggle (SpeakerIntelligenceSection) |
| `enableObsidianFormat` | Bool | false | (used by TranscriptSaver, no UI toggle here) |
| `autoRecordMeetings` | Bool | false | Toggle (MeetingDetectionSection) |
| `enableUISounds` | Bool | true | Read via UserDefaults (not @AppStorage) |

## Speaker Management Operations (SpeakersSection.swift)
```
Edit: tap name -> inline TextField -> commit on Return
  -> SpeakerDatabase.shared.setDisplayName(id:, name:, source: "user_manual")
  -> TranscriptSaver.retroactivelyUpdateSpeaker(dbId:, newName:)

Delete: click delete -> "Delete?" confirm -> "Yes"
  -> SpeakerClipExtractor.deletePersistedClip(for:)
  -> SpeakerDatabase.shared.deleteSpeaker(id:)

Play: toggle clip playback via ClipAudioPlayer (requires persistent clip)
```
Delayed reload pattern: `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` after DB writes.

## Migration System (MigrationOverlayView.swift + SettingsWindowController.swift)
- Trigger: `SettingsWindowController.showWindow()` calls `checkMigrationNeeded()`
- Flow: `TranscriptScanner.migrateExistingTranscripts { progress, status in ... }`
- UI: `MigrationOverlayView` with progress bar + percentage, dark overlay
- Completion: Alert with "Successfully imported X transcripts"

## Window Configuration (SettingsWindowController.swift)
- Size: 500x400 (min) to 800x900 (max), centered
- Appearance: `.darkAqua`, titlebar transparent, title hidden
- Background: `NSColor(Color.panelCharcoal)`
- Not released when closed (`isReleasedWhenClosed = false`)

## Key Splits from Original Files
- `SettingsContainerView.swift` had 8 inline sections -- each extracted to its own file in Sections/
- `SettingsSectionCard.swift` had 4 helper components + 4 button styles -- components split into separate files in Components/
- `SettingsTopBar.swift` was extracted from the top of SettingsContainerView
- `MigrationOverlayView.swift` was extracted from SettingsContainerView

## Design Tokens Used
Colors: panelCharcoal/Elevated/Surface, panelText Primary/Secondary/Muted, recordingCoral, accentBlue, attentionGreen, warningAmber, errorRed
Spacing: xs, sm, ms, md, lg, xl
Radius: lawsCard, lawsButton
Typography: .headingLarge, .headingMedium, .bodyMedium, .bodySmall, .caption

## All files are @MainActor (SwiftUI views)

## Gotchas
- Sound toggle uses `UserDefaults.standard.object(forKey:)` (not @AppStorage) to distinguish "never set" vs "explicitly disabled"
- Single `editingId: UUID?` means only one speaker can be edited at a time
- `enableObsidianFormat` is stored in AppStorage but has no UI toggle in settings
- SettingsNavigationState has an unused `SettingsTab` enum + `selectTab()` method (vestigial tabbed design)
- Avatar: first letter of displayName in circle, "?" fallback if no name
- Qwen download in settings caches the model then immediately calls `unload()` to free memory
