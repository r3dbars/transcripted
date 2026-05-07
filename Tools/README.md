# Tools

`Tools/` contains standalone packages that live next to the app, but are not part of the macOS app target.

## Packages

- `TranscriptedCLI/` — local context and offline diarization CLI
- `TranscriptedCaptureParsing/` — shared Markdown capture parser for the CLI and MCP packages
- `TranscriptedMCP/` — read-only MCP server for saved meetings and dictations
- `TranscriptedQA/` — artifact validation and QA CLI

## Read first

Each package has its own local `CLAUDE.md` and `Package.swift`.

- `Tools/TranscriptedCLI/CLAUDE.md`
- `Tools/TranscriptedMCP/CLAUDE.md`
- `Tools/TranscriptedQA/CLAUDE.md`

## Why this exists

Keeping these as sibling packages makes the repo easier to understand:

- the app lives under `Sources/`
- shared meeting library code lives under `Sources/TranscriptedCore/`
- standalone operator and agent tooling lives under `Tools/`
