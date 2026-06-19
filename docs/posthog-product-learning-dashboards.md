# Transcripted PostHog Product-Learning Dashboards

Use this when building or refreshing the aggregate PostHog dashboards for the
current product loop:

```text
speech or meeting -> saved Markdown -> one sourced agent answer -> return later
```

The helper is:

```bash
python3 scripts/ops/posthog-product-learning-report.py --days 30
```

It writes:

```text
/tmp/transcripted-posthog-product-learning/<run-id>/product-learning-report.md
/tmp/transcripted-posthog-product-learning/<run-id>/product-learning-data.json
```

## Privacy Contract

The report is aggregate-only. It exports counts and enum buckets, not raw
PostHog rows.

Do not add queries that output:

- distinct IDs, people rows, emails, names, or device identifiers
- transcript text, prompt text, audio references, or filenames
- meeting titles, speaker names, source app names, bundle IDs, or file paths
- tokens, raw URLs, raw error strings, or raw payload blobs

## Dashboards Covered

The script produces one Markdown/JSON bundle for:

- 100 WAU operating dashboard
- activation funnel
- dictation reliability funnel
- meeting reliability funnel
- local summary beta funnel
- agent and Markdown value loop
- release health by app version

Use `--app-version <version>` when you need a release-scoped product-learning
read. Release-health tables still include app-version and update-version
breakdowns so the dashboard can compare versions without user-level joins.

## Missing Events

The helper intentionally calls out gaps instead of hiding them:

- `agent_capture_query_observed` is needed to prove a saved artifact produced a
  sourced agent answer.
- `activation_second_artifact_saved` is needed for first-to-second artifact and
  habit conversion.
- `dictation_artifact_saved` is needed because general dictation saved Markdown
  currently uses `dictation_completed` as a proxy.
- `dictation_retry_started` is needed for recovery after failed or empty
  dictation.
- `meeting_speaker_review_prompted` and
  `meeting_speaker_review_completed` are needed for a real speaker-review
  funnel.
- `meeting_summary_requested` and `meeting_summary_finished` are needed before
  the local summary beta can be read as a real PostHog funnel.
- `workflow_abandoned` is needed for a safe abandonment taxonomy.

Treat missing true-use events as `UNKNOWN`, not green. Prompt-copy and setup
clicks show intent only.

## Checks

```bash
python3 -m py_compile scripts/ops/posthog-product-learning-report.py
python3 scripts/ops/posthog-product-learning-report.py --self-test
```

