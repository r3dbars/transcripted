# Settings

Single-page settings view with no sidebar or tabs.

## Key Files

- **SettingsContainerView.swift** - Main settings view with sections: Stats, Failed Transcriptions, Voice Fingerprints, Preferences
- **SettingsWindowController.swift** - Window controller that hosts the settings panel

## Sections

1. **Stats** - All-time metrics: total recordings, hours recorded, open folder button, refresh button
2. **Failed Transcriptions** - List of failed transcripts with retry buttons (only shown if any exist)
3. **Voice Fingerprints** - Collapsible speaker management: add/edit/delete speakers, play audio clips
4. **Preferences** - User profile, save location, format options (Obsidian/Markdown), auto-record meetings
5. **Meeting Detection** - Auto-record when meeting detected settings
6. **Speaker Intelligence** - Qwen model inference toggle
7. **AI Services** - Model management and status

## State Management

- Uses `@AppStorage` for user preferences (transcriptSaveLocation, userName, enableQwenSpeakerInference, etc.)
- `StatsService` tracks metrics and writes to SQLite database
- `SpeakerDatabase.shared` manages speaker profiles
- `QwenService` handles speaker name inference via LLM

## Rules

- **Single scrolling page** - No tabs or sidebars
- **Migration overlay** - Shows progress bar when importing old transcripts
- **Sound toggle** - Respects `enableUISounds` preference
- **Speaker editing** - Inline editing with delete confirmation

## Connections

- Reads from `StatsService` and `SpeakerDatabase`
- Writes to UserDefaults and SQLite databases
- Opens System Settings for microphone/screen recording permissions
