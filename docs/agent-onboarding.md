# Agent Onboarding

This repo already has multiple layers of documentation. The main improvement
needed for coding agents is consistency: know which docs are current, which are
historical, and which local doc to read before editing a subsystem.

## Read Order

1. `AGENT_START.md`
2. `AGENTS.md` or root `CLAUDE.md`
3. `docs/repo-layout.md`
4. `docs/agent-onboarding.md`
5. `Sources/CLAUDE.md`
6. the nearest local `CLAUDE.md`
7. `Sources/Accessibility/CLAUDE.md` when touching focused-editor AX metadata, overlay placement, or paste-back context
8. `Sources/Beta/CLAUDE.md` when touching beta-build configuration
9. `Sources/Speech/CLAUDE.md` when touching STT, audio recovery, or device handling
10. `Sources/Support/CLAUDE.md` when touching shared preferences, paths, permissions, or install flows
11. `Sources/UI/CLAUDE.md` when touching overlay, menubar, onboarding, settings, or agent-connect UI
12. `Sources/Capture/CLAUDE.md` when touching hotkeys or physical dictation trigger routing
13. `Tests/README.md` when touching verification or package seams
14. `docs/storage-paths.md` when touching persisted output or path resolution
15. `docs/release-packaging.md` and `docs/sparkle-updates.md` when touching packaging, notarization, releases, or in-app updates
16. `Sources/Observability/CLAUDE.md` when touching crash reporting, analytics, or Sparkle plumbing
17. `Sources/Reliability/CLAUDE.md` when touching wake / sleep recovery or hotkey recovery
18. `Tools/*/CLAUDE.md` when touching standalone CLI, MCP, or QA tools
19. `scripts/README.md` when touching the shell entrypoints or release helpers
20. source comments

For the active directory map and command surface, prefer `docs/repo-layout.md`.

## Current Documentation Layers

- `README.md`
  Product intent and repo truth.
- `AGENT_START.md`
  Shortest safe start path for coding agents.
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
- `scripts/README.md`
  Canonical map for thin root wrappers vs script implementations.
- `Tests/README.md`
  Verification surfaces and fast-test runner rules.
- `.agents/test-matrix.yml`
  Machine-readable path-to-verification map for agents.
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

- run `scripts/dev/agent-preflight.sh` when starting or handing off a branch
- after Swift edits, run `bash build.sh` and `bash run-tests.sh`
- if you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run
  `bash run-integration-smoke.sh`
- if you touch `Package.swift`, `Sources/TranscriptedCore/`, or the public
  core package seam, also run `swift test`

## Highest-Value Local Docs

- `Sources/CLAUDE.md`
  App boot order and shared state wiring.
- `Sources/Accessibility/CLAUDE.md`
  Focused-editor AX metadata, overlay placement, and paste-back context.
- `Sources/Beta/CLAUDE.md`
  Beta-build configuration and archived beta-worker boundaries.
- `Sources/Meeting/CLAUDE.md`
  App/Core bridge, meeting storage, runtime lifecycle.
- `Sources/TranscriptedCore/CLAUDE.md`
  Library boundary, pipeline layout, embedder seams.
- `Sources/Speech/CLAUDE.md`
  Dictation STT ownership, recovery policy, and audio-device guardrails.
- `Sources/Support/CLAUDE.md`
  Shared preferences, permissions, app paths, and Claude Desktop install flow.
- `Sources/UI/CLAUDE.md`
  Overlay, menubar, onboarding, settings, and agent-connect ownership.
- `Sources/Capture/CLAUDE.md`
  Global trigger and hotkey routing behavior.
- `Tools/TranscriptedCLI/CLAUDE.md`
  Standalone local-context and offline diarization CLI.

## Historical Zones

Treat these as reference, not source of truth for runtime behavior on `main`:

- `docs/archive/*`
- `docs/archive/screenshots/*`
- `archive/backend-beta-worker/*`
- older cloud/API references in comments or outdated docs

## When To Update Docs

Update docs in the same change whenever you modify:

- build/test commands
- storage locations
- distribution-build feature flags
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
