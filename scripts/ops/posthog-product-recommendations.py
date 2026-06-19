#!/usr/bin/env python3
"""Turn aggregate Transcripted PostHog signals into ranked product tasks."""

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
    "app_unclean_shutdown_detected",
    "app_session_stall_detected",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_completed",
    "onboarding_dismissed",
    "onboarding_first_dictation_empty",
    "dictation_started",
    "dictation_start_failed",
    "dictation_completed",
    "dictation_stop_latency_measured",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_recording_stopped",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "agent_capture_query_observed",
    "meeting_summary_requested",
    "meeting_summary_finished",
    "update_check_finished",
    "update_download_finished",
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


class RecommendationReportError(RuntimeError):
    pass


@dataclass(frozen=True)
class Recommendation:
    rank: int
    priority: str
    score: int
    title: str
    product_task: str
    trigger: str
    evidence: str
    owner_lane: str
    pr_thread_prompt: str
    confidence: str


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
        raise RecommendationReportError("missing " + ", ".join(missing))
    if not host.startswith("https://"):
        raise RecommendationReportError(f"refusing non-HTTPS PostHog host: {host}")
    if host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1":
        raise RecommendationReportError(
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


def release_version_filter(app_version: str | None) -> str:
    if not app_version:
        return ""
    version = sql_quote(app_version)
    return f"""
AND (
  (event IN ('app_unclean_shutdown_detected', 'app_session_stall_detected') AND properties['app_version'] = {version})
  OR (event IN ('update_check_finished', 'update_download_finished') AND properties['version'] = {version})
)
"""


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
        raise RecommendationReportError(f"PostHog query failed with HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RecommendationReportError(f"PostHog query failed: {exc}") from exc


def rows_as_dicts(response: dict[str, Any]) -> list[dict[str, Any]]:
    columns = response.get("columns") or []
    rows = response.get("results") or response.get("data") or []
    unsafe = [
        str(column)
        for column in columns
        if any(fragment in str(column).lower() for fragment in DISALLOWED_OUTPUT_COLUMNS)
    ]
    if unsafe:
        raise RecommendationReportError(f"query attempted to expose unsafe output columns: {', '.join(unsafe)}")
    return [
        {str(column): row[index] if index < len(row) else None for index, column in enumerate(columns)}
        for row in rows
    ]


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


def overview_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  uniqIf(distinct_id, event IN ('onboarding_shown', 'onboarding_step_viewed')) AS onboarding_touched_devices,
  uniqIf(distinct_id, event IN ('onboarding_dismissed', 'onboarding_first_dictation_empty')) AS onboarding_exit_devices,
  uniqIf(distinct_id, event = 'onboarding_completed') AS onboarding_completed_devices,
  uniqIf(distinct_id, event = 'dictation_started') AS dictation_started_devices,
  uniqIf(distinct_id, event = 'dictation_completed') AS dictation_completed_devices,
  uniqIf(distinct_id, event IN ('dictation_start_failed', 'dictation_no_speech', 'dictation_audio_route_recovery_timeout')) AS dictation_problem_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_saved') AS meeting_saved_devices,
  uniqIf(distinct_id, event IN ('meeting_transcript_failed', 'meeting_transcript_skipped')) AS meeting_failed_devices,
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked')) AS activation_bridge_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS agent_query_devices,
  uniqIf(distinct_id, event = 'meeting_summary_requested') AS summary_requested_devices,
  uniqIf(distinct_id, event = 'meeting_summary_finished') AS summary_finished_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(RELEVANT_EVENTS)})
  {app_version_filter(app_version)}
"""


def onboarding_exits_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['step_id'] AS step_id,
  properties['step_index'] AS step_index,
  properties['model_state'] AS model_state,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('onboarding_dismissed', 'onboarding_first_dictation_empty')
  {app_version_filter(app_version)}
GROUP BY step_id, step_index, model_state
ORDER BY devices DESC
LIMIT 30
"""


def dictation_outcomes_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['delivery'] AS delivery,
  properties['outcome'] AS outcome,
  properties['save_outcome'] AS save_outcome,
  properties['failure_kind'] AS failure_kind,
  properties['route_shape'] AS route_shape,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('dictation_started', 'dictation_start_failed', 'dictation_completed', 'dictation_stop_latency_measured', 'dictation_no_speech', 'dictation_audio_route_recovery_timeout')
  {app_version_filter(app_version)}
GROUP BY event, delivery, outcome, save_outcome, failure_kind, route_shape
ORDER BY events DESC
LIMIT 60
"""


def meeting_outcomes_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['failure_kind'] AS failure_kind,
  properties['capture_quality'] AS capture_quality,
  properties['system_status'] AS system_status,
  properties['queue_depth_bucket'] AS queue_depth_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_recording_started', 'meeting_recording_start_failed', 'meeting_recording_stopped', 'meeting_transcript_saved', 'meeting_transcript_failed', 'meeting_transcript_skipped')
  {app_version_filter(app_version)}
GROUP BY event, failure_kind, capture_quality, system_status, queue_depth_bucket
ORDER BY events DESC
LIMIT 60
"""


def activation_bridge_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['artifact_kind'] AS artifact_kind,
  properties['action_kind'] AS action_kind,
  properties['prompt_kind'] AS prompt_kind,
  properties['agent_target'] AS agent_target,
  properties['result'] AS result,
  properties['surface'] AS surface,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('activation_first_artifact_saved', 'activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'activation_return_proxy_observed', 'agent_capture_query_observed')
  {app_version_filter(app_version)}
GROUP BY event, artifact_kind, action_kind, prompt_kind, agent_target, result, surface
ORDER BY events DESC
LIMIT 80
"""


def summary_outcomes_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['model_state'] AS model_state,
  properties['result'] AS result,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_summary_requested', 'meeting_summary_finished')
  {app_version_filter(app_version)}
GROUP BY event, model_state, result, failure_kind
ORDER BY events DESC
LIMIT 40
"""


def release_health_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['app_version'] AS app_version,
  properties['version'] AS update_version,
  event,
  properties['result'] AS result,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('app_unclean_shutdown_detected', 'app_session_stall_detected', 'update_check_finished', 'update_download_finished')
  {release_version_filter(app_version)}
GROUP BY app_version, update_version, event, result, failure_kind
ORDER BY events DESC
LIMIT 80
"""


def release_failure_summary_query(days: int, app_version: str | None) -> str:
    failure_predicate = """
event IN ('app_unclean_shutdown_detected', 'app_session_stall_detected')
OR properties['result'] IN ('failed', 'failure')
OR (properties['failure_kind'] IS NOT NULL AND properties['failure_kind'] != '')
"""
    return f"""
SELECT
  uniqIf(distinct_id, {failure_predicate}) AS release_failure_devices,
  countIf({failure_predicate}) AS release_failure_events
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('app_unclean_shutdown_detected', 'app_session_stall_detected', 'update_check_finished', 'update_download_finished')
  {release_version_filter(app_version)}
"""


def fetch_report_data(days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()
    queries = {
        "overview": overview_query(days, app_version),
        "event_counts": event_counts_query(days, app_version),
        "onboarding_exits": onboarding_exits_query(days, app_version),
        "dictation_outcomes": dictation_outcomes_query(days, app_version),
        "meeting_outcomes": meeting_outcomes_query(days, app_version),
        "activation_bridge": activation_bridge_query(days, app_version),
        "summary_outcomes": summary_outcomes_query(days, app_version),
        "release_health": release_health_query(days, app_version),
        "release_failure_summary": release_failure_summary_query(days, app_version),
    }
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "project": "configured PostHog project",
            "privacy": "aggregate counts and enum buckets only; no IDs, people rows, transcript text, paths, titles, URLs, or raw payloads are written",
        },
        "results": {
            name: rows_as_dicts(run_hogql(host, project_id, token, query))
            for name, query in queries.items()
        },
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


def event_devices(data: dict[str, Any], event: str) -> int:
    return sum(
        as_int(row.get("devices"))
        for row in data.get("results", {}).get("event_counts", [])
        if row.get("event") == event
    )


def event_events(data: dict[str, Any], event: str) -> int:
    return sum(
        as_int(row.get("events"))
        for row in data.get("results", {}).get("event_counts", [])
        if row.get("event") == event
    )


def overview_value(data: dict[str, Any], key: str, fallback_event: str | None = None) -> int:
    overview = (data.get("results", {}).get("overview") or [{}])[0]
    if key in overview:
        return as_int(overview.get(key))
    if fallback_event:
        return event_devices(data, fallback_event)
    return 0


def sum_rows(rows: list[dict[str, Any]], events: set[str]) -> int:
    return sum(as_int(row.get("devices")) for row in rows if row.get("event") in events)


def add_recommendation(
    items: list[Recommendation],
    *,
    priority: str,
    score: int,
    title: str,
    product_task: str,
    trigger: str,
    evidence: str,
    owner_lane: str,
    pr_thread_prompt: str,
    confidence: str,
) -> None:
    items.append(
        Recommendation(
            rank=0,
            priority=priority,
            score=score,
            title=title,
            product_task=product_task,
            trigger=trigger,
            evidence=evidence,
            owner_lane=owner_lane,
            pr_thread_prompt=pr_thread_prompt,
            confidence=confidence,
        )
    )


def build_recommendations(data: dict[str, Any]) -> list[Recommendation]:
    results = data.get("results", {})
    launch = overview_value(data, "launch_devices", "app_launched")
    onboarding_touched = overview_value(data, "onboarding_touched_devices")
    if onboarding_touched == 0:
        onboarding_touched = max(event_devices(data, "onboarding_shown"), event_devices(data, "onboarding_step_viewed"))
    onboarding_completed = overview_value(data, "onboarding_completed_devices", "onboarding_completed")
    onboarding_exit_devices = overview_value(data, "onboarding_exit_devices")
    if onboarding_exit_devices == 0:
        onboarding_exit_devices = event_devices(data, "onboarding_dismissed") + event_devices(data, "onboarding_first_dictation_empty")
    dictation_started = overview_value(data, "dictation_started_devices", "dictation_started")
    dictation_completed = overview_value(data, "dictation_completed_devices", "dictation_completed")
    dictation_problem_devices = overview_value(data, "dictation_problem_devices")
    if dictation_problem_devices == 0:
        dictation_problem_devices = (
            event_devices(data, "dictation_start_failed")
            + event_devices(data, "dictation_no_speech")
            + event_devices(data, "dictation_audio_route_recovery_timeout")
        )
    meeting_saved = overview_value(data, "meeting_saved_devices", "meeting_transcript_saved")
    meeting_failed = overview_value(data, "meeting_failed_devices")
    if meeting_failed == 0:
        meeting_failed = event_devices(data, "meeting_transcript_failed") + event_devices(data, "meeting_transcript_skipped")
    first_artifact = overview_value(data, "first_artifact_devices", "activation_first_artifact_saved")
    bridge_devices = overview_value(data, "activation_bridge_devices")
    if bridge_devices == 0:
        bridge_devices = (
            event_devices(data, "activation_artifact_action_clicked")
            + event_devices(data, "activation_agent_prompt_action_clicked")
            + event_devices(data, "activation_agent_setup_cta_clicked")
        )
    agent_query = overview_value(data, "agent_query_devices", "agent_capture_query_observed")

    recommendations: list[Recommendation] = []

    if onboarding_touched > 0 and onboarding_exit_devices / onboarding_touched >= 0.20:
        top_exit = (results.get("onboarding_exits") or [{}])[0]
        step = top_exit.get("step_id") or f"step {top_exit.get('step_index') or '?'}"
        add_recommendation(
            recommendations,
            priority="P1",
            score=90,
            title="Fix the largest onboarding exit",
            product_task="Inspect the step UX, permission copy, and model-readiness messaging where onboarding exits cluster.",
            trigger="onboarding exit spike",
            evidence=f"{onboarding_exit_devices} exit/empty devices out of {onboarding_touched} onboarding-touched devices ({pct(onboarding_exit_devices, onboarding_touched)}); top exit bucket: {step}.",
            owner_lane="onboarding",
            pr_thread_prompt=f"Create a small PR thread to reduce onboarding exit at `{step}` using clearer copy, state recovery, or permission next-step UI.",
            confidence="high",
        )

    if dictation_started > 0 and dictation_problem_devices / dictation_started >= 0.15:
        add_recommendation(
            recommendations,
            priority="P1",
            score=86,
            title="Improve dictation retry and pasteback recovery",
            product_task="Make failed/empty dictation recovery clearer and make retry preserve the user's context.",
            trigger="dictation retry/failure spike",
            evidence=f"{dictation_problem_devices} problem devices vs {dictation_started} started devices ({pct(dictation_problem_devices, dictation_started)}); completed reach is {dictation_completed} devices.",
            owner_lane="dictation reliability",
            pr_thread_prompt="Create a PR thread around no-speech/start-failure recovery, pasteback retry copy, and post-failure affordances.",
            confidence="high",
        )

    if meeting_saved > 0 and agent_query == 0:
        add_recommendation(
            recommendations,
            priority="P1",
            score=84,
            title="Turn saved meetings into agent handoff",
            product_task="Improve the post-save artifact card: open Markdown, reveal folder, and copy one exact first agent question.",
            trigger="meeting saved but no true agent query",
            evidence=f"{meeting_saved} devices saved meetings; {bridge_devices} devices clicked an artifact/prompt/setup proxy; 0 true agent-query devices.",
            owner_lane="activation / agent handoff",
            pr_thread_prompt="Create a PR thread for a stronger post-save Home bridge from saved Markdown to one sourced agent question.",
            confidence="medium",
        )

    summary_requested = overview_value(data, "summary_requested_devices", "meeting_summary_requested")
    summary_finished = overview_value(data, "summary_finished_devices", "meeting_summary_finished")
    if summary_requested > 0 and summary_finished / summary_requested < 0.80:
        add_recommendation(
            recommendations,
            priority="P1",
            score=82,
            title="Fix summary completion",
            product_task="Improve model prep/download UX and the failure state when a summary starts but does not finish.",
            trigger="summary start without finish",
            evidence=f"{summary_requested} summary-request devices and {summary_finished} summary-finish devices ({pct(summary_finished, summary_requested)} completion).",
            owner_lane="local summary",
            pr_thread_prompt="Create a PR thread around summary model readiness, progress, failure recovery, and retry.",
            confidence="high",
        )
    elif meeting_saved > 0 and summary_requested == 0 and summary_finished == 0:
        add_recommendation(
            recommendations,
            priority="P2",
            score=62,
            title="Instrument summary start/finish before optimizing summary UX",
            product_task="Add privacy-safe summary lifecycle telemetry before using dashboards to judge summary prep/download UX.",
            trigger="summary lifecycle blind spot",
            evidence=f"{meeting_saved} devices saved meetings, but no `meeting_summary_requested` or `meeting_summary_finished` aggregate rows exist.",
            owner_lane="local summary analytics",
            pr_thread_prompt="Create a PR thread for enum-only summary requested/finished telemetry with model_state, result, failure_kind, and latency bucket.",
            confidence="medium",
        )

    if meeting_saved > 0 and meeting_failed / max(meeting_saved + meeting_failed, 1) >= 0.15:
        add_recommendation(
            recommendations,
            priority="P1",
            score=80,
            title="Reduce meeting transcript failures",
            product_task="Inspect meeting failure buckets, queue depth, and capture-health rows before shipping more meeting UX.",
            trigger="meeting failure spike",
            evidence=f"{meeting_failed} failed/skipped meeting devices vs {meeting_saved} saved devices.",
            owner_lane="meeting reliability",
            pr_thread_prompt="Create a PR thread to classify the top meeting failure kind and add the narrowest recovery or retry fix.",
            confidence="high",
        )

    release_failure_rows = [
        row
        for row in results.get("release_health", [])
        if row.get("event") in {"app_unclean_shutdown_detected", "app_session_stall_detected"}
        or row.get("result") in {"failed", "failure"}
        or row.get("failure_kind")
    ]
    release_summary = (results.get("release_failure_summary") or [{}])[0]
    release_failure_devices = as_int(release_summary.get("release_failure_devices"))
    if release_failure_devices == 0:
        release_failure_devices = sum(as_int(row.get("devices")) for row in release_failure_rows)
    if release_failure_devices >= 2:
        versions = sorted({
            str((row.get("update_version") if row.get("event") in {"update_check_finished", "update_download_finished"} else row.get("app_version")) or "unknown")
            for row in release_failure_rows
        })
        add_recommendation(
            recommendations,
            priority="P0",
            score=95,
            title="Hold release confidence and drill into Sentry",
            product_task="Scope failures by release version, then compare against Sentry before calling the release healthy.",
            trigger="release version has failures",
            evidence=f"{release_failure_devices} aggregate failure/stall/update-failure devices across versions: {', '.join(versions[:4])}.",
            owner_lane="release health",
            pr_thread_prompt="Create a release-health thread: isolate the current shipped version, pull Sentry issues, and map failures to a hold/fix/release call.",
            confidence="high",
        )

    if launch > 0 and first_artifact == 0:
        add_recommendation(
            recommendations,
            priority="P1",
            score=78,
            title="Fix first-artifact visibility",
            product_task="Make the first saved Markdown event and Home proof obvious before reading activation as healthy.",
            trigger="launches without first-artifact proof",
            evidence=f"{launch} launch devices and 0 first-artifact devices in this window.",
            owner_lane="activation instrumentation",
            pr_thread_prompt="Create a PR thread to verify `activation_first_artifact_saved` fires from both dictation and meeting save paths.",
            confidence="medium",
        )

    if not recommendations:
        add_recommendation(
            recommendations,
            priority="P3",
            score=20,
            title="No deterministic product fire this window",
            product_task="Keep watching the saved Markdown -> agent query -> return ladder before opening broad work.",
            trigger="no threshold crossed",
            evidence="No recommendation rule crossed its threshold on the available aggregate rows.",
            owner_lane="product analytics",
            pr_thread_prompt="Do not open a product PR from this report alone; rerun with a longer window or a specific app version.",
            confidence="low",
        )

    ranked = sorted(recommendations, key=lambda item: (-item.score, item.title))
    return [
        Recommendation(
            rank=index,
            priority=item.priority,
            score=item.score,
            title=item.title,
            product_task=item.product_task,
            trigger=item.trigger,
            evidence=item.evidence,
            owner_lane=item.owner_lane,
            pr_thread_prompt=item.pr_thread_prompt,
            confidence=item.confidence,
        )
        for index, item in enumerate(ranked, start=1)
    ]


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


def render_report(data: dict[str, Any], recommendations: list[Recommendation]) -> str:
    source = data.get("source", {})
    app_version = data.get("app_version") or "all app versions"
    top_rows = [
        [
            item.rank,
            item.priority,
            item.title,
            item.trigger,
            item.product_task,
            item.owner_lane,
        ]
        for item in recommendations
    ]
    detail_lines: list[str] = []
    for item in recommendations:
        detail_lines.extend(
            [
                f"### {item.rank}. {item.title}",
                "",
                f"- Priority: **{item.priority}**; score: **{item.score}**; confidence: **{item.confidence}**.",
                f"- Signal: {item.trigger}.",
                f"- Evidence: {item.evidence}",
                f"- Build next: {item.product_task}",
                f"- PR thread: {item.pr_thread_prompt}",
                "",
            ]
        )

    lines = [
        "# Transcripted PostHog Product Recommendations",
        "",
        f"Generated: {data.get('generated_at')}",
        f"Window: last {data.get('window_days')} days, {app_version}",
        "",
        "Source: PostHog aggregate rows only. This report exports enum/count buckets, not user IDs, transcript text, audio references, file paths, meeting titles, names, URLs, or raw payloads.",
        f"Data source detail: {source.get('kind', 'fixture')} ({source.get('privacy', 'aggregate fixture rows')}).",
        "",
        "## Ranked Tasks",
        "",
        md_table(["Rank", "Priority", "Task", "Trigger", "Build next", "Lane"], top_rows),
        "",
        "## Recommendation Details",
        "",
        "\n".join(detail_lines).rstrip(),
        "",
        "## Coordinator Copy",
        "",
        "\n".join(
            f"- {item.priority}: {item.title} -> {item.pr_thread_prompt}"
            for item in recommendations[:5]
        ),
        "",
    ]
    return "\n".join(lines)


def write_outputs(
    data: dict[str, Any],
    recommendations: list[Recommendation],
    report: str,
    write_dir: Path | None,
) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-product-recommendations") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "product-recommendations.md"
    data_path = output_dir / "product-recommendations-data.json"
    payload = dict(data)
    payload["recommendations"] = [item.__dict__ for item in recommendations]
    report_path.write_text(report, encoding="utf-8")
    data_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return report_path, data_path


def load_fixture(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RecommendationReportError(f"could not read fixture {path}: {exc}") from exc


def sample_fixture() -> dict[str, Any]:
    return {
        "generated_at": "2026-06-19T00:00:00+00:00",
        "window_days": 30,
        "app_version": "fixture",
        "source": {"kind": "fixture", "privacy": "aggregate enum/count rows only"},
        "results": {
            "overview": [{
                "launch_devices": 50,
                "onboarding_touched_devices": 40,
                "onboarding_exit_devices": 14,
                "onboarding_completed_devices": 18,
                "dictation_started_devices": 30,
                "dictation_completed_devices": 22,
                "dictation_problem_devices": 12,
                "meeting_saved_devices": 18,
                "meeting_failed_devices": 4,
                "first_artifact_devices": 22,
                "activation_bridge_devices": 14,
                "agent_query_devices": 0,
                "summary_requested_devices": 10,
                "summary_finished_devices": 4,
            }],
            "event_counts": [
                {"event": "app_launched", "events": 150, "devices": 50},
                {"event": "onboarding_shown", "events": 60, "devices": 40},
                {"event": "onboarding_step_viewed", "events": 110, "devices": 40},
                {"event": "onboarding_dismissed", "events": 16, "devices": 14},
                {"event": "onboarding_completed", "events": 20, "devices": 18},
                {"event": "dictation_started", "events": 70, "devices": 30},
                {"event": "dictation_completed", "events": 42, "devices": 22},
                {"event": "dictation_no_speech", "events": 10, "devices": 8},
                {"event": "dictation_start_failed", "events": 5, "devices": 4},
                {"event": "meeting_transcript_saved", "events": 28, "devices": 18},
                {"event": "meeting_transcript_failed", "events": 5, "devices": 4},
                {"event": "activation_first_artifact_saved", "events": 26, "devices": 22},
                {"event": "activation_artifact_action_clicked", "events": 14, "devices": 10},
                {"event": "activation_agent_prompt_action_clicked", "events": 5, "devices": 4},
                {"event": "meeting_summary_requested", "events": 12, "devices": 10},
                {"event": "meeting_summary_finished", "events": 5, "devices": 4},
                {"event": "app_unclean_shutdown_detected", "events": 4, "devices": 3},
            ],
            "onboarding_exits": [
                {"step_id": "permissions", "step_index": 2, "model_state": "downloading", "events": 10, "devices": 9}
            ],
            "dictation_outcomes": [],
            "meeting_outcomes": [],
            "activation_bridge": [],
            "summary_outcomes": [],
            "release_health": [
                {"app_version": "1.1.48", "event": "app_unclean_shutdown_detected", "events": 4, "devices": 3}
            ],
            "release_failure_summary": [
                {"release_failure_devices": 3, "release_failure_events": 4}
            ],
        },
    }


def run_self_test() -> int:
    data = sample_fixture()
    recommendations = build_recommendations(data)
    report = render_report(data, recommendations)
    titles = [item.title for item in recommendations]
    required = {
        "Hold release confidence and drill into Sentry",
        "Fix the largest onboarding exit",
        "Improve dictation retry and pasteback recovery",
        "Fix summary completion",
        "Turn saved meetings into agent handoff",
    }
    missing = sorted(required.difference(titles))
    if missing:
        print(f"self-test failed: missing recommendations: {', '.join(missing)}", file=sys.stderr)
        return 1
    forbidden = ("distinct_id", "transcript_text", "audio_path", "meeting_title", "raw_url")
    lowered = report.lower()
    leaked = [fragment for fragment in forbidden if fragment in lowered]
    if leaked:
        print(f"self-test failed: unsafe fragment in rendered report: {', '.join(leaked)}", file=sys.stderr)
        return 1
    for query in (
        event_counts_query(30, None),
        overview_query(30, None),
        onboarding_exits_query(30, None),
        dictation_outcomes_query(30, None),
        meeting_outcomes_query(30, None),
        activation_bridge_query(30, None),
        summary_outcomes_query(30, None),
        release_health_query(30, None),
        release_failure_summary_query(30, None),
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
    parser.add_argument("--fixture", type=Path, help="Read aggregate fixture JSON instead of querying PostHog.")
    parser.add_argument("--write-dir", type=Path, help="Directory for product-recommendations.md and product-recommendations-data.json.")
    parser.add_argument("--json-only", action="store_true", help="Print the JSON payload instead of the Markdown report.")
    parser.add_argument("--self-test", action="store_true", help="Run offline deterministic checks without PostHog access.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.days <= 0:
        print("ERROR: --days must be positive", file=sys.stderr)
        return 2

    try:
        data = load_fixture(args.fixture) if args.fixture else fetch_report_data(args.days, args.app_version)
        recommendations = build_recommendations(data)
        report = render_report(data, recommendations)
        report_path, data_path = write_outputs(data, recommendations, report, args.write_dir)
    except RecommendationReportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3

    if args.json_only:
        payload = dict(data)
        payload["recommendations"] = [item.__dict__ for item in recommendations]
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(report)
        print(f"Report written: {report_path}")
        print(f"Data written: {data_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
