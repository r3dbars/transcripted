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
bash build.sh --no-open
bash build-beta.sh '' <user>
bash run-tests.sh
bash run-integration-smoke.sh
bash run-e2e-smoke.sh
bash run-slow-pasteback-smoke.sh
bash run-live-capture-smoke.sh
bash run-daily-audio-reliability.sh
python3 scripts/ops/release-gate-report.py
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode full
bash scripts/ops/transcripted-qa-bench.sh --mode ui
bash scripts/ops/transcripted-qa-bench.sh --mode corpus
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare
swift test
```

Command ownership:

- `scripts/dev/agent-preflight.sh` — agent preflight and suggested verification map for the current branch
- `build-deps.sh` — thin root wrapper for the dependency build entrypoint
- `build.sh` — thin root wrapper for the authoritative local app build; use `--no-open` for agent verification
- `build-beta.sh` — thin root wrapper for signed beta/distribution builds
- `run-tests.sh` — thin root wrapper for curated fast tests
- `run-integration-smoke.sh` — thin root wrapper for app/core smoke verification
- `run-e2e-smoke.sh` — thin root wrapper for deterministic release-critical artifact smoke
- `run-slow-pasteback-smoke.sh` — thin root wrapper for the deterministic fake slow Cmd+V pasteback target smoke
- `run-live-capture-smoke.sh` — thin root wrapper for local hardware/TCC capture smoke
- `run-daily-audio-reliability.sh` — thin root wrapper for the interactive and synthetic daily audio reliability check
- `scripts/ops/release-gate-report.py` — single pre-merge/release report covering QA bench, telemetry, release surfaces, and local log warnings
- `scripts/ops/transcripted-qa-bench.sh` — orchestrated QA tester pass with local report output, including `--mode ui` for the Accessibility-driven onboarding/menu bar/Home/Settings smoke
- `scripts/ops/validate-meeting-corpus.py` — local-only meeting corpus validator for Downloads fixtures
- `scripts/ops/compare-meeting-corpus.py` — local-only Transcripted-vs-Zoom corpus comparator for Downloads fixtures
- `swift test` — `TranscriptedCore` package seam tests

For helper and legacy scripts, see `scripts/README.md`.

## Directory Map

- `.agents/` — machine-readable agent maps for path verification and QA gates
- `.agent-review/` — sanitized review evidence for agent PRs, not current UI truth
- `.github/` — issue templates, PR template, and repository workflows
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
- `Sources/UI/` — app-facing UI grouped into `Overlay/`, `MenuBar/`, `Settings/`, and `Shared/`
- `Tests/` — fast tests, package tests, and integration smoke sources
- `Tools/` — standalone sibling packages; see `Tools/README.md`
- `docs/` — live project docs
- `docs/strategy/` — dated strategy syntheses and deep dives for product, market, and architecture planning
- `docs/archive/` — archived planning, reviews, and historical notes
- `archive/` — historical code and legacy tooling kept out of the live product surface
- `config/` — app config artifacts including entitlements and nightly security manifests
- `Casks/` — committed Homebrew cask release surface
- `Resources/` — bundled app assets
- `scripts/entrypoints/` — implementations behind the thin root command wrappers

Dated audit and autoeval docs in `docs/` are point-in-time evidence. Use the
current command map, local `CLAUDE.md`, and `.agents/test-matrix.yml` for live
instructions unless a dated doc is explicitly the target of the task.

## Docs Map

Use these docs for these jobs:

- `README.md` — public product overview and quick start
- `AGENT_START.md` — short agent entrypoint
- `CONTRIBUTING.md` — contributor setup and contribution norms
- `AGENTS.md` — Codex-specific workflow rules
- `WORKFLOW.md` - local GitHub Issues to Codex agent workflow contract
- `.github/` — GitHub issue templates, PR checklist, and workflow automation
- `CLAUDE.md` — Claude-specific repo orientation
- `docs/agent-onboarding.md` — how to interpret the repo’s doc layers
- `docs/activation-lane.md` — saved Markdown, agent payoff, and return-use routing
- `docs/agent-closeout.md` — compact coordinator and agent handoff format
- `docs/agent-connect.md` — saved-folder and MCP handoff guidance for agents
- `docs/docs.md` - documentation tone, drift checks, and follow-up PR rules
- `docs/strategy/` - point-in-time strategy synthesis and deep-dive docs for planning context
- `docs/agent-issue-orchestration.md` - how to queue GitHub issues for the local Codex runner
- `docs/live-meeting-codex-sidecar.md` — opt-in live meeting sidecar and agent workspace notes
- `docs/ops-credentials.md` — Sentry, PostHog, GitHub, and Cloudflare credential lanes
- `docs/storage-paths.md` — canonical storage and fallback path map
- `docs/audio-reliability-daily-check.md` — daily manual audio reliability loop and evidence contract
- `docs/qa-test-bench.md` — orchestrated QA tester bench for quick, deep, corpus, corpus-compare, live, artifact, and synthetic audio passes
- `docs/test-automation-strategy.md` — agent-first QA coverage map, gate strategy, and automation roadmap
- `docs/qa-issue-500-meeting-audio.md` — manual WebRTC / meeting-volume QA matrix for issue #500
- `docs/release-packaging.md` — release packaging flow
- `docs/sparkle-updates.md` — Sparkle update contract
- `docs/qa-parakeet-start-failure-smoke.md` — historical BET-88 validation checklist for the closed Parakeet start-failure recovery gate
- `Tests/README.md` — verification surfaces and fast-test runner behavior
- `.agents/test-matrix.yml` — quick path-to-verification map for agents
- `.agents/qa-gates.yml` — product-risk-to-proof gate map for agents
- `Sources/*/CLAUDE.md` — subsystem-local ownership and verification notes

## Historical Zones

Treat these as reference, not current product surface:

- `archive/backend-beta-worker/`
- `archive/evals/`
- `docs/archive/`
- `docs/archive/screenshots/`
- `.claude/`
