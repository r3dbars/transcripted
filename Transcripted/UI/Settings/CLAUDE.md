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

### Sections/ (7 files)

| File | Purpose |
|------|---------|
| `StatsSection.swift` | "ALL TIME" stats (total recordings + hours), Open Folder + Refresh buttons |
| `FailedTranscriptionsSection.swift` | Failed transcription list with retry/delete, "Retry All" button |
| `SpeakersSection.swift` | Voice fingerprints list: play clip, edit name inline, delete with confirmation |
| `ProfileSection.swift` | User name text field, save location path picker |
| `MeetingDetectionSection.swift` | Auto-record toggle, supported apps info |
| `SpeakerIntelligenceSection.swift` | Qwen toggle, model status/download, progress bar |
| `AIServicesSection.swift` | Parakeet + Sortformer status badges, "100% local" info |

### Components/ (6 files)

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
| `SettingsNavigationState.swift` | Migration state tracking + unused SettingsTab enum (vestigial) |

## Key Splits from Original Files

- `SettingsContainerView.swift` had 8 inline sections -- each extracted to its own file in Sections/
- `SettingsSectionCard.swift` had 4 helper components + 4 button styles -- components split into separate files in Components/
- `SettingsTopBar.swift` was extracted from the top of SettingsContainerView

## All files are @MainActor (SwiftUI views)

## Gotchas
- Sound toggle uses `UserDefaults.standard.object(forKey:)` (not @AppStorage) to distinguish "never set" vs "explicitly disabled"
- Single `editingId: UUID?` means only one speaker can be edited at a time
- `enableObsidianFormat` is stored in AppStorage but has no UI toggle in settings
- SettingsNavigationState has an unused `SettingsTab` enum + `selectTab()` method (vestigial tabbed design)
- Qwen download in settings caches the model then immediately calls `unload()` to free memory
