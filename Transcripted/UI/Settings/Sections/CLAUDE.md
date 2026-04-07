# Settings Sections

7 section views composing the settings dashboard. Each is a self-contained SwiftUI view rendered inside a `SettingsSectionCard`. All `@MainActor`.

## File Index

| File | Section Title | Purpose |
|------|---------------|---------|
| `StatsSection.swift` | "ALL TIME" | Total recordings + hours, Open Folder + Refresh buttons |
| `FailedTranscriptionsSection.swift` | "FAILED TRANSCRIPTIONS" | Failed list with retry/delete, "Retry All" button |
| `SpeakersSection.swift` | "VOICE FINGERPRINTS" | Speaker list: play clip, edit name inline, delete with confirmation |
| `ProfileSection.swift` | "PROFILE" | User name text field, save location path picker |
| `MeetingDetectionSection.swift` | "MEETING DETECTION" | Auto-record toggle, supported apps info |
| `AIServicesSection.swift` | "AI SERVICES" | Parakeet + Sortformer status badges, local-only info |
| `TroubleshootingSection.swift` | "TROUBLESHOOTING" | Permission rows, data locations, onboarding reset, full settings reset |

## Section Details

### StatsSection
- Displays total recording count and total hours
- Buttons: **Open Folder** and **Refresh**
- Data source: `StatsService`

### FailedTranscriptionsSection
- Rendered only when failures exist
- Shows the first few failures with retry/delete actions
- Includes **Retry All** and **Clear** actions
- Data source: `FailedTranscriptionManager`

### SpeakersSection
- Collapsible list of speaker profiles
- Inline rename flow writes through `SpeakerDatabase.shared.setDisplayName(...)`
- Retroactive transcript updates flow through `TranscriptSaver.retroactivelyUpdateSpeaker(...)`
- Delete flow removes persisted clips via `SpeakerClipExtractor.deletePersistedClip(for:)`
- Delayed reload pattern uses `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)` after DB writes
- Single `editingId: UUID?` means only one speaker can be edited at a time

### ProfileSection
- `@AppStorage("userName")`
- `@AppStorage("transcriptSaveLocation")`
- Default save path is `~/Documents/Transcripted/`

### MeetingDetectionSection
- Toggle: `@AppStorage("autoRecordMeetings")`
- Covers Zoom, Teams, Webex, FaceTime, and Loom
- Notes browser meetings still require manual start

### AIServicesSection
- Static informational section
- Shows Parakeet TDT V3 and Sortformer as local models
- Copy emphasizes fully local processing and hardware requirements

### TroubleshootingSection
- **Permission Status**
  - Microphone uses `AVCaptureDevice.authorizationStatus(for: .audio)`
  - Screen recording uses `CGPreflightScreenCaptureAccess()`
  - Missing permissions show a **Fix** button that opens the matching System Settings deep link via `SystemSettingsHelper`
- **Data Locations**
  - Transcripts path comes from `transcriptSaveLocation` or `TranscriptSaver.defaultSaveDirectory`
  - Logs: `~/Library/Logs/Transcripted`
  - Model Cache: `~/Library/Caches/models/mlx-community`
  - "Open in Finder" creates the directory first if needed
- **Reset**
  - **Re-run Onboarding** calls `OnboardingState.resetOnboarding()` and opens a fresh onboarding window
  - **Reset All Settings** clears the app's `UserDefaults` persistent domain, then launches onboarding
  - Reset does **not** delete transcripts or speaker data
- The whole section is `@available(macOS 26.0, *)`

## @AppStorage Keys Used by Sections
| Key | Section | Type | Default |
|-----|---------|------|---------|
| `userName` | Profile | String | "" |
| `transcriptSaveLocation` | Profile | String | "" |
| `autoRecordMeetings` | Meeting Detection | Bool | false |

## Relationships
- All sections are rendered by `SettingsContainerView.swift`
- Reusable components live in `Transcripted/UI/Settings/Components/`
- Speaker operations use `SpeakerDatabase`, `SpeakerClipExtractor`, and `TranscriptSaver`
- Stats come from `StatsService`
- Troubleshooting reset flow reaches into `OnboardingState` and `OnboardingWindowController`

## Gotchas
- `FailedTranscriptionsSection` disappears entirely when there are no failures
- `enableUISounds` is handled in the parent settings container via `UserDefaults`, not `@AppStorage`
- `TroubleshootingSection` launches onboarding directly through `NSApp.delegate as? AppDelegate`
- Older docs mentioning `CGWindowListCopyWindowInfo` screen-recording detection are stale
