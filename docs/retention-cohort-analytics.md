# Retention Cohort Analytics

Use this runbook when checking Transcripted habit formation from PostHog without
looking at transcript content, file paths, meeting titles, speaker names, emails,
tokens, raw URLs, or person records.

## Command

```bash
python3 scripts/ops/retention-cohort-report.py
```

Optional:

```bash
python3 scripts/ops/retention-cohort-report.py --days 30 --write-json /tmp/transcripted-retention.json
python3 scripts/ops/retention-cohort-report.py --write-dir /tmp/transcripted-retention-health
python3 scripts/ops/retention-cohort-report.py --self-test
```

The script loads PostHog credentials from the same local env paths used by other
ops scripts, including `~/.hermes/.env`.

Required env:

- `POSTHOG_PERSONAL_API_KEY`
- `POSTHOG_PROJECT_ID`

Optional env:

- `POSTHOG_HOST` or `POSTHOG_APP_HOST`
- `POSTHOG_ALLOW_UNTRUSTED_HOST=1` only for a trusted self-hosted PostHog host

## What It Measures

- Active anonymous devices in the lookback window.
- Active days per anonymous device.
- Repeat dictation use from `dictation_completed`.
- Repeat meeting use from `meeting_transcript_saved`.
- Repeat agent use from `agent_capture_query_observed` when that true-use event
  exists, plus separate prompt/setup proxy repeats.
- Repeat summary use from `meeting_summary_finished` when that event exists.
- 3-days-this-week active devices.
- Latest observed app version per anonymous device.
- First artifact and second artifact signals from true saved-artifact events:
  `meeting_transcript_saved`, plus `activation_first_artifact_saved` when its
  `artifact_kind` is `dictation`.
- Next-day and 7-day return after the first artifact.
- Drop-off after first run, where first run is the first observed
  `app_launched` within the configured first-seen lookback.

With `--write-dir`, the script writes:

- `retention-cohort-report.md`
- `retention-cohort-data.json`
- `retention-health-summary.json`

The health summary is intentionally small so health skills can ingest the habit
cohorts without parsing the full Markdown report.

## How To Read It

Treat these as aggregate habit signals, not user forensics.

- Strong signal: repeat artifact devices and devices returning 18h-7d after a
  first artifact.
- Stronger future signal: repeat `agent_capture_query_observed` devices. Until
  that event exists, treat agent use as unknown rather than green.
- Useful proxy: `activation_return_proxy_observed`, which means Home observed
  a prior saved artifact after 18h+.
- Weak proxy: `activation_agent_prompt_action_clicked` or
  `activation_agent_setup_cta_clicked`, which means an in-app prompt, setup,
  copy, or open action happened. It does not prove an external agent actually
  read the file or answered with sources.
- First-run drop-off: mature first-run devices with one active day and no
  artifact in the first 7 days.
- Summary repeat: currently expected to be zero/unknown unless a privacy-safe
  summary-finished PostHog event has been added.

## Blind Spots

- The product does not currently measure a full sourced answer loop unless
  `agent_capture_query_observed` has started flowing from the agent layer.
- External agent reads are not visible without that true-use event; prompt/setup
  actions are proxy intent only.
- Summary repeat is unsupported until a summary-finished analytics event is
  allowlisted and emitted.
- First-artifact and first-run cohorts depend on first observed events in the
  configured lookback, so telemetry that started late can make old devices look
  new.
- Version adoption should use latest observed version per device. The report
  highlights the most common latest-observed version; event counts by version can
  over-count devices that upgraded during the window.
- Normal repeat dictation saves do not yet have a dedicated remote saved-artifact
  event. The report counts repeat dictation separately from `dictation_completed`,
  but does not treat that event as saved Markdown because persistence can fail.

## Privacy Rules

Keep reports anonymous and aggregate only. Do not add raw `distinct_id`, person
rows, transcript text, audio references, meeting titles, speaker names, emails,
tokens, absolute paths, raw URLs, source app names, or raw device names.

If the report needs stronger proof, prefer a small privacy-safe event such as a
bucketed `agent_capture_query_observed` or `activation_first_artifact_saved`
event. Keep it allowlisted in `Sources/Observability/AnalyticsEventPolicy.swift`
and covered by the analytics sanitizer tests.
