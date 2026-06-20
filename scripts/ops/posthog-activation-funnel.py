#!/usr/bin/env python3
"""Build a privacy-safe PostHog activation funnel report for Transcripted."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import posthog_common as posthog

RELEVANT_EVENTS = (
    "app_launched",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_permission_status_changed",
    "onboarding_completed",
    "onboarding_first_dictation_started",
    "dictation_started",
    "onboarding_first_dictation_saved",
    "dictation_artifact_saved",
    "dictation_completed",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "activation_return_proxy_observed",
    "activation_first_artifact_saved",
    "activation_second_artifact_saved",
    "agent_capture_query_observed",
    "workflow_abandoned",
)

WORKFLOW_EVENTS = (
    "app_launched",
    "onboarding_completed",
    "dictation_started",
    "dictation_artifact_saved",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "activation_second_artifact_saved",
    "workflow_abandoned",
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
        "event = 'activation_first_artifact_saved'",
        "observed",
        "First saved dictation or meeting Markdown artifact, emitted once per install from the successful save path.",
    ),
    StepDefinition(
        "saved_markdown_plus_dictation_proxy_devices",
        "Saved Markdown plus dictation proxy",
        "event IN ('activation_first_artifact_saved', 'dictation_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')",
        "proxy",
        "Adds dictation completion as useful dictation-volume context, but saved Markdown proof comes from saved-artifact events.",
    ),
    StepDefinition(
        "artifact_action_devices",
        "Artifact opened or revealed",
        "event = 'activation_artifact_action_clicked'",
        "observed",
        "Home/onboarding artifact actions such as open Markdown, preview, and reveal folder.",
    ),
    StepDefinition(
        "second_artifact_devices",
        "Second saved artifact",
        "event = 'activation_second_artifact_saved'",
        "observed",
        "Devices that reached a second durable saved Markdown artifact, bucketed from first save.",
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
    StepDefinition(
        "workflow_abandonment_devices",
        "Workflow abandonment",
        "event = 'workflow_abandoned'",
        "observed",
        "Devices with a confident privacy-safe abandonment event, bucketed by workflow, stage, and reason.",
    ),
)

SEQUENCE_STEPS = (
    ("Launch", "event = 'app_launched'"),
    ("Onboarding touched", "event IN ('onboarding_shown', 'onboarding_step_viewed')"),
    ("Permission ready", "event = 'onboarding_completed'"),
    ("Dictation started", "event IN ('onboarding_first_dictation_started', 'dictation_started')"),
    (
        "Saved Markdown or dictation proxy",
        "event IN ('activation_first_artifact_saved', 'dictation_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')",
    ),
    (
        "Artifact opened or prompt copied",
        "event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked')",
    ),
    (
        "Agent setup/prompt signal",
        "event IN ('activation_agent_setup_cta_clicked', 'activation_agent_prompt_action_clicked', 'onboarding_agent_cta_clicked')",
    ),
)


class PostHogReportError(RuntimeError):
    pass


load_env = posthog.load_env
sql_quote = posthog.sql_quote
sql_list = posthog.sql_list
app_version_filter = posthog.app_version_filter


def posthog_config() -> tuple[str, str, str]:
    return posthog.posthog_config(PostHogReportError)


def run_hogql(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
    return posthog.run_hogql(host, project_id, token, query, PostHogReportError)


def rows_as_dicts(response: dict[str, Any]) -> list[dict[str, Any]]:
    return posthog.rows_as_dicts(response, DISALLOWED_OUTPUT_COLUMNS, PostHogReportError)


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


def second_artifact_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['first_artifact_kind'] AS first_artifact_kind,
  properties['second_artifact_kind'] AS second_artifact_kind,
  properties['days_since_first_bucket'] AS days_since_first_bucket,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event = 'activation_second_artifact_saved'
  {app_version_filter(app_version)}
GROUP BY first_artifact_kind, second_artifact_kind, days_since_first_bucket, surface
ORDER BY devices DESC, events DESC
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


def workflow_abandonment_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['workflow_kind'] AS workflow_kind,
  properties['stage'] AS stage,
  properties['reason_kind'] AS reason_kind,
  properties['surface'] AS surface,
  properties['prior_ready_state'] AS prior_ready_state,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event = 'workflow_abandoned'
  {app_version_filter(app_version)}
GROUP BY workflow_kind, stage, reason_kind, surface, prior_ready_state
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
        "second_artifacts": second_artifact_query(days, app_version),
        "agent_signals": agent_signals_query(days, app_version),
        "workflow_abandonment": workflow_abandonment_query(days, app_version),
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
    second_artifact = as_int(reach.get("second_artifact_devices"))
    agent_signal = as_int(reach.get("agent_setup_devices"))
    true_agent_query = as_int(reach.get("true_agent_query_devices"))
    return_proxy = as_int(reach.get("return_proxy_devices"))
    workflow_abandonment = as_int(reach.get("workflow_abandonment_devices"))
    app_version = data.get("app_version") or "all app versions"

    limitations = [
        "`permission ready` uses `onboarding_completed` as a proxy. The app guards completion on required dictation permissions, but this does not count users who became ready outside onboarding.",
        "`strict saved Markdown` counts `activation_first_artifact_saved`, emitted once per install from successful dictation and meeting Markdown save paths.",
        "`dictation_artifact_saved`, `dictation_completed`, `onboarding_first_dictation_saved`, and `meeting_transcript_saved` are included only in the broader proxy row for dictation volume and legacy continuity.",
        "Agent setup and prompt-copy events prove intent. They do not prove the user asked an agent a sourced question or got a useful answer.",
        "`activation_second_artifact_saved` proves a second durable artifact save on the same anonymous device, but does not inspect artifact content or join identity.",
        "`agent_capture_query_observed` is the desired true first-agent-use signal and is currently expected to be zero until instrumentation exists.",
        "`workflow_abandoned` is a conservative exit map. It should not be read as every possible drop-off or every click.",
    ]

    recommended_tiles = [
        "Ordered funnel: launch -> onboarding -> permission ready -> dictation -> saved Markdown/proxy -> artifact/prompt -> agent setup signal.",
        "Saved artifact quality: strict saved Markdown vs dictation-completed volume, split by artifact kind.",
        "Second value moment: `activation_second_artifact_saved` by first/second artifact kind and days-since-first bucket.",
        "Artifact actions: open Markdown, preview, reveal folder, and copy-for-agent surfaces.",
        "Agent bridge: setup kind, agent target, prompt kind, result, and surface.",
        "Abandonment exits: workflow kind, stage, reason kind, surface, and prior-ready state.",
        "Return loop: `activation_return_proxy_observed` by return-window bucket.",
        "Data quality: missing true-agent-use event and the dictation completion-vs-saved-artifact split.",
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
        f"- Second saved artifact reach: **{second_artifact} devices** ({pct(second_artifact, launch)} of launch).",
        f"- Agent setup/proxy reach: **{agent_signal} devices** ({pct(agent_signal, launch)} of launch).",
        f"- Return proxy reach: **{return_proxy} devices** ({pct(return_proxy, launch)} of launch).",
        f"- Workflow abandonment exits: **{workflow_abandonment} devices** ({pct(workflow_abandonment, launch)} of launch).",
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
            "Second Saved Artifacts",
            data["results"].get("second_artifacts", []),
            ["first_artifact_kind", "second_artifact_kind", "days_since_first_bucket", "surface", "events", "devices"],
        ),
        render_top_rows(
            "Agent Signals",
            data["results"].get("agent_signals", []),
            ["event", "prompt_kind", "setup_kind", "agent_target", "result", "surface", "events", "devices"],
        ),
        render_top_rows(
            "Workflow Abandonment Exits",
            data["results"].get("workflow_abandonment", []),
            ["workflow_kind", "stage", "reason_kind", "surface", "prior_ready_state", "events", "devices"],
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
        "Verify `activation_first_artifact_saved` and `activation_second_artifact_saved` reach live PostHog for current builds, then add `agent_capture_query_observed` so the dashboard can separate repeated saved-artifact value from true sourced-agent-use.",
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
                "second_artifact_devices": 1,
                "agent_prompt_devices": 1,
                "agent_setup_devices": 1,
                "workflow_abandonment_devices": 1,
                "return_proxy_devices": 1,
                "true_agent_query_devices": 0,
            }],
            "sequence": [{"deepest_step": 1, "devices": 2}, {"deepest_step": 7, "devices": 1}],
            "event_counts": [{"event": "app_launched", "events": 20, "devices": 10}],
            "daily_active": [{"day": "2026-06-19", "active_devices": 3}],
            "onboarding_completion": [],
            "artifact_actions": [],
            "second_artifacts": [],
            "agent_signals": [],
            "workflow_abandonment": [{
                "workflow_kind": "onboarding",
                "stage": "permissions",
                "reason_kind": "window_closed",
                "surface": "onboarding",
                "prior_ready_state": "not_ready",
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
    reach = reach_query(30, None)
    sequence = sequence_query(30, None)
    if "activation_first_artifact_saved') AS strict_saved_markdown_devices" not in reach:
        print("self-test failed: strict saved-Markdown reach must use activation_first_artifact_saved", file=sys.stderr)
        return 1
    if "activation_first_artifact_saved" not in sequence:
        print("self-test failed: ordered saved-Markdown step must include activation_first_artifact_saved", file=sys.stderr)
        return 1
    if "Workflow abandonment exits: **1 devices**" not in report:
        print("self-test failed: missing workflow abandonment reach", file=sys.stderr)
        return 1
    for query in (
        reach,
        event_counts_query(30, None),
        daily_active_query(30, None),
        sequence,
        onboarding_completion_query(30, None),
        artifact_actions_query(30, None),
        second_artifact_query(30, None),
        agent_signals_query(30, None),
        workflow_abandonment_query(30, None),
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
