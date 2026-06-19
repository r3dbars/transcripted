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
- `run-e2e-smoke.sh` — deterministic release-critical artifact smoke without microphone/TCC
- `run-live-capture-smoke.sh` — local hardware/TCC smoke for app launch plus mic and system-audio capture
- `run-daily-audio-reliability.sh` — interactive or synthetic daily audio reliability check

## Wrapper implementations

Most root wrapper bodies live under `scripts/entrypoints/` so the repo root does
not have to carry the full operational logic:

- `scripts/entrypoints/build-deps.sh`
- `scripts/entrypoints/build.sh`
- `scripts/entrypoints/build-beta.sh`
- `scripts/entrypoints/run-e2e-smoke.sh`
- `scripts/entrypoints/run-tests.sh`
- `scripts/entrypoints/run-integration-smoke.sh`
- `scripts/entrypoints/run-live-capture-smoke.sh`

`run-daily-audio-reliability.sh` is the exception: it keeps its implementation
with the operational health probes at `scripts/ops/daily-audio-reliability-check.sh`.

## Active helper scripts

- `scripts/dev/agent-preflight.sh` — summarize branch state, changed paths, trusted docs, and suggested checks from the agent test matrix
- `scripts/dev/benchmark-home-recent-captures.sh` — compile and run the Settings Home recent-capture loader benchmark
- `scripts/download_ami.sh` — fetch the gitignored AMI ES2002 audio/RTTM subset used by `Tools/SpeakerEvalHarness`
- `scripts/run_speaker_eval.sh` — build and run the AMI speaker-naming sweep, writing local reports under `data/eval/`
- `scripts/score_speaker_eval.py` — score speaker-eval hypotheses against AMI RTTM labels without printing private transcript text
- `scripts/aggregate_sweep.py` — aggregate speaker-eval sweep scores and highlight closest-to-target threshold combinations
- `scripts/release/generate-dmg-background.swift` — regenerate the committed DMG install background art
- `scripts/release/generate-sparkle-appcast.sh` — generate a Sparkle appcast from an updates folder and copy it into `docs/appcast.xml`
- `scripts/release/verify-sparkle-release.sh` — verify a GitHub release DMG, Sparkle appcast entry, and app updater settings line up
- `scripts/release/update-cask.sh` — bump `Casks/transcripted.rb` to point at a newly published GitHub release
- `scripts/release/sentry-release-metadata.py` — print the Sentry release/dist that the app will report from `Info.plist`
- `scripts/release/register-sentry-release.sh` — create/finalize the matching Sentry release, verify the release dSYM matches the app binary, and upload it after a GitHub release is published
- `scripts/dev/onboarding.sh` — inspect, reset, or force the first-run onboarding state while iterating on copy and layout

## Operational health probes

- `scripts/ops/health-probe.sh` — run health checks for observability lanes (Sentry, PostHog, GitHub, Cloudflare)
  - Usage: `bash scripts/ops/health-probe.sh <github|sentry|posthog|cloudflare|all>`
  - See `docs/ops-credentials.md` for credential setup and privacy guidelines
- `scripts/ops/release-health-card.py` — print a compact release-health card for one app version by combining local release metadata, GitHub downloads, live public release surfaces, and PostHog update/workflow counts when credentials are present
  - Usage: `python3 scripts/ops/release-health-card.py --version 1.1.47`
- `scripts/ops/posthog-activation-funnel.py` — build a privacy-safe PostHog activation funnel report for launch, onboarding, permission readiness, saved Markdown, artifact actions, agent setup proxies, and return proxies
  - Usage: `python3 scripts/ops/posthog-activation-funnel.py --days 30`
  - Release-scoped usage: `python3 scripts/ops/posthog-activation-funnel.py --days 30 --app-version 1.1.48`
  - Writes local Markdown and JSON under `/tmp/transcripted-posthog-activation-funnel/<run-id>/`
  - Self-test: `python3 scripts/ops/posthog-activation-funnel.py --self-test`
- `scripts/ops/daily-audio-reliability-check.sh` — interactive daily audio reliability loop for launch, wake, Bluetooth/device-change, meeting recovery, retry, and stop-race checks
  - Usage: `bash run-daily-audio-reliability.sh`
  - Synthetic-only usage: `bash run-daily-audio-reliability.sh --synthetic`
  - Writes local-only evidence under `/tmp/transcripted-repro-lab/<run-id>/`
- `scripts/ops/nightly-security-check.py` — deterministic nightly security/privacy guardrail checker for repo drift, release/update drift, Homebrew cask/appcast parity, PostHog schema drift, raw observability payload keys, entitlements, shell hazards, recent-history secret leaks, and shared sanitizer coverage
  - Usage: `python3 scripts/ops/nightly-security-check.py --write-report build/nightly-security-report.json`
  - Strict gate: `python3 scripts/ops/nightly-security-check.py --strict --write-report build/nightly-security-report.json`
  - Deterministic release-health fixture gate: `python3 scripts/ops/nightly-security-check.py --strict --automation-toml Tests/Fixtures/nightly-security-automation.toml --github-release-json Tests/Fixtures/release-health-github-release-1.1.48.json --write-report build/nightly-security-report.json`
  - Live release-surface gate: `python3 scripts/ops/nightly-security-check.py --strict --live-release-surfaces`
  - Sentry release gate: `python3 scripts/ops/nightly-security-check.py --sentry-release-health`
  - Required Sentry release gate: `python3 scripts/ops/nightly-security-check.py --strict --require-sentry-release-health`
  - Release dSYM gate after packaging: `python3 scripts/ops/nightly-security-check.py --require-release-debug-files`
  - Optional built-app verification: `python3 scripts/ops/nightly-security-check.py --app-bundle build/Transcripted.app --write-report build/nightly-security-report.json`
- `scripts/ops/release-gate-report.py` — single pre-merge/release gate report that runs the QA bench, Sentry/PostHog probes, appcast/download/release-health checks, and a local log sweep
  - Usage: `python3 scripts/ops/release-gate-report.py`
  - Deep RC usage: `python3 scripts/ops/release-gate-report.py --qa-mode deep --strict-artifacts`
  - Full one-command release gate: `python3 scripts/ops/release-gate-report.py --release-candidate`
  - Writes local Markdown and JSON under `/tmp/transcripted-release-gate/<run-id>/`
  - Exits `0` for GREEN, `3` for YELLOW/unknown, and `1` for RED
  - Missing Sentry/PostHog credentials or manual proof are reported as yellow/unknown, not green
  - Its first screen separates deterministic proof, mocked/proxy proof, telemetry proof, release-surface proof, timestamped current-run local log proof, and manual/hardware UNKNOWN
- `scripts/ops/privacy-leak-sweep.py` — synthetic-only privacy sweep for logs/events/reliability JSONL, Sentry/PostHog payloads, QA/local reports, PR/release text, and scanner handoff summaries
  - Usage: `python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json`
- `scripts/ops/performance-budget.rb` — fail a built app that exceeds bundle/resource budgets, ships the wrong Parakeet model set, includes old icon assets, or regresses optional runtime latency budgets
  - Usage: `scripts/ops/performance-budget.rb`
  - Thin-build usage: `scripts/ops/performance-budget.rb --allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80`
  - Optional runtime log verification: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"`
  - Optional strict dictation stop proof: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --require-dictation-stop-latency-samples 3`
  - Fresh-window verification: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --events-since 2026-06-01T01:13:00Z --require-dictation-stop-latency-samples 3`
  - Optional meeting throughput verification: `scripts/ops/performance-budget.rb --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"` (defaults to recordings 30s or longer)
- `scripts/ops/dictation-stop-autoeval.sh` — synthetic local-audio benchmark for dictation stop-to-text, stop-to-saved, and stop-to-delivery timing
  - Usage: `bash scripts/ops/dictation-stop-autoeval.sh --label baseline --variant native`
  - Writes ignored scratch output under `.autoeval/dictation-stop/`
- `scripts/ops/dictation-recovery-autoeval.rb` — deterministic policy lab for dictation start-readiness, recovery timing, and Bluetooth-settle guardrails
  - Usage: `ruby scripts/ops/dictation-recovery-autoeval.rb --details`
- `scripts/ops/agent-todo-runner.rb` — local GitHub Issues queue runner for Codex agent tasks
  - Usage: `ruby scripts/ops/agent-todo-runner.rb --labels-only`
  - Usage: `ruby scripts/ops/agent-todo-runner.rb --once`
  - Usage: `ruby scripts/ops/agent-todo-runner.rb --watch`
  - Reads `WORKFLOW.md` and watches issues labeled `agent todo` or `agent in progress`
- `scripts/ops/agent-todo-launchagent.sh` — install, restart, inspect, or remove the macOS background watcher
  - Usage: `bash scripts/ops/agent-todo-launchagent.sh install`
  - Usage: `bash scripts/ops/agent-todo-launchagent.sh status`
  - Usage: `bash scripts/ops/agent-todo-launchagent.sh logs`
- `scripts/ops/qa-gate-check.sh` — historical one-shot check for the closed BET-88 QA gate `#428`, using the same strict owner + first-line PASS/FAIL rules as the label-gated auto-close workflow
  - Usage: `bash scripts/ops/qa-gate-check.sh [--json] [repo] [issue_number] [owner_login]`
  - Returns JSON and exits `0` for `pass`/`fail`, `3` for `PENDING`
- `scripts/ops/qa-gate-closeout.sh` — closeout wrapper around `qa-gate-check.sh` that prints explicit unblock owner/action when status is still pending
  - Usage: `bash scripts/ops/qa-gate-closeout.sh [repo] [issue_number] [owner_login]`
  - Returns `0` for pass/fail closeout-ready, `3` when still blocked/pending
  - Keep these only while the closed BET-88 workflow remains useful as a repo
    contract fixture; do not treat them as active queue automation.
- `scripts/ops/transcripted-qa-bench.sh` — orchestrated QA tester pass for build, fast tests, deterministic E2E smoke, Core/package tests, TranscriptedQA, synthetic audio, release-health fixture checks, optional Gemma planning, and optional live capture
  - Quick usage: `bash scripts/ops/transcripted-qa-bench.sh --mode quick`
  - Deep usage: `bash scripts/ops/transcripted-qa-bench.sh --mode deep`
  - Full usage: `bash scripts/ops/transcripted-qa-bench.sh --mode full`
  - UI usage: `bash scripts/ops/transcripted-qa-bench.sh --mode ui`
  - Corpus usage: `bash scripts/ops/transcripted-qa-bench.sh --mode corpus`
  - Corpus compare usage: `bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare --corpus-ids meeting-0024,meeting-0025`
  - Live usage: `bash scripts/ops/transcripted-qa-bench.sh --mode live`
  - Writes local evidence under `/tmp/transcripted-qa-bench/<run-id>/`
- `scripts/ops/speaker-naming-simulator.py` — deterministic synthetic speaker-review simulator for tuning `EmbeddingClusterer` same-voice consolidation without audio or private transcripts
  - Usage: `scripts/ops/speaker-naming-simulator.py`
  - Sweep usage: `scripts/ops/speaker-naming-simulator.py --sweep`
  - JSON usage: `scripts/ops/speaker-naming-simulator.py --json`
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
