# Storage Refactor Plan

## Goal

Refactor Transcripted storage so that:

- user-facing captures are lean, portable, and easy to point agents at
- app-owned state is separate from user-owned content
- Markdown becomes the single canonical capture format
- MCP and CLI build their own caches instead of depending on app-written sidecars
- the capture library can be relocated to places like an Obsidian vault

This document describes the target design and the execution plan. It does **not**
change the current runtime truth yet. For the current live paths, keep using
`docs/storage-paths.md` until the refactor lands.

## Target Layout

App-owned internal storage:

```text
~/Library/Application Support/Transcripted/
  state/
    speakers.sqlite
    failed_transcriptions.json
    stats.sqlite
  cache/
    mcp_index.sqlite
  logs/
    app.jsonl
  tmp/
    recordings/
```

User-owned capture library:

```text
<capture-library>/
  meetings/
    <meeting>.md
  dictations/
    Dictations_YYYY-MM-DD.md
```

Default capture library:

```text
~/Library/Application Support/Transcripted/captures/
```

Relocatable examples:

```text
~/Documents/Obsidian/MyVault/Transcripted/
~/Documents/Raw Context/Transcripted/
```

## Explicit Non-Goals

The target design removes these from the capture folders:

- `Call_*.json`
- `Dictations_*.json`
- `transcripted.json`
- `AGENT.md`
- `CLAUDE.md`
- persistent `speaker_clips/`

## Design Rules

1. Markdown is canonical.
2. `captures/` is user content and may live outside Application Support.
3. `state/`, `cache/`, `logs/`, and `tmp/` remain app-owned and non-portable.
4. Caches are rebuildable and must never be treated as source of truth.
5. Agents should be able to read only the capture library and still get useful context.
6. Internal app behavior must not rely on agent-facing sidecar duplication.

## Canonical Markdown Shape

### Meetings

Meeting Markdown already carries most of the needed structure in YAML frontmatter
plus a timestamped transcript body. The refactor should keep that approach and
make sure the frontmatter is sufficient for parsing without any `.json` sidecar.

Required meeting frontmatter fields:

- `capture_id`
- `capture_type: meeting`
- `date`
- `time`
- `duration`
- `processing_time`
- `transcription_engine`
- `diarization_engine`
- `mic_utterances`
- `system_utterances`
- `mic_speakers`
- `system_speakers`
- `total_word_count`
- `speakers:` with stable per-speaker ids and persistent db ids where available

The transcript body remains the human-readable source for utterances:

```text
[00:12] [System/Alex] We should ship this Friday.
```

### Dictations

Dictation Markdown becomes the canonical source for both day-level and
entry-level reads. Each entry needs stable parseable metadata in the Markdown
itself, not only in a JSON sidecar.

Each dictation entry should include:

- `Entry ID: ...`
- `Captured: ...`
- `Source app: ...`
- `Bundle ID: ...` when available
- `Delivery: pasted|copied|failed`
- `Words: ...`
- `Characters: ...`

Example:

```md
## 9:15 AM - First note from the morning

Entry ID: `dictation-20260410-091500-123`
Captured: 2026-04-10 09:15:00
Source app: Messages
Bundle ID: `com.apple.MobileSMS`
Delivery: pasted
Words: 7
Characters: 34

first note from the morning
```

## Identity Rules

Relocatable captures mean absolute file paths cannot be the stable identity.

The refactor should use:

- a stable `capture_id` for each meeting Markdown file
- a stable `entry_id` for each dictation entry
- stats records keyed by `capture_id`, not only `transcript_path`

During migration we can keep path fields temporarily for compatibility, but the
new system should treat path as a resolvable location, not as identity.

## Why This Is Simpler

This removes the current duplicate-write model where the app writes Markdown,
JSON sidecars, a meeting index, and helper docs for the same capture event.

Benefits:

- fewer files per capture
- less drift between duplicated artifacts
- simpler rename behavior
- cleaner folders for humans and agents
- relocatable user content without moving app state
- one parser path for MCP and CLI instead of app-owned agent exports

## Implementation Phases

### Phase 1: Introduce New Storage Layout

Create a new storage abstraction that separates:

- app root: `~/Library/Application Support/Transcripted/`
- capture library: configurable path
- internal state/cache/log/tmp paths under the app root

Primary touchpoints:

- `Sources/DraftPaths.swift`
- `Sources/Dictation/DictationStoragePaths.swift`
- `Sources/Meeting/MeetingStoragePaths.swift`
- `Sources/Meeting/MeetingSessionController.swift`
- `Sources/TranscriptedCore/Services/CoreStoragePaths.swift`
- settings UI for choosing the capture library

Deliverables:

- default `Transcripted` app-support root
- configurable capture library path
- auto-create `meetings/` and `dictations/` in the chosen library
- keep legacy Draft paths readable until migration completes

### Phase 2: Make Markdown The Only Capture Artifact

Stop writing capture-side JSON artifacts and helper docs.

Meetings:

- remove `AgentOutput.writeTranscriptJSON(...)`
- remove `AgentOutput.writeIndex(...)`
- remove `AgentOutput.writeAgentReadme(...)`
- simplify transcript rename logic so it only manages Markdown filenames

Dictations:

- remove `DictationAgentOutput`
- add stable `Entry ID` and normalized metadata lines to each Markdown entry

Primary touchpoints:

- `Sources/TranscriptedCore/Storage/TranscriptSaver.swift`
- `Sources/TranscriptedCore/Storage/AgentOutput.swift`
- `Sources/TranscriptedCore/Storage/TranscriptFormatter.swift`
- `Sources/Meeting/MeetingTranscriptStyler.swift`
- `Sources/Dictation/DictationTranscriptWriter.swift`
- tests that currently expect `.json` sidecars or `transcripted.json`

### Phase 3: Rebuild MCP And CLI Around Markdown Parsing

Move agent-tool indexing responsibility out of the app and into MCP/CLI.

Rules:

- parse Markdown directly
- build `mcp_index.sqlite` in `Application Support/Transcripted/cache/`
- do not write anything into the capture library except user-owned Markdown

Primary touchpoints:

- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptLoader.swift`
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptIndex.swift`
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/DataDirectories.swift`
- `Tools/TranscriptedMCP/Sources/TranscriptedMCP/ToolHandlers.swift`
- `Tools/TranscriptedCLI/Sources/TranscriptedCLI/ContextStore.swift`

Compatibility path:

- during rollout, MCP/CLI may support both old JSON and new Markdown
- once migrated, remove the JSON parser path

### Phase 4: Remove Persistent Speaker Clips

Speaker clips should become temporary flow artifacts, not durable storage.

Plan:

- stop persisting clips under `state/speaker_clips/`
- generate naming clips into `tmp/`
- clean them up when naming completes or is discarded

Tradeoff:

- speaker naming will no longer survive indefinitely from saved clip files alone
- if delayed naming across launches is still required, it must be regenerated
  from retained raw audio or explicitly redesigned

Primary touchpoints:

- `Sources/TranscriptedCore/Speaker/SpeakerClipExtractor.swift`
- `Sources/TranscriptedCore/Pipeline/TranscriptionPipelineRunner.swift`
- `Sources/TranscriptedCore/Speaker/SpeakerNamingCoordinator.swift`

### Phase 5: Migrate Stats Identity

`stats.sqlite` currently records transcript paths. That is fragile once the
capture library becomes relocatable.

Plan:

- add `capture_id` to stats records
- treat path as a convenience field, not the primary key
- rebuild or backfill ids for existing captures during migration

Primary touchpoints:

- `Sources/TranscriptedCore/Stats/StatsDatabase.swift`
- `Sources/TranscriptedCore/Stats/StatsDatabaseQueries.swift`
- `Sources/TranscriptedCore/Stats/StatsService.swift`
- `Sources/TranscriptedCore/Storage/TranscriptScanner.swift`

### Phase 6: Collapse Logging

Target one durable structured log:

- keep `logs/app.jsonl`
- retire `~/draft-debug.log`
- decide whether `events.jsonl` remains distinct or merges into `app.jsonl`

Primary touchpoints:

- `Sources/Observability/AppLogger.swift`
- `Sources/Observability/EventReporter.swift`
- `Sources/TranscriptedCore/Logging/FileLogger.swift`

## Migration Strategy

On first launch after the refactor:

1. Create `~/Library/Application Support/Transcripted/` if missing.
2. Default the capture library to `~/Library/Application Support/Transcripted/captures/`.
3. Detect legacy Draft paths.
4. Offer:
   - use legacy location for now
   - move captures into the default Transcripted library
   - move captures into a custom library
5. Rebuild `mcp_index.sqlite`.
6. Leave internal state in Application Support even when captures move elsewhere.

Optional cleanup after successful migration:

- remove old sidecars
- remove `transcripted.json`
- remove helper docs in capture folders
- remove old Draft-only capture directories once no longer referenced

## Verification

App-side verification:

- `bash build.sh`
- `bash run-tests.sh`
- `bash run-integration-smoke.sh`

Core/package verification when storage seams change:

- `swift test`

Refactor-specific verification:

- save a meeting and verify only one `.md` capture appears
- save a dictation and verify only one daily `.md` appears
- point capture library to a custom folder and verify new captures land there
- rebuild MCP index and confirm meeting + dictation search still works
- move the capture library and confirm stats still resolve captures by id
- complete and discard the speaker naming flow without persistent clip leakage

## Acceptance Criteria

- Capture folders contain only Markdown files organized into `meetings/` and `dictations/`.
- No app-owned JSON sidecars or helper docs are emitted into the capture library.
- MCP and CLI can answer existing read/search flows from Markdown plus cache.
- `stats.sqlite` remains functional after moving the capture library.
- `speaker_clips/` no longer exists as persistent state.
- The app no longer depends on the legacy Draft-named root for new installs.

## Recommended Execution Order

1. Introduce the new path abstraction and configurable capture library.
2. Strengthen Markdown schemas so meetings and dictations are fully parseable.
3. Teach MCP and CLI to index Markdown.
4. Remove sidecar/index/helper-doc writes.
5. Remove persistent speaker clips.
6. Migrate stats identity away from absolute paths.
7. Collapse logging and finish legacy cleanup.
