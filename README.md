<img width="625" height="329" alt="Screenshot 2026-04-10 at 7 31 17 PM" src="https://github.com/user-attachments/assets/86453a3e-9eee-4525-b985-777366296cf5" />


## Transcripted
Transcripted is a local Mac app for dictation and meeting capture that turns
spoken words into structured files your agent can actually use.

Today it is a practical dictation and meeting tool. It keeps the capture flow
local, saves plain files on disk, and makes that context easy to hand off to
agents later.

## What It Does

- Dictate into any app and paste text back
- Record meetings locally
- Save human-readable Markdown and agent-readable JSON files on disk
- Let Claude, Codex, OpenClaw, or any other agent work from those files later

## How It Works

1. Capture dictation or a meeting.
2. Transcripted processes the audio locally on your Mac.
3. It saves durable Markdown and JSON artifacts to disk.
4. Your agent can load the right slice later instead of rereading everything.

## Artifacts, Not A Black Box

Transcripted is opinionated about file output because inspectable artifacts are
more useful than opaque app state.

Example meeting transcript:

```md
# Meeting with Alex

## Full Transcript

**[00:00] [Mic/You]**
Thanks for making time today.

**[00:04] [System/Alex]**
Happy to help. Let's get started.
```

Example meeting sidecar:

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

Example dictation artifact:

```md
---
title: "Dictations for April 7, 2026"
date: 2026-04-07
capture_type: dictation_day
---

## 9:15 AM - First note from the morning

Source app: Messages
Timestamp: 2026-04-07 09:15:00

first note from the morning
```

## Local By Default

Transcripted keeps its core workflows on-device:

- dictation capture and saved dictation logs stay on your Mac
- meeting capture, transcription, and saved transcripts stay on your Mac
- agent-facing artifacts are plain local files you can inspect directly

Default locations on a new install are:

- capture library: `~/Library/Application Support/Transcripted/captures/`
- meetings: `~/Library/Application Support/Transcripted/captures/meetings/`
- dictations: `~/Library/Application Support/Transcripted/captures/dictations/`
- app state, logs, and temp files: `~/Library/Application Support/Transcripted/{state,logs,tmp}/`

You can move the capture library in Settings. Transcripted keeps its databases,
logs, cache, and temporary recordings under `~/Library/Application Support/Transcripted/`
even when captures live somewhere else.

For the full storage map, compatibility paths, and migration details, see
`docs/storage-paths.md`.

## Build

```bash
bash build-deps.sh
bash build.sh
```

`build.sh` is the local development path. It expects the unified dependency
artifacts from `build-deps.sh` and then signs the app for stable local
permissions on the current machine.

For signed DMG packaging and notarization workflow notes, see
`docs/release-packaging.md`.

## Tests

```bash
bash run-tests.sh
```

If you touch meeting integration or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
```

For build, release, and legacy helper scripts, see `scripts/README.md`.
For the active repo map and command surface, see `docs/repo-layout.md`.

Legacy Draft and standalone Transcripted storage layouts are still recognized
for compatibility. See `docs/storage-paths.md` for details.

## Contributing And Security

- See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and architecture notes
- See [SECURITY.md](SECURITY.md) for privacy architecture and vulnerability reporting
- See `docs/repo-layout.md` for the current directory map and canonical command surface
