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
bash build-deps.sh
bash build.sh
bash run-tests.sh
bash run-integration-smoke.sh
swift test
```

Command ownership:

- `build-deps.sh` — thin root wrapper for the dependency build entrypoint
- `build.sh` — thin root wrapper for the authoritative local app build
- `build-beta.sh` — thin root wrapper for signed beta/distribution builds
- `run-tests.sh` — thin root wrapper for curated fast tests
- `run-integration-smoke.sh` — thin root wrapper for app/core smoke verification
- `swift test` — `TranscriptedCore` package seam tests

For helper and legacy scripts, see `scripts/README.md`.

## Directory Map

- `Sources/` — macOS app target
- `Sources/UI/` — app-facing UI grouped into `Overlay/`, `MenuBar/`, `Settings/`, `AgentConnect/`, and `Shared/`
- `Sources/Support/` — shared app utilities such as paths, permissions, hotkeys, and constants
- `Sources/Dictation/` — dictation persistence
- `Sources/Meeting/` — app-side meeting bridge into `TranscriptedCore`
- `Sources/Reliability/` — wake/sleep recovery
- `Sources/TranscriptedCore/` — reusable meeting transcription library
- `Tests/` — fast tests, package tests, and integration smoke sources
- `Tools/` — standalone sibling packages; see `Tools/README.md`
- `docs/` — live project docs
- `docs/archive/` — archived planning, reviews, and historical notes
- `archive/` — historical code and legacy tooling kept out of the live product surface
- `config/` — app config artifacts such as entitlements
- `Resources/` — bundled app assets
- `scripts/entrypoints/` — implementations behind the thin root command wrappers

## Docs Map

Use these docs for these jobs:

- `README.md` — public product overview and quick start
- `CONTRIBUTING.md` — contributor setup and contribution norms
- `AGENTS.md` — Codex-specific workflow rules
- `CLAUDE.md` — Claude-specific repo orientation
- `docs/agent-onboarding.md` — how to interpret the repo’s doc layers
- `docs/storage-paths.md` — canonical storage and fallback path map
- `docs/release-packaging.md` — release packaging flow
- `docs/sparkle-updates.md` — Sparkle update contract
- `Tests/README.md` — verification surfaces and fast-test runner behavior
- `Sources/*/CLAUDE.md` — subsystem-local ownership and verification notes

## Historical Zones

Treat these as reference, not current product surface:

- `archive/backend-beta-worker/`
- `archive/evals/`
- `docs/archive/`
- `.claude/`
