#!/usr/bin/env python3
"""Reusable privacy-safe PostHog query helpers for Transcripted dashboards."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import posthog_common as posthog

FAMILIES = (
    "100_wau",
    "activation",
    "reliability",
    "feature_adoption",
    "release_health",
)

ACTIVE_WORKFLOW_EVENTS = (
    "app_launched",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "agent_capture_query_observed",
)

ACTIVATION_EVENTS = (
    "app_launched",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_completed",
    "onboarding_first_dictation_started",
    "dictation_started",
    "meeting_recording_started",
    "onboarding_first_dictation_saved",
    "activation_first_artifact_saved",
    "meeting_transcript_saved",
    "dictation_completed",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "agent_capture_query_observed",
    "activation_return_proxy_observed",
)

RELIABILITY_EVENTS = (
    "dictation_started",
    "dictation_start_failed",
    "dictation_completed",
    "dictation_cancelled",
    "dictation_no_speech",
    "dictation_stop_latency_measured",
    "dictation_audio_route_recovery_finished",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_recording_stopped",
    "meeting_capture_health_snapshot",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "meeting_file_import_failed",
)

FEATURE_EVENTS = (
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "meeting_prompt_shown",
    "meeting_prompt_choice_made",
    "meeting_prompt_record_selected",
    "meeting_prompt_dismissed",
    "meeting_prompt_outcome_recorded",
    "meeting_prompt_suppressed",
    "meeting_mic_boost_prompt_shown",
    "meeting_mic_boost_prompt_actioned",
    "meeting_saved_audio_retranscription_requested",
    "meeting_file_imported",
    "settings_opened",
    "settings_page_viewed",
    "settings_action_clicked",
    "settings_toggle_changed",
    "update_action_clicked",
)

RELEASE_EVENTS = (
    "app_launched",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "update_check_finished",
    "update_download_started",
    "update_download_finished",
    "update_ready_to_install",
    "update_relaunching",
    "update_installed",
)

DISALLOWED_OUTPUT_FRAGMENTS = (
    "distinct_id",
    "person",
    "uuid",
    "email",
    "name",
    "path",
    "title",
    "transcript",
    "audio",
    "url",
    "token",
    "raw",
)

FIXTURE_PATH = Path("Tests/Fixtures/posthog-dashboard-query-results.json")


@dataclass(frozen=True)
class QuerySpec:
    id: str
    family: str
    title: str
    description: str
    sql: str
    columns: tuple[str, ...]
    notes: tuple[str, ...] = ()


class PostHogDashboardError(RuntimeError):
    pass


load_env = posthog.load_env
sql_quote = posthog.sql_quote
sql_list = posthog.sql_list
event_filter = posthog.event_filter
app_version_filter = posthog.app_version_filter
version_or_app_version_filter = posthog.version_or_app_version_filter


def posthog_config() -> tuple[str, str, str]:
    return posthog.posthog_config(PostHogDashboardError)


def query_specs(days: int, app_version: str | None) -> list[QuerySpec]:
    days = int(days)
    return [
        QuerySpec(
            id="wau.active_devices_by_week",
            family="100_wau",
            title="Weekly active workflow devices",
            description="Counts anonymous active devices by PostHog UTC week from workflow and first-value events.",
            columns=("week", "active_devices", "workflow_events", "first_value_devices", "return_proxy_devices"),
            sql=f"""
SELECT
  toStartOfWeek(timestamp) AS week,
  uniq(distinct_id) AS active_devices,
  count() AS workflow_events,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'meeting_transcript_saved', 'onboarding_first_dictation_saved')) AS first_value_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVE_WORKFLOW_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY week
ORDER BY week ASC
""",
            notes=("Use this as the top-line 100 WAU read. It is device-level and aggregate only.",),
        ),
        QuerySpec(
            id="wau.daily_active_devices",
            family="100_wau",
            title="Daily active workflow devices",
            description="Shows DAU, launches, workflow events, and first-value devices for trend cards.",
            columns=("day", "active_devices", "launch_events", "workflow_events", "first_value_devices"),
            sql=f"""
SELECT
  toDate(timestamp) AS day,
  uniq(distinct_id) AS active_devices,
  countIf(event = 'app_launched') AS launch_events,
  count() AS workflow_events,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'meeting_transcript_saved', 'onboarding_first_dictation_saved')) AS first_value_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVE_WORKFLOW_EVENTS)}
  {app_version_filter(app_version)}
GROUP BY day
ORDER BY day ASC
""",
        ),
        QuerySpec(
            id="wau.version_mix",
            family="100_wau",
            title="Active devices by app version",
            description="Breaks active workflow devices by public app version without exposing devices.",
            columns=("app_version", "active_devices", "events", "last_seen"),
            sql=f"""
SELECT
  properties['app_version'] AS app_version,
  uniq(distinct_id) AS active_devices,
  count() AS events,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVE_WORKFLOW_EVENTS)}
  AND properties['app_version'] IS NOT NULL
  {app_version_filter(app_version)}
GROUP BY app_version
ORDER BY active_devices DESC
LIMIT 20
""",
        ),
        QuerySpec(
            id="activation.reach_ladder",
            family="activation",
            title="Activation reach ladder",
            description="One-row reach table for launch through saved Markdown, agent proxy, true agent-use, and return proxy.",
            columns=(
                "launch_devices",
                "onboarding_devices",
                "permission_ready_devices",
                "capture_started_devices",
                "strict_saved_markdown_devices",
                "saved_markdown_or_dictation_proxy_devices",
                "artifact_action_devices",
                "agent_proxy_devices",
                "true_agent_query_devices",
                "return_proxy_devices",
            ),
            sql=f"""
SELECT
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  uniqIf(distinct_id, event IN ('onboarding_shown', 'onboarding_step_viewed')) AS onboarding_devices,
  uniqIf(distinct_id, event = 'onboarding_completed') AS permission_ready_devices,
  uniqIf(distinct_id, event IN ('onboarding_first_dictation_started', 'dictation_started', 'meeting_recording_started')) AS capture_started_devices,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved')) AS strict_saved_markdown_devices,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')) AS saved_markdown_or_dictation_proxy_devices,
  uniqIf(distinct_id, event = 'activation_artifact_action_clicked') AS artifact_action_devices,
  uniqIf(distinct_id, event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')) AS agent_proxy_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS true_agent_query_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(ACTIVATION_EVENTS)}
  {app_version_filter(app_version)}
""",
            notes=("Treat agent proxy counts as intent. They do not prove a sourced answer.",),
        ),
        QuerySpec(
            id="activation.ordered_funnel",
            family="activation",
            title="Ordered activation funnel",
            description="Uses windowFunnel for ordered launch to agent proxy progression.",
            columns=("deepest_step", "devices"),
            sql=f"""
SELECT deepest_step, count() AS devices
FROM (
  SELECT
    distinct_id,
    windowFunnel({days} * 24 * 3600)(toDateTime(timestamp),
      event = 'app_launched',
      event IN ('onboarding_shown', 'onboarding_step_viewed'),
      event = 'onboarding_completed',
      event IN ('dictation_started', 'onboarding_first_dictation_started', 'meeting_recording_started'),
      event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed'),
      event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked'),
      event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')
    ) AS deepest_step
  FROM events
  WHERE timestamp >= now() - INTERVAL {days} DAY
    AND {event_filter(ACTIVATION_EVENTS)}
    {app_version_filter(app_version)}
  GROUP BY distinct_id
)
GROUP BY deepest_step
ORDER BY deepest_step ASC
""",
        ),
        QuerySpec(
            id="activation.return_windows",
            family="activation",
            title="Return proxy windows",
            description="Counts return-proxy events by coarse return window and prior artifact kind.",
            columns=("return_window_bucket", "prior_artifact_kind", "surface", "events", "devices"),
            sql=f"""
SELECT
  properties['return_window_bucket'] AS return_window_bucket,
  properties['prior_artifact_kind'] AS prior_artifact_kind,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'activation_return_proxy_observed'
  {app_version_filter(app_version)}
GROUP BY return_window_bucket, prior_artifact_kind, surface
ORDER BY devices DESC
LIMIT 40
""",
        ),
        QuerySpec(
            id="reliability.workflow_failure_rates",
            family="reliability",
            title="Workflow failure rates",
            description="Top-level dictation and meeting reliability counters for health checks.",
            columns=(
                "dictation_starts",
                "dictation_start_failures",
                "dictation_completed",
                "dictation_no_speech",
                "meeting_starts",
                "meeting_start_failures",
                "meeting_saved",
                "meeting_failed_or_skipped",
            ),
            sql=f"""
SELECT
  countIf(event = 'dictation_started') AS dictation_starts,
  countIf(event = 'dictation_start_failed') AS dictation_start_failures,
  countIf(event = 'dictation_completed') AS dictation_completed,
  countIf(event = 'dictation_no_speech') AS dictation_no_speech,
  countIf(event = 'meeting_recording_started') AS meeting_starts,
  countIf(event = 'meeting_recording_start_failed') AS meeting_start_failures,
  countIf(event = 'meeting_transcript_saved') AS meeting_saved,
  countIf(event IN ('meeting_transcript_failed', 'meeting_transcript_skipped')) AS meeting_failed_or_skipped
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(RELIABILITY_EVENTS)}
  {app_version_filter(app_version)}
""",
        ),
        QuerySpec(
            id="reliability.failure_kinds",
            family="reliability",
            title="Failure kinds",
            description="Ranks coarse failure_kind buckets for failed start/transcript/import outcomes.",
            columns=("event", "failure_kind", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('dictation_start_failed', 'meeting_recording_start_failed', 'meeting_transcript_failed', 'meeting_transcript_skipped', 'meeting_file_import_failed')
  {app_version_filter(app_version)}
GROUP BY event, failure_kind
ORDER BY events DESC
LIMIT 40
""",
        ),
        QuerySpec(
            id="reliability.latency_buckets",
            family="reliability",
            title="Dictation stop latency buckets",
            description="Counts coarse stop-to-done, save, paste, and decode buckets.",
            columns=("stop_to_done_bucket", "decode_bucket", "save_bucket", "paste_bucket", "outcome", "events", "devices"),
            sql=f"""
SELECT
  properties['stop_to_done_bucket'] AS stop_to_done_bucket,
  properties['decode_bucket'] AS decode_bucket,
  properties['save_bucket'] AS save_bucket,
  properties['paste_bucket'] AS paste_bucket,
  properties['outcome'] AS outcome,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event = 'dictation_stop_latency_measured'
  {app_version_filter(app_version)}
GROUP BY stop_to_done_bucket, decode_bucket, save_bucket, paste_bucket, outcome
ORDER BY events DESC
LIMIT 50
""",
        ),
        QuerySpec(
            id="feature_adoption.artifact_and_agent_actions",
            family="feature_adoption",
            title="Artifact and agent action adoption",
            description="Shows open/reveal/copy/setup actions by surface and coarse artifact/agent fields.",
            columns=("event", "surface", "artifact_kind", "action_kind", "agent_target", "result", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['surface'] AS surface,
  properties['artifact_kind'] AS artifact_kind,
  properties['action_kind'] AS action_kind,
  properties['agent_target'] AS agent_target,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')
  {app_version_filter(app_version)}
GROUP BY event, surface, artifact_kind, action_kind, agent_target, result
ORDER BY events DESC
LIMIT 60
""",
        ),
        QuerySpec(
            id="feature_adoption.meeting_prompts",
            family="feature_adoption",
            title="Meeting prompt adoption and suppression",
            description="Measures prompt shown, choice, accepted, outcome, dismissed, and suppressed without app names or meeting titles.",
            columns=("event", "provider", "source", "route_ready", "choice_kind", "outcome_kind", "elapsed_bucket", "suppression_reason", "cooldown_reason", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['provider'] AS provider,
  properties['source'] AS source,
  properties['route_ready'] AS route_ready,
  properties['choice_kind'] AS choice_kind,
  properties['outcome_kind'] AS outcome_kind,
  properties['elapsed_bucket'] AS elapsed_bucket,
  properties['suppression_reason'] AS suppression_reason,
  properties['cooldown_reason'] AS cooldown_reason,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('meeting_prompt_shown', 'meeting_prompt_choice_made', 'meeting_prompt_record_selected', 'meeting_prompt_outcome_recorded', 'meeting_prompt_dismissed', 'meeting_prompt_suppressed')
  {app_version_filter(app_version)}
GROUP BY event, provider, source, route_ready, choice_kind, outcome_kind, elapsed_bucket, suppression_reason, cooldown_reason
ORDER BY events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="feature_adoption.settings_discovery",
            family="feature_adoption",
            title="Settings discovery",
            description="Counts coarse settings pages and actions that can explain feature discovery.",
            columns=("event", "page_id", "action_id", "setting_id", "enabled", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['page_id'] AS page_id,
  properties['action_id'] AS action_id,
  properties['setting_id'] AS setting_id,
  properties['enabled'] AS enabled,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('settings_opened', 'settings_page_viewed', 'settings_action_clicked', 'settings_toggle_changed')
  {app_version_filter(app_version)}
GROUP BY event, page_id, action_id, setting_id, enabled
ORDER BY events DESC
LIMIT 80
""",
        ),
        QuerySpec(
            id="release_health.version_event_counts",
            family="release_health",
            title="Release event counts",
            description="Counts workflow and update events for a release-scoped health card.",
            columns=("event", "events", "devices", "first_seen", "last_seen"),
            sql=f"""
SELECT
  event,
  count() AS events,
  uniq(distinct_id) AS devices,
  min(timestamp) AS first_seen,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND {event_filter(RELEASE_EVENTS)}
  {version_or_app_version_filter(app_version)}
GROUP BY event
ORDER BY event ASC
LIMIT 100
""",
            notes=("Pass --app-version for a specific release. Update events use properties['version']; workflow events use app_version.",),
        ),
        QuerySpec(
            id="release_health.update_results",
            family="release_health",
            title="Update result breakdown",
            description="Breaks Sparkle update outcomes by coarse result/state/failure kind.",
            columns=("event", "result", "state", "failure_kind", "version", "events", "devices"),
            sql=f"""
SELECT
  event,
  properties['result'] AS result,
  properties['state'] AS state,
  properties['failure_kind'] AS failure_kind,
  properties['version'] AS version,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {days} DAY
  AND event IN ('update_check_finished', 'update_download_finished', 'update_ready_to_install', 'update_installed')
  {version_or_app_version_filter(app_version)}
GROUP BY event, result, state, failure_kind, version
ORDER BY events DESC
LIMIT 80
""",
        ),
    ]


def selected_specs(family: str, days: int, app_version: str | None) -> list[QuerySpec]:
    specs = query_specs(days, app_version)
    if family == "all":
        return specs
    return [spec for spec in specs if spec.family == family]


def run_hogql(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
    return posthog.run_hogql(host, project_id, token, query, PostHogDashboardError)


def rows_as_dicts(response: dict[str, Any], spec: QuerySpec) -> list[dict[str, Any]]:
    try:
        return posthog.rows_as_dicts(
            response,
            DISALLOWED_OUTPUT_FRAGMENTS,
            PostHogDashboardError,
            declared_columns=spec.columns,
        )
    except PostHogDashboardError as exc:
        message = str(exc)
        prefix = "query attempted to expose unsafe output columns: "
        if message.startswith(prefix):
            raise PostHogDashboardError(f"{spec.id} attempted to expose unsafe output columns: {message.removeprefix(prefix)}") from exc
        raise


def unsafe_columns(columns: list[str] | tuple[str, ...]) -> list[str]:
    return [
        str(column)
        for column in columns
        if any(fragment in str(column).lower() for fragment in DISALLOWED_OUTPUT_FRAGMENTS)
    ]


def spec_payload(specs: list[QuerySpec], days: int, app_version: str | None) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "dry_run",
        "window_days": days,
        "app_version": app_version,
        "privacy": "Query specs aggregate anonymous devices and events only. Output columns are enum buckets, counts, timestamps, and public versions; no people rows, raw IDs, transcript text, audio references, titles, paths, URLs, emails, or tokens.",
        "families": sorted({spec.family for spec in specs}),
        "queries": [
            {
                "id": spec.id,
                "family": spec.family,
                "title": spec.title,
                "description": spec.description,
                "columns": list(spec.columns),
                "notes": list(spec.notes),
                "hogql": clean_sql(spec.sql),
            }
            for spec in specs
        ],
    }


def execute_payload(specs: list[QuerySpec], days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()
    queries: list[dict[str, Any]] = []
    for spec in specs:
        response = run_hogql(host, project_id, token, spec.sql)
        queries.append(
            {
                "id": spec.id,
                "family": spec.family,
                "title": spec.title,
                "description": spec.description,
                "columns": list(spec.columns),
                "notes": list(spec.notes),
                "rows": rows_as_dicts(response, spec),
            }
        )
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "live",
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "project": "configured PostHog project",
        },
        "privacy": "Aggregate rows only; no user IDs, people rows, transcript text, audio references, titles, paths, URLs, emails, or tokens are written.",
        "families": sorted({spec.family for spec in specs}),
        "queries": queries,
    }


def clean_sql(sql: str) -> str:
    return "\n".join(line.rstrip() for line in sql.strip().splitlines())


def md_table(headers: list[str], rows: list[list[Any]]) -> str:
    def clean(value: Any) -> str:
        if value is True:
            return "true"
        if value is False:
            return "false"
        if value is None or value == "":
            return "-"
        return str(value).replace("|", "\\|").replace("\n", " ")

    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(clean(value) for value in row) + " |")
    return "\n".join(lines)


def render_markdown(payload: dict[str, Any]) -> str:
    lines = [
        "# Transcripted PostHog Dashboard Queries",
        "",
        f"Generated: {payload['generated_at']}",
        f"Mode: {payload['mode']}",
        f"Window: last {payload['window_days']} days",
        f"App version: {payload.get('app_version') or 'all app versions'}",
        "",
        payload["privacy"],
        "",
    ]
    by_family: dict[str, list[dict[str, Any]]] = {}
    for query in payload["queries"]:
        by_family.setdefault(query["family"], []).append(query)

    for family in FAMILIES:
        queries = by_family.get(family)
        if not queries:
            continue
        lines.extend(["## " + family.replace("_", " ").title(), ""])
        for query in queries:
            lines.extend(
                [
                    "### " + query["id"],
                    "",
                    query["description"],
                    "",
                    "Output columns: `" + "`, `".join(query["columns"]) + "`.",
                    "",
                ]
            )
            for note in query.get("notes") or []:
                lines.extend([f"- {note}", ""])
            if "hogql" in query:
                lines.extend(["```sql", query["hogql"], "```", ""])
            if "rows" in query:
                rows = query.get("rows") or []
                if rows:
                    headers = list(query["columns"])
                    lines.extend([md_table(headers, [[row.get(column) for column in headers] for row in rows[:12]]), ""])
                else:
                    lines.extend(["No rows returned.", ""])
    return "\n".join(lines)


def write_outputs(payload: dict[str, Any], markdown: str, write_dir: Path | None) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-dashboard-queries") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    markdown_path = output_dir / "posthog-dashboard-queries.md"
    json_path = output_dir / "posthog-dashboard-queries.json"
    markdown_path.write_text(markdown, encoding="utf-8")
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return markdown_path, json_path


def load_fixture(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PostHogDashboardError(f"fixture could not be read: {path}: {exc}") from exc


def fixture_payload(path: Path, family: str, days: int, app_version: str | None) -> dict[str, Any]:
    fixture = load_fixture(path)
    specs = selected_specs(family, days, app_version)
    spec_ids = {spec.id for spec in specs}
    queries = [query for query in fixture.get("queries", []) if query.get("id") in spec_ids]
    by_id = {spec.id: spec for spec in specs}
    for query in queries:
        spec = by_id[str(query["id"])]
        query["family"] = spec.family
        query["title"] = spec.title
        query["description"] = spec.description
        query["columns"] = list(spec.columns)
        query["notes"] = list(spec.notes)
        unsafe = unsafe_columns(query["columns"])
        if unsafe:
            raise PostHogDashboardError(f"fixture query {spec.id} has unsafe output columns: {', '.join(unsafe)}")
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "mode": "fixture",
        "window_days": days,
        "app_version": app_version,
        "privacy": "Synthetic fixture rows only. Counts and buckets are fake and contain no private data.",
        "families": sorted({query["family"] for query in queries}),
        "queries": queries,
    }


def validate_specs(specs: list[QuerySpec], require_all_families: bool = False) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()
    for spec in specs:
        if spec.id in seen:
            errors.append(f"duplicate query id: {spec.id}")
        seen.add(spec.id)
        unsafe = unsafe_columns(spec.columns)
        if unsafe:
            errors.append(f"{spec.id} exposes unsafe output column(s): {', '.join(unsafe)}")
        sql_upper = spec.sql.upper()
        if "SELECT *" in sql_upper:
            errors.append(f"{spec.id} uses SELECT *")
        if spec.family not in FAMILIES:
            errors.append(f"{spec.id} uses unknown family {spec.family}")
    if require_all_families:
        missing = sorted(set(FAMILIES) - {spec.family for spec in specs})
        if missing:
            errors.append("missing family specs: " + ", ".join(missing))
    return errors


def run_self_test() -> int:
    specs = query_specs(30, "1.1.48")
    errors = validate_specs(specs, require_all_families=True)
    try:
        payload = fixture_payload(FIXTURE_PATH, "all", 30, "1.1.48")
    except PostHogDashboardError as exc:
        errors.append(str(exc))
        payload = {"queries": []}
    fallback_rows = posthog.rows_as_dicts(
        {"results": [["2026-06-18", 24]]},
        DISALLOWED_OUTPUT_FRAGMENTS,
        PostHogDashboardError,
        declared_columns=("day", "active_devices"),
    )
    if fallback_rows != [{"day": "2026-06-18", "active_devices": 24}]:
        errors.append("column-less response fallback did not use declared columns")
    rendered = render_markdown(payload)
    required = (
        "wau.active_devices_by_week",
        "activation.reach_ladder",
        "reliability.workflow_failure_rates",
        "feature_adoption.artifact_and_agent_actions",
        "release_health.version_event_counts",
    )
    for query_id in required:
        if query_id not in rendered:
            errors.append(f"fixture render missing {query_id}")
    forbidden_output = ("transcript_text", "audio_path", "meeting_title", "raw_url", "email", "token")
    lowered = rendered.lower()
    leaked = [fragment for fragment in forbidden_output if fragment in lowered]
    if leaked:
        errors.append("fixture render contains unsafe fragment(s): " + ", ".join(leaked))
    if errors:
        print("self-test failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=("all", *FAMILIES), default="all", help="Dashboard family to print or run.")
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version/version filter, e.g. 1.1.48.")
    parser.add_argument("--dry-run", action="store_true", help="Print query specs without requiring PostHog credentials.")
    parser.add_argument("--fixture", type=Path, help="Render synthetic fixture rows instead of querying PostHog.")
    parser.add_argument("--json-only", action="store_true", help="Print JSON instead of Markdown.")
    parser.add_argument("--write-dir", type=Path, help="Directory for posthog-dashboard-queries.md/json outputs.")
    parser.add_argument("--self-test", action="store_true", help="Run offline fixture/spec/privacy checks.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.days <= 0:
        print("ERROR: --days must be positive", file=sys.stderr)
        return 2

    specs = selected_specs(args.family, args.days, args.app_version)
    if not specs:
        print("ERROR: no query specs selected", file=sys.stderr)
        return 2

    try:
        spec_errors = validate_specs(specs)
        if spec_errors:
            raise PostHogDashboardError("; ".join(spec_errors))
        if args.fixture:
            payload = fixture_payload(args.fixture, args.family, args.days, args.app_version)
        elif args.dry_run:
            payload = spec_payload(specs, args.days, args.app_version)
        else:
            payload = execute_payload(specs, args.days, args.app_version)
    except PostHogDashboardError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3

    markdown = render_markdown(payload)
    if args.write_dir:
        markdown_path, json_path = write_outputs(payload, markdown, args.write_dir)
    else:
        markdown_path = json_path = None

    if args.json_only:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(markdown)
        if markdown_path and json_path:
            print(f"Report written: {markdown_path}")
            print(f"Data written: {json_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
