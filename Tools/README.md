# Tools

`Tools/` contains standalone packages that live next to the app, but are not part of the macOS app target.

## Packages

- `TranscriptedCLI/` — local context and offline diarization CLI
- `TranscriptedMCP/` — read-only MCP server for saved meetings and dictations
- `TranscriptedQA/` — artifact validation and QA CLI
- `SpeakerLearningEval/` — local corpus scoreboard and autoresearch runner for meeting speaker learning

## Read first

Each package has its own local `CLAUDE.md` and `Package.swift`.

- `Tools/TranscriptedCLI/CLAUDE.md`
- `Tools/TranscriptedMCP/CLAUDE.md`
- `Tools/TranscriptedQA/CLAUDE.md`
- `Tools/SpeakerLearningEval/README.md`

## Why this exists

Keeping these as sibling packages makes the repo easier to understand:

- the app lives under `Sources/`
- shared meeting library code lives under `Sources/TranscriptedCore/`
- standalone operator and agent tooling lives under `Tools/`
