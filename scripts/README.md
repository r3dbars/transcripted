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
- `run-slow-pasteback-smoke.sh` — deterministic fake slow paste target smoke for the clipboard-restoring paster

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
- `scripts/entrypoints/run-slow-pasteback-smoke.sh`

`run-daily-audio-reliability.sh` is the exception: it keeps its implementation
with the operational health probes at `scripts/ops/daily-audio-reliability-check.sh`.

The wrappers share code from `scripts/entrypoints/lib/`:

- `scripts/entrypoints/lib/deps-staleness.sh` — dependency-staleness-check functions shared by `build-deps.sh`, `build.sh`, and `run-integration-smoke.sh` (mtime then sha256 freshness check against `deps-libs/.build-deps-stamp`)
- `scripts/entrypoints/lib/shared-smoke-sources.sh` — the overlapping subset of the hand-listed swiftc source files used by `run-tests.sh`, `run-e2e-smoke.sh`, and `run-slow-pasteback-smoke.sh`
- `scripts/entrypoints/lib/swiftc-app-args.sh` — shared swiftc argument construction (frameworks, linker inputs, source list) for the Transcripted app target, sourced by `build.sh` and `build-beta.sh` so they cannot silently diverge

## Active helper scripts

- `scripts/dev/agent-preflight.sh` — summarize branch state, changed paths, trusted docs, and suggested checks selected directly from the agent test matrix
- `scripts/dev/test-matrix-checks.py` — dependency-free selector that executes `.agents/test-matrix.yml` path rules for preflight
- `scripts/dev/check-build-source-lists.py` — checks the hand-maintained fast-test and smoke source lists for missing files
- `scripts/dev/benchmark-home-recent-captures.sh` — compile and run the Settings Home recent-capture loader benchmark; pass `--max-average-load-ms` and `--max-cancellation-ms` to fail on regression
- `scripts/dev/agent-check.py` — run mapped Transcripted checks sequentially and write a bounded proof report
- `scripts/dev/agent-context.py` — print bounded, machine-backed context for a Transcripted change or symptom
- `scripts/dev/check-duplicate-declarations.py` — heuristic static scan for same-scope duplicate Swift declarations (the merge-collision shapes `swift -frontend -parse` misses)
- `scripts/dev/check-superseded.py` — checks whether a dirty/conflicting PR's fix already merged under a different PR number before a repair branch gets spun up
- `scripts/download_ami.sh` — fetch the gitignored AMI ES2002 audio/RTTM subset used by `Tools/SpeakerEvalHarness`
- `scripts/download_icsi.sh` — fetch the gitignored ICSI meeting-corpus audio/RTTM subset (research-use license; speakers recur heavily across meetings)
- `scripts/download_voxceleb_sample.sh` — stream a capped-size VoxCeleb1 identity sample and build multi-identity sessions for the speaker-DB test, gitignored
- `scripts/download_voxconverse.sh` — download the gated VoxConverse in-the-wild diarization audio + ground-truth RTTMs (~4 GB), gitignored
- `scripts/voxceleb_sample.py` — hard-capped VoxCeleb1 identity/clip streaming sampler used by `download_voxceleb_sample.sh`
- `scripts/build_voxceleb_sessions.py` — stitch sampled VoxCeleb clips into synthetic multi-identity sessions with ground-truth RTTM, for the cross-recording re-ID/false-merge test
- `scripts/icsi_rttm_from_hf.py` — materialize per-meeting ICSI RTTMs from the gated HF `diarizers-community/icsi` dataset
- `scripts/gen_synthetic_speaker_eval.py` — generate deterministic synthetic embeddings/RTTMs for `Tools/SpeakerEvalHarness` so write-path fixes can be A/B'd without a real corpus
- `scripts/run_synthetic_speaker_eval.sh` — A/B the speaker write-path fixes on the synthetic corpora from `gen_synthetic_speaker_eval.py`
- `scripts/ab_dot_vs_cloud.py` — A/B the dot-product-profile vs cloud-of-samples speaker matcher on cached VoxCeleb embeddings
- `scripts/run_speaker_eval.sh` — build and run the AMI speaker-naming sweep, writing local reports under `data/eval/`
- `scripts/score_speaker_eval.py` — score speaker-eval hypotheses against AMI RTTM labels without printing private transcript text
- `scripts/aggregate_sweep.py` — aggregate speaker-eval sweep scores and highlight closest-to-target threshold combinations
- `scripts/convert_eres2net_fused.py` — converts the pretrained ERes2Net speaker-embedding model to the fused raw-audio-in CoreML model shipped in the app; reproducibility record for the model `Sources/TranscriptedCore/Speaker/ERes2NetEmbedder.swift` loads
- `scripts/recalibrate_eres2net_groundtruth.py` — recomputes the ERes2Net match/consolidation thresholds against AMI ground truth; reproducibility record for the thresholds in `Sources/TranscriptedCore/Speaker/SpeakerEmbeddingThresholds.swift`
- `scripts/make_eres2net_swift_fixture.py` — regenerates the checked-in golden fixture `Tests/TranscriptedCoreTests/SpeakerTests/Fixtures/eres2net_swift_golden.json` used by the Swift ERes2NetEmbedder parity test
- `scripts/release/generate-dmg-background.swift` — regenerate the committed DMG install background art
- `scripts/release/bump-release-version.py` — bump `Info.plist` app/build version metadata for a release-prep branch without tagging, publishing, appcast, or Homebrew changes
- `scripts/release/generate-sparkle-appcast.sh` — generate a Sparkle appcast from an updates folder and copy it into `docs/appcast.xml`
- `scripts/release/post-dmg-release-audit.py` — read-only audit for the post-DMG release surfaces before or after publishing
- `scripts/release/verify-sparkle-release.sh` — verify a GitHub release DMG, Sparkle appcast entry, and app updater settings line up
- `scripts/release/update-cask.sh` — bump `Casks/transcripted.rb` to point at a newly published GitHub release
- `scripts/release/sentry-release-metadata.py` — print the Sentry release/dist that the app will report from `Info.plist`
- `scripts/release/sentry-release-dry-run.py` — read-only Sentry release/dSYM readiness check; it never creates/finalizes releases, sets commits, or uploads debug files
- `scripts/release/register-sentry-release.sh` — create/finalize the matching Sentry release, verify the release dSYM matches the app binary, and upload it after a GitHub release is published
- `scripts/dev/onboarding.sh` — inspect, reset, or force the first-run onboarding state while iterating on copy and layout

## Operational health probes

- `scripts/ops/health-probe.sh` — run health checks for observability lanes (Sentry, PostHog, GitHub, Cloudflare)
  - Usage: `bash scripts/ops/health-probe.sh <github|sentry|posthog|cloudflare|all>`
  - See `docs/ops-credentials.md` for credential setup and privacy guidelines
- `scripts/ops/release-health-card.py` — print a compact release-health card for one app version by combining local release metadata, GitHub downloads, live public release surfaces, and PostHog update/workflow counts when credentials are present; installed workflow rows are grouped by `app_version`, `build_version`, `build_channel`, and `build_revision` so local/current-main builds cannot be counted as shipped-release proof
  - Usage: `python3 scripts/ops/release-health-card.py --version 1.1.47`
- `scripts/ops/check-crash-free-rate.py` — crash-free-rate release gate: query Sentry Release Health (Sessions) for a release's crash-free session/user rate and exit non-zero if it is below threshold (red) or unverifiable (yellow, e.g. credentials absent or no session data), so it can be a go/no-go gate; read-only, never publishes
  - Usage: `python3 scripts/ops/check-crash-free-rate.py --version 1.1.48`
  - Verdicts: exit 0 green (>= threshold), exit 1 red (below threshold), exit 3 yellow (cannot verify; never auto-green)
- `scripts/ops/retention-cohort-report.py` — print a privacy-safe PostHog retention cohort report for first/second artifact, next-day and 7-day return, repeat dictation/meeting/agent/summary use, 3-days-this-week, version adoption, and first-run drop-off
  - Usage: `python3 scripts/ops/retention-cohort-report.py`
  - Health output: `python3 scripts/ops/retention-cohort-report.py --write-dir /tmp/transcripted-retention-health`
  - Offline self-test: `python3 scripts/ops/retention-cohort-report.py --self-test`
- `scripts/ops/posthog-activation-funnel.py` — build a privacy-safe PostHog activation funnel report for launch, onboarding, permission readiness, saved Markdown, artifact actions, agent setup proxies, and return proxies
  - Usage: `python3 scripts/ops/posthog-activation-funnel.py --days 30`
  - Release-scoped usage: `python3 scripts/ops/posthog-activation-funnel.py --days 30 --app-version 1.1.48`
  - Writes local Markdown and JSON under `/tmp/transcripted-posthog-activation-funnel/<run-id>/`
  - Self-test: `python3 scripts/ops/posthog-activation-funnel.py --self-test`
- `scripts/ops/posthog-product-context-pack.py` — build a compact JSON + Markdown product-context pack for Codex/agents from aggregate PostHog data
  - Usage: `python3 scripts/ops/posthog-product-context-pack.py --days 30`
  - Fixture/sample usage: `python3 scripts/ops/posthog-product-context-pack.py --fixture Tests/Fixtures/posthog-product-context-pack-fixture.json --write-dir build/posthog-product-context-sample`
  - Writes local Markdown and JSON under `/tmp/transcripted-posthog-product-context/<run-id>/`
  - Missing PostHog credentials produce explicit `UNKNOWN` states unless `--strict` is passed
  - Self-test: `python3 scripts/ops/posthog-product-context-pack.py --self-test`
- `scripts/ops/posthog-dashboard-queries.py` — reusable PostHog aggregate query catalog for the 100 WAU, activation, meeting-prompt-quality, artifact-usefulness, agent-payoff, speaker-trust, retry-recovery, onboarding-friction, and release-health dashboard families; release-health keeps installed build outcomes separate from update target-version outcomes
  - Dry-run specs: `python3 scripts/ops/posthog-dashboard-queries.py --dry-run`
  - One family: `python3 scripts/ops/posthog-dashboard-queries.py --family activation --dry-run`
  - Live aggregate query: `python3 scripts/ops/posthog-dashboard-queries.py --family 100_wau --days 30`
  - Live taxonomy check: `python3 scripts/ops/posthog-dashboard-queries.py --taxonomy-check --days 30`
  - Fixture taxonomy check: `python3 scripts/ops/posthog-dashboard-queries.py --taxonomy-check --observed-fixture Tests/Fixtures/posthog-observed-event-taxonomy.json --json-only`
  - CI/offline proof: `python3 scripts/ops/posthog-dashboard-queries.py --self-test`
  - Machine output for health agents: `python3 scripts/ops/posthog-dashboard-queries.py --family all --json-only`
- `scripts/ops/posthog_common.py` — shared privacy-safe PostHog request/host-allowlist helpers imported by the other `posthog-*.py` scripts; not a standalone entry point
- `scripts/ops/normalize-analytics-taxonomy.py` — normalize the union-mergeable analytics taxonomy files `Resources/analytics-events.psv` and `Resources/analytics-reviewed-properties.psv`
- `scripts/ops/posthog-product-dashboard-summary.py` — turn the five PostHog product-learning dashboard families into ranked product tasks, with current-release rows scoped by full build identity
  - Usage: `python3 scripts/ops/posthog-product-dashboard-summary.py --days 30`
  - Exact shipped build: `python3 scripts/ops/posthog-product-dashboard-summary.py --days 7 --app-version 1.1.50 --build-channel release --build-revision <revision>`
  - Fixture usage: `python3 scripts/ops/posthog-product-dashboard-summary.py --fixture Tests/Fixtures/posthog-product-dashboard-summary.json`
  - Release health stays `UNKNOWN` without all three confirmed public-build fields; fixture mode rejects exact-build filters
  - Writes local Markdown and JSON under `/tmp/transcripted-posthog-product-tasks/<run-id>/`
  - Self-test: `python3 scripts/ops/posthog-product-dashboard-summary.py --self-test`
- `scripts/ops/daily-audio-reliability-check.sh` — interactive daily audio reliability loop for launch, wake, Bluetooth/device-change, meeting recovery, retry, and stop-race checks
  - Usage: `bash run-daily-audio-reliability.sh`
  - Synthetic-only usage: `bash run-daily-audio-reliability.sh --synthetic`
  - Writes local-only evidence under `/tmp/transcripted-repro-lab/<run-id>/`
- `scripts/ops/nightly-security-check.py` — deterministic nightly security/privacy guardrail checker for repo drift, release/update drift, Homebrew cask/appcast parity, PostHog schema drift, raw observability payload keys, entitlements, shell hazards, recent-history secret leaks, and shared sanitizer coverage
  - Usage: `python3 scripts/ops/nightly-security-check.py --write-report build/nightly-security-report.json`
  - Strict gate: `python3 scripts/ops/nightly-security-check.py --strict --write-report build/nightly-security-report.json`
  - Deterministic release-health fixture gate: `python3 scripts/ops/nightly-security-check.py --strict --automation-toml Tests/Fixtures/nightly-security-automation.toml --github-release-json Tests/Fixtures/release-health-github-release-1.1.58.json --write-report build/nightly-security-report.json`
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
- `scripts/ops/packaged-app-smoke.py` — smoke a built/packaged `Transcripted.app` before release publishing: app bundle, DMG, dSYM, Sparkle appcast keys, and an isolated launch/menu check, with output scrubbed of secrets/paths/emails before it's written
  - Usage: `python3 scripts/ops/packaged-app-smoke.py --app-bundle build/Transcripted.app`
  - Self-test: `python3 scripts/ops/packaged-app-smoke.py --self-test`
- `scripts/ops/privacy-leak-sweep.py` — synthetic-only privacy sweep for logs/events/reliability JSONL, Sentry/PostHog payloads, QA/local reports, PR/release text, and scanner handoff summaries
  - Usage: `python3 scripts/ops/privacy-leak-sweep.py --write-report build/privacy-leak-sweep-report.json`
- `scripts/ops/performance-budget.rb` — fail a built app that exceeds bundle/resource budgets, ships the wrong Parakeet model set, includes old icon assets, or regresses optional runtime latency budgets
  - Usage: `scripts/ops/performance-budget.rb`
  - Thin-build usage: `scripts/ops/performance-budget.rb --allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80`
  - Runtime log verification against the ratchet ceilings: `TRANSCRIPTED_RUNTIME_BUDGET=1 bash build.sh --no-open` (opt-in: the log was produced by whatever binary you ran, not the build under test, so the default build stays hermetic)
  - Runtime log verification against the aspirational targets: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl"` — expected to fail today; the defaults are the product targets, not the current ceilings
    - Passing `--events` now scores the dictation latency budgets on its own. Each one evaluates once the log carries at least 20 samples (`MIN_DICTATION_LATENCY_SAMPLES`); below that it is skipped rather than failed, so a thin log does not break a build. An explicit `--require-*-samples N` lowers that scoring floor to N as well as asserting the samples exist. This used to require `--require-dictation-fast-start-samples`, which defaults to `0` — meaning the budgets printed their percentiles and enforced nothing.
    - `--max-dictation-fast-start-fallback-rate R` scores fallback/retry events as a fraction of fast-start samples; the raw `--max-dictation-fast-start-fallback-events N` count is kept for scripted callers but fails on dictation volume rather than regression over a long window.
    - `--min-transcription-samples` is likewise the floor for *scoring*, not an assertion. Use `--require-transcription-samples N` / `--require-dictation-fast-start-samples N` / `--require-dictation-stop-latency-samples N` when the samples genuinely have to be there.
    - A failing run now prints the full percentile summary on stdout before the reasons on stderr, so you can act on the numbers without re-running.
  - Optional strict dictation stop proof: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --require-dictation-stop-latency-samples 3`
  - Fresh-window verification: `scripts/ops/performance-budget.rb --events "$HOME/Library/Application Support/Transcripted/logs/events.jsonl" --events-since 2026-06-01T01:13:00Z --require-dictation-stop-latency-samples 3`
  - Optional meeting throughput verification: `scripts/ops/performance-budget.rb --stats "$HOME/Library/Application Support/Transcripted/state/stats.sqlite"` (defaults to recordings 30s or longer)
  - CI-safe Home list/action budget: `scripts/ops/performance-budget.rb --check-home-recent-captures --allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80`
  - Manual hardware proof still owns meeting-list 120fps on Apple Silicon; CI checks deterministic loader latency (<750 ms for the 10k stress fixture) and cancellation acknowledgement (<100 ms) only.
  - `TRANSCRIPTED_RUNTIME_BUDGET=1 bash build.sh --no-open` passes `--events` for the local event log, scoped to the last 14 days, with ratchet ceilings defined inline in `scripts/entrypoints/build.sh`. Those ceilings sit above today's measured latency so the gate catches regressions; the aspirational targets are the defaults in `performance-budget.rb`, and the ceilings must only ever move down toward them. It is opt-in because the log was produced by whatever binary you ran, not by the build under test, so a red result cannot be attributed to the change being built. Set `TRANSCRIPTED_EVENTS_LOG` to point at a different log.
- `scripts/dev/latency-percentiles.py` — full p50/p90/p95/p99 distribution for every latency key in an events log, sorted by p99 so the stage owning the tail reads first
  - Usage: `python3 scripts/dev/latency-percentiles.py`
- `scripts/dev/bench-launch-latency.sh` — launch-to-interactive over N isolated launches, reporting p50/p90/p95/p99 instead of the single sample `build.sh` takes
  - Usage: `bash scripts/dev/bench-launch-latency.sh --samples 20`
- `scripts/dev/bench-all.sh` — runs the launch, Home-loader, and real-usage benchmarks together and writes JSON under `build/benchmarks/<label>/`
  - Usage: `bash scripts/dev/bench-all.sh`
- `scripts/ops/dictation-stop-autoeval.sh` — synthetic local-audio benchmark for dictation stop-to-text, stop-to-saved, and stop-to-delivery timing
  - Production-path usage: `bash scripts/ops/dictation-stop-autoeval.sh --label baseline --variant production`
  - Encoder comparison: add `--encoder-compute cpu-and-gpu` or `--encoder-compute all`; production remains on FluidAudio's default unless this benchmark-only override is present
  - The `production` variant includes snapshot/resampling plus the durable recovery checkpoint, but not a real microphone, clipboard, or target app.
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
- `scripts/ops/transcripted-qa-bench.sh` — orchestrated QA tester pass for build, fast tests, deterministic E2E smoke, Core/package tests, TranscriptedQA, synthetic audio, release-health fixture checks, and optional live capture
  - Quick usage: `bash scripts/ops/transcripted-qa-bench.sh --mode quick`
  - Deep usage: `bash scripts/ops/transcripted-qa-bench.sh --mode deep`
  - Full usage: `bash scripts/ops/transcripted-qa-bench.sh --mode full`
  - UI usage: `bash scripts/ops/transcripted-qa-bench.sh --mode ui`
  - Corpus usage: `bash scripts/ops/transcripted-qa-bench.sh --mode corpus`
  - Corpus compare usage: `bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare --corpus-ids meeting-0024,meeting-0025`
  - Live usage: `bash scripts/ops/transcripted-qa-bench.sh --mode live`
  - Writes local evidence under `/tmp/transcripted-qa-bench/<run-id>/`
- `scripts/ops/score-boards.py` — aggregate ui-smoke, validate-all, and scorer JSON evidence into a per-board 0-100 accuracy scorecard; missing evidence is reported INCOMPLETE, never silently passed
  - Usage: `python3 scripts/ops/score-boards.py --registry .agents/board-scorecard.yml --json-out /tmp/qa/board-scorecard.json`
- `scripts/ops/score_boards_lib.py` — pure scoring math (no I/O) behind `score-boards.py`: per-board dimension weighting and INCOMPLETE handling
- `scripts/ops/score-detection.py` — score meeting-detection accuracy (F1) against a labelled fixture of app-state cases, emits `score-detection.json`
- `scripts/ops/score-diarization.py` — score diarization accuracy (frame-based DER, greedy label mapping) from a reference/hypothesis segments JSON, emits `score-diarization.json`
- `scripts/ops/score-dictation.py` — score dictation correction accuracy against a fixture of raw/expected cases, emits `score-dictation.json`
- `scripts/ops/score-summary-judge.py` — build or ingest an LLM-judge rubric packet for meeting-summary quality, emits `score-summary.json`
- `scripts/ops/test-score-boards.py` — pure-logic/CLI unit tests for the board scorecard engine and scorers; `python3 scripts/ops/test-score-boards.py`
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
