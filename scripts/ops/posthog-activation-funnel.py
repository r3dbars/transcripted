#!/usr/bin/env python3
"""Build a privacy-safe PostHog activation funnel report for Transcripted."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TRUSTED_POSTHOG_HOSTS = {
    "https://app.posthog.com",
    "https://eu.posthog.com",
    "https://posthog.com",
    "https://us.posthog.com",
}

ENV_PATHS = (
    Path.cwd() / ".env.local",
    Path.cwd() / ".env",
    Path.home() / ".transcripted-ops.env",
    Path.home() / ".hermes" / ".env",
    Path.home() / ".hermes" / "profiles" / "ops" / ".env",
)

RELEVANT_EVENTS = (
    "app_launched",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_permission_status_changed",
    "onboarding_completed",
    "onboarding_first_dictation_started",
    "dictation_started",
    "onboarding_first_dictation_saved",
    "dictation_completed",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "activation_return_proxy_observed",
    "activation_first_artifact_saved",
    "meeting_summary_requested",
    "meeting_summary_finished",
    "local_meeting_summary_model_prepare_started",
    "local_meeting_summary_model_prepare_completed",
    "local_meeting_summary_model_prepare_cancelled",
    "local_meeting_summary_model_prepare_failed",
    "agent_capture_query_observed",
)

WORKFLOW_EVENTS = (
    "app_launched",
    "onboarding_completed",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "meeting_summary_requested",
    "meeting_summary_finished",
)

DISALLOWED_OUTPUT_COLUMNS = {
    "distinct_id",
    "person_id",
    "uuid",
    "email",
    "name",
    "path",
    "title",
    "transcript",
    "url",
}


@dataclass(frozen=True)
class StepDefinition:
    key: str
    label: str
    predicate: str
    quality: str
    definition: str


REACH_STEPS = (
    StepDefinition(
        "launch_devices",
        "Launch",
        "event = 'app_launched'",
        "observed",
        "Anonymous devices that launched the app.",
    ),
    StepDefinition(
        "onboarding_devices",
        "Onboarding touched",
        "event IN ('onboarding_shown', 'onboarding_step_viewed')",
        "observed",
        "Devices that saw or moved through onboarding.",
    ),
    StepDefinition(
        "permission_ready_devices",
        "Permission ready",
        "event = 'onboarding_completed'",
        "proxy",
        "Onboarding completion is guarded by required dictation permissions. Meeting System Audio readiness is shown separately.",
    ),
    StepDefinition(
        "first_dictation_or_dictation_devices",
        "First dictation or dictation started",
        "event IN ('onboarding_first_dictation_started', 'dictation_started')",
        "mixed",
        "Onboarding first-dictation starts plus general dictation starts.",
    ),
    StepDefinition(
        "strict_saved_markdown_devices",
        "Strict saved Markdown",
        "event IN ('onboarding_first_dictation_saved', 'meeting_transcript_saved')",
        "observed",
        "Saved onboarding dictation Markdown or saved meeting Markdown. General saved dictation lacks a dedicated remote event.",
    ),
    StepDefinition(
        "saved_markdown_plus_dictation_proxy_devices",
        "Saved Markdown plus dictation proxy",
        "event IN ('onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')",
        "proxy",
        "Adds dictation completion as a product-success proxy because general dictation save is only local diagnostics today.",
    ),
    StepDefinition(
        "artifact_action_devices",
        "Artifact opened or revealed",
        "event = 'activation_artifact_action_clicked'",
        "observed",
        "Home/onboarding artifact actions such as open Markdown, preview, and reveal folder.",
    ),
    StepDefinition(
        "summary_requested_devices",
        "Summary requested",
        "event = 'meeting_summary_requested'",
        "observed",
        "Devices that asked for a local meeting summary from a saved transcript.",
    ),
    StepDefinition(
        "summary_finished_devices",
        "Summary finished",
        "event = 'meeting_summary_finished'",
        "observed",
        "Devices with a local summary success, failure, or cancellation outcome.",
    ),
    StepDefinition(
        "agent_prompt_devices",
        "Agent prompt copied/opened",
        "event = 'activation_agent_prompt_action_clicked'",
        "proxy",
        "Prompt or setup text copied/opened for an agent. This is not proof the agent answered.",
    ),
    StepDefinition(
        "agent_setup_devices",
        "Agent setup signal",
        "event IN ('activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')",
        "proxy",
        "Agent setup CTAs and onboarding agent CTAs.",
    ),
    StepDefinition(
        "return_proxy_devices",
        "Return proxy",
        "event = 'activation_return_proxy_observed'",
        "proxy",
        "A later Home view of a prior saved artifact, bucketed by return window.",
    ),
    StepDefinition(
        "true_agent_query_devices",
        "True agent-use signal",
        "event = 'agent_capture_query_observed'",
        "missing",
        "Desired future privacy-safe event for the first sourced agent query/answer loop.",
    ),
)

SEQUENCE_STEPS = (
    ("Launch", "event = 'app_launched'"),
    ("Onboarding touched", "event IN ('onboarding_shown', 'onboarding_step_viewed')"),
    ("Permission ready", "event = 'onboarding_completed'"),
    ("Dictation started", "event IN ('onboarding_first_dictation_started', 'dictation_started')"),
    (
        "Saved Markdown or dictation proxy",
        "event IN ('onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')",
    ),
    (
        "Artifact opened or prompt copied",
        "event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked')",
    ),
    ("Local summary requested", "event = 'meeting_summary_requested'"),
    ("Local summary finished", "event = 'meeting_summary_finished'"),
    (
        "Agent setup/prompt signal",
        "event IN ('activation_agent_setup_cta_clicked', 'activation_agent_prompt_action_clicked', 'onboarding_agent_cta_clicked')",
    ),
)


class PostHogReportError(RuntimeError):
    pass


def load_env() -> None:
    for path in ENV_PATHS:
        if not path.is_file():
            continue
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip().removeprefix("export ").strip()
            value = value.strip().strip('"').strip("'")
            if key and value and key not in os.environ:
                os.environ[key] = value


def normalize_posthog_host(raw: str) -> str:
    host = raw.strip().rstrip("/")
    if host == "https://us.i.posthog.com":
        return "https://us.posthog.com"
    if host == "https://eu.i.posthog.com":
        return "https://eu.posthog.com"
    return host


def posthog_config() -> tuple[str, str, str]:
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    host = normalize_posthog_host(
        os.environ.get("POSTHOG_APP_HOST")
        or os.environ.get("POSTHOG_HOST")
        or "https://us.posthog.com"
    )

    missing = []
    if not token:
        missing.append("POSTHOG_PERSONAL_API_KEY")
    if not project_id:
        missing.append("POSTHOG_PROJECT_ID")
    if missing:
        raise PostHogReportError("missing " + ", ".join(missing))

    if not host.startswith("https://"):
        raise PostHogReportError(f"refusing non-HTTPS PostHog host: {host}")
    if host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1":
        raise PostHogReportError(
            f"refusing untrusted PostHog host: {host}; set POSTHOG_ALLOW_UNTRUSTED_HOST=1 only for trusted self-hosted PostHog"
        )

    return host, project_id, token


def sql_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def sql_list(values: tuple[str, ...]) -> str:
    return ", ".join(sql_quote(value) for value in values)


def app_version_filter(app_version: str | None) -> str:
    if not app_version:
        return ""
    return f"AND properties['app_version'] = {sql_quote(app_version)}"


def run_hogql(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
    payload = {
        "query": {"kind": "HogQLQuery", "query": query},
        "refresh": "blocking",
    }
    request = urllib.request.Request(
        f"{host}/api/projects/{project_id}/query/",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise PostHogReportError(f"PostHog query failed with HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise PostHogReportError(f"PostHog query failed: {exc}") from exc


def rows_as_dicts(response: dict[str, Any]) -> list[dict[str, Any]]:
    columns = response.get("columns") or []
    rows = response.get("results") or response.get("data") or []
    unsafe = [
        str(column)
        for column in columns
        if any(fragment in str(column).lower() for fragment in DISALLOWED_OUTPUT_COLUMNS)
    ]
    if unsafe:
        raise PostHogReportError(f"query attempted to expose unsafe output columns: {', '.join(unsafe)}")
    return [
        {str(column): row[index] if index < len(row) else None for index, column in enumerate(columns)}
        for row in rows
    ]


def reach_query(days: int, app_version: str | None) -> str:
    columns = ",\n  ".join(
        f"uniqIf(distinct_id, {step.predicate}) AS {step.key}"
        for step in REACH_STEPS
    )
    return f"""
SELECT
  {columns}
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(RELEVANT_EVENTS)})
  {app_version_filter(app_version)}
"""


def event_counts_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT event, count() AS events, uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(RELEVANT_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY event
ORDER BY event ASC
"""


def daily_active_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT toDate(timestamp) AS day, uniq(distinct_id) AS active_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(WORKFLOW_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY day
ORDER BY day ASC
"""


def sequence_query(days: int, app_version: str | None) -> str:
    predicates = ",\n      ".join(predicate for _, predicate in SEQUENCE_STEPS)
    return f"""
SELECT deepest_step, count() AS devices
FROM (
  SELECT distinct_id,
    windowFunnel({int(days)} * 24 * 3600)(toDateTime(timestamp),
      {predicates}
    ) AS deepest_step
  FROM events
  WHERE timestamp >= now() - INTERVAL {int(days)} DAY
    AND event IN ({sql_list(RELEVANT_EVENTS)})
    {app_version_filter(app_version)}
  GROUP BY distinct_id
)
GROUP BY deepest_step
ORDER BY deepest_step ASC
"""


def onboarding_completion_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['completion_flow'] AS completion_flow,
  properties['meeting_recording_ready'] AS meeting_recording_ready,
  properties['calendar_status'] AS calendar_status,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event = 'onboarding_completed'
  {app_version_filter(app_version)}
GROUP BY completion_flow, meeting_recording_ready, calendar_status
ORDER BY devices DESC
LIMIT 20
"""


def artifact_actions_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['artifact_kind'] AS artifact_kind,
  properties['action_kind'] AS action_kind,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event = 'activation_artifact_action_clicked'
  {app_version_filter(app_version)}
GROUP BY artifact_kind, action_kind, surface
ORDER BY events DESC
LIMIT 40
"""


def agent_signals_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['prompt_kind'] AS prompt_kind,
  properties['setup_kind'] AS setup_kind,
  properties['agent_target'] AS agent_target,
  properties['result'] AS result,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')
  {app_version_filter(app_version)}
GROUP BY event, prompt_kind, setup_kind, agent_target, result, surface
ORDER BY events DESC
LIMIT 60
"""


def meeting_summary_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['result'] AS result,
  properties['failure_kind'] AS failure_kind,
  properties['model_state'] AS model_state,
  properties['provider'] AS provider,
  properties['model_family'] AS model_family,
  properties['artifact_age_bucket'] AS artifact_age_bucket,
  properties['duration_bucket'] AS duration_bucket,
  properties['latency_bucket'] AS latency_bucket,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_summary_requested', 'meeting_summary_finished', 'local_meeting_summary_model_prepare_started', 'local_meeting_summary_model_prepare_completed', 'local_meeting_summary_model_prepare_cancelled', 'local_meeting_summary_model_prepare_failed')
  {app_version_filter(app_version)}
GROUP BY event, result, failure_kind, model_state, provider, model_family, artifact_age_bucket, duration_bucket, latency_bucket, surface
ORDER BY events DESC
LIMIT 80
"""


def fetch_report_data(days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()

    queries = {
        "reach": reach_query(days, app_version),
        "event_counts": event_counts_query(days, app_version),
        "daily_active": daily_active_query(days, app_version),
        "sequence": sequence_query(days, app_version),
        "onboarding_completion": onboarding_completion_query(days, app_version),
        "artifact_actions": artifact_actions_query(days, app_version),
        "agent_signals": agent_signals_query(days, app_version),
        "meeting_summary": meeting_summary_query(days, app_version),
    }

    results = {
        name: rows_as_dicts(run_hogql(host, project_id, token, query))
        for name, query in queries.items()
    }
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "project": "configured PostHog project",
            "privacy": "aggregate counts only; no distinct IDs, people rows, transcript text, paths, titles, URLs, or raw payloads are written",
        },
        "step_definitions": [
            {
                "key": step.key,
                "label": step.label,
                "quality": step.quality,
                "definition": step.definition,
            }
            for step in REACH_STEPS
        ],
        "sequence_steps": [
            {"step": index + 1, "label": label}
            for index, (label, _) in enumerate(SEQUENCE_STEPS)
        ],
        "results": results,
    }


def as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def pct(numerator: int, denominator: int) -> str:
    if denominator <= 0:
        return "n/a"
    return f"{(numerator / denominator) * 100:.1f}%"


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


def render_reach_table(data: dict[str, Any]) -> str:
    reach = (data["results"].get("reach") or [{}])[0]
    launch_devices = as_int(reach.get("launch_devices"))
    rows: list[list[Any]] = []
    for step in REACH_STEPS:
        devices = as_int(reach.get(step.key))
        rows.append([
            step.label,
            devices,
            pct(devices, launch_devices),
            step.quality,
            step.definition,
        ])
    return md_table(
        ["Step", "Devices", "Of launch", "Quality", "Definition"],
        rows,
    )


def render_sequence_table(data: dict[str, Any]) -> str:
    histogram = {
        as_int(row.get("deepest_step")): as_int(row.get("devices"))
        for row in data["results"].get("sequence", [])
    }
    launch_sequence_devices = sum(count for step, count in histogram.items() if step >= 1)
    rows = []
    previous = 0
    for index, item in enumerate(data["sequence_steps"], start=1):
        devices = sum(count for step, count in histogram.items() if step >= index)
        rows.append([
            index,
            item["label"],
            devices,
            pct(devices, launch_sequence_devices),
            pct(devices, previous) if previous else "n/a",
        ])
        previous = devices
    rows.append([
        "0",
        "Relevant events without a launch in-window",
        histogram.get(0, 0),
        "n/a",
        "n/a",
    ])
    return md_table(["Order", "Step", "Devices", "Of ordered launch", "Step conversion"], rows)


def render_top_rows(title: str, rows: list[dict[str, Any]], columns: list[str], limit: int = 12) -> str:
    if not rows:
        return f"### {title}\n\nNo rows in this window.\n"
    return f"### {title}\n\n" + md_table(columns, [[row.get(column) for column in columns] for row in rows[:limit]]) + "\n"


def render_report(data: dict[str, Any]) -> str:
    reach = (data["results"].get("reach") or [{}])[0]
    launch = as_int(reach.get("launch_devices"))
    strict_saved = as_int(reach.get("strict_saved_markdown_devices"))
    saved_proxy = as_int(reach.get("saved_markdown_plus_dictation_proxy_devices"))
    agent_signal = as_int(reach.get("agent_setup_devices"))
    summary_requested = as_int(reach.get("summary_requested_devices"))
    summary_finished = as_int(reach.get("summary_finished_devices"))
    true_agent_query = as_int(reach.get("true_agent_query_devices"))
    return_proxy = as_int(reach.get("return_proxy_devices"))
    app_version = data.get("app_version") or "all app versions"

    limitations = [
        "`permission ready` uses `onboarding_completed` as a proxy. The app guards completion on required dictation permissions, but this does not count users who became ready outside onboarding.",
        "`strict saved Markdown` counts onboarding first-dictation saves and meeting transcript saves. General dictation save currently has local diagnostics but no dedicated remote saved-artifact event.",
        "`dictation_completed` is included only in the proxy saved-Markdown row. It can prove useful dictation volume, but not every general saved Markdown write.",
        "Agent setup and prompt-copy events prove intent. They do not prove the user asked an agent a sourced question or got a useful answer.",
        "`agent_capture_query_observed` is the desired true first-agent-use signal and is currently expected to be zero until instrumentation exists.",
    ]

    recommended_tiles = [
        "Ordered funnel: launch -> onboarding -> permission ready -> dictation -> saved Markdown/proxy -> artifact/prompt -> agent setup signal.",
        "Saved artifact quality: strict saved Markdown vs dictation-completed proxy, split by artifact kind.",
        "Artifact actions: open Markdown, preview, reveal folder, and copy-for-agent surfaces.",
        "Local summary beta: requested vs finished, result, model state, provider family, artifact age, meeting duration, and latency buckets.",
        "Agent bridge: setup kind, agent target, prompt kind, result, and surface.",
        "Return loop: `activation_return_proxy_observed` by return-window bucket.",
        "Data quality: missing true-agent-use event and general dictation saved-artifact gap.",
    ]

    lines = [
        "# Transcripted PostHog Activation Funnel",
        "",
        f"Generated: {data['generated_at']}",
        f"Window: last {data['window_days']} days, {app_version}",
        "",
        "Source: PostHog aggregate HogQL. The report writes counts and enum breakdowns only; no user IDs, transcript text, file paths, meeting titles, raw URLs, or raw payload rows are exported.",
        "",
        "## Decision Read",
        "",
        f"- Launch reach in-window: **{launch} anonymous devices**.",
        f"- Strict saved Markdown reach: **{strict_saved} devices** ({pct(strict_saved, launch)} of launch).",
        f"- Saved Markdown plus dictation proxy reach: **{saved_proxy} devices** ({pct(saved_proxy, launch)} of launch).",
        f"- Local summary requested / finished reach: **{summary_requested} / {summary_finished} devices**.",
        f"- Agent setup/proxy reach: **{agent_signal} devices** ({pct(agent_signal, launch)} of launch).",
        f"- Return proxy reach: **{return_proxy} devices** ({pct(return_proxy, launch)} of launch).",
        f"- True agent-query proof: **{true_agent_query} devices**. Treat this as unknown, not green, until instrumentation exists.",
        "",
        "## Funnel Reach",
        "",
        render_reach_table(data),
        "",
        "## Ordered Funnel",
        "",
        render_sequence_table(data),
        "",
        "## Source Event Counts",
        "",
        md_table(
            ["Event", "Events", "Devices"],
            [
                [row.get("event"), row.get("events"), row.get("devices")]
                for row in data["results"].get("event_counts", [])
            ],
        ),
        "",
        "## Daily Active Workflow Devices",
        "",
        md_table(
            ["Day", "Active devices"],
            [
                [row.get("day"), row.get("active_devices")]
                for row in data["results"].get("daily_active", [])
            ],
        ),
        "",
        "## Breakdowns",
        "",
        render_top_rows(
            "Onboarding Completion",
            data["results"].get("onboarding_completion", []),
            ["completion_flow", "meeting_recording_ready", "calendar_status", "events", "devices"],
        ),
        render_top_rows(
            "Artifact Actions",
            data["results"].get("artifact_actions", []),
            ["artifact_kind", "action_kind", "surface", "events", "devices"],
        ),
        render_top_rows(
            "Agent Signals",
            data["results"].get("agent_signals", []),
            ["event", "prompt_kind", "setup_kind", "agent_target", "result", "surface", "events", "devices"],
        ),
        render_top_rows(
            "Local Meeting Summary Funnel",
            data["results"].get("meeting_summary", []),
            ["event", "result", "failure_kind", "model_state", "provider", "model_family", "artifact_age_bucket", "duration_bucket", "latency_bucket", "surface", "events", "devices"],
        ),
        "## Data Limitations",
        "",
        "\n".join(f"- {item}" for item in limitations),
        "",
        "## Recommended PostHog Dashboard",
        "",
        "\n".join(f"- {item}" for item in recommended_tiles),
        "",
        "## Next Best Action",
        "",
        "Add one privacy-safe first-use event for `activation_first_artifact_saved` and one for `agent_capture_query_observed`, then make the dashboard's primary KPI the share of launch devices that reach true sourced-agent-use within 7 days.",
        "",
    ]
    return "\n".join(lines)


def write_outputs(data: dict[str, Any], report: str, write_dir: Path | None) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-activation-funnel") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "activation-funnel-report.md"
    data_path = output_dir / "activation-funnel-data.json"
    report_path.write_text(report, encoding="utf-8")
    data_path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    return report_path, data_path


def run_self_test() -> int:
    sample = {
        "generated_at": "2026-06-19T00:00:00+00:00",
        "window_days": 30,
        "app_version": None,
        "source": {"privacy": "aggregate counts only"},
        "step_definitions": [],
        "sequence_steps": [{"step": index + 1, "label": label} for index, (label, _) in enumerate(SEQUENCE_STEPS)],
        "results": {
            "reach": [{
                "launch_devices": 10,
                "onboarding_devices": 8,
                "permission_ready_devices": 4,
                "first_dictation_or_dictation_devices": 3,
                "strict_saved_markdown_devices": 2,
                "saved_markdown_plus_dictation_proxy_devices": 3,
                "artifact_action_devices": 2,
                "summary_requested_devices": 2,
                "summary_finished_devices": 1,
                "agent_prompt_devices": 1,
                "agent_setup_devices": 1,
                "return_proxy_devices": 1,
                "true_agent_query_devices": 0,
            }],
            "sequence": [{"deepest_step": 1, "devices": 2}, {"deepest_step": 7, "devices": 1}],
            "event_counts": [{"event": "app_launched", "events": 20, "devices": 10}],
            "daily_active": [{"day": "2026-06-19", "active_devices": 3}],
            "onboarding_completion": [],
            "artifact_actions": [],
            "agent_signals": [],
            "meeting_summary": [{
                "event": "meeting_summary_finished",
                "result": "success",
                "failure_kind": None,
                "model_state": "ready",
                "provider": "gemma_mlx",
                "model_family": "gemma_mlx",
                "artifact_age_bucket": "24_48h",
                "duration_bucket": "10_29m",
                "latency_bucket": "5s_plus",
                "surface": "home",
                "events": 1,
                "devices": 1,
            }],
        },
    }
    report = render_report(sample)
    forbidden = ("distinct_id", "transcript_text", "audio_path", "meeting_title", "raw_url")
    lowered = report.lower()
    leaked = [fragment for fragment in forbidden if fragment in lowered]
    if leaked:
        print(f"self-test failed: unsafe fragment in rendered report: {', '.join(leaked)}", file=sys.stderr)
        return 1
    if "True agent-query proof: **0 devices**" not in report:
        print("self-test failed: missing true agent-query proof limitation", file=sys.stderr)
        return 1
    for query in (
        reach_query(30, None),
        event_counts_query(30, None),
        daily_active_query(30, None),
        sequence_query(30, None),
        onboarding_completion_query(30, None),
        artifact_actions_query(30, None),
        agent_signals_query(30, None),
        meeting_summary_query(30, None),
    ):
        if "SELECT *" in query.upper():
            print("self-test failed: query uses SELECT *", file=sys.stderr)
            return 1
    print("self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version filter, e.g. 1.1.48.")
    parser.add_argument("--write-dir", type=Path, help="Directory for activation-funnel-report.md and activation-funnel-data.json.")
    parser.add_argument("--json-only", action="store_true", help="Print the JSON payload instead of the Markdown report.")
    parser.add_argument("--self-test", action="store_true", help="Run offline formatting/privacy checks without PostHog access.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.days <= 0:
        print("ERROR: --days must be positive", file=sys.stderr)
        return 2

    try:
        data = fetch_report_data(args.days, args.app_version)
        report = render_report(data)
        report_path, data_path = write_outputs(data, report, args.write_dir)
    except PostHogReportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3

    if args.json_only:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print(report)
        print(f"Report written: {report_path}")
        print(f"Data written: {data_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
