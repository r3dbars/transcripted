# Activation Lane

Use this when work touches the user's first useful Transcripted loop:

1. create or find a saved Markdown artifact
2. hand that artifact to an agent
3. get one useful answer
4. come back later and reuse the saved context

The product question is not just "did transcription run?" It is "did the user
end up with local Markdown their agent can use?"

## What Counts

Good activation work should improve at least one of these moments:

- first saved dictation or meeting Markdown is visible and easy to open
- agent setup makes the saved folders or MCP tools usable
- the user sees a concrete first question to ask an agent
- recent saved artifacts are easy to return to from Home
- failure states explain whether audio or Markdown was preserved
- telemetry counts only coarse, privacy-safe activation events

## Read First

- `README.md` for the product promise
- `docs/agent-connect.md` for the saved-folder and MCP handoff
- `Sources/UI/CLAUDE.md` for Home, onboarding, settings, and agent-connect UI
- `Sources/Support/CLAUDE.md` for Claude Desktop install, paths, paste, and preferences
- `Sources/Dictation/CLAUDE.md` for dictation Markdown persistence
- `Sources/Meeting/CLAUDE.md` for meeting save, retry, and retained-audio behavior
- `Sources/Observability/CLAUDE.md` for activation telemetry guardrails

## Route The Work

| If the issue is about | Start here |
| --- | --- |
| first saved dictation or meeting is missing, hidden, or hard to open | `Sources/UI/Settings/HomeView.swift`, `Sources/UI/Shared/RecentCaptureScanners.swift`, `Sources/Dictation/`, `Sources/Meeting/` |
| agent setup, first prompt, agent connect rows, or folder handoff | `Sources/UI/Shared/AgentConnectionGuide.swift`, `Sources/UI/Settings/AgentConnectionSettingsPage.swift`, `Sources/Support/ClaudeDesktopIntegrationInstaller.swift`, `Sources/Support/AgentMCPConnector.swift`, `docs/agent-connect.md` |
| pasteback, copied text, Auto Enter, or clipboard restore | `Sources/Support/ClipboardRestoringTextPaster.swift`, `Sources/UI/Overlay/DictationSessionController.swift`, `Sources/Accessibility/CLAUDE.md` |
| Bluetooth or AirPods dictation reliability | `Sources/Speech/CLAUDE.md`, `docs/audio-reliability-daily-check.md` |
| Zoom, Meet, Teams, or meeting prompt trust | `Sources/Meeting/CLAUDE.md`, `Sources/UI/Overlay/MeetingOverlayController.swift`, `docs/qa-issue-500-meeting-audio.md` |
| activation analytics or health probes | `Sources/Observability/ActivationTelemetry.swift`, `Sources/Observability/AnalyticsEventPolicy.swift`, `docs/privacy-first-observability.md`, `docs/ops-credentials.md` |

## PostHog Funnel Report

Use this for the aggregate product decision layer:

```bash
python3 scripts/ops/posthog-activation-funnel.py --days 30
```

The script writes a Markdown report and JSON data under
`/tmp/transcripted-posthog-activation-funnel/<run-id>/`. It keeps output
aggregate-only and separates strict saved-Markdown proof from proxy rows like
`dictation_completed` completion volume, `meeting_file_imported` import activity,
agent setup clicks, and copied starter prompts.

For the broader 100 WAU dashboard, reliability funnels, local summary beta
funnel, agent/Markdown value loop, and release-health view, use
`docs/posthog-100-wau-dashboard.md`.

For the full product-learning telemetry map, current event taxonomy, blind
spots, and dashboard plan, see `docs/posthog-product-learning-plan.md`.
For reusable 100 WAU, activation, reliability, feature-adoption, and
release-health query specs, use:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --family activation --dry-run
```

For the dashboard-to-product-task loop, use:

```bash
python3 scripts/ops/posthog-product-dashboard-summary.py --days 30
```

That script reads the five dashboard families (`100 WAU Operating`,
`Activation`, `Reliability`, `Feature Adoption`, and `Release Health`) and
outputs the biggest activation leak, biggest reliability leak, strongest
adoption signal, under-discovered feature, release regression watch, and top
three PR/task candidates. It has fixture and self-test modes so CI can check
the ranking logic without PostHog credentials.

## PostHog Product Context Pack

Use this when an agent needs the short decision context, not the full funnel:

```bash
python3 scripts/ops/posthog-product-context-pack.py --days 30
```

The script writes `product-context-pack.json` and `product-context-pack.md`
under `/tmp/transcripted-posthog-product-context/<run-id>/`. It stays
aggregate-only and returns explicit `UNKNOWN` states when credentials, events,
or denominators are missing.

## Guardrails

- Do not add transcript text, meeting titles, speaker names, file paths, source
  app names, raw device names, emails, tokens, or raw URLs to off-device
  analytics or crash payloads.
- Do not claim activation is fixed from artifact volume alone. The stronger
  proof is saved Markdown -> agent use -> return.
- Do not start with a broad onboarding redesign when a smaller artifact, prompt,
  Home, or retry-path fix would prove the loop.
- Keep live release/download truth separate from source truth before making
  launch or outreach claims.

## Verification

Always start with:

```bash
bash scripts/dev/agent-preflight.sh
```

Then follow `.agents/test-matrix.yml`.

Common activation checks:

- Swift/UI/support change: `bash build.sh --no-open` and `bash run-tests.sh`
- Meeting/Core change: also `bash run-integration-smoke.sh`
- Agent-connect helper change: include the relevant `Tools/TranscriptedMCP` or
  Claude Desktop installer checks
- UI change: add sanitized `.agent-review/visuals/` evidence for the PR
- Telemetry change: update sanitizer/policy tests and keep payloads bucketed

For GitHub issues, write acceptance criteria around the user-visible artifact
or handoff proof, not just the internal function that changed.
