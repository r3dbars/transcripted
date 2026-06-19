#!/usr/bin/env python3
"""Build aggregate PostHog dashboard helper data for Transcripted product learning."""

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

CORE_ACTIVE_EVENTS = (
    "app_launched",
    "onboarding_completed",
    "dictation_started",
    "dictation_completed",
    "dictation_start_failed",
    "dictation_cancelled",
    "dictation_no_speech",
    "meeting_prompt_shown",
    "meeting_prompt_record_selected",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_recording_stopped",
    "meeting_recording_cancelled",
    "meeting_file_imported",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
)

UPDATE_EVENTS = (
    "update_action_clicked",
    "update_check_finished",
    "update_download_started",
    "update_download_finished",
    "update_ready_to_install",
    "update_relaunching",
    "update_installed",
)

ALL_REPORT_EVENTS = tuple(dict.fromkeys(CORE_ACTIVE_EVENTS + (
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_permission_status_changed",
    "onboarding_first_dictation_started",
    "onboarding_first_dictation_saved",
    "dictation_stop_latency_measured",
    "dictation_artifact_saved",
    "dictation_retry_started",
    "meeting_capture_health_snapshot",
    "meeting_speaker_review_prompted",
    "meeting_speaker_review_completed",
    "meeting_summary_requested",
    "meeting_summary_finished",
    "local_meeting_summary_started",
    "local_meeting_summary_completed",
    "local_meeting_summary_failed",
    "agent_capture_query_observed",
    "activation_second_artifact_saved",
    "workflow_abandoned",
) + UPDATE_EVENTS))

MISSING_OR_PROXY_EVENTS = (
    {
        "event": "agent_capture_query_observed",
        "dashboard": "Agent and Markdown loop",
        "status": "missing",
        "why": "Needed to prove a saved Transcripted artifact produced a sourced agent answer.",
    },
    {
        "event": "activation_second_artifact_saved",
        "dashboard": "100 WAU and retention",
        "status": "missing",
        "why": "Needed for first-artifact-to-second-artifact and habit conversion.",
    },
    {
        "event": "dictation_artifact_saved",
        "dashboard": "Dictation reliability",
        "status": "missing",
        "why": "General dictation saved-Markdown writes currently use dictation_completed as a proxy.",
    },
    {
        "event": "dictation_retry_started",
        "dashboard": "Dictation reliability",
        "status": "missing",
        "why": "Needed to see recovery behavior after failed or empty dictation.",
    },
    {
        "event": "meeting_speaker_review_prompted",
        "dashboard": "Meeting reliability",
        "status": "missing",
        "why": "Speaker review is inferred from outcomes; the review funnel is not first-class yet.",
    },
    {
        "event": "meeting_speaker_review_completed",
        "dashboard": "Meeting reliability",
        "status": "missing",
        "why": "Needed to separate accepted, dismissed, and completed speaker-review work.",
    },
    {
        "event": "meeting_summary_requested",
        "dashboard": "Local summary beta",
        "status": "missing",
        "why": "Local summary has local observability events and settings-action proxies, not a PostHog lifecycle event.",
    },
    {
        "event": "meeting_summary_finished",
        "dashboard": "Local summary beta",
        "status": "missing",
        "why": "Needed for result, failure kind, model state, and latency-bucket learning.",
    },
    {
        "event": "workflow_abandoned",
        "dashboard": "Activation and reliability",
        "status": "missing",
        "why": "Needed for safe abandonment taxonomy without raw content.",
    },
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
class Dashboard:
    key: str
    title: str
    goal: str
    queries: tuple[str, ...]
    tiles: tuple[str, ...]
    missing_events: tuple[str, ...]


DASHBOARDS = (
    Dashboard(
        "wau",
        "100 WAU Operating Dashboard",
        "Track whether active anonymous devices are approaching 100 weekly active users and reaching first value.",
        ("wau_summary", "daily_active", "active_by_version", "failure_tiles"),
        (
            "WAU and DAU from core workflow events, not only launches.",
            "WAU by app_version.",
            "First artifact, second artifact, return-proxy, dictation, and meeting devices.",
            "Failure tiles for dictation, meeting, and update health.",
        ),
        ("activation_second_artifact_saved",),
    ),
    Dashboard(
        "activation",
        "Activation Funnel",
        "Measure launch to saved Markdown to agent-intent to return.",
        ("activation_reach", "activation_sequence", "event_counts"),
        (
            "Launch -> onboarding -> permission-ready proxy -> capture start -> first artifact -> artifact action -> agent signal -> true agent query -> return proxy.",
            "Strict saved Markdown separated from dictation_completed proxy.",
        ),
        ("agent_capture_query_observed", "dictation_artifact_saved"),
    ),
    Dashboard(
        "dictation",
        "Dictation Reliability Funnel",
        "Keep start, stop, save, and delivery reliability visible without raw text.",
        ("dictation_summary", "dictation_breakdowns"),
        (
            "Started, start failed, stop latency measured, completed, cancelled, no speech.",
            "Breakdowns by trigger, delivery, outcome, save outcome, route shape, and failure kind.",
        ),
        ("dictation_artifact_saved", "dictation_retry_started"),
    ),
    Dashboard(
        "meeting",
        "Meeting Reliability Funnel",
        "Measure prompt trust, recording success, transcript output, and review gaps.",
        ("meeting_summary", "meeting_breakdowns"),
        (
            "Prompt shown -> record selected -> started -> stopped -> saved/failed/skipped.",
            "Breakdowns by provider, source, route readiness, trigger, quality, system stream, queue depth, and failure kind.",
        ),
        ("meeting_speaker_review_prompted", "meeting_speaker_review_completed"),
    ),
    Dashboard(
        "local_summary",
        "Local Summary Beta Funnel",
        "Make summary beta learnable once remote lifecycle events exist.",
        ("local_summary_summary",),
        (
            "Transcript saved -> summary requested -> summary finished.",
            "Current output calls out local-only/proxy state instead of pretending the funnel exists.",
        ),
        ("meeting_summary_requested", "meeting_summary_finished"),
    ),
    Dashboard(
        "agent_loop",
        "Agent And Markdown Value Loop",
        "Prove saved Markdown becomes a sourced agent answer and a later return.",
        ("agent_loop_summary", "agent_breakdowns"),
        (
            "First artifact -> open/reveal/preview -> prompt/setup -> true agent query -> return -> second artifact.",
            "Prompt-copy/setup clicks remain intent, not proof.",
        ),
        ("agent_capture_query_observed", "activation_second_artifact_saved"),
    ),
    Dashboard(
        "release_health",
        "Release Health By App Version",
        "Pair app-version usage with workflow success and update lifecycle events.",
        ("active_by_version", "release_health_by_version", "update_lifecycle"),
        (
            "Active devices by app_version.",
            "Dictation completed, meeting transcript saved, first artifact saved, and update lifecycle by version.",
        ),
        (),
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


def app_version_filter(app_version: str | None, property_name: str = "app_version") -> str:
    if not app_version:
        return ""
    return f"AND properties[{sql_quote(property_name)}] = {sql_quote(app_version)}"


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


def event_counts_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT event, count() AS events, uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY event
ORDER BY event ASC
"""


def daily_active_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT toDate(timestamp) AS day, uniq(distinct_id) AS active_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(CORE_ACTIVE_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY day
ORDER BY day ASC
"""


def active_by_version_query(days: int) -> str:
    return f"""
SELECT properties['app_version'] AS app_version, uniq(distinct_id) AS devices, count() AS events
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(CORE_ACTIVE_EVENTS)})
GROUP BY app_version
ORDER BY devices DESC
LIMIT 20
"""


def wau_summary_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event IN ({sql_list(CORE_ACTIVE_EVENTS)})) AS active_devices_in_window,
  uniqIf(distinct_id, event IN ({sql_list(CORE_ACTIVE_EVENTS)}) AND timestamp >= now() - INTERVAL 7 DAY) AS weekly_active_devices,
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event = 'activation_second_artifact_saved') AS second_artifact_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices,
  uniqIf(distinct_id, event = 'dictation_completed') AS dictation_completed_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_saved') AS meeting_saved_devices,
  uniqIf(distinct_id, event IN ('dictation_start_failed', 'dictation_no_speech', 'meeting_recording_start_failed', 'meeting_transcript_failed')
    OR (event IN ('update_check_finished', 'update_download_finished')
      AND (properties['failure_kind'] IS NOT NULL OR properties['result'] IN ('error', 'download_failed', 'failed')))) AS failure_signal_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
  {app_version_filter(app_version)}
"""


def failure_tiles_query(days: int, app_version: str | None) -> str:
    failure_events = (
        "dictation_start_failed",
        "dictation_no_speech",
        "meeting_recording_start_failed",
        "meeting_transcript_failed",
        "meeting_transcript_skipped",
        "update_download_finished",
        "update_check_finished",
    )
    return f"""
SELECT
  event,
  properties['failure_kind'] AS failure_kind,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(failure_events)})
  {app_version_filter(app_version)}
  AND (
    event NOT IN ('update_check_finished', 'update_download_finished')
    OR properties['failure_kind'] IS NOT NULL
    OR properties['result'] IN ('error', 'download_failed', 'failed')
  )
GROUP BY event, failure_kind, result
ORDER BY events DESC
LIMIT 60
"""


def activation_reach_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  uniqIf(distinct_id, event IN ('onboarding_shown', 'onboarding_step_viewed')) AS onboarding_devices,
  uniqIf(distinct_id, event = 'onboarding_completed') AS permission_ready_proxy_devices,
  uniqIf(distinct_id, event IN ('onboarding_first_dictation_started', 'dictation_started', 'meeting_recording_started')) AS capture_start_devices,
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event IN ('onboarding_first_dictation_saved', 'meeting_transcript_saved')) AS strict_saved_markdown_devices,
  uniqIf(distinct_id, event IN ('onboarding_first_dictation_saved', 'meeting_transcript_saved', 'dictation_completed')) AS saved_markdown_plus_dictation_proxy_devices,
  uniqIf(distinct_id, event = 'activation_artifact_action_clicked') AS artifact_action_devices,
  uniqIf(distinct_id, event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked')) AS agent_intent_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS true_agent_query_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
  {app_version_filter(app_version)}
"""


def activation_sequence_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT deepest_step, count() AS devices
FROM (
  SELECT active_subject,
    windowFunnel({int(days)} * 24 * 3600)(toDateTime(timestamp),
      event = 'app_launched',
      event IN ('onboarding_shown', 'onboarding_step_viewed'),
      event = 'onboarding_completed',
      event IN ('dictation_started', 'meeting_recording_started', 'onboarding_first_dictation_started'),
      event = 'activation_first_artifact_saved',
      event = 'activation_artifact_action_clicked',
      event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked'),
      event = 'agent_capture_query_observed',
      event = 'activation_return_proxy_observed'
    ) AS deepest_step
  FROM events
  WHERE timestamp >= now() - INTERVAL {int(days)} DAY
    AND event IN ({sql_list(ALL_REPORT_EVENTS)})
    {app_version_filter(app_version)}
  GROUP BY active_subject
)
GROUP BY deepest_step
ORDER BY deepest_step ASC
""".replace("active_subject", "distinct_id")


def dictation_summary_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'dictation_started') AS started_devices,
  uniqIf(distinct_id, event = 'dictation_start_failed') AS start_failed_devices,
  uniqIf(distinct_id, event = 'dictation_stop_latency_measured') AS stop_latency_devices,
  uniqIf(distinct_id, event = 'dictation_completed') AS completed_devices,
  uniqIf(distinct_id, event = 'dictation_artifact_saved') AS artifact_saved_devices,
  uniqIf(distinct_id, event = 'dictation_cancelled') AS cancelled_devices,
  uniqIf(distinct_id, event = 'dictation_no_speech') AS no_speech_devices,
  uniqIf(distinct_id, event = 'dictation_retry_started') AS retry_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
  {app_version_filter(app_version)}
"""


def dictation_breakdowns_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['trigger'] AS trigger,
  properties['delivery'] AS delivery,
  properties['outcome'] AS outcome,
  properties['save_outcome'] AS save_outcome,
  properties['route_shape'] AS route_shape,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('dictation_started', 'dictation_start_failed', 'dictation_stop_latency_measured', 'dictation_completed', 'dictation_cancelled', 'dictation_no_speech', 'dictation_artifact_saved', 'dictation_retry_started')
  {app_version_filter(app_version)}
GROUP BY event, trigger, delivery, outcome, save_outcome, route_shape, failure_kind
ORDER BY events DESC
LIMIT 80
"""


def meeting_summary_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'meeting_prompt_shown') AS prompt_shown_devices,
  uniqIf(distinct_id, event = 'meeting_prompt_record_selected') AS prompt_record_selected_devices,
  uniqIf(distinct_id, event = 'meeting_recording_started') AS started_devices,
  uniqIf(distinct_id, event = 'meeting_recording_start_failed') AS start_failed_devices,
  uniqIf(distinct_id, event = 'meeting_recording_stopped') AS stopped_devices,
  uniqIf(distinct_id, event = 'meeting_capture_health_snapshot') AS health_snapshot_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_saved') AS saved_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_failed') AS failed_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_skipped') AS skipped_devices,
  uniqIf(distinct_id, event = 'meeting_speaker_review_prompted') AS speaker_review_prompted_devices,
  uniqIf(distinct_id, event = 'meeting_speaker_review_completed') AS speaker_review_completed_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
  {app_version_filter(app_version)}
"""


def meeting_breakdowns_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['provider'] AS provider,
  properties['source'] AS source,
  properties['route_ready'] AS route_ready,
  properties['trigger'] AS trigger,
  properties['capture_quality'] AS capture_quality,
  properties['system_stream_present'] AS system_stream_present,
  properties['queue_depth_bucket'] AS queue_depth_bucket,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_prompt_shown', 'meeting_prompt_record_selected', 'meeting_recording_started', 'meeting_recording_start_failed', 'meeting_recording_stopped', 'meeting_capture_health_snapshot', 'meeting_transcript_saved', 'meeting_transcript_failed', 'meeting_transcript_skipped')
  {app_version_filter(app_version)}
GROUP BY event, provider, source, route_ready, trigger, capture_quality, system_stream_present, queue_depth_bucket, failure_kind
ORDER BY events DESC
LIMIT 100
"""


def local_summary_summary_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'meeting_transcript_saved') AS source_meeting_saved_devices,
  uniqIf(distinct_id, event = 'meeting_summary_requested') AS summary_requested_devices,
  uniqIf(distinct_id, event = 'meeting_summary_finished') AS summary_finished_devices,
  uniqIf(distinct_id, event IN ('local_meeting_summary_started', 'local_meeting_summary_completed', 'local_meeting_summary_failed')) AS local_observability_proxy_devices,
  uniqIf(distinct_id, event = 'settings_action_clicked' AND properties['action_id'] IN ('generate_local_meeting_summary', 'open_local_meeting_summary', 'retry_local_meeting_summary_notice', 'open_local_meeting_summary_notice')) AS settings_action_proxy_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_transcript_saved', 'meeting_summary_requested', 'meeting_summary_finished', 'local_meeting_summary_started', 'local_meeting_summary_completed', 'local_meeting_summary_failed', 'settings_action_clicked')
  {app_version_filter(app_version)}
"""


def agent_loop_summary_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event = 'activation_artifact_action_clicked') AS artifact_action_devices,
  uniqIf(distinct_id, event = 'activation_agent_prompt_action_clicked') AS agent_prompt_devices,
  uniqIf(distinct_id, event = 'activation_agent_setup_cta_clicked') AS agent_setup_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS true_agent_query_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices,
  uniqIf(distinct_id, event = 'activation_second_artifact_saved') AS second_artifact_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
  {app_version_filter(app_version)}
"""


def agent_breakdowns_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['artifact_kind'] AS artifact_kind,
  properties['action_kind'] AS action_kind,
  properties['agent_target'] AS agent_target,
  properties['prompt_kind'] AS prompt_kind,
  properties['setup_kind'] AS setup_kind,
  properties['result'] AS result,
  properties['return_window_bucket'] AS return_window_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('activation_first_artifact_saved', 'activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'agent_capture_query_observed', 'activation_return_proxy_observed', 'activation_second_artifact_saved')
  {app_version_filter(app_version)}
GROUP BY event, artifact_kind, action_kind, agent_target, prompt_kind, setup_kind, result, return_window_bucket
ORDER BY events DESC
LIMIT 100
"""


def release_health_by_version_query(days: int) -> str:
    return f"""
SELECT
  properties['app_version'] AS app_version,
  uniqIf(distinct_id, event IN ({sql_list(CORE_ACTIVE_EVENTS)})) AS active_devices,
  uniqIf(distinct_id, event = 'dictation_completed') AS dictation_completed_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_saved') AS meeting_saved_devices,
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event IN ('dictation_start_failed', 'meeting_recording_start_failed', 'meeting_transcript_failed')) AS workflow_failure_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(ALL_REPORT_EVENTS)})
GROUP BY app_version
ORDER BY active_devices DESC
LIMIT 20
"""


def update_lifecycle_query(days: int) -> str:
    return f"""
SELECT
  properties['version'] AS version,
  event,
  properties['result'] AS result,
  properties['failure_kind'] AS failure_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('update_action_clicked', 'update_check_finished', 'update_download_started', 'update_download_finished', 'update_ready_to_install', 'update_relaunching', 'update_installed')
GROUP BY version, event, result, failure_kind
ORDER BY version DESC, event ASC, events DESC
LIMIT 120
"""


QUERY_BUILDERS = {
    "event_counts": event_counts_query,
    "daily_active": daily_active_query,
    "active_by_version": lambda days, app_version: active_by_version_query(days),
    "wau_summary": wau_summary_query,
    "failure_tiles": failure_tiles_query,
    "activation_reach": activation_reach_query,
    "activation_sequence": activation_sequence_query,
    "dictation_summary": dictation_summary_query,
    "dictation_breakdowns": dictation_breakdowns_query,
    "meeting_summary": meeting_summary_query,
    "meeting_breakdowns": meeting_breakdowns_query,
    "local_summary_summary": local_summary_summary_query,
    "agent_loop_summary": agent_loop_summary_query,
    "agent_breakdowns": agent_breakdowns_query,
    "release_health_by_version": lambda days, app_version: release_health_by_version_query(days),
    "update_lifecycle": lambda days, app_version: update_lifecycle_query(days),
}


def fetch_report_data(days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()
    queries = {
        key: builder(days, app_version)
        for key, builder in QUERY_BUILDERS.items()
    }
    results = {
        name: rows_as_dicts(run_hogql(host, project_id, token, query))
        for name, query in queries.items()
    }
    return build_payload(days, app_version, host, results)


def build_payload(days: int, app_version: str | None, host: str, results: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "privacy": "aggregate counts and enum buckets only; no raw rows, people exports, transcript text, paths, titles, URLs, or identifiers are written",
        },
        "dashboards": [
            {
                "key": dashboard.key,
                "title": dashboard.title,
                "goal": dashboard.goal,
                "queries": list(dashboard.queries),
                "tiles": list(dashboard.tiles),
                "missing_events": list(dashboard.missing_events),
            }
            for dashboard in DASHBOARDS
        ],
        "missing_or_proxy_events": list(MISSING_OR_PROXY_EVENTS),
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


def first_row(data: dict[str, Any], key: str) -> dict[str, Any]:
    return (data["results"].get(key) or [{}])[0]


def render_kv_table(row: dict[str, Any]) -> str:
    return md_table(["Metric", "Value"], [[key, value] for key, value in row.items()])


def render_top_rows(title: str, rows: list[dict[str, Any]], columns: list[str], limit: int = 12) -> str:
    if not rows:
        return f"### {title}\n\nNo rows in this window.\n"
    return f"### {title}\n\n" + md_table(columns, [[row.get(column) for column in columns] for row in rows[:limit]]) + "\n"


def render_activation_sequence(data: dict[str, Any]) -> str:
    labels = [
        "Launch",
        "Onboarding touched",
        "Permission-ready proxy",
        "Capture started",
        "First artifact saved",
        "Artifact action",
        "Agent prompt/setup intent",
        "True agent query",
        "Return proxy",
    ]
    histogram = {
        as_int(row.get("deepest_step")): as_int(row.get("devices"))
        for row in data["results"].get("activation_sequence", [])
    }
    launch_sequence_devices = sum(count for step, count in histogram.items() if step >= 1)
    rows = []
    previous = 0
    for index, label in enumerate(labels, start=1):
        devices = sum(count for step, count in histogram.items() if step >= index)
        rows.append([index, label, devices, pct(devices, launch_sequence_devices), pct(devices, previous) if previous else "n/a"])
        previous = devices
    rows.append(["0", "Relevant events without an in-window launch", histogram.get(0, 0), "n/a", "n/a"])
    return md_table(["Order", "Step", "Devices", "Of launch sequence", "Step conversion"], rows)


def render_dashboard_index(data: dict[str, Any]) -> str:
    return md_table(
        ["Dashboard", "Queries", "Missing/proxy calls"],
        [
            [
                dashboard["title"],
                ", ".join(dashboard["queries"]),
                ", ".join(dashboard["missing_events"]) or "-",
            ]
            for dashboard in data["dashboards"]
        ],
    )


def render_report(data: dict[str, Any]) -> str:
    app_version = data.get("app_version") or "all app versions"
    wau = first_row(data, "wau_summary")
    activation = first_row(data, "activation_reach")
    agent = first_row(data, "agent_loop_summary")
    active_devices = as_int(wau.get("weekly_active_devices"))
    window_active_devices = as_int(wau.get("active_devices_in_window"))
    first_artifact = as_int(wau.get("first_artifact_devices"))
    true_agent_query = as_int(agent.get("true_agent_query_devices"))
    return_proxy = as_int(agent.get("return_proxy_devices"))

    lines = [
        "# Transcripted PostHog Product-Learning Dashboards",
        "",
        f"Generated: {data['generated_at']}",
        f"Window: last {data['window_days']} days, {app_version}",
        "",
        "Source: PostHog aggregate HogQL. This helper writes counts and enum breakdowns only; it does not export user/device IDs, people rows, transcript text, audio references, file paths, meeting titles, raw URLs, or raw payloads.",
        "",
        "## Decision Read",
        "",
        f"- Weekly active devices: **{active_devices}**.",
        f"- Active devices in full report window: **{window_active_devices}**.",
        f"- First artifact devices: **{first_artifact}** ({pct(first_artifact, window_active_devices)} of full-window active).",
        f"- True agent-query proof: **{true_agent_query}** ({pct(true_agent_query, window_active_devices)} of full-window active). This stays unknown, not green, until `agent_capture_query_observed` exists.",
        f"- Return proxy devices: **{return_proxy}** ({pct(return_proxy, window_active_devices)} of full-window active).",
        "",
        "## Dashboards Covered",
        "",
        render_dashboard_index(data),
        "",
        "## 100 WAU Operating Dashboard",
        "",
        render_kv_table(wau),
        "",
        render_top_rows("Daily Active Devices", data["results"].get("daily_active", []), ["day", "active_devices"]),
        render_top_rows("Active Devices By App Version", data["results"].get("active_by_version", []), ["app_version", "devices", "events"]),
        render_top_rows("Failure Tiles", data["results"].get("failure_tiles", []), ["event", "failure_kind", "result", "events", "devices"]),
        "## Activation Funnel",
        "",
        render_kv_table(activation),
        "",
        "### Ordered Activation Sequence",
        "",
        render_activation_sequence(data),
        "",
        "## Dictation Reliability Funnel",
        "",
        render_kv_table(first_row(data, "dictation_summary")),
        "",
        render_top_rows("Dictation Breakdowns", data["results"].get("dictation_breakdowns", []), ["event", "trigger", "delivery", "outcome", "save_outcome", "route_shape", "failure_kind", "events", "devices"]),
        "## Meeting Reliability Funnel",
        "",
        render_kv_table(first_row(data, "meeting_summary")),
        "",
        render_top_rows("Meeting Breakdowns", data["results"].get("meeting_breakdowns", []), ["event", "provider", "source", "route_ready", "trigger", "capture_quality", "system_stream_present", "queue_depth_bucket", "failure_kind", "events", "devices"]),
        "## Local Summary Beta Funnel",
        "",
        render_kv_table(first_row(data, "local_summary_summary")),
        "",
        "## Agent And Markdown Value Loop",
        "",
        render_kv_table(agent),
        "",
        render_top_rows("Agent Loop Breakdowns", data["results"].get("agent_breakdowns", []), ["event", "artifact_kind", "action_kind", "agent_target", "prompt_kind", "setup_kind", "result", "return_window_bucket", "events", "devices"]),
        "## Release Health By App Version",
        "",
        render_top_rows("Workflow Health By App Version", data["results"].get("release_health_by_version", []), ["app_version", "active_devices", "dictation_completed_devices", "meeting_saved_devices", "first_artifact_devices", "workflow_failure_devices"], limit=20),
        render_top_rows("Update Lifecycle", data["results"].get("update_lifecycle", []), ["version", "event", "result", "failure_kind", "events", "devices"], limit=20),
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
        "## Missing Events And Proxy Warnings",
        "",
        md_table(
            ["Event", "Dashboard", "Status", "Why it matters"],
            [
                [item["event"], item["dashboard"], item["status"], item["why"]]
                for item in data["missing_or_proxy_events"]
            ],
        ),
        "",
        "## Smallest Next Action",
        "",
        "Instrument `agent_capture_query_observed` in the read-only MCP/agent surface, then make the north-star tile the share of active devices that reach true agent-query proof after a saved artifact.",
        "",
    ]
    return "\n".join(lines)


def write_outputs(data: dict[str, Any], report: str, write_dir: Path | None) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-product-learning") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "product-learning-report.md"
    data_path = output_dir / "product-learning-data.json"
    report_path.write_text(report, encoding="utf-8")
    data_path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
    return report_path, data_path


def run_self_test() -> int:
    sample_results: dict[str, list[dict[str, Any]]] = {
        "wau_summary": [{
            "active_devices_in_window": 100,
            "weekly_active_devices": 44,
            "first_artifact_devices": 42,
            "second_artifact_devices": 0,
            "return_proxy_devices": 12,
            "dictation_completed_devices": 31,
            "meeting_saved_devices": 11,
            "failure_signal_devices": 4,
        }],
        "daily_active": [{"day": "2026-06-19", "active_devices": 18}],
        "active_by_version": [{"app_version": "1.1.48", "devices": 80, "events": 300}],
        "failure_tiles": [{"event": "dictation_no_speech", "failure_kind": None, "result": None, "events": 4, "devices": 3}],
        "activation_reach": [{
            "launch_devices": 90,
            "onboarding_devices": 50,
            "permission_ready_proxy_devices": 44,
            "capture_start_devices": 40,
            "first_artifact_devices": 42,
            "strict_saved_markdown_devices": 25,
            "saved_markdown_plus_dictation_proxy_devices": 42,
            "artifact_action_devices": 20,
            "agent_intent_devices": 9,
            "true_agent_query_devices": 0,
            "return_proxy_devices": 12,
        }],
        "activation_sequence": [{"deepest_step": 1, "devices": 3}, {"deepest_step": 7, "devices": 2}],
        "dictation_summary": [{
            "started_devices": 35,
            "start_failed_devices": 2,
            "stop_latency_devices": 30,
            "completed_devices": 31,
            "artifact_saved_devices": 0,
            "cancelled_devices": 1,
            "no_speech_devices": 3,
            "retry_devices": 0,
        }],
        "dictation_breakdowns": [],
        "meeting_summary": [{
            "prompt_shown_devices": 20,
            "prompt_record_selected_devices": 14,
            "started_devices": 13,
            "start_failed_devices": 1,
            "stopped_devices": 12,
            "health_snapshot_devices": 12,
            "saved_devices": 11,
            "failed_devices": 1,
            "skipped_devices": 0,
            "speaker_review_prompted_devices": 0,
            "speaker_review_completed_devices": 0,
        }],
        "meeting_breakdowns": [],
        "local_summary_summary": [{
            "source_meeting_saved_devices": 11,
            "summary_requested_devices": 0,
            "summary_finished_devices": 0,
            "local_observability_proxy_devices": 0,
            "settings_action_proxy_devices": 0,
        }],
        "agent_loop_summary": [{
            "first_artifact_devices": 42,
            "artifact_action_devices": 20,
            "agent_prompt_devices": 6,
            "agent_setup_devices": 4,
            "true_agent_query_devices": 0,
            "return_proxy_devices": 12,
            "second_artifact_devices": 0,
        }],
        "agent_breakdowns": [],
        "release_health_by_version": [{"app_version": "1.1.48", "active_devices": 80, "dictation_completed_devices": 31, "meeting_saved_devices": 11, "first_artifact_devices": 42, "workflow_failure_devices": 4}],
        "update_lifecycle": [],
        "event_counts": [{"event": "app_launched", "events": 120, "devices": 90}],
    }
    data = build_payload(30, None, "https://us.posthog.com", sample_results)
    report = render_report(data)
    lowered = report.lower()
    forbidden = ("distinct_id", "person_id", "transcript_text", "audio_path", "meeting_title", "raw_url")
    leaked = [fragment for fragment in forbidden if fragment in lowered]
    if leaked:
        print(f"self-test failed: unsafe fragment in rendered report: {', '.join(leaked)}", file=sys.stderr)
        return 1
    for required in (
        "100 WAU Operating Dashboard",
        "Activation Funnel",
        "Dictation Reliability Funnel",
        "Meeting Reliability Funnel",
        "Local Summary Beta Funnel",
        "Agent And Markdown Value Loop",
        "Release Health By App Version",
        "agent_capture_query_observed",
        "True agent-query proof: **0**",
    ):
        if required not in report:
            print(f"self-test failed: missing report text: {required}", file=sys.stderr)
            return 1
    for name, builder in QUERY_BUILDERS.items():
        query = builder(30, None).upper()
        if "SELECT *" in query:
            print(f"self-test failed: {name} uses SELECT *", file=sys.stderr)
            return 1
        unsafe_aliases = (" AS DISTINCT_ID", " AS PERSON_ID", " AS UUID")
        if any(fragment in query for fragment in unsafe_aliases):
            print(f"self-test failed: {name} exposes an unsafe alias", file=sys.stderr)
            return 1
    print("self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version filter, e.g. 1.1.48.")
    parser.add_argument("--write-dir", type=Path, help="Directory for product-learning-report.md and product-learning-data.json.")
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
