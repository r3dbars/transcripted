# Agent Onboarding

This repo already has multiple layers of documentation. The main improvement
needed for coding agents is consistency: know which docs are current, which are
historical, and which local doc to read before editing a subsystem.

## Read Order

1. `README.md`
2. `AGENTS.md` or root `CLAUDE.md`
3. `docs/repo-layout.md`
4. `docs/agent-onboarding.md`
5. `Sources/CLAUDE.md`
6. the nearest local `CLAUDE.md`
7. `Tests/README.md` when touching verification or package seams
8. `docs/storage-paths.md` when touching persisted output or path resolution
9. `docs/release-packaging.md` and `docs/sparkle-updates.md` when touching packaging, notarization, releases, or in-app updates
10. `Sources/Observability/CLAUDE.md` when touching crash reporting, analytics, or Sparkle plumbing
11. `Sources/Reliability/CLAUDE.md` when touching wake / sleep recovery or hotkey recovery
12. source comments

For the active directory map and command surface, prefer `docs/repo-layout.md`.

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
- `Tools/*/CLAUDE.md`
  Standalone tool package docs where present.
- `Tests/README.md`
  Verification surfaces and fast-test runner rules.
- `docs/storage-paths.md`
  Canonical app, tool, and fallback storage layout.
- `docs/release-packaging.md` + `docs/sparkle-updates.md`
  Release, notarization, Sparkle, and Homebrew contract.
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
- `Tools/TranscriptedCLI/CLAUDE.md`
  Standalone diarization CLI.

## Historical Zones

Treat these as reference, not source of truth for runtime behavior on `main`:

- `docs/archive/*`
- `archive/backend-beta-worker/*`
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
