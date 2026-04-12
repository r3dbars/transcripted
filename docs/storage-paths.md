# Storage Paths

## Current App Paths On `main`

The current Transcripted app on `main` still uses Draft-named compatibility
roots in Application Support.

App support root:

`~/Library/Application Support/Draft/`

## Dictation

- folder: `~/Library/Application Support/Draft/dictations/`
- transcripts: `~/Library/Application Support/Draft/dictations/transcripts/`
- format: daily markdown files written by `DictationTranscriptWriter`

## Meetings

Meeting storage is isolated under:

`~/Library/Application Support/Draft/meetings/`

Key paths:

- transcripts: `~/Library/Application Support/Draft/meetings/transcripts/`
- speaker DB: `~/Library/Application Support/Draft/meetings/speakers.sqlite`
- stats DB: `~/Library/Application Support/Draft/meetings/stats.sqlite`
- failed queue: `~/Library/Application Support/Draft/meetings/failed_transcriptions.json`
- speaker clips: `~/Library/Application Support/Draft/meetings/speaker_clips/`
- recording scratch: `~/Library/Application Support/Draft/meetings/recordings/`

These paths are defined on the app side in `Sources/Meeting/MeetingStoragePaths.swift`
and then injected into `TranscriptedCore` through `CoreStoragePaths`.

## Logs And Events

- debug log: `~/draft-debug.log`
- events: `~/Library/Application Support/Draft/events.jsonl`
- core/app logs folder: `~/Library/Logs/Transcripted/` for logging infrastructure and beta-related paths

## Standalone `TranscriptedCore` Defaults

When `TranscriptedCore` runs with `CoreStoragePaths.default`, it points to the
historic standalone Transcripted layout:

- transcripts and DBs: `~/Documents/Transcripted/`
- logs: `~/Library/Logs/Transcripted/`

Draft does **not** use those defaults for meetings on `main`.
