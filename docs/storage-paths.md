# Storage Paths

## Current App Layout On `main`

The current Transcripted app defaults to a Transcripted-named Application
Support root:

- app support root: `~/Library/Application Support/Transcripted/`
- default capture library: `~/Library/Application Support/Transcripted/captures/`

Users can move the capture library in Settings via the `transcriptSaveLocation`
preference. When that happens, meetings and dictations move under the selected
folder, while app-owned state, cache, logs, and temp files stay under
`~/Library/Application Support/Transcripted/`.

## Dictation

Dictation artifacts live under:

- root: `<capture-library>/dictations/`
- current runtime output: daily markdown files like `Dictations_2026-04-11.md`

`DictationStoragePaths.transcriptsFolder` points directly at the dictations
folder. There is no extra `transcripts/` subdirectory in the current app
layout.

## Meetings

Meeting captures live under:

- root: `<capture-library>/meetings/`

The meetings capture folder contains user-facing artifacts:

- markdown transcripts: `<capture-library>/meetings/*.md`
- retained recording audio: `<capture-library>/meetings/audio/*_audio/`

After a successful transcript save, app-managed retained `.wav` audio is
converted to `.m4a` and the original `.wav` is removed only after conversion
succeeds. The Storage settings page controls whether retained audio is deleted
after 7 days, 30 days, or never. Markdown transcripts are not removed by audio
retention cleanup.

On launch, Transcripted also performs the same best-effort compression pass for
existing retained audio folders that already have matching Markdown transcripts.
Failed or orphaned audio without a saved transcript is left alone for the
failed-meeting retry/delete flow.

App-owned meeting state is stored separately under:

- speaker DB: `~/Library/Application Support/Transcripted/state/speakers.sqlite`
- stats DB: `~/Library/Application Support/Transcripted/state/stats.sqlite`
- failed queue: `~/Library/Application Support/Transcripted/state/failed_transcriptions.json`
- runtime diagnostics marker: `~/Library/Application Support/Transcripted/state/runtime-diagnostics.json`

Claude Desktop integration installs the bundled read-only MCP helper under:

- MCP helper: `~/Library/Application Support/Transcripted/mcp/transcripted-mcp`
- MCP directory manifest: `~/Library/Application Support/Transcripted/mcp-directories.json`

The opt-in Codex live-meeting sidecar writes provisional files under:

- live Codex workspace: `~/Library/Application Support/Transcripted/CodexLiveMeeting/`
- live transcript: `~/Library/Application Support/Transcripted/CodexLiveMeeting/live_transcript.md`
- live state: `~/Library/Application Support/Transcripted/CodexLiveMeeting/state.json`
- automatic Codex handoff: `~/Library/Application Support/Transcripted/CodexLiveMeeting/codex-handoff.md`
- live preview file: `~/Library/Application Support/Transcripted/CodexLiveMeeting/preview.html`
- live Codex browser preview while Transcripted is running: `http://127.0.0.1:47834/live-preview`

These files do not replace the normal saved meeting Markdown. Once a meeting is
saved, `codex-handoff.md` switches to `Status: ready` and `state.json` can
point Codex at the final transcript path. Lines marked
`[partial]` in the live transcript are streaming ASR hypotheses, not durable
diarized transcript output. `preview.html` is rewritten with the latest
transcript as a direct-file snapshot. Transcripted also serves the same preview
on loopback for Codex's in-app browser, where it updates in place without
full-page refreshes.

Temporary audio scratch paths live under:

- raw recordings: `~/Library/Application Support/Transcripted/tmp/recordings/`
- speaker clips: `~/Library/Application Support/Transcripted/tmp/recordings/speaker_clips/`

Successful live and imported meeting recordings are copied from scratch into
the meeting capture library before scratch cleanup. Failed live meeting
transcriptions also copy their available recording audio there while keeping
the scratch files available for retry. Explicitly discarded recordings still
delete their scratch audio.

These paths are defined on the app side in `Sources/Meeting/MeetingStoragePaths.swift`
and then injected into `TranscriptedCore` through `CoreStoragePaths`.

## Logs And Events

App-side observability output currently lives under:

- debug log: `~/Library/Application Support/Transcripted/logs/debug.log`
- events: `~/Library/Application Support/Transcripted/logs/events.jsonl`

The embedded `TranscriptedCore` logger also writes JSONL under the same logs
directory:

- core pipeline log: `~/Library/Application Support/Transcripted/logs/app.jsonl`

## `TranscriptedCore` Defaults

`CoreStoragePaths.default` now uses the same Transcripted-named Application
Support layout:

- meeting captures: `~/Library/Application Support/Transcripted/captures/meetings/`
- databases + failed queue: `~/Library/Application Support/Transcripted/state/`
- raw audio scratch: `~/Library/Application Support/Transcripted/tmp/recordings/`
- logs: `~/Library/Application Support/Transcripted/logs/`

The app still injects its own `CoreStoragePaths` so the meeting capture folder
can follow the user-selected capture library.

## Standalone Tool Fallbacks

The standalone tools do not all resolve paths the same way:

- `TranscriptedCLI` first follows the app-selected capture library from `mcp-directories.json` or the app's `transcriptSaveLocation` preference, then falls back to the current Transcripted capture folders, then legacy Draft `.../transcripts/`, then `~/Documents/Transcripted/`; explicit `--data-dir`, `--meetings-dir`, `--dictations-dir`, or matching env vars still override this
- `TranscriptedMCP` first follows the app-selected capture library from `mcp-directories.json` or the app's `transcriptSaveLocation` preference, then falls back to the current-plus-legacy read order. It keeps its SQLite index under `~/Library/Application Support/Transcripted/cache/` by default; if `TRANSCRIPTED_DATA_DIR` is set, it instead keeps the index in that shared root unless `TRANSCRIPTED_INDEX_DIR` is also set
- `TranscriptedQA` now defaults to the current Transcripted meetings/state/log layout, uses `~/Library/Application Support/Transcripted/logs/app.jsonl` for log validation, falls back to legacy Draft and then `~/Documents/Transcripted/`, and accepts explicit `--path`, `--state-dir`, and `--log-path` overrides for nonstandard setups
