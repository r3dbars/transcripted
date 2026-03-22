# Settings Sections

7 section views composing the settings dashboard. Each is a self-contained SwiftUI view rendered inside a SettingsSectionCard. All @MainActor.

## File Index

| File | Section Title | Purpose |
|------|---------------|---------|
| `StatsSection.swift` | "ALL TIME" | Total recordings + hours, Open Folder + Refresh buttons |
| `FailedTranscriptionsSection.swift` | "FAILED TRANSCRIPTIONS" | Failed list with retry/delete, "Retry All" button (conditional) |
| `SpeakersSection.swift` | "VOICE FINGERPRINTS" | Speaker list: play clip, edit name inline, delete with confirmation |
| `ProfileSection.swift` | "PROFILE" | User name TextField, save location path picker |
| `MeetingDetectionSection.swift` | "MEETING DETECTION" | Auto-record toggle, supported apps info |
| `SpeakerIntelligenceSection.swift` | "SPEAKER INTELLIGENCE" | Qwen toggle, model status/download, progress bar |
| `AIServicesSection.swift` | "AI SERVICES" | Parakeet + Sortformer status badges, "100% local" info |

## Section Details

### StatsSection
- Displays: total recording count, total hours (formatted)
- Buttons: "Open Folder" (reveals in Finder), "Refresh" (reloads stats)
- Data source: StatsService (aggregates from StatsDatabase)

### FailedTranscriptionsSection (conditional — only shown when failures exist)
- Shows first 3 failures with error message + retry/delete buttons per item
- "Retry All" button at bottom
- "Clear" button to remove all permanent failures
- Data source: FailedTranscriptionManager

### SpeakersSection (collapsible)
- Speaker list with avatar (first letter circle, "?" fallback), display name, call count
- Inline edit: tap name → TextField → commit on Return
  - → SpeakerDatabase.setDisplayName(id:, name:, source: "user_manual")
  - → RetroactiveSpeakerUpdater.retroactivelyUpdateSpeaker(dbId:, newName:)
- Delete: click → "Delete?" confirm → "Yes"
  - → SpeakerClipExtractor.deletePersistedClip(for:)
  - → SpeakerDatabase.deleteSpeaker(id:)
- Play: toggle clip via ClipAudioPlayer (one at a time)
- Delayed reload: `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` after DB writes
- Single `editingId: UUID?` — only one speaker editable at a time

### ProfileSection
- "Your Name" text field (placeholder: "Enter your name") → @AppStorage("userName")
- "Save Location" path picker → @AppStorage("transcriptSaveLocation")
- Default path: ~/Documents/Transcripted/

### MeetingDetectionSection
- Toggle: "Auto-Record Meetings" → @AppStorage("autoRecordMeetings")
- Description: "Starts recording when Zoom, Teams, Webex, FaceTime, or Loom is active"
- Trigger info: "after 5s of active call audio. Stops 15s after audio drops."
- Browser note: "Browser meetings (Google Meet, Teams web) require manual start."

### SpeakerIntelligenceSection
- Toggle: "Auto-Detect Speaker Names" → @AppStorage("enableQwenSpeakerInference")
- Model display: "Qwen 3.5-4B" with status badge
- Download progress: 80pt ProgressView + percentage label
- Info: "Reads first 15 minutes... 100% on-device."
- Download button: triggers QwenService download, caches model, immediately unloads

### AIServicesSection
- Static display (no user interaction beyond info)
- Models: "Parakeet TDT V3" (ASR) + "Sortformer" (streaming diarization)
- Both show "local" badge: 10pt medium, panelTextMuted, panelCharcoalSurface bg, 4pt radius
- Info text: "100% local transcription. No cloud API, no internet, no cost."
- Requirements: "English only · macOS 14.2+ · 16 GB RAM recommended"

## @AppStorage Keys Used by Sections
| Key | Section | Type | Default |
|-----|---------|------|---------|
| `userName` | Profile | String | "" |
| `transcriptSaveLocation` | Profile | String | "" |
| `enableQwenSpeakerInference` | Speaker Intelligence | Bool | true |
| `autoRecordMeetings` | Meeting Detection | Bool | false |

## Relationships
- All sections rendered by: SettingsContainerView.swift (parent)
- Reusable components from: Components/ (SettingsSectionCard, SettingsToggleRow, SettingsTextField, SettingsPathRow)
- Speaker operations use: SpeakerDatabase, SpeakerClipExtractor, RetroactiveSpeakerUpdater (Core/)
- Stats from: StatsService → StatsDatabase (Core/)

## Gotchas
- FailedTranscriptionsSection only appears when FailedTranscriptionManager has items
- Speaker edit uses single `editingId` — can't edit two names simultaneously
- SpeakerIntelligenceSection download caches Qwen model then immediately calls `unload()` to free memory
- `enableUISounds` is read via `UserDefaults.standard.object(forKey:)` (not @AppStorage) to distinguish "never set" vs "explicitly disabled"
