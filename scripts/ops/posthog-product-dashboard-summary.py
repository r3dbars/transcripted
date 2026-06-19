#!/usr/bin/env python3
"""Print the five aggregate PostHog product-learning dashboard summaries."""

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

DASHBOARD_EVENTS = (
    "app_launched",
    "app_unclean_shutdown_detected",
    "app_session_stall_detected",
    "onboarding_shown",
    "onboarding_completed",
    "onboarding_agent_cta_clicked",
    "onboarding_first_dictation_started",
    "onboarding_first_dictation_saved",
    "dictation_started",
    "dictation_start_failed",
    "dictation_completed",
    "dictation_cancelled",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_recording_stopped",
    "meeting_recording_cancelled",
    "meeting_file_imported",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "meeting_capture_health_snapshot",
    "meeting_prompt_shown",
    "meeting_prompt_dismissed",
    "meeting_prompt_record_selected",
    "meeting_prompt_suppressed",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "agent_capture_query_observed",
    "update_action_clicked",
    "update_setting_changed",
    "update_check_finished",
    "update_download_started",
    "update_download_finished",
    "update_ready_to_install",
    "update_relaunching",
    "update_installed",
)

WORKFLOW_EVENTS = (
    "app_launched",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_file_imported",
    "meeting_transcript_saved",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
)

DISALLOWED_OUTPUT_FRAGMENTS = {
    "distinct_id",
    "person",
    "email",
    "name",
    "path",
    "title",
    "transcript",
    "audio",
    "url",
}


class DashboardError(RuntimeError):
    pass


@dataclass(frozen=True)
class DashboardSummary:
    name: str
    status: str
    summary: str
    metrics: dict[str, Any]
    next_action: str


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


def normalize_host(raw: str) -> str:
    host = raw.strip().rstrip("/")
    if host == "https://us.i.posthog.com":
        return "https://us.posthog.com"
    if host == "https://eu.i.posthog.com":
        return "https://eu.posthog.com"
    return host


def posthog_config() -> tuple[str, str, str] | None:
    load_env()
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    if not token or not project_id:
        return None

    host = normalize_host(
        os.environ.get("POSTHOG_APP_HOST")
        or os.environ.get("POSTHOG_HOST")
        or "https://us.posthog.com"
    )
    if not host.startswith("https://"):
        raise DashboardError(f"PostHog host must use HTTPS: {host}")
    if host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1":
        raise DashboardError(
            f"PostHog host is not trusted: {host}; set POSTHOG_ALLOW_UNTRUSTED_HOST=1 only for trusted self-hosted PostHog"
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
        raise DashboardError(f"PostHog query failed with HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise DashboardError(f"PostHog query failed: {exc}") from exc


def rows_as_dicts(response: dict[str, Any]) -> list[dict[str, Any]]:
    columns = [str(column) for column in response.get("columns") or []]
    unsafe = [
        column
        for column in columns
        if any(fragment in column.lower() for fragment in DISALLOWED_OUTPUT_FRAGMENTS)
    ]
    if unsafe:
        raise DashboardError(f"unsafe output columns requested: {', '.join(unsafe)}")

    rows = response.get("results") or response.get("data") or []
    return [
        {column: row[index] if index < len(row) else None for index, column in enumerate(columns)}
        for row in rows
    ]


def dashboard_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event IN ({sql_list(WORKFLOW_EVENTS)})) AS active_workflow_devices,
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  countIf(event = 'app_launched') AS launches,
  uniqIf(distinct_id, event = 'onboarding_completed') AS onboarding_completed_devices,
  uniqIf(distinct_id, event IN ('activation_first_artifact_saved', 'onboarding_first_dictation_saved', 'meeting_transcript_saved')) AS saved_artifact_devices,
  uniqIf(distinct_id, event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')) AS agent_bridge_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS true_agent_query_devices,
  countIf(event IN ('app_unclean_shutdown_detected', 'app_session_stall_detected', 'dictation_start_failed', 'dictation_no_speech', 'dictation_audio_route_recovery_timeout', 'meeting_recording_start_failed', 'meeting_transcript_failed', 'meeting_transcript_skipped')) AS reliability_events,
  countIf(event IN ('dictation_started', 'meeting_recording_started', 'meeting_file_imported')) AS core_start_events,
  countIf(event IN ('dictation_completed', 'meeting_transcript_saved')) AS core_success_events,
  countIf(event = 'meeting_capture_health_snapshot') AS meeting_health_snapshots,
  uniqIf(distinct_id, event = 'dictation_started') AS dictation_devices,
  uniqIf(distinct_id, event IN ('meeting_recording_started', 'meeting_file_imported', 'meeting_transcript_saved')) AS meeting_devices,
  uniqIf(distinct_id, event IN ('meeting_prompt_shown', 'meeting_prompt_record_selected')) AS meeting_prompt_devices,
  countIf(event = 'meeting_prompt_record_selected') AS meeting_prompt_record_events,
  countIf(event = 'meeting_prompt_suppressed') AS meeting_prompt_suppressed_events,
  countIf(event IN ('update_check_finished', 'update_download_started', 'update_download_finished', 'update_ready_to_install', 'update_relaunching', 'update_installed')) AS update_events,
  countIf(event = 'update_installed') AS update_installed_events
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(DASHBOARD_EVENTS)})
  {app_version_filter(app_version)}
"""


def daily_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT toDate(timestamp) AS day, uniq(distinct_id) AS active_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(WORKFLOW_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY day
ORDER BY day ASC
"""


def version_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  coalesce(toString(properties['app_version']), 'unknown') AS app_version,
  uniq(distinct_id) AS active_devices,
  countIf(event = 'app_launched') AS launches,
  countIf(event = 'update_installed') AS update_installs,
  countIf(event IN ('dictation_completed', 'meeting_transcript_saved')) AS first_value_success_events
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(DASHBOARD_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY app_version
ORDER BY active_devices DESC, launches DESC
LIMIT 8
"""


def event_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT event, count() AS events, uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(DASHBOARD_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY event
ORDER BY events DESC, event ASC
"""


def as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def pct(numerator: int, denominator: int) -> str:
    if denominator <= 0:
        return "n/a"
    return f"{(numerator / denominator) * 100:.1f}%"


def status_from_ratio(numerator: int, denominator: int, *, warn_under: float, green_at: float) -> str:
    if denominator <= 0:
        return "UNKNOWN"
    ratio = numerator / denominator
    if ratio >= green_at:
        return "GREEN"
    if ratio < warn_under:
        return "YELLOW"
    return "BRIEF"


def build_summaries(data: dict[str, Any]) -> list[DashboardSummary]:
    row = (data["results"].get("dashboard") or [{}])[0]
    daily = data["results"].get("daily_active") or []
    versions = data["results"].get("versions") or []

    active = as_int(row.get("active_workflow_devices"))
    launch = as_int(row.get("launch_devices"))
    saved_artifact = as_int(row.get("saved_artifact_devices"))
    agent_bridge = as_int(row.get("agent_bridge_devices"))
    return_proxy = as_int(row.get("return_proxy_devices"))
    true_agent = as_int(row.get("true_agent_query_devices"))
    reliability_events = as_int(row.get("reliability_events"))
    core_starts = as_int(row.get("core_start_events"))
    core_success = as_int(row.get("core_success_events"))
    dictation_devices = as_int(row.get("dictation_devices"))
    meeting_devices = as_int(row.get("meeting_devices"))
    prompt_devices = as_int(row.get("meeting_prompt_devices"))
    latest_version = versions[0].get("app_version") if versions else "unknown"
    latest_version_devices = as_int(versions[0].get("active_devices")) if versions else 0

    return [
        DashboardSummary(
            name="100 WAU Operating",
            status="GREEN" if active >= 100 else ("YELLOW" if active > 0 else "UNKNOWN"),
            summary=f"{active}/100 weekly active workflow devices; launches={as_int(row.get('launches'))}, daily points={len(daily)}.",
            metrics={
                "active_workflow_devices": active,
                "weekly_target": 100,
                "launch_devices": launch,
                "daily_active_devices": daily,
            },
            next_action="If below 100 WAU, focus the brief on first-value and return-loop fixes, not broad launch.",
        ),
        DashboardSummary(
            name="Activation",
            status=status_from_ratio(saved_artifact, launch, warn_under=0.15, green_at=0.4),
            summary=(
                f"saved_artifact={saved_artifact} ({pct(saved_artifact, launch)} of launch), "
                f"agent_bridge={agent_bridge}, return_proxy={return_proxy}, true_agent_query={true_agent}."
            ),
            metrics={
                "launch_devices": launch,
                "onboarding_completed_devices": as_int(row.get("onboarding_completed_devices")),
                "saved_artifact_devices": saved_artifact,
                "agent_bridge_devices": agent_bridge,
                "return_proxy_devices": return_proxy,
                "true_agent_query_devices": true_agent,
            },
            next_action="Treat true agent-query proof as UNKNOWN until `agent_capture_query_observed` exists in live data.",
        ),
        DashboardSummary(
            name="Reliability",
            status="GREEN" if reliability_events == 0 and core_starts > 0 else ("YELLOW" if reliability_events else "UNKNOWN"),
            summary=f"reliability_events={reliability_events}; core_success={core_success}/{core_starts}; meeting_health_snapshots={as_int(row.get('meeting_health_snapshots'))}.",
            metrics={
                "reliability_events": reliability_events,
                "core_start_events": core_starts,
                "core_success_events": core_success,
                "meeting_health_snapshots": as_int(row.get("meeting_health_snapshots")),
            },
            next_action="If reliability events are non-zero, size them before product-growth recommendations.",
        ),
        DashboardSummary(
            name="Feature Adoption",
            status="GREEN" if dictation_devices and meeting_devices else ("BRIEF" if dictation_devices or meeting_devices else "UNKNOWN"),
            summary=(
                f"dictation_devices={dictation_devices}, meeting_devices={meeting_devices}, "
                f"meeting_prompt_devices={prompt_devices}, prompt_record_events={as_int(row.get('meeting_prompt_record_events'))}."
            ),
            metrics={
                "dictation_devices": dictation_devices,
                "meeting_devices": meeting_devices,
                "meeting_prompt_devices": prompt_devices,
                "meeting_prompt_record_events": as_int(row.get("meeting_prompt_record_events")),
                "meeting_prompt_suppressed_events": as_int(row.get("meeting_prompt_suppressed_events")),
            },
            next_action="Use this to decide whether dictation, meetings, or prompt routing deserves the next product pass.",
        ),
        DashboardSummary(
            name="Release Health",
            status="GREEN" if latest_version_devices > 0 and reliability_events == 0 else ("YELLOW" if latest_version_devices > 0 else "UNKNOWN"),
            summary=f"top_version={latest_version} on {latest_version_devices} active devices; update_events={as_int(row.get('update_events'))}, installs={as_int(row.get('update_installed_events'))}.",
            metrics={
                "top_versions": versions,
                "update_events": as_int(row.get("update_events")),
                "update_installed_events": as_int(row.get("update_installed_events")),
            },
            next_action="If a release just shipped, filter this helper with `--app-version` and compare against Sentry release issues.",
        ),
    ]


def unknown_payload(days: int, app_version: str | None, missing: list[str]) -> dict[str, Any]:
    generated_at = datetime.now(timezone.utc).isoformat()
    summaries = [
        DashboardSummary(
            name=name,
            status="UNKNOWN",
            summary=f"Missing prerequisite: {', '.join(missing)}.",
            metrics={},
            next_action="Set PostHog read credentials and rerun.",
        )
        for name in ("100 WAU Operating", "Activation", "Reliability", "Feature Adoption", "Release Health")
    ]
    return {
        "generated_at": generated_at,
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "privacy": "aggregate counts only; no raw rows, people rows, transcript text, recording references, titles, paths, URLs, or identities",
            "status": "unknown",
            "missing_prerequisites": missing,
        },
        "sections": [summary.__dict__ for summary in summaries],
        "results": {},
    }


def fetch_payload(days: int, app_version: str | None) -> dict[str, Any]:
    config = posthog_config()
    missing = [
        name
        for name in ("POSTHOG_PERSONAL_API_KEY", "POSTHOG_PROJECT_ID")
        if not os.environ.get(name)
    ]
    if config is None:
        return unknown_payload(days, app_version, missing)

    host, project_id, token = config
    queries = {
        "dashboard": dashboard_query(days, app_version),
        "daily_active": daily_query(days, app_version),
        "versions": version_query(days, app_version),
        "event_counts": event_query(days, app_version),
    }
    results = {
        name: rows_as_dicts(run_hogql(host, project_id, token, query))
        for name, query in queries.items()
    }
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "project": "configured PostHog project",
            "privacy": "aggregate counts only; no raw rows, people rows, transcript text, recording references, titles, paths, URLs, or identities",
            "status": "ok",
        },
        "results": results,
    }
    payload["sections"] = [summary.__dict__ for summary in build_summaries(payload)]
    return payload


def render_markdown(payload: dict[str, Any]) -> str:
    app_version = payload.get("app_version") or "all app versions"
    lines = [
        "# Transcripted PostHog Product-Learning Summary",
        "",
        f"Window: last {payload['window_days']} days, {app_version}",
        f"Source: {payload['source']['status']} PostHog aggregate HogQL. Privacy: {payload['source']['privacy']}.",
        "",
        "## Dashboard Sections",
        "",
    ]
    for section in payload["sections"]:
        lines.append(f"- {section['name']}: {section['status']} | {section['summary']} Next: {section['next_action']}")
    lines.extend(
        [
            "",
            "## Health Brief Snippet",
            "",
            "Product usage",
        ]
    )
    for section in payload["sections"]:
        lines.append(f"- {section['name']}: {section['status']} - {section['summary']}")
    return "\n".join(lines) + "\n"


def write_outputs(payload: dict[str, Any], report: str, write_dir: Path | None) -> tuple[Path, Path] | None:
    if write_dir is None:
        return None
    write_dir.mkdir(parents=True, exist_ok=True)
    report_path = write_dir / "posthog-product-dashboard-summary.md"
    data_path = write_dir / "posthog-product-dashboard-summary.json"
    report_path.write_text(report, encoding="utf-8")
    data_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return report_path, data_path


def run_self_test() -> int:
    payload = unknown_payload(7, None, ["POSTHOG_PERSONAL_API_KEY", "POSTHOG_PROJECT_ID"])
    report = render_markdown(payload)
    required = ("100 WAU Operating", "Activation", "Reliability", "Feature Adoption", "Release Health", "UNKNOWN")
    missing = [item for item in required if item not in report]
    if missing:
        print(f"self-test failed: missing {', '.join(missing)}", file=sys.stderr)
        return 1
    forbidden = ("distinct_id", "meeting_title", "transcript_text", "audio_path", "raw_url", "email")
    lowered = report.lower()
    leaked = [item for item in forbidden if item in lowered]
    if leaked:
        print(f"self-test failed: unsafe output fragment {', '.join(leaked)}", file=sys.stderr)
        return 1
    queries = (dashboard_query(7, None), daily_query(7, None), version_query(7, None), event_query(7, None))
    if any("SELECT *" in query.upper() for query in queries):
        print("self-test failed: query uses SELECT *", file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=7, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version filter, e.g. 1.1.48.")
    parser.add_argument("--write-dir", type=Path, help="Optional output directory for Markdown and JSON.")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of Markdown.")
    parser.add_argument("--self-test", action="store_true", help="Run offline rendering/privacy checks.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.days <= 0:
        print("ERROR: --days must be positive", file=sys.stderr)
        return 2

    try:
        payload = fetch_payload(args.days, args.app_version)
        report = render_markdown(payload)
        paths = write_outputs(payload, report, args.write_dir)
    except DashboardError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(report, end="")
        if paths:
            print(f"Report written: {paths[0]}")
            print(f"Data written: {paths[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
