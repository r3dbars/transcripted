# Agent Onboarding

This repo already has multiple layers of documentation. The main improvement
needed for coding agents is consistency: know which docs are current, which are
historical, and which local doc to read before editing a subsystem.

## Read Order

1. `README.md`
2. `AGENTS.md` or root `CLAUDE.md`
3. the nearest local `CLAUDE.md`
4. source comments

## Current Documentation Layers

- `README.md`
  Product intent and repo truth.
- `AGENTS.md`
  Codex-oriented workflow rules and build/test guardrails.
- `CLAUDE.md`
  Claude-oriented repo overview and runtime truth.
- `Sources/CLAUDE.md`
  App bootstrap and initialization order.
- `Sources/*/CLAUDE.md`
  Local subsystem docs.
- `archive/backend-beta-worker/CLAUDE.md`
  Archived beta worker contract.
- `Tools/*/CLAUDE.md`
  Standalone tool package docs where present.
- `docs/archive/`
  Historical merge/todo docs and other archived planning notes.

## What To Trust Most

When docs disagree, prefer:

1. current repo-level docs
2. current source files
3. current local `CLAUDE.md` files whose file lists match the tree
4. `docs/archive/` only as context

## Validation Layers

This repo has four different verification surfaces that agents should treat as
distinct:

- `bash build.sh`
  The authoritative app build.
- `bash run-tests.sh`
  Curated fast tests for app-facing logic.
- `bash run-integration-smoke.sh`
  App/Core integration smoke.
- `swift test`
  SPM tests for `TranscriptedCore`.

Rule of thumb:

- after Swift edits, run `bash build.sh` and `bash run-tests.sh`
- if you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`

## Highest-Value Local Docs

- `Sources/CLAUDE.md`
  App boot order and shared state wiring.
- `Sources/Meeting/CLAUDE.md`
  App/Core bridge, meeting storage, runtime lifecycle.
- `Sources/TranscriptedCore/CLAUDE.md`
  Library boundary, pipeline layout, embedder seams.
- `archive/backend-beta-worker/CLAUDE.md`
  Archived beta worker endpoints and data model.
- `Tools/TranscriptedCLI/CLAUDE.md`
  Standalone diarization CLI.

## Historical Zones

Treat these as reference, not source of truth for runtime behavior on `main`:

- `docs/archive/*`
- older cloud/API references in comments or outdated docs

## When To Update Docs

Update docs in the same change whenever you modify:

- build/test commands
- storage locations
- feature flags like `BETA_BUILD`
- cross-module ownership boundaries
- threading/actor-isolation assumptions
- output schemas consumed by tools or agents
- new directories that become real edit targets

## Good Local Doc Shape

The strongest docs in this repo do five things:

- say what the directory owns
- name the important files
- explain lifecycle or data flow
- call out non-obvious constraints
- give exact verification commands

If a doc does not help an unfamiliar agent answer "what owns this, what can I
change safely, and how do I verify it," it should be tightened.
