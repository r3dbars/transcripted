# Tools

`Tools/` contains standalone packages that live next to the app, but are not part of the macOS app target.

## Packages

- `TranscriptedCaptureKit/` — shared library for capture-library resolution and capture-Markdown parsing, used by the CLI and MCP packages
- `TranscriptedCLI/` — local context, offline transcription, and offline diarization CLI
- `TranscriptedMCP/` — read-only MCP server for saved meetings and dictations
- `TranscriptedQA/` — artifact validation and QA CLI
- `SpeakerEvalHarness/` — headless AMI speaker-naming eval harness for diarization, embedding, clustering, and cross-meeting match sweeps

## Read first

Each package has its own local `CLAUDE.md` and `Package.swift`.

- `Tools/SpeakerEvalHarness/CLAUDE.md`
- `Tools/TranscriptedCaptureKit/CLAUDE.md`
- `Tools/TranscriptedCLI/CLAUDE.md`
- `Tools/TranscriptedMCP/CLAUDE.md`
- `Tools/TranscriptedQA/CLAUDE.md`

## Why this exists

Keeping these as sibling packages makes the repo easier to understand:

- the app lives under `Sources/`
- shared meeting library code lives under `Sources/TranscriptedCore/`
- standalone operator and agent tooling lives under `Tools/`
