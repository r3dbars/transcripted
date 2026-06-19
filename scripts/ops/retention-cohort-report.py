#!/usr/bin/env python3
"""Print a privacy-safe Transcripted retention cohort report from PostHog."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


TRUSTED_POSTHOG_HOSTS = {
    "https://app.posthog.com",
    "https://eu.posthog.com",
    "https://posthog.com",
    "https://us.posthog.com",
}

RETENTION_EVENTS = (
    "app_launched",
    "dictation_completed",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
)

ARTIFACT_EVENTS = (
    "dictation_completed",
    "meeting_transcript_saved",
)


def load_env() -> None:
    for path in (
        Path.cwd() / ".env.local",
        Path.cwd() / ".env",
        Path.home() / ".transcripted-ops.env",
        Path.home() / ".hermes" / ".env",
        Path.home() / ".hermes" / "profiles" / "ops" / ".env",
    ):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
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


def posthog_host_error(host: str) -> str | None:
    if not host.startswith("https://"):
        return "PostHog host must use HTTPS"
    if host in TRUSTED_POSTHOG_HOSTS or os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") == "1":
        return None
    return f"untrusted PostHog host: {host}"


def event_list(events: tuple[str, ...]) -> str:
    return ", ".join("'" + event.replace("'", "\\'") + "'" for event in events)


def posthog_query(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
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
            "User-Agent": "TranscriptedRetentionCohortReport/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def rows_from(payload: dict[str, Any]) -> list[list[Any]]:
    rows = payload.get("results") or payload.get("data") or []
    return [row for row in rows if isinstance(row, list)]


def first_row(payload: dict[str, Any]) -> list[Any]:
    rows = rows_from(payload)
    return rows[0] if rows else []


def number(row: list[Any], index: int, default: int | float = 0) -> int | float:
    if index >= len(row) or row[index] is None:
        return default
    value = row[index]
    if isinstance(value, (int, float)):
        return value
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    if parsed.is_integer():
        return int(parsed)
    return parsed


def pct(numerator: int | float, denominator: int | float) -> str:
    if not denominator:
        return "n/a"
    return f"{(float(numerator) / float(denominator) * 100):.1f}%"


def build_queries(days: int, first_seen_lookback_days: int) -> dict[str, str]:
    retention_events = event_list(RETENTION_EVENTS)
    artifact_events = event_list(ARTIFACT_EVENTS)
    first_run_events = event_list(RETENTION_EVENTS + ("onboarding_completed",))

    summary = f"""
WITH device_rollup AS (
  SELECT
    distinct_id,
    uniq(toDate(timestamp)) AS active_days,
    countIf(event = 'app_launched') AS launches,
    countIf(event = 'dictation_completed') AS dictation_completed,
    countIf(event = 'meeting_transcript_saved') AS meeting_saved,
    countIf(event IN ({artifact_events})) AS artifact_events,
    countIf(event = 'activation_return_proxy_observed') AS return_proxy_events,
    countIf(event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked')) AS agent_action_events,
    countIf(event = 'activation_artifact_action_clicked') AS artifact_action_events,
    min(timestamp) AS first_seen,
    max(timestamp) AS last_seen
  FROM events
  WHERE timestamp >= now() - INTERVAL {days} DAY
    AND event IN ({retention_events})
  GROUP BY distinct_id
)
SELECT
  count() AS devices,
  round(avg(active_days), 2) AS avg_active_days,
  quantile(0.5)(active_days) AS p50_active_days,
  max(active_days) AS max_active_days,
  countIf(active_days = 1) AS one_day_devices,
  countIf(active_days BETWEEN 2 AND 3) AS two_three_day_devices,
  countIf(active_days >= 4) AS four_plus_day_devices,
  countIf(dictation_completed > 0) AS dictation_devices,
  countIf(dictation_completed >= 2) AS repeat_dictation_devices,
  sum(dictation_completed) AS dictation_events,
  countIf(meeting_saved > 0) AS meeting_devices,
  countIf(meeting_saved >= 2) AS repeat_meeting_devices,
  sum(meeting_saved) AS meeting_events,
  countIf(artifact_events > 0) AS artifact_devices,
  countIf(artifact_events >= 2) AS repeat_artifact_devices,
  countIf(return_proxy_events > 0) AS return_proxy_devices,
  sum(return_proxy_events) AS return_proxy_events,
  countIf(agent_action_events > 0) AS agent_action_devices,
  sum(agent_action_events) AS agent_action_events,
  countIf(artifact_action_events > 0) AS artifact_action_devices
FROM device_rollup
LIMIT 100
""".strip()

    latest_versions = f"""
WITH device_latest AS (
  SELECT
    distinct_id,
    argMax(if(empty(toString(properties['app_version'])), 'unknown', toString(properties['app_version'])), timestamp) AS latest_app_version,
    max(timestamp) AS last_seen
  FROM events
  WHERE timestamp >= now() - INTERVAL {days} DAY
    AND event IN ({retention_events})
  GROUP BY distinct_id
)
SELECT
  latest_app_version AS app_version,
  count() AS devices,
  min(last_seen) AS oldest_last_seen,
  max(last_seen) AS newest_last_seen
FROM device_latest
GROUP BY app_version
ORDER BY devices DESC, app_version DESC
LIMIT 100
""".strip()

    first_artifact = f"""
WITH first_artifacts AS (
  SELECT
    distinct_id,
    min(timestamp) AS first_artifact_at,
    argMin(event, timestamp) AS first_artifact_event
  FROM events
  WHERE timestamp >= now() - INTERVAL {first_seen_lookback_days} DAY
    AND event IN ({artifact_events})
  GROUP BY distinct_id
  HAVING first_artifact_at >= now() - INTERVAL {days} DAY
),
post_artifact AS (
  SELECT
    fa.distinct_id AS distinct_id,
    fa.first_artifact_at AS first_artifact_at,
    fa.first_artifact_event AS first_artifact_event,
    countIf(e.timestamp > fa.first_artifact_at + INTERVAL 18 HOUR) AS post_18h_7d_events,
    countIf(e.event = 'activation_return_proxy_observed') AS return_proxy_events,
    countIf(e.event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked')) AS agent_action_events,
    countIf(e.event IN ({artifact_events})) AS second_artifact_events
  FROM first_artifacts AS fa
  LEFT JOIN events AS e ON e.distinct_id = fa.distinct_id
    AND e.timestamp > fa.first_artifact_at
    AND e.timestamp <= fa.first_artifact_at + INTERVAL 7 DAY
    AND e.event IN ({retention_events})
  GROUP BY fa.distinct_id, fa.first_artifact_at, fa.first_artifact_event
)
SELECT
  count() AS first_artifact_devices,
  countIf(first_artifact_event = 'dictation_completed') AS first_dictation_devices,
  countIf(first_artifact_event = 'meeting_transcript_saved') AS first_meeting_devices,
  countIf(first_artifact_at <= now() - INTERVAL 18 HOUR) AS mature_18h_devices,
  countIf(first_artifact_at <= now() - INTERVAL 18 HOUR AND post_18h_7d_events > 0) AS returned_18h_7d_devices,
  countIf(return_proxy_events > 0) AS return_proxy_devices,
  sum(return_proxy_events) AS return_proxy_events,
  countIf(second_artifact_events > 0) AS second_artifact_devices,
  sum(second_artifact_events) AS second_artifact_events,
  countIf(agent_action_events > 0) AS agent_action_devices,
  sum(agent_action_events) AS agent_action_events
FROM post_artifact
LIMIT 100
""".strip()

    first_run = f"""
WITH first_runs AS (
  SELECT
    distinct_id,
    min(timestamp) AS first_launch_at,
    argMin(if(empty(toString(properties['app_version'])), 'unknown', toString(properties['app_version'])), timestamp) AS first_app_version
  FROM events
  WHERE timestamp >= now() - INTERVAL {first_seen_lookback_days} DAY
    AND event = 'app_launched'
  GROUP BY distinct_id
  HAVING first_launch_at >= now() - INTERVAL {days} DAY
),
first_run_outcomes AS (
  SELECT
    fr.distinct_id AS distinct_id,
    fr.first_launch_at AS first_launch_at,
    fr.first_app_version AS first_app_version,
    uniq(toDate(e.timestamp)) AS active_days_7d,
    countIf(e.event IN ({artifact_events})
      AND e.timestamp <= fr.first_launch_at + INTERVAL 24 HOUR) AS artifact_events_24h,
    countIf(e.event IN ({artifact_events})) AS artifact_events_7d,
    countIf(e.event IN ({retention_events})
      AND e.timestamp > fr.first_launch_at + INTERVAL 18 HOUR) AS returned_18h_7d_events,
    countIf(e.event = 'onboarding_completed') AS onboarding_completed_7d
  FROM first_runs AS fr
  LEFT JOIN events AS e ON e.distinct_id = fr.distinct_id
    AND e.timestamp >= fr.first_launch_at
    AND e.timestamp <= fr.first_launch_at + INTERVAL 7 DAY
    AND e.event IN ({first_run_events})
  GROUP BY fr.distinct_id, fr.first_launch_at, fr.first_app_version
)
SELECT
  count() AS first_run_devices,
  countIf(first_launch_at <= now() - INTERVAL 24 HOUR) AS mature_24h_devices,
  countIf(first_launch_at <= now() - INTERVAL 7 DAY) AS mature_7d_devices,
  countIf(first_launch_at <= now() - INTERVAL 24 HOUR AND artifact_events_24h > 0) AS artifact_within_24h_devices,
  countIf(first_launch_at <= now() - INTERVAL 7 DAY AND artifact_events_7d > 0) AS artifact_within_7d_devices,
  countIf(first_launch_at <= now() - INTERVAL 7 DAY AND returned_18h_7d_events > 0) AS returned_18h_7d_devices,
  countIf(first_launch_at <= now() - INTERVAL 7 DAY AND active_days_7d = 1 AND artifact_events_7d = 0) AS one_day_no_artifact_7d_devices,
  countIf(onboarding_completed_7d > 0) AS onboarding_completed_7d_devices
FROM first_run_outcomes
LIMIT 100
""".strip()

    return {
        "summary": summary,
        "latest_versions": latest_versions,
        "first_artifact": first_artifact,
        "first_run": first_run,
    }


def run_report(days: int, first_seen_lookback_days: int) -> dict[str, Any]:
    load_env()
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    if not token or not project_id:
        missing = [
            name
            for name, value in (
                ("POSTHOG_PERSONAL_API_KEY", token),
                ("POSTHOG_PROJECT_ID", project_id),
            )
            if not value
        ]
        return {"available": False, "error": "missing " + ", ".join(missing)}

    host = normalize_posthog_host(os.environ.get("POSTHOG_APP_HOST") or os.environ.get("POSTHOG_HOST") or "https://us.posthog.com")
    if error := posthog_host_error(host):
        return {"available": False, "error": error}

    queries = build_queries(days, first_seen_lookback_days)
    payloads: dict[str, dict[str, Any]] = {}
    for name, query in queries.items():
        try:
            payloads[name] = posthog_query(host, project_id, token, query)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            return {"available": False, "error": f"PostHog query failed for {name}: {exc}"}

    return {
        "available": True,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "days": days,
        "first_seen_lookback_days": first_seen_lookback_days,
        "source": {
            "kind": "posthog_hogql",
            "host": host,
            "privacy": "aggregate counts only; no raw distinct_id, person rows, transcript text, audio, titles, names, paths, emails, tokens, or URLs",
        },
        "queries": queries,
        "rows": {name: rows_from(payload) for name, payload in payloads.items()},
    }


def most_common_latest_version(rows: list[list[Any]]) -> tuple[str, int]:
    if not rows:
        return ("unknown", 0)
    row = rows[0]
    return (str(row[0]), int(number(row, 1)))


def render_markdown(report: dict[str, Any]) -> str:
    if not report.get("available"):
        return "\n".join(
            [
                "# Transcripted Retention Cohort Report",
                "",
                f"Unavailable: {report.get('error', 'unknown error')}",
                "",
                "Set POSTHOG_PERSONAL_API_KEY and POSTHOG_PROJECT_ID, then rerun this script.",
            ]
        )

    days = report["days"]
    rows = report["rows"]
    summary = first_row({"results": rows.get("summary", [])})
    first_artifact = first_row({"results": rows.get("first_artifact", [])})
    first_run = first_row({"results": rows.get("first_run", [])})
    versions = rows.get("latest_versions", [])

    devices = int(number(summary, 0))
    avg_active_days = number(summary, 1)
    p50_active_days = number(summary, 2)
    one_day_devices = int(number(summary, 4))
    four_plus_day_devices = int(number(summary, 6))
    dictation_devices = int(number(summary, 7))
    repeat_dictation_devices = int(number(summary, 8))
    dictation_events = int(number(summary, 9))
    meeting_devices = int(number(summary, 10))
    repeat_meeting_devices = int(number(summary, 11))
    meeting_events = int(number(summary, 12))
    artifact_devices = int(number(summary, 13))
    repeat_artifact_devices = int(number(summary, 14))
    return_proxy_devices = int(number(summary, 15))
    return_proxy_events = int(number(summary, 16))
    agent_action_devices = int(number(summary, 17))
    agent_action_events = int(number(summary, 18))
    artifact_action_devices = int(number(summary, 19))

    first_artifact_devices = int(number(first_artifact, 0))
    mature_artifact_devices = int(number(first_artifact, 3))
    returned_after_artifact_devices = int(number(first_artifact, 4))
    second_artifact_devices = int(number(first_artifact, 7))
    post_artifact_agent_action_devices = int(number(first_artifact, 9))

    first_run_devices = int(number(first_run, 0))
    mature_24h_devices = int(number(first_run, 1))
    mature_7d_devices = int(number(first_run, 2))
    artifact_24h_devices = int(number(first_run, 3))
    artifact_7d_devices = int(number(first_run, 4))
    returned_7d_devices = int(number(first_run, 5))
    one_day_no_artifact_devices = int(number(first_run, 6))
    onboarding_completed_devices = int(number(first_run, 7))

    common_version, common_version_devices = most_common_latest_version(versions)
    version_share = pct(common_version_devices, devices)

    lines = [
        "# Transcripted Retention Cohort Report",
        "",
        f"- Generated: {report['generated_at']}",
        f"- Window: last {days} days",
        f"- Source: PostHog HogQL aggregate queries only",
        f"- Privacy: {report['source']['privacy']}",
        "",
        "## Retention Signals",
        "",
        f"- Active devices: {devices}; average active days {avg_active_days}; median active days {p50_active_days}; one-day devices {one_day_devices} ({pct(one_day_devices, devices)}); 4+ day devices {four_plus_day_devices} ({pct(four_plus_day_devices, devices)}).",
        f"- Repeat dictation: {repeat_dictation_devices}/{dictation_devices} dictation devices repeated ({pct(repeat_dictation_devices, dictation_devices)}); {dictation_events} dictation completions.",
        f"- Repeat meetings: {repeat_meeting_devices}/{meeting_devices} meeting devices repeated ({pct(repeat_meeting_devices, meeting_devices)}); {meeting_events} meeting transcript saves.",
        f"- Artifact depth: {artifact_devices} devices saved an artifact; {repeat_artifact_devices} repeated ({pct(repeat_artifact_devices, artifact_devices)}).",
        f"- Return proxy: {return_proxy_devices} devices had {return_proxy_events} Home return-proxy events after an older saved artifact; {agent_action_devices} devices had {agent_action_events} agent prompt/setup actions; {artifact_action_devices} devices clicked an artifact action.",
        f"- Version adoption: most common latest-observed version is {common_version} on {common_version_devices}/{devices} active devices ({version_share}).",
        "",
        "## First Artifact Cohort",
        "",
        f"- First-artifact devices: {first_artifact_devices}; mature 18h cohort: {mature_artifact_devices}.",
        f"- Returned 18h-7d after first artifact: {returned_after_artifact_devices}/{mature_artifact_devices} ({pct(returned_after_artifact_devices, mature_artifact_devices)}).",
        f"- Saved another artifact within 7d after first artifact: {second_artifact_devices}/{first_artifact_devices} ({pct(second_artifact_devices, first_artifact_devices)}).",
        f"- Agent prompt/setup action within 7d after first artifact: {post_artifact_agent_action_devices}/{first_artifact_devices} ({pct(post_artifact_agent_action_devices, first_artifact_devices)}).",
        "",
        "## First Run Drop-Off",
        "",
        f"- First-run devices: {first_run_devices}; mature 24h devices: {mature_24h_devices}; mature 7d devices: {mature_7d_devices}.",
        f"- Saved an artifact within 24h: {artifact_24h_devices}/{mature_24h_devices} ({pct(artifact_24h_devices, mature_24h_devices)}).",
        f"- Saved an artifact within 7d: {artifact_7d_devices}/{mature_7d_devices} ({pct(artifact_7d_devices, mature_7d_devices)}).",
        f"- Returned 18h-7d after first run: {returned_7d_devices}/{mature_7d_devices} ({pct(returned_7d_devices, mature_7d_devices)}).",
        f"- One-day/no-artifact drop-off: {one_day_no_artifact_devices}/{mature_7d_devices} ({pct(one_day_no_artifact_devices, mature_7d_devices)}).",
        f"- Onboarding completed within 7d: {onboarding_completed_devices}/{first_run_devices} ({pct(onboarding_completed_devices, first_run_devices)}).",
        "",
        "## Blind Spots",
        "",
        "- Return proxy means Home observed a prior saved artifact after 18h+. It is not proof of a sourced agent answer.",
        "- Agent prompt/setup actions measure in-app copy/open/setup clicks. External agent reads are not measured.",
        f"- First-artifact and first-run cohorts use first observed events in the last {report['first_seen_lookback_days']} days, so older telemetry gaps can misclassify returning devices as new.",
        "- Counts are anonymous-device aggregates. Do not join them to transcript text, file paths, titles, names, emails, tokens, raw URLs, or person records.",
    ]
    return "\n".join(lines)


def run_self_test() -> None:
    queries = build_queries(days=30, first_seen_lookback_days=180)
    assert set(queries) == {"summary", "latest_versions", "first_artifact", "first_run"}
    for name, query in queries.items():
        assert "LIMIT 100" in query, f"{name} query must keep PostHog result bounded"
        assert "SELECT properties" not in query, f"{name} query must not select full properties"
        assert "person" not in query.lower(), f"{name} query must not use person tables"
    fixture = {
        "available": True,
        "generated_at": "2026-06-19T00:00:00+00:00",
        "days": 30,
        "first_seen_lookback_days": 180,
        "source": {
            "privacy": "aggregate counts only",
        },
        "rows": {
            "summary": [[187, 2.73, 1.0, 31, 147, 13, 27, 26, 14, 2954, 35, 33, 912, 43, 37, 17, 41, 24, 70, 16]],
            "latest_versions": [["1.1.48", 138, "2026-06-13T12:25:13Z", "2026-06-19T00:36:52Z"]],
            "first_artifact": [[17, 9, 8, 15, 7, 5, 10, 11, 56, 2, 3]],
            "first_run": [[157, 147, 31, 12, 11, 6, 18, 12]],
        },
    }
    rendered = render_markdown(fixture)
    assert "Transcripted Retention Cohort Report" in rendered
    assert "Repeat dictation" in rendered
    assert "One-day/no-artifact drop-off" in rendered
    print("retention-cohort-report self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="Recent retention window in days.")
    parser.add_argument(
        "--first-seen-lookback-days",
        type=int,
        default=180,
        help="Lookback used to decide whether a device's first app_launched event is recent.",
    )
    parser.add_argument("--write-json", type=Path, default=None, help="Optional path for the raw aggregate JSON report.")
    parser.add_argument("--self-test", action="store_true", help="Run offline assertions and exit.")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        return 0
    if args.days < 1:
        print("ERROR: --days must be positive", file=sys.stderr)
        return 2
    if args.first_seen_lookback_days < args.days:
        print("ERROR: --first-seen-lookback-days must be at least --days", file=sys.stderr)
        return 2

    report = run_report(args.days, args.first_seen_lookback_days)
    if args.write_json:
        args.write_json.parent.mkdir(parents=True, exist_ok=True)
        args.write_json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(render_markdown(report))
    return 0 if report.get("available") else 3


if __name__ == "__main__":
    raise SystemExit(main())
