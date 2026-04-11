# Storage Paths

## Current App Layout On `main`

Transcripted now separates user-facing captures from app-owned state.

Default app root:

`~/Library/Application Support/Transcripted/`

## Capture Library

Default capture library:

`~/Library/Application Support/Transcripted/captures/`

The capture library is user-configurable through Settings via
`TranscriptedStoragePreferences` (`transcriptSaveLocation`). When the user picks
another folder, only the capture folders move; app state remains under the
Transcripted Application Support root.

## Dictation

Default folder:

`~/Library/Application Support/Transcripted/captures/dictations/`

Current app behavior:

- daily markdown files live directly in the dictations folder
- filenames look like `Dictations_YYYY-MM-DD.md`
- each file contains multiple entries with timestamps, source app metadata, and delivery outcome

Owned by:

- `Sources/Dictation/DictationStoragePaths.swift`
- `Sources/Dictation/DictationTranscriptWriter.swift`

## Meetings

Default capture folder:

`~/Library/Application Support/Transcripted/captures/meetings/`

Current contents:

- transcript markdown files
- meeting `.json` sidecars
- `transcripted.json`
- `AGENT.md`
- `CLAUDE.md`

Meeting-related app state is stored separately:

- speaker DB: `~/Library/Application Support/Transcripted/state/speakers.sqlite`
- stats DB: `~/Library/Application Support/Transcripted/state/stats.sqlite`
- failed queue: `~/Library/Application Support/Transcripted/state/failed_transcriptions.json`
- logs: `~/Library/Application Support/Transcripted/logs/`
- speaker clips scratch: `~/Library/Application Support/Transcripted/tmp/recordings/speaker_clips/`
- recording scratch: `~/Library/Application Support/Transcripted/tmp/recordings/`

Owned by:

- `Sources/Meeting/MeetingStoragePaths.swift`
- `Sources/Meeting/MeetingSessionController.swift`

## App Logs And Diagnostics

Current app-owned paths:

- debug log: `~/Library/Application Support/Transcripted/logs/debug.log`
- events: `~/Library/Application Support/Transcripted/logs/events.jsonl`
- core JSONL log: `~/Library/Application Support/Transcripted/logs/app.jsonl`

## Standalone `TranscriptedCore` Defaults

`CoreStoragePaths.default` now points to the Transcripted Application Support
layout, not `~/Documents/Transcripted/`:

- captures: `~/Library/Application Support/Transcripted/captures/meetings/`
- state DBs and failed queue: `~/Library/Application Support/Transcripted/state/`
- logs: `~/Library/Application Support/Transcripted/logs/`
- raw audio scratch: `~/Library/Application Support/Transcripted/tmp/recordings/`

The app still overrides the transcript path so meetings follow the selected
capture library, while state/logs/tmp remain app-owned.

## Tool Compatibility Paths

Standalone tools do not all use the same fallback behavior.

`Tools/TranscriptedCLI` and `Tools/TranscriptedMCP`:

- default to the Transcripted capture folders above
- fall back to legacy Draft folders when the new default folders do not exist
- then fall back to `~/Documents/Transcripted/` for older standalone data

Legacy Draft fallback folders:

- `~/Library/Application Support/Draft/meetings/transcripts/`
- `~/Library/Application Support/Draft/dictations/transcripts/`

`Tools/TranscriptedQA`:

- still defaults to the Draft meetings tree unless `--path` is provided

## Legacy Context

Older docs may still mention:

- `~/Library/Application Support/Draft/`
- `~/Documents/Transcripted/`

Treat those as compatibility or historical layouts, not the default app layout
for current development on `main`.
