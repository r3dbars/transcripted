# Repo Layout

This is the canonical map of the live repo surface on `main`.

## Root Contract

The repo root should only expose:

- live product code and assets
- canonical build and verification entry points
- public project policy docs
- clearly marked historical/archive zones

If a file or folder does not fit one of those jobs, it should usually live
under `scripts/`, `Tools/`, `docs/archive/`, or `archive/`.

When a root shell command is part of the public repo surface, prefer a thin
wrapper at the root and keep the implementation under `scripts/`.

## Main Commands

Use these as the active command surface:

```bash
bash scripts/dev/agent-preflight.sh
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
bash run-daily-audio-reliability.sh
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode corpus
swift test
```

Command ownership:

- `scripts/dev/agent-preflight.sh` — agent preflight and suggested verification map for the current branch
- `build-deps.sh` — thin root wrapper for the dependency build entrypoint
- `build.sh` — thin root wrapper for the authoritative local app build
- `build-beta.sh` — thin root wrapper for signed beta/distribution builds
- `run-tests.sh` — thin root wrapper for curated fast tests
- `run-integration-smoke.sh` — thin root wrapper for app/core smoke verification
- `run-daily-audio-reliability.sh` — thin root wrapper for the interactive and synthetic daily audio reliability check
- `scripts/ops/transcripted-qa-bench.sh` — orchestrated QA tester pass with local report output
- `scripts/ops/validate-meeting-corpus.py` — local-only meeting corpus validator for Downloads fixtures
- `swift test` — `TranscriptedCore` package seam tests

For helper and legacy scripts, see `scripts/README.md`.

## Directory Map

- `.agents/` — machine-readable agent maps, currently the path-to-verification matrix
- `.agent-review/` — sanitized review evidence for agent PRs, not current UI truth
- `Sources/` — macOS app target
- `Sources/Accessibility/` — AX helpers for overlay positioning
- `Sources/Beta/` — beta-only configuration
- `Sources/Capture/` — physical dictation trigger capture and meeting hotkey routing
- `Sources/Dictation/` — dictation persistence
- `Sources/Meeting/` — app-side meeting bridge into `TranscriptedCore`
- `Sources/Observability/` — analytics, crash reporting, debug logging, and Sparkle updater
- `Sources/Reliability/` — wake/sleep recovery
- `Sources/Speech/` — local STT engines, router, and audio recovery
- `Sources/Support/` — shared app utilities such as paths, permissions, hotkeys, and constants
- `Sources/TranscriptedCore/` — reusable meeting transcription library
- `Sources/UI/` — app-facing UI grouped into `Overlay/`, `MenuBar/`, `Settings/`, `AgentConnect/`, and `Shared/`
- `Tests/` — fast tests, package tests, and integration smoke sources
- `Tools/` — standalone sibling packages; see `Tools/README.md`
- `docs/` — live project docs
- `docs/archive/` — archived planning, reviews, and historical notes
- `archive/` — historical code and legacy tooling kept out of the live product surface
- `config/` — app config artifacts including entitlements and nightly security manifests
- `Resources/` — bundled app assets
- `scripts/entrypoints/` — implementations behind the thin root command wrappers

## Docs Map

Use these docs for these jobs:

- `README.md` — public product overview and quick start
- `AGENT_START.md` — short agent entrypoint
- `CONTRIBUTING.md` — contributor setup and contribution norms
- `AGENTS.md` — Codex-specific workflow rules
- `WORKFLOW.md` - local GitHub Issues to Codex agent workflow contract
- `CLAUDE.md` — Claude-specific repo orientation
- `docs/agent-onboarding.md` — how to interpret the repo’s doc layers
- `docs/docs.md` - documentation tone, drift checks, and follow-up PR rules
- `docs/agent-issue-orchestration.md` - how to queue GitHub issues for the local Codex runner
- `docs/storage-paths.md` — canonical storage and fallback path map
- `docs/audio-reliability-daily-check.md` — daily manual audio reliability loop and evidence contract
- `docs/qa-test-bench.md` — orchestrated QA tester bench for quick, deep, live, artifact, and synthetic audio passes
- `docs/qa-issue-500-meeting-audio.md` — manual WebRTC / meeting-volume QA matrix for issue #500
- `docs/release-packaging.md` — release packaging flow
- `docs/sparkle-updates.md` — Sparkle update contract
- `docs/qa-parakeet-start-failure-smoke.md` — manual BET-88 validation checklist for Parakeet start-failure recovery
- `Tests/README.md` — verification surfaces and fast-test runner behavior
- `.agents/test-matrix.yml` — quick path-to-verification map for agents
- `Sources/*/CLAUDE.md` — subsystem-local ownership and verification notes

## Historical Zones

Treat these as reference, not current product surface:

- `archive/backend-beta-worker/`
- `archive/evals/`
- `docs/archive/`
- `docs/archive/screenshots/`
- `.claude/`
