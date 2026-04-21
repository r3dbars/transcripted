# Scripts

This repo keeps the live day-to-day command surface intentionally small.

## Active root entry points

These stay at the repo root as thin wrappers so the public command surface stays
stable and the docs can keep pointing at the same commands:

- `build-deps.sh` — build and cache the shared dependency bundle
- `build.sh` — local app build
- `build-beta.sh` — signed beta/distribution build
- `run-tests.sh` — curated fast test runner
- `run-integration-smoke.sh` — app/core smoke verification

## Entrypoint implementations

The actual script bodies live under `scripts/entrypoints/` so the repo root does
not have to carry the full operational logic:

- `scripts/entrypoints/build-deps.sh`
- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `scripts/entrypoints/run-tests.sh`
- `scripts/entrypoints/run-integration-smoke.sh`

## Active helper scripts

- `scripts/release/generate-dmg-background.swift` — regenerate the committed DMG install background art
- `scripts/release/generate-sparkle-appcast.sh` — generate a Sparkle appcast from an updates folder and copy it into `docs/appcast.xml`
- `scripts/release/update-cask.sh` — bump `Casks/transcripted.rb` to point at a newly published GitHub release
- `scripts/dev/onboarding.sh` — inspect, reset, or force the first-run onboarding state while iterating on copy and layout

## Operational health probes

- `scripts/ops/health-probe.sh` — run health checks for observability lanes (Sentry, PostHog, GitHub, Cloudflare)
  - Usage: `bash scripts/ops/health-probe.sh <github|sentry|posthog|cloudflare|qa|all>`
  - QA lane defaults to `r3dbars/transcripted#428` and can be overridden with:
    - `QA_GATE_REPO=<owner/repo>`
    - `QA_GATE_ISSUE_NUMBER=<issue-number>`
  - See `docs/ops-credentials.md` for credential setup and privacy guidelines
- `scripts/ops/qa-gate-check.sh` — check a GitHub issue for a top-level QA `PASS` / `FAIL` comment
  - Usage: `bash scripts/ops/qa-gate-check.sh <owner/repo> <issue-number>`
  - Exit codes:
    - `0` = `PASS`
    - `2` = `FAIL`
    - `3` = pending (no top-level `PASS` / `FAIL` yet)
- `scripts/ops/build-codex-memory-index.py` — build a safe metadata-only index from local Codex session archives for Transcripted memory briefs
  - Usage: `python3 scripts/ops/build-codex-memory-index.py --verbose`
  - Writes:
    - `build/codex-memory-index/transcripted-codex-index.json`
    - `build/codex-memory-index/transcripted-codex-stats.json`
    - `build/codex-memory-index/transcripted-codex-followups.json`
    - `build/codex-memory-index/transcripted-paperclip-task-seeds.json`
    - `build/codex-memory-index/transcripted-codex-digest.md`
  - Optional: `--limit 200` to scan only the newest 200 session files while iterating
  - Optional: `--since-hours 24` to only include sessions from the last N hours
  - Optional: `--nightly-report` to generate a decision-ready nightly archive miner report
  - Optional: `--mlx-summarize --mlx-model <model-id>` to generate local intent summaries through an MLX OpenAI-compatible endpoint
  - Guardrail: `--mlx-summarize` now requires `--allow-local-model-calls`
- `scripts/ops/nightly-transcripted-archive-miner.sh` — run the nightly Transcripted archive miner profile (24h window + decision report)
  - Usage: `bash scripts/ops/nightly-transcripted-archive-miner.sh`

## Rule of thumb

If a command is not listed above, do not assume it is part of the current app build or release contract.
