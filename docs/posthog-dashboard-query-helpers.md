# PostHog Dashboard Query Helpers

`scripts/ops/posthog-dashboard-queries.py` is the shared query catalog for
Transcripted product-learning dashboards and health checks.

It covers five dashboard families:

- `100_wau` - WAU, DAU, first-value devices, return proxy, and version mix
- `activation` - launch -> onboarding -> saved Markdown -> agent proxy -> return
- `reliability` - dictation and meeting failure rates, failure kinds, latency buckets
- `feature_adoption` - artifact actions, agent setup, meeting prompts, settings discovery
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

Render synthetic fixture rows without credentials:

```bash
python3 scripts/ops/posthog-dashboard-queries.py --fixture Tests/Fixtures/posthog-dashboard-query-results.json
```

## Example Output

Dry-run output includes stable query IDs, output columns, and HogQL:

```text
### activation.reach_ladder

One-row reach table for launch through saved Markdown, agent proxy, true agent-use, and return proxy.

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

## Dashboard Family Notes

`100_wau` uses active workflow and first-value events, not launch alone. That
keeps the operating dashboard centered on real product use.

`activation` separates strict saved-Markdown proof from `dictation_completed`
proxy rows. Agent setup/prompt rows are intent signals only; the stronger proof
is `agent_capture_query_observed`, which confirms a saved-capture MCP query but
still does not measure answer quality.

`reliability` uses coarse failure kinds and latency buckets. It does not expose
raw error strings, device names, app names, or audio details.

`feature_adoption` tracks feature discovery through stable surfaces, action IDs,
agent targets, and prompt buckets.

`release_health` accepts `--app-version`. Workflow events use `app_version`;
update events use `version`, so the helper filters both.
