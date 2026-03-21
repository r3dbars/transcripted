# Settings

Single-page scrolling settings dashboard. 4 Swift files.

## File Index

| File | Purpose |
|------|---------|
| `SettingsContainerView.swift` (896 lines) | Main view with 8 sections + top bar + migration overlay |
| `Components/SettingsSectionCard.swift` (497 lines) | Reusable card container + 4 helper components + 4 button styles |
| `SettingsWindowController.swift` (144 lines) | NSWindow management, triggers migration check on show |
| `Models/SettingsNavigationState.swift` (89 lines) | Migration state + unused SettingsTab enum (vestigial) |

## Sections (in render order)
1. **Top Bar** - Branding ("Transcripted" + waveform icon) + audio device name (right)
2. **Stats** ("ALL TIME") - Total recordings + hours, Open Folder + Refresh buttons
3. **Failed Transcriptions** (conditional) - First 3 failures with retry/delete, "Retry All" button
4. **Voice Fingerprints** (collapsible) - Speaker list: play clip, edit name inline, delete with confirmation
5. **Profile** - User name (TextField), save location (path picker, default ~/Documents/Transcripted/)
6. **Meeting Detection** - Auto-record toggle, supported apps info (Zoom/Teams/Webex/FaceTime/Loom)
7. **Speaker Intelligence** - Qwen toggle, model status/download, progress bar
8. **AI Services** - Parakeet + Sortformer status badges, "100% local" info

## @AppStorage Keys
| Key | Type | Default | UI Element |
|-----|------|---------|------------|
| `transcriptSaveLocation` | String | "" (-> ~/Documents/Transcripted/) | Path picker |
| `userName` | String | "" | Text field |
| `enableQwenSpeakerInference` | Bool | true | Toggle |
| `enableObsidianFormat` | Bool | false | (used by TranscriptSaver, no UI toggle here) |
| `autoRecordMeetings` | Bool | false | Toggle |
| `enableUISounds` | Bool | true | Read via UserDefaults (not @AppStorage) |

## Reusable Components (SettingsSectionCard.swift)

**Layout Components:**
- `SettingsSectionCard(icon:, title:, content:)` - Dark card with uppercase header
- `SettingsToggleRow(title:, description:, isOn:)` - Toggle + label + optional description
- `CoralToggle(isOn:)` - Custom toggle (44x24pt, coral ON / charcoal OFF, 0.2s animation)
- `SettingsTextField(title:, placeholder:, text:, isSecure:, onVerify:)` - Input with focus border
- `SettingsRadioGroup<T>(title:, options:, selection:, descriptions:)` - Radio buttons
- `SettingsPathRow(title:, path:, defaultPath:, onChoose:)` - Folder picker with ~ display

**Button Styles:**
- `SettingsPrimaryButtonStyle` - Coral filled, white text
- `SettingsSecondaryButtonStyle` - Gray background, hover highlight
- `SettingsDestructiveButtonStyle` - Red text, red bg on hover
- `SettingsIconButtonStyle` - 28x28 circle, gray bg on hover

## Speaker Management Operations
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

## Migration System
- Trigger: `SettingsWindowController.showWindow()` calls `checkMigrationNeeded()`
- Flow: `TranscriptScanner.migrateExistingTranscripts { progress, status in ... }`
- UI: `MigrationOverlayView` with progress bar + percentage, dark overlay
- Completion: Alert with "Successfully imported X transcripts"

## Window Configuration
- Size: 500x400 (min) to 800x900 (max), centered
- Appearance: `.darkAqua`, titlebar transparent, title hidden
- Background: `NSColor(Color.panelCharcoal)`
- Not released when closed (`isReleasedWhenClosed = false`)

## Design Tokens Used
Colors: panelCharcoal/Elevated/Surface, panelText Primary/Secondary/Muted, recordingCoral, accentBlue, attentionGreen, warningAmber, errorRed
Spacing: xs, sm, ms, md, lg, xl
Radius: lawsCard, lawsButton
Typography: .headingLarge, .headingMedium, .bodyMedium, .bodySmall, .caption

## Gotchas
- Sound toggle uses `UserDefaults.standard.object(forKey:)` (not @AppStorage) to distinguish "never set" vs "explicitly disabled"
- Single `editingId: UUID?` means only one speaker can be edited at a time
- `enableObsidianFormat` is stored in AppStorage but has no UI toggle in settings (used by TranscriptSaver)
- SettingsNavigationState has an unused `SettingsTab` enum + `selectTab()` method (vestigial tabbed design)
- Avatar: first letter of displayName in circle, "?" fallback if no name
- Qwen download in settings caches the model then immediately calls `unload()` to free memory
