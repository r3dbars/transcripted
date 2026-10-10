# Docs index

Every live doc in `docs/`, grouped by job. The repo map (folders, commands, hotspots) is `docs/repo-layout.md`; subsystem rules live in each folder's `AGENTS.md`. Finished records sit in `docs/archive/`.

When you add, move, or retire a doc here, update this list. `python3 scripts/dev/check-doc-paths.py` fails on a path that doesn't exist.

## Product and file formats

- `docs/capture-format.md` — the authoritative spec for saved Markdown: meetings, dictation day files, writing day files
- `docs/storage-paths.md` — where every file lives, including the capture library, app state, models, logs, and old `Draft` fallbacks
- `docs/agent-connect.md` — how an agent finds the saved folder, and the MCP setup behind the Agent page
- `docs/cross-meeting-tools.md` — MCP rollups across meeting summaries (`list_action_items`, `list_decisions`, `digest`)
- `docs/mcp-ui-recent-meetings.md` — the MCP server's interactive recent-meetings view
- `docs/auto-call-detection-spec.md` — meeting auto-detection: signals, prompt flow, phase status
- `docs/transcription-language.md` — the meeting-language picker and how Auto samples audio
- `docs/ui-settings-menubar-spec.md` — product intent for the menu bar popover and the Settings window
- `docs/DESIGN_TOKENS.md` — type, spacing, and corner-radius tokens

## Writing

- `docs/writing-plan.md` — design record for Writing (decisions, keyboard behavior, approved tab copy); shipped in 1.1.67
- `docs/writing-port-ledger.md` — which Tilde file became which Transcripted file, and the deliberate deviations
- `docs/llama-server-provenance.md` — where the pinned `llama-server` helper comes from and how it was verified

## Releases (read before changing release flow)

- `docs/release-packaging.md` — building, signing, notarizing, and publishing a release
- `docs/sparkle-updates.md` — the Sparkle update contract
- `docs/appcast.xml` — the live Sparkle feed
- `docs/release-guardrails.md` — what may ship without an explicit publish decision
- `docs/release-notes-template.md` — template for release notes

## Testing and QA

- `docs/debug-control-surface.md` — debug-only CLI / URL hook to drive the app and read JSON state (compiled out of release)
- `docs/qa-test-bench.md` — the orchestrated QA bench (`scripts/ops/transcripted-qa-bench.sh`) and its modes
- `docs/qa/manual-10-minute-checklist.md` — the 10-minute manual pass after a local build
- `docs/audio-reliability-daily-check.md` — daily manual audio reliability loop
- `docs/qa-issue-500-meeting-audio.md` — manual WebRTC / meeting-volume QA matrix
- `docs/qa-meeting-cross-app-crossover.md` — manual same-build check for whether recording silences another app
- `docs/qa-audio-route-notification-recovery.md` — manual USB / route-change recovery checks
- `docs/clean-vm-testing.md` — throwaway macOS VM for new-user and upgrade tests
- `docs/mutation-testing.md` — finding assertions that never catch a bug
- `docs/testing-source-text-inventory.md` — the grandfathered tests that read source as text
- `docs/board-scorecard.md` — the agent-runnable per-board health task list

## Labs and evals

- `docs/hill-climb-lab.md` — tuning settings against scored tests
- `docs/lab-control-channel.md` — the lab-only file-drop channel that drives the real app
- `docs/transcripted-lab.md` — Transcripted Lab architecture
- `docs/speaker-recognition-metrics.md` — how speaker-recognition accuracy is measured over time
- `docs/speaker-eval-exemplar-delta-2026-07.md` — dated multi-exemplar speaker eval; code comments cite it, so it stays here (raw JSON in `docs/archive/`)

## Observability and analytics

- `docs/observability.md` — the five diagnostic sinks and which one owns what
- `docs/privacy-first-observability.md` — the observability lanes and their privacy contract
- `docs/analytics-taxonomy-merge.md` — why the analytics registry is line-based with union merge, and how to add an event
- `docs/activation-lane.md` — saved Markdown, agent payoff, and return-use routing
- `docs/install-attribution-map.md` — anonymous path from website visit to first useful file
- `docs/retention-cohort-analytics.md` — privacy-safe PostHog retention report
- `docs/posthog-100-wau-dashboard.md` — minimum PostHog dashboard for steering toward 100+ weekly users
- `docs/posthog-dashboard-query-helpers.md` — the query catalog behind `scripts/ops/posthog-dashboard-queries.py`

## Agents and operations

- `docs/repo-layout.md` — the repo map
- `docs/agent-closeout.md` — the coordinator handoff line and lane routing
- `docs/concurrency-debt.md` — Swift concurrency warnings the cleanup PRs left alone (hot-path and audio items), and how the census counts them
- `docs/ops-credentials.md` — Sentry, PostHog, GitHub, and Cloudflare credential lanes
- `docs/self-hosted-mac-runner.md` — the owner's Mac as a self-hosted CI runner

## Assets (not engineering docs)

- `docs/assets/` — app icon options, menu bar icon sources (`docs/assets/menu-bar-icon/make_menu_bar_icons.py` is read by a test), launch GIFs and videos, social preview
- `docs/launch-assets/README.md` — what each launch asset is for
- `docs/marketing/hero-video-storyboard.md` — plan for replacing the README hero with a real recording
- `docs/screenshots/README.md` — launch screenshots
