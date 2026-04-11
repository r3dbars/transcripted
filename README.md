<img width="625" height="329" alt="Screenshot 2026-04-10 at 7 31 17 PM" src="https://github.com/user-attachments/assets/86453a3e-9eee-4525-b985-777366296cf5" />

# Transcripted

Transcripted is a local macOS menu bar app for two concrete workflows:

- dictation into any app
- meeting capture and transcription

The current product is not the older draft / ghostwriting flow. `main` is the
dictation-plus-meetings app.

## What Exists Today

- Global dictation with paste-back or clipboard fallback
- Local meeting recording, diarization, transcription, and transcript browsing
- Human-readable Markdown artifacts on disk
- Agent-readable meeting sidecars and indexes
- A read-only MCP server and companion CLIs for searching saved context

## Files You Get

Meeting captures are saved as plain files in the meetings capture folder:

- `MeetingTitle_YYYY-MM-DD_HH-mm-ss.md`
- matching `.json` sidecars
- `transcripted.json`
- `AGENT.md`
- `CLAUDE.md`

Dictation captures are grouped by day:

- `Dictations_YYYY-MM-DD.md`

Each dictation day file contains timestamped sections with entry IDs, source app
metadata, delivery status, and the final text.

## Storage Model

Transcripted now separates user-facing captures from app-owned state.

Default app-owned root:

- `~/Library/Application Support/Transcripted/`

Default capture library:

- `~/Library/Application Support/Transcripted/captures/`

Default capture folders:

- `~/Library/Application Support/Transcripted/captures/meetings/`
- `~/Library/Application Support/Transcripted/captures/dictations/`

App-owned support folders:

- `~/Library/Application Support/Transcripted/state/`
- `~/Library/Application Support/Transcripted/cache/`
- `~/Library/Application Support/Transcripted/logs/`
- `~/Library/Application Support/Transcripted/tmp/recordings/`

The capture library is user-configurable from Settings. You can point it at a
folder like an Obsidian vault while Transcripted keeps databases, cache, logs,
and temporary recording scratch under Application Support.

Legacy `Draft` and `~/Documents/Transcripted` layouts still appear in some tool
fallback paths for old saved data, but they are no longer the default app
layout on `main`.

## Why File Output Matters

Transcripted is opinionated about inspectable artifacts instead of opaque app
state.

Meeting transcripts stay readable:

```md
# Meeting with Alex

## Full Transcript

**[00:00] [Mic/You]**
Thanks for making time today.

**[00:04] [System/Alex]**
Happy to help. Let's get started.
```

Meeting sidecars stay structured:

```json
{
  "version": "1.0",
  "recording": {
    "duration_seconds": 750,
    "engines": {
      "stt": "parakeet-tdt-v3",
      "diarization": "pyannote-offline"
    }
  },
  "speakers": [
    { "id": "mic_0", "name": "You" },
    { "id": "system_0", "name": "Alex" }
  ],
  "utterances": [
    { "start": 0.0, "end": 4.0, "speaker_id": "mic_0", "text": "Thanks for making time today." }
  ]
}
```

Dictation exports stay simple:

```md
---
title: "Dictations for April 7, 2026"
date: 2026-04-07
capture_type: dictation_day
---

# Dictations for April 7, 2026

## 9:15 AM - First note from the morning

Entry ID: `dictation-20260407-091500-000`
Captured: 2026-04-07T09:15:00-0500
Source app: Messages
Delivery: pasted
Words: 6
Characters: 28

first note from the morning
```

## Agents And MCP

Transcripted supports two agent connection styles:

- direct folder access to the capture library
- read-only MCP through `Tools/TranscriptedMCP/`

The app’s Agent Connect flow leads with one smart prompt that prefers MCP when
available and falls back to folders when it is not.

See [docs/agent-connect.md](docs/agent-connect.md) for the current setup flow.

## Build

```bash
bash build-deps.sh
bash build.sh
```

`build.sh` is the authoritative app build. The root `Package.swift` exists for
`TranscriptedCore` package tests and smoke coverage, not as the primary app
build path.

## Test

```bash
bash run-tests.sh
```

Also run these when relevant:

```bash
bash run-integration-smoke.sh
swift test
```

Rules of thumb:

- after Swift edits, run `bash build.sh` and `bash run-tests.sh`
- if you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`
- if you touch `Package.swift` or the public `TranscriptedCore` seam, also run
  `swift test`

## Repo Docs

Start here when orienting:

- `AGENTS.md`
- `CLAUDE.md`
- `docs/agent-onboarding.md`
- `docs/storage-paths.md`
- `Sources/CLAUDE.md`

## Transition Notes

Historical branches preserved from earlier phases:

- `legacy/transcripted-standalone`
- `pre-draft-takeover-2026-04-06`

Current `main` is the live dictation + meetings app. Older drafting-oriented
docs now live under `docs/archive/`.

## Contributing And Security

- See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and workflow
- See [SECURITY.md](SECURITY.md) and [docs/security-review-2026-04-10.md](docs/security-review-2026-04-10.md) for privacy and review notes
