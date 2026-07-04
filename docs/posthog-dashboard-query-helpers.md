# PostHog Dashboard Query Helpers

`scripts/ops/posthog-dashboard-queries.py` is the shared query catalog for
Transcripted product-learning dashboards and health checks.

It covers ten dashboard families:

- `100_wau` - WAU, DAU, first-value devices, return proxy, and version mix
- `activation` - launch -> onboarding -> saved Markdown -> agent proxy -> return, plus the post-save habit loop (review-yesterday, promise-review, recent-meeting, daily digest)
- `meeting_prompt_quality` - detected-meeting prompt reach, acceptance, dismissal, suppression, and missed-call nudges
- `artifact_usefulness` - saved artifacts, second artifacts, artifact actions, and return proxy
- `agent_payoff` - agent setup/prompt intent, saved-capture query proof, and local summary outcomes
- `speaker_trust` - speaker review, auto-recognition, corrections, deferrals, and finalization failures
- `retry_recovery` - workflow retry/recovery, failure kinds, and dictation latency buckets
- `onboarding_friction` - first-run steps, permission readiness, dismissals, abandonment, and product friction
- `timeline_dayflow` - shipped timeline/dayflow adoption and data-quality rows from the allowlisted timeline taxonomy
- `release_health` - release-scoped workflow and Sparkle update health

All query outputs are aggregate, bucketed, and privacy-safe. The helpers do not
export distinct IDs, people rows, transcript text, audio references, meeting
titles, file paths, URLs, emails, tokens, raw payloads, or raw device names.

## Example Commands

Print all query specs without credentials:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --dry-run
```

Print one family:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --family activation --dry-run
```

Run live PostHog aggregate queries:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --family 100_wau --days 30
```

Scope release-health queries to one version:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --family release_health --days 14 --app-version 1.1.48
```

Write Markdown and JSON output for a worker or dashboard job:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --family all --days 30 --write-dir /tmp/transcripted-posthog-dashboard
```

Run the offline CI/self-test path:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --self-test
```

Compare observed/live event names against the checked-in allowlist without
exporting user rows:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --taxonomy-check --days 30
```

Run the same event-name check against a synthetic aggregate fixture:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --taxonomy-check --observed-fixture Tests/Fixtures/posthog-observed-event-taxonomy.json --json-only
```

Render synthetic fixture rows without credentials:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --fixture Tests/Fixtures/posthog-dashboard-query-results.json
```

## Example Output

Dry-run output includes stable query IDs, output columns, and HogQL:

```text
### activation.reach_ladder

One-row reach table for launch through saved Markdown, second artifact, agent payoff, next-day/7-day return, and habit-loop actions.

Output columns: `launch_devices`, `onboarding_devices`, `permission_ready_devices`, ...
```

Fixture/live output includes the same stable query IDs with rows:

```text
| launch_devices | onboarding_devices | permission_ready_devices | capture_started_devices |
| --- | --- | --- | --- |
| 100 | 72 | 44 | 38 |
```

## Environment

Live mode reads:

- `POSTHOG_PERSONAL_API_KEY`
- `POSTHOG_PROJECT_ID`
- optional `POSTHOG_HOST` or `POSTHOG_APP_HOST`

The script also loads local ops env files used by the existing health scripts:

- `.env.local`
- `.env`
- `~/.transcripted-ops.env`
- `~/.hermes/.env`
- `~/.hermes/profiles/ops/.env`

PostHog hosts must be HTTPS and in the trusted host list unless
`POSTHOG_ALLOW_UNTRUSTED_HOST=1` is set for a trusted self-hosted endpoint.

## For transcripted-health

Use `--json-only` for machine-readable output:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --family all --days 30 --json-only
```

The JSON shape is stable:

- `mode`: `dry_run`, `fixture`, or `live`
- `window_days`
- `app_version`
- `families`
- `queries[]`
- `queries[].id`
- `queries[].family`
- `queries[].columns`
- `queries[].rows` in fixture/live mode
- `queries[].hogql` in dry-run mode

Health checks should treat missing live credentials as an environment gap, not
as a product analytics failure. Use `--dry-run` or `--fixture` in CI.

For taxonomy checks, the JSON shape includes `unknown_events`,
`required_taxonomy_events`, `observed_required_taxonomy_events`, and
`observed_events`. `observed_events` is aggregate-only: event name, count,
anonymous device count, and first/last seen timestamps.

## Dashboard Family Notes

`100_wau` uses active workflow and first-value events, not launch alone. That
keeps the operating dashboard centered on real product use.

`activation` separates strict saved-Markdown proof from `dictation_completed`
proxy rows. Agent setup/prompt rows are intent signals only; the stronger proof
is `agent_capture_query_observed`, which confirms a saved-capture MCP query but
still does not measure answer quality.

`meeting_prompt_quality` uses coarse meeting-provider, source, route-ready,
prompt-reason, choice/outcome, elapsed, suppression, cooldown, and permission
buckets. It does not expose calendar titles, app names, raw meeting URLs, or
participant data.

`artifact_usefulness` proves saves, second saves, artifact actions, habit-loop
actions, and return proxy rows. It does not inspect transcript contents or
artifact text quality.

`agent_payoff` separates setup/prompt intent from `agent_capture_query_observed`,
the stronger privacy-safe saved-capture query proof. It still does not measure
answer quality.

`speaker_trust` uses review, correction, auto-recognition, and finalization
buckets. It does not export speaker names, samples, clip references, or transcript
text.

`activation.habit_loop_summary` is the coordinator shortcut for the daily return
loop: first artifact, second artifact, agent payoff, next-day return, 7-day
return, Review yesterday, What did I promise, open recent meeting, and daily
digest viewed/exported. Daily digest counts remain zero until a real UI seam
emits the existing `activation_habit_loop_actioned` helper for those actions.

`retry_recovery` uses coarse failure kinds and latency buckets. It does not expose
raw error strings, device names, app names, or audio details.

`onboarding_friction` tracks step, permission, abandonment, and product-friction
buckets only.

`timeline_dayflow` is intentionally separate because timeline analytics can be
sparse. It must not export screen text, screenshots, app names, file paths, or
raw timeline rows.

`release_health` accepts `--app-version`. Workflow events use `app_version`;
update events use `version`, so the helper filters both.
