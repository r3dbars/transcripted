# Storage Paths

## Current App Layout On `main`

The current Transcripted app defaults to a Transcripted-named Application
Support root:

- app support root: `~/Library/Application Support/Transcripted/`
- default capture library: `~/Library/Application Support/Transcripted/captures/`

Users can point the capture library at a different folder in Settings via the
`transcriptSaveLocation` preference. When the current library still has saved
meetings or dictations, Settings offers to copy those captures to the new
folder before switching. The copy never deletes originals and skips destination
name collisions instead of overwriting. App-owned state, cache, logs, and temp
files always stay under `~/Library/Application Support/Transcripted/`.

Timeline screen capture state is app-owned and local-only:

- screenshots: `~/Library/Application Support/Transcripted/recordings/screenshots/`
- future timeline database: `~/Library/Application Support/Transcripted/state/timeline.sqlite`

## Dictation

Dictation artifacts live under:

- root: `<capture-library>/dictations/`
- current runtime output: daily markdown files like `Dictations_2026-04-11.md`

`DictationStoragePaths.transcriptsFolder` points directly at the dictations
folder. There is no extra `transcripts/` subdirectory in the current app
layout.

## Timeline

Agent-readable day timeline files live under:

- root: `<capture-library>/timeline/`
- current runtime output: daily markdown files like `2026-04-11.md`

Timeline files summarize activity cards for a local day. They may link to saved
meeting Markdown by relative path, but they must not include screenshots or raw
OCR text.

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

On launch, Transcripted also performs best-effort compression for existing
retained audio folders that already have matching Markdown transcripts. Failed
audio that is still referenced by the failed-meeting retry queue can also be
compressed in place, with the queue updated to point at the new `.m4a` files
before the original `.wav` files are removed. Orphaned audio without a saved
transcript or failed-queue entry is left alone instead of guessing ownership.

App-owned meeting state is stored separately under:

- speaker DB: `~/Library/Application Support/Transcripted/state/speakers.sqlite`
- stats DB: `~/Library/Application Support/Transcripted/state/stats.sqlite`
- timeline DB: `~/Library/Application Support/Transcripted/state/timeline.sqlite`
- failed queue: `~/Library/Application Support/Transcripted/state/failed_transcriptions.json`
- runtime diagnostics marker: `~/Library/Application Support/Transcripted/state/runtime-diagnostics.json`

The Dayflow-style timeline stores app-owned screen activity data separately from
the relocatable capture library:

- screenshots: `~/Library/Application Support/Transcripted/recordings/screenshots/YYYY-MM-DD/*.jpg`
- future timeline Markdown summaries: `<capture-library>/timeline/`

Timeline database rows and screenshot files are owner-only local state. The
retention manager soft-deletes old screenshot rows first, removes files oldest
first when the configured cap is exceeded, then hard-deletes the purged rows.
Screenshots that belong to an `analysis_batches.status = processing` batch are
not deleted by retention.

Claude Desktop integration installs the bundled read-only MCP helper under:

- MCP helper: `~/Library/Application Support/Transcripted/mcp/transcripted-mcp`
- MCP directory manifest: `~/Library/Application Support/Transcripted/mcp-directories.json`

The opt-in live-meeting sidecar for Codex or Claude Cowork writes provisional files under:

- live sidecar workspace: `~/Library/Application Support/Transcripted/AgentLiveMeeting/`
- live transcript: `~/Library/Application Support/Transcripted/AgentLiveMeeting/live_transcript.md`
- live state: `~/Library/Application Support/Transcripted/AgentLiveMeeting/state.json`
- automatic agent handoff: `~/Library/Application Support/Transcripted/AgentLiveMeeting/agent-handoff.md`
- agent watcher state: `~/Library/Application Support/Transcripted/AgentLiveMeeting/agent-watcher-state.json`
- live preview file: `~/Library/Application Support/Transcripted/AgentLiveMeeting/preview.html`
- live browser preview while Transcripted is running: tokenized localhost URL in `agent-live-meeting.md`

These files do not replace the normal saved meeting Markdown. Once a meeting is
saved, `agent-handoff.md` switches to `Status: ready` and `state.json` can
point the agent at the final transcript path. `agent-watcher-state.json` lets
Codex or Cowork record the last final transcript it already handled so repeat
watchers stay quiet. Lines marked
`[partial]` in the live transcript are streaming ASR hypotheses, not durable
diarized transcript output. `preview.html` is rewritten with the latest
transcript as a direct-file snapshot. Transcripted also serves the same preview
on loopback, where it updates in place without full-page refreshes.

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

## Timeline

Timeline state is app-owned and stays under the Transcripted Application
Support root:

- timeline DB: `~/Library/Application Support/Transcripted/state/timeline.sqlite`
- timeline screenshots: `~/Library/Application Support/Transcripted/recordings/screenshots/`

The future agent-readable daily timeline Markdown will live in the relocatable
capture library:

- timeline Markdown: `<capture-library>/timeline/`

Screen pixels and screen-derived text stay out of the capture library unless a
future phase writes user/agent-readable Markdown summaries there.

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

- `TranscriptedCLI` first follows the app-selected capture library from `mcp-directories.json` or the app's `transcriptSaveLocation` preference, then falls back to the current Transcripted capture folders, then legacy Draft `.../transcripts/`, then `~/Documents/Transcripted/`; explicit `--data-dir`, `--meetings-dir`, `--dictations-dir`, `--timeline-dir`, or matching env vars still override this
- `TranscriptedMCP` first follows the app-selected capture library from `mcp-directories.json` or the app's `transcriptSaveLocation` preference, then falls back to the current-plus-legacy read order. It keeps its SQLite index under `~/Library/Application Support/Transcripted/cache/` by default; if `TRANSCRIPTED_DATA_DIR` is set, it instead keeps the index in that shared root unless `TRANSCRIPTED_INDEX_DIR` is also set. `TRANSCRIPTED_TIMELINE_DIR` can override just the timeline directory.
- `TranscriptedQA` now defaults to the current Transcripted meetings/dictations/timeline/state/log layout, uses `~/Library/Application Support/Transcripted/logs/app.jsonl` for log validation, falls back to legacy Draft and then `~/Documents/Transcripted/`, and accepts explicit `--path`, `--dictations-path`, `--timeline-path`, `--state-dir`, and `--log-path` overrides for nonstandard setups
