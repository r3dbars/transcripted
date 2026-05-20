# Scripts

This repo keeps the live day-to-day command surface intentionally small.

## Active root entry points

These stay at the repo root as thin wrappers so the public command surface stays
stable and the docs can keep pointing at the same commands:

- `build-deps.sh` — build and cache the shared dependency bundle
- `build.sh` — local app build; defaults to the thin model-download app variant. Use `bash build.sh --no-open` for non-interactive verification, or `bash build.sh --full --no-open` to verify the full offline variant
- `build-beta.sh` — signed beta/distribution build
- `run-tests.sh` — curated fast test runner
- `run-integration-smoke.sh` — app/core smoke verification
- `run-daily-audio-reliability.sh` — interactive or synthetic daily audio reliability check

## Entrypoint implementations

The actual script bodies live under `scripts/entrypoints/` so the repo root does
not have to carry the full operational logic:

- `scripts/entrypoints/build-deps.sh`
- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `scripts/entrypoints/run-tests.sh`
- `scripts/entrypoints/run-integration-smoke.sh`

## Active helper scripts

- `scripts/dev/agent-preflight.sh` — summarize branch state, changed paths, trusted docs, and suggested checks from the agent test matrix
- `scripts/release/generate-dmg-background.swift` — regenerate the committed DMG install background art
- `scripts/release/generate-sparkle-appcast.sh` — generate a Sparkle appcast from an updates folder and copy it into `docs/appcast.xml`
- `scripts/release/verify-sparkle-release.sh` — verify a GitHub release DMG, Sparkle appcast entry, and app updater settings line up
- `scripts/release/update-cask.sh` — bump `Casks/transcripted.rb` to point at a newly published GitHub release
- `scripts/release/sentry-release-metadata.py` — print the Sentry release/dist that the app will report from `Info.plist`
- `scripts/release/register-sentry-release.sh` — create/finalize the matching Sentry release and upload release dSYMs after a GitHub release is published
- `scripts/dev/onboarding.sh` — inspect, reset, or force the first-run onboarding state while iterating on copy and layout

## Operational health probes

- `scripts/ops/health-probe.sh` — run health checks for observability lanes (Sentry, PostHog, GitHub, Cloudflare)
  - Usage: `bash scripts/ops/health-probe.sh <github|sentry|posthog|cloudflare|all>`
  - See `docs/ops-credentials.md` for credential setup and privacy guidelines
- `scripts/ops/daily-audio-reliability-check.sh` — interactive daily audio reliability loop for launch, wake, Bluetooth/device-change, meeting recovery, retry, and stop-race checks
  - Usage: `bash run-daily-audio-reliability.sh`
  - Synthetic-only usage: `bash run-daily-audio-reliability.sh --synthetic`
  - Writes local-only evidence under `/tmp/transcripted-repro-lab/<run-id>/`
- `scripts/ops/nightly-security-check.py` — deterministic nightly security/privacy guardrail checker for repo drift, release/update drift, entitlements, shell hazards, recent-history secret leaks, and shared sanitizer coverage
  - Usage: `python3 scripts/ops/nightly-security-check.py --write-report build/nightly-security-report.json`
  - Optional built-app verification: `python3 scripts/ops/nightly-security-check.py --app-bundle build/Transcripted.app --write-report build/nightly-security-report.json`
- `scripts/ops/performance-budget.rb` — fail a built app that exceeds bundle/resource budgets, ships the wrong Parakeet model set, includes old icon assets, or regresses optional runtime latency budgets
  - Usage: `scripts/ops/performance-budget.rb`
  - Thin-build usage: `scripts/ops/performance-budget.rb --allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80`
  - Optional runtime log verification: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"`
  - Optional meeting throughput verification: `scripts/ops/performance-budget.rb --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"` (defaults to recordings 30s or longer)
- `scripts/ops/agent-todo-runner.rb` — local GitHub Issues queue runner for Codex agent tasks
  - Usage: `ruby scripts/ops/agent-todo-runner.rb --labels-only`
  - Usage: `ruby scripts/ops/agent-todo-runner.rb --once`
  - Usage: `ruby scripts/ops/agent-todo-runner.rb --watch`
  - Reads `WORKFLOW.md` and watches issues labeled `agent todo` or `agent in progress`
- `scripts/ops/agent-todo-launchagent.sh` — install, restart, inspect, or remove the macOS background watcher
  - Usage: `bash scripts/ops/agent-todo-launchagent.sh install`
  - Usage: `bash scripts/ops/agent-todo-launchagent.sh status`
  - Usage: `bash scripts/ops/agent-todo-launchagent.sh logs`
- `scripts/ops/qa-gate-check.sh` — one-shot check for the BET-88 QA gate comment on `#428` using the same strict owner + first-line PASS/FAIL rules as the auto-close workflow
  - Usage: `bash scripts/ops/qa-gate-check.sh [--json] [repo] [issue_number] [owner_login]`
  - Returns JSON and exits `0` for `pass`/`fail`, `3` for `PENDING`
- `scripts/ops/qa-gate-closeout.sh` — closeout wrapper around `qa-gate-check.sh` that prints explicit unblock owner/action when status is still pending
  - Usage: `bash scripts/ops/qa-gate-closeout.sh [repo] [issue_number] [owner_login]`
  - Returns `0` for pass/fail closeout-ready, `3` when still blocked/pending
- `scripts/ops/transcripted-qa-bench.sh` — orchestrated QA tester pass for build, fast tests, deterministic E2E smoke, Core/package tests, TranscriptedQA, synthetic audio, and optional live capture
  - Quick usage: `bash scripts/ops/transcripted-qa-bench.sh --mode quick`
  - Deep usage: `bash scripts/ops/transcripted-qa-bench.sh --mode deep`
  - Corpus usage: `bash scripts/ops/transcripted-qa-bench.sh --mode corpus`
  - Corpus compare usage: `bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare --corpus-ids meeting-0024,meeting-0025`
  - Live usage: `bash scripts/ops/transcripted-qa-bench.sh --mode live`
  - Writes local evidence under `/tmp/transcripted-qa-bench/<run-id>/`
- `scripts/ops/validate-meeting-corpus.py` — local-only validator for the private meeting corpus in `~/Downloads/meeting-corpus`; parses metadata, audio presence/duration, and Zoom caption structure without printing transcript text
- `scripts/ops/compare-meeting-corpus.py` — local-only comparator for Transcripted Markdown against private Zoom caption truth; reports redacted recall and speaker-label scores without printing transcript text or speaker names
- `scripts/ops/nightly-transcripted-archive-miner.sh` — thin nightly wrapper that runs `build-codex-memory-index.py` with `--since-hours 24 --nightly-report`
  - Usage: `bash scripts/ops/nightly-transcripted-archive-miner.sh`
- `scripts/ops/generate-nightly-digest.py` — create the morning HTML + JSON summary from active Transcripted nightly automation memories and GitHub PR state
  - Usage: `python3 scripts/ops/generate-nightly-digest.py --open`
  - Self-test: `python3 scripts/ops/generate-nightly-digest.py --self-test`
  - Writes:
    - `/Users/redbars/Delance/transcripted-nightly-digest-YYYY-MM-DD.html`
    - `/Users/redbars/Delance/transcripted-nightly-digest-latest.html`
    - `/Users/redbars/Delance/transcripted-nightly-digest-YYYY-MM-DD.json`
    - `/Users/redbars/Delance/transcripted-nightly-digest-latest.json`
- `scripts/ops/build-codex-memory-index.py` — build a safe metadata-only index from local Codex session archives for Transcripted memory briefs
  - Usage: `python3 scripts/ops/build-codex-memory-index.py --verbose`
  - Writes:
    - `build/codex-memory-index/transcripted-codex-index.json`
    - `build/codex-memory-index/transcripted-codex-stats.json`
    - `build/codex-memory-index/transcripted-codex-followups.json`
    - `build/codex-memory-index/transcripted-paperclip-task-seeds.json`
    - `build/codex-memory-index/transcripted-codex-digest.md`
  - Optional: `--limit 200` to scan only the newest 200 session files while iterating
  - Optional: `--mlx-summarize --mlx-model <model-id>` to generate local intent summaries through an MLX OpenAI-compatible endpoint

## Rule of thumb

If a command is not listed above, do not assume it is part of the current app build or release contract.
