# Storage Paths

## Current App Layout On `main`

The current Transcripted app defaults to a Transcripted-named Application
Support root:

- app support root: `~/Library/Application Support/Transcripted/`
- default capture library: `~/Library/Application Support/Transcripted/captures/`

Users can point the capture library at a different folder in Settings via the
`transcriptSaveLocation` preference. When the current library still has saved
meetings, dictations, or writing, Settings offers to move or copy those captures
to the new folder before switching. Both skip destination name collisions instead of
overwriting. Copy never deletes originals. Move copies first, switches the
library, then sends each copied original to the Trash only if its copy exists
and the original hasn't changed since it was copied; anything else stays in
the old folder. App-owned state, cache, logs, and temp
files always stay under `~/Library/Application Support/Transcripted/`.

## Dictation

Dictation artifacts live under:

- root: `<capture-library>/dictations/`
- current runtime output: daily markdown files like `Dictations_2026-04-11.md`

`DictationStoragePaths.transcriptsFolder` points directly at the dictations
folder. There is no extra `transcripts/` subdirectory in the current app
layout.

## Writing

Saved writing lives under:

- root: `<capture-library>/writing/`
- runtime output: one Markdown file per local day, like `Writing_2026-09-25.md`.
  The format is in `docs/capture-format.md` ("Writing day files").

The main app writes these day files, never the keyboard. The folder is created
0700 and each file 0600. `FileManager.writingSupportDir` resolves the folder
(`FileManager.writingDirectory(in:)` for a library other than the current one),
and `mcp-directories.json` lists it as `writingDirectory`. That key is optional:
manifests written before Writing lack it and get rewritten once with it, and
tools that predate it ignore it. Choosing a new capture library prepares
`writing/` next to `meetings/` and `dictations/`, and Move and Copy carry
`writing/*.md` with the same collision and changed-since-copy rules as
dictation day files.

App-owned Writing state stays under Application Support when the capture
library moves:

- state root: `~/Library/Application Support/Transcripted/writing/`, holding
  the keyboard socket `ghost.sock`, `runtime.lock`, the text-free
  `Outcome Ledger/` and `Word Diary/` (Tilde's plaintext word diary isn't
  ported; accepted text is saved only by Save my writing), and the encrypted
  `Personal History/`
- models: `~/Library/Application Support/Transcripted/models/writing/<id>/model.gguf`,
  excluded from backup
- diagnostics log: `~/Library/Application Support/Transcripted/logs/writing-diagnostics.log`

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
- failed queue: `~/Library/Application Support/Transcripted/state/failed_transcriptions.json`
- queued import journals: `~/Library/Application Support/Transcripted/state/imported_transcription_queue/`
- runtime diagnostics marker: `~/Library/Application Support/Transcripted/state/runtime-diagnostics.json`
- dictionary-fix backups: `~/Library/Application Support/Transcripted/state/dictionary-fix-backups/` (one folder per "Fix them" from the Corrections list: the original text of each meeting it changed plus a `receipt.json`; kept 3 days so Undo survives a relaunch, pruned at launch, and dropped when the meeting is deleted from Home). Backups follow the meeting's file name, so renaming a fixed meeting drops its Undo at the next launch; the prune is skipped while the meetings folder is missing (for example on an unmounted drive)

Claude Desktop integration installs the bundled read-only MCP helper under:

- MCP helper: `~/Library/Application Support/Transcripted/mcp/transcripted-mcp`
- MCP directory manifest: `~/Library/Application Support/Transcripted/mcp-directories.json`

Script-installed experimental models (never downloaded by the app) live under:

- Parakeet Ultra: `~/Library/Application Support/Transcripted/models/parakeet-ultra/parakeet-tdt-0.6b-v3/`, installed by `scripts/models/parakeet-ultra/install.sh` and only used when its `transcripted-model.json` marker is present

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
- Writing diagnostics: `~/Library/Application Support/Transcripted/logs/writing-diagnostics.log`

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
- `TranscriptedQA` follows the app-selected capture library from `mcp-directories.json` or the `transcriptSaveLocation` preference, scans the current and existing legacy fallback capture directories, keeps state/log validation under the app-owned `~/Library/Application Support/Transcripted/` root, and accepts explicit `--path`, `--dictations-path`, `--state-dir`, and `--log-path` overrides for nonstandard setups
