# Agent Onboarding

This repo already has several layers of documentation. The important part is
knowing which docs describe the live dictation-plus-meetings app and which ones
are only historical context.

## Read Order

1. `README.md`
2. `AGENTS.md` or root `CLAUDE.md`
3. `docs/storage-paths.md`
4. the nearest local `CLAUDE.md`
5. source comments only after the local docs and file list agree

## Current Documentation Layers

- `README.md`
  Product-level repo overview and current storage model.
- `AGENTS.md`
  Codex-oriented workflow rules, build/test expectations, and doc-update triggers.
- `CLAUDE.md`
  Repo overview, architecture summary, and current runtime truth.
- `docs/storage-paths.md`
  Current filesystem layout, capture-library behavior, and tool compatibility notes.
- `docs/agent-connect.md`
  User-facing agent and MCP connection model.
- `Sources/CLAUDE.md`
  App-target map and bootstrap wiring.
- `Sources/*/CLAUDE.md`
  Local subsystem docs.
- `Tools/*/CLAUDE.md`
  Standalone tool package docs.
- `docs/archive/`
  Historical planning, merge, and backlog material.

## What To Trust Most

When docs disagree, prefer:

1. current repo-level docs
2. current source files
3. current local `CLAUDE.md` files whose file lists match the tree
4. `docs/archive/` only as reference

## Storage Reality

The app no longer treats the Draft folder as the primary storage root.

Current defaults:

- app root: `~/Library/Application Support/Transcripted/`
- capture library: `~/Library/Application Support/Transcripted/captures/`
- meetings: `.../captures/meetings/`
- dictations: `.../captures/dictations/`
- state: `.../state/`
- cache: `.../cache/`
- logs: `.../logs/`
- tmp recordings: `.../tmp/recordings/`

The capture library is user-configurable. A few standalone tools still fall
back to legacy Draft or `~/Documents/Transcripted` locations when newer folders
are absent.

## Validation Layers

This repo has four distinct verification surfaces:

- `bash build.sh`
  The authoritative app build.
- `bash run-tests.sh`
  Curated fast tests for app-facing logic.
- `bash run-integration-smoke.sh`
  App-to-core integration smoke.
- `swift test`
  Swift Package tests for `TranscriptedCore`.

Rule of thumb:

- after Swift edits, run `bash build.sh` and `bash run-tests.sh`
- if you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`
- if you touch `Package.swift` or the public core seam, also run `swift test`

## Highest-Value Local Docs

- `Sources/CLAUDE.md`
  App boot order and shared service ownership.
- `Sources/Meeting/CLAUDE.md`
  Meeting adapter, queueing, and storage split.
- `Sources/TranscriptedCore/CLAUDE.md`
  Library boundary, injection seams, and default paths.
- `Sources/Reliability/CLAUDE.md`
  Wake / hotkey recovery coordination.
- `Tools/TranscriptedMCP/CLAUDE.md`
  Read-only MCP server behavior and directory resolution.

## When To Update Docs

Update docs in the same change whenever you modify:

- build or test commands
- storage locations or capture-library behavior
- env vars or tool path resolution
- app/core ownership boundaries
- wake-recovery or hotkey assumptions
- agent-facing artifact formats or folder conventions

## Good Local Doc Shape

The strongest docs in this repo do five things:

- say what the directory owns
- name the important files
- explain lifecycle or data flow
- call out non-obvious constraints
- give exact verification commands
