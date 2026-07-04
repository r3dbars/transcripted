#!/usr/bin/env python3
"""Turn aggregate PostHog dashboard signal into ranked Transcripted product tasks."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import posthog_common as posthog

CORE_EVENTS = (
    "app_launched",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_completed",
    "onboarding_first_dictation_started",
    "dictation_started",
    "meeting_recording_started",
    "onboarding_first_dictation_saved",
    "activation_first_artifact_saved",
    "dictation_completed",
    "meeting_transcript_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "activation_return_proxy_observed",
    "activation_second_artifact_saved",
    "agent_capture_query_observed",
    "workflow_abandoned",
    "workflow_recovery_attempted",
    "workflow_recovery_finished",
    "product_friction_observed",
    "dictation_start_failed",
    "dictation_no_speech",
    "dictation_cancelled",
    "dictation_audio_route_recovery_timeout",
    "dictation_audio_route_recovery_finished",
    "meeting_recording_start_failed",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "meeting_speaker_finalization_failed",
    "meeting_speaker_review_shown",
    "meeting_speaker_review_submitted",
    "meeting_speaker_match_reviewed",
    "meeting_speaker_auto_recognized",
    "update_check_finished",
    "update_download_finished",
    "update_installed",
    "settings_opened",
    "settings_page_viewed",
    "settings_action_clicked",
    "meeting_prompt_shown",
    "meeting_prompt_record_selected",
    "meeting_prompt_dismissed",
    "meeting_prompt_suppressed",
    "meeting_missed_call_nudge",
    "meeting_file_imported",
    "meeting_saved_audio_retranscription_requested",
    "timeline_onboarding_completed",
    "timeline_viewed",
    "timeline_card_opened",
    "timeline_chat_question_asked",
)

WORKFLOW_EVENTS = (
    "app_launched",
    "onboarding_completed",
    "dictation_started",
    "dictation_completed",
    "meeting_recording_started",
    "meeting_transcript_saved",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "activation_second_artifact_saved",
    "agent_capture_query_observed",
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
    "raw",
    "audio",
    "token",
}


class ProductTaskReportError(RuntimeError):
    pass


@dataclass(frozen=True)
class Finding:
    title: str
    metric: str
    recommendation: str
    confidence: str
    score: float


load_env = posthog.load_env
sql_quote = posthog.sql_quote
sql_list = posthog.sql_list
app_version_filter = posthog.app_version_filter


def posthog_config() -> tuple[str, str, str]:
    return posthog.posthog_config(ProductTaskReportError)


def run_hogql(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
    return posthog.run_hogql(host, project_id, token, query, ProductTaskReportError)


def rows_as_dicts(response: dict[str, Any]) -> list[dict[str, Any]]:
    return posthog.rows_as_dicts(response, DISALLOWED_OUTPUT_COLUMNS, ProductTaskReportError)


def event_counts_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT event, count() AS events, uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(CORE_EVENTS)})
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


def reliability_breakdown_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['failure_kind'] AS failure_kind,
  properties['trigger'] AS trigger,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('dictation_start_failed', 'dictation_no_speech', 'dictation_audio_route_recovery_timeout', 'meeting_recording_start_failed', 'meeting_transcript_failed', 'meeting_transcript_skipped', 'meeting_speaker_finalization_failed', 'workflow_recovery_finished')
  {app_version_filter(app_version)}
GROUP BY event, failure_kind, trigger
ORDER BY events DESC
LIMIT 30
"""


def adoption_breakdown_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['artifact_kind'] AS artifact_kind,
  properties['action_kind'] AS action_kind,
  properties['agent_target'] AS agent_target,
  properties['page_id'] AS page_id,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('activation_artifact_action_clicked', 'activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked', 'settings_page_viewed', 'settings_action_clicked', 'meeting_prompt_record_selected', 'meeting_file_imported', 'meeting_saved_audio_retranscription_requested', 'activation_second_artifact_saved', 'agent_capture_query_observed', 'timeline_viewed', 'timeline_card_opened')
  {app_version_filter(app_version)}
GROUP BY event, artifact_kind, action_kind, agent_target, page_id
ORDER BY devices DESC, events DESC
LIMIT 50
"""


def meeting_prompt_quality_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  properties['provider'] AS provider,
  properties['source'] AS source,
  properties['prompt_reason'] AS prompt_reason,
  properties['route_ready'] AS route_ready,
  countIf(event = 'meeting_prompt_shown') AS shown_events,
  countIf(event = 'meeting_prompt_record_selected') AS record_selected_events,
  countIf(event = 'meeting_prompt_dismissed') AS dismissed_events,
  countIf(event = 'meeting_prompt_suppressed') AS suppressed_events,
  countIf(event = 'meeting_missed_call_nudge') AS missed_call_nudges,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_prompt_shown', 'meeting_prompt_record_selected', 'meeting_prompt_dismissed', 'meeting_prompt_suppressed', 'meeting_missed_call_nudge')
  {app_version_filter(app_version)}
GROUP BY provider, source, prompt_reason, route_ready
ORDER BY shown_events DESC, devices DESC
LIMIT 50
"""


def speaker_trust_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['review_action'] AS review_action,
  properties['completion_kind'] AS completion_kind,
  properties['result'] AS result,
  properties['had_suggestion'] AS had_suggestion,
  properties['similarity_bucket'] AS similarity_bucket,
  properties['margin_bucket'] AS margin_bucket,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('meeting_speaker_review_shown', 'meeting_speaker_review_submitted', 'meeting_speaker_match_reviewed', 'meeting_speaker_auto_recognized', 'meeting_speaker_finalization_failed')
  {app_version_filter(app_version)}
GROUP BY event, review_action, completion_kind, result, had_suggestion, similarity_bucket, margin_bucket
ORDER BY events DESC
LIMIT 50
"""


def onboarding_friction_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['step_id'] AS step_id,
  properties['stage'] AS stage,
  properties['reason_kind'] AS reason_kind,
  properties['permission_kind'] AS permission_kind,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('onboarding_dismissed', 'onboarding_permission_cta_clicked', 'onboarding_permission_status_changed', 'onboarding_primary_cta_clicked', 'product_friction_observed', 'workflow_abandoned')
  {app_version_filter(app_version)}
GROUP BY event, step_id, stage, reason_kind, permission_kind
ORDER BY events DESC
LIMIT 50
"""


def timeline_dayflow_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  properties['provider'] AS provider,
  properties['mode'] AS mode,
  properties['result'] AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ('timeline_onboarding_completed', 'timeline_viewed', 'timeline_mode_changed', 'timeline_card_opened', 'timeline_provider_selected', 'timeline_chat_question_asked', 'timeline_batch_completed', 'timeline_batch_failed')
  {app_version_filter(app_version)}
GROUP BY event, provider, mode, result
ORDER BY events DESC
LIMIT 50
"""


def release_breakdown_query(days: int) -> str:
    return f"""
SELECT
  properties['app_version'] AS app_version,
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  uniqIf(distinct_id, event IN ('dictation_completed', 'meeting_transcript_saved', 'activation_first_artifact_saved')) AS success_devices,
  countIf(event IN ('dictation_start_failed', 'meeting_recording_start_failed', 'meeting_transcript_failed', 'meeting_transcript_skipped')) AS failure_events,
  uniqIf(distinct_id, event IN ('dictation_start_failed', 'meeting_recording_start_failed', 'meeting_transcript_failed', 'meeting_transcript_skipped')) AS failure_devices,
  max(timestamp) AS last_seen
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(CORE_EVENTS)})
GROUP BY app_version
ORDER BY last_seen DESC
LIMIT 20
"""


def fetch_report_data(days: int, app_version: str | None) -> dict[str, Any]:
    load_env()
    host, project_id, token = posthog_config()
    queries = {
        "event_counts": event_counts_query(days, app_version),
        "daily_active": daily_active_query(days, app_version),
        "reliability_breakdown": reliability_breakdown_query(days, app_version),
        "adoption_breakdown": adoption_breakdown_query(days, app_version),
        "meeting_prompt_quality": meeting_prompt_quality_query(days, app_version),
        "speaker_trust": speaker_trust_query(days, app_version),
        "onboarding_friction": onboarding_friction_query(days, app_version),
        "timeline_dayflow": timeline_dayflow_query(days, app_version),
        "release_breakdown": release_breakdown_query(days),
    }
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "privacy": "aggregate counts only; no user IDs, people rows, transcript text, audio references, file paths, titles, URLs, or raw payload rows are written",
        },
        "results": {
            name: rows_as_dicts(run_hogql(host, project_id, token, query))
            for name, query in queries.items()
        },
    }


def load_fixture(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProductTaskReportError(f"unable to read fixture {path}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("results"), dict):
        raise ProductTaskReportError("fixture must be a JSON object with a results object")
    data.setdefault("generated_at", datetime.now(timezone.utc).isoformat())
    data.setdefault("source", {"kind": "fixture", "privacy": "aggregate fixture counts only"})
    data.setdefault("window_days", 30)
    data.setdefault("app_version", None)
    return data


def as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def pct(numerator: int, denominator: int) -> str:
    if denominator <= 0:
        return "n/a"
    return f"{(numerator / denominator) * 100:.1f}%"


def event_devices(data: dict[str, Any]) -> dict[str, int]:
    return {
        str(row.get("event")): as_int(row.get("devices"))
        for row in data["results"].get("event_counts", [])
    }


def event_events(data: dict[str, Any]) -> dict[str, int]:
    return {
        str(row.get("event")): as_int(row.get("events"))
        for row in data["results"].get("event_counts", [])
    }


def build_activation_leak(data: dict[str, Any]) -> Finding:
    devices = event_devices(data)
    stages = [
        ("launch", devices.get("app_launched", 0), "Improve first-run reach and install-to-launch proof."),
        (
            "onboarding touched",
            max(devices.get("onboarding_shown", 0), devices.get("onboarding_step_viewed", 0)),
            "Make the first screen and permission path harder to miss.",
        ),
        ("permission ready", devices.get("onboarding_completed", 0), "Shorten the permission/model-ready path."),
        (
            "capture started",
            max(
                devices.get("onboarding_first_dictation_started", 0),
                devices.get("dictation_started", 0),
                devices.get("meeting_recording_started", 0),
            ),
            "Put the first successful capture action closer to launch."),
        (
            "first saved artifact",
            max(
                devices.get("activation_first_artifact_saved", 0),
                devices.get("onboarding_first_dictation_saved", 0),
                devices.get("meeting_transcript_saved", 0),
            ),
            "Make saved Markdown visible immediately after capture.",
        ),
        (
            "artifact action",
            devices.get("activation_artifact_action_clicked", 0),
            "Add a stronger open/copy/reveal moment after save.",
        ),
        (
            "agent signal",
            max(
                devices.get("activation_agent_prompt_action_clicked", 0),
                devices.get("activation_agent_setup_cta_clicked", 0),
                devices.get("onboarding_agent_cta_clicked", 0),
            ),
            "Make the first agent question explicit and copyable.",
        ),
        (
            "return proxy",
            devices.get("activation_return_proxy_observed", 0),
            "Nudge users back to yesterday's saved artifact."),
        (
            "true agent query",
            devices.get("agent_capture_query_observed", 0),
            "Instrument privacy-safe sourced-agent-use before calling the loop proven.",
        ),
    ]
    biggest = ("unknown", 0, 0, "Add more activation instrumentation.")
    previous_label, previous_count = stages[0][0], stages[0][1]
    for label, count, recommendation in stages[1:]:
        drop = max(previous_count - count, 0)
        if drop > biggest[1]:
            biggest = (f"{previous_label} -> {label}", drop, previous_count, recommendation)
        previous_label, previous_count = label, count
    rate = pct(biggest[1], biggest[2])
    return Finding(
        "Biggest activation leak",
        f"{biggest[0]} drops {biggest[1]} devices ({rate} of prior stage).",
        biggest[3],
        "high" if biggest[2] >= 10 else "medium",
        float(biggest[1]),
    )


def build_reliability_leak(data: dict[str, Any]) -> Finding:
    events = event_events(data)
    devices = event_devices(data)
    candidates = [
        (
            "Dictation start failure",
            events.get("dictation_start_failed", 0),
            max(events.get("dictation_started", 0) + events.get("dictation_start_failed", 0), 1),
            "Add a clearer retry/recovery path for dictation start failures.",
            ("dictation_start_failed",),
        ),
        (
            "Dictation no-speech",
            events.get("dictation_no_speech", 0),
            max(events.get("dictation_started", 0), 1),
            "Tune no-speech guidance and route-readiness recovery.",
            ("dictation_no_speech",),
        ),
        (
            "Meeting start failure",
            events.get("meeting_recording_start_failed", 0),
            max(events.get("meeting_recording_started", 0) + events.get("meeting_recording_start_failed", 0), 1),
            "Tighten meeting permission/route preflight before start.",
            ("meeting_recording_start_failed",),
        ),
        (
            "Meeting transcript failure",
            events.get("meeting_transcript_failed", 0) + events.get("meeting_transcript_skipped", 0),
            max(
                events.get("meeting_transcript_saved", 0)
                + events.get("meeting_transcript_failed", 0)
                + events.get("meeting_transcript_skipped", 0),
                1,
            ),
            "Improve failed/queued meeting transcript recovery and retained-audio retry.",
            ("meeting_transcript_failed", "meeting_transcript_skipped"),
        ),
    ]
    title, count, base, recommendation, matching_events = max(candidates, key=lambda item: (item[1] / item[2], item[1], item[0]))
    breakdown = data["results"].get("reliability_breakdown", [])
    matching_breakdown = [row for row in breakdown if row.get("event") in matching_events]
    top_kind = ""
    if matching_breakdown:
        top = max(matching_breakdown, key=lambda row: as_int(row.get("events")))
        failure_kind = top.get("failure_kind") or "unknown"
        trigger = top.get("trigger") or "any trigger"
        top_kind = f" Top breakdown: {top.get('event')} / {failure_kind} / {trigger}."
    return Finding(
        "Biggest reliability leak",
        f"{title}: {count} failure events, {pct(count, base)} of relevant attempts.{top_kind}",
        recommendation,
        "high" if count >= 5 else "medium" if count else "low",
        (count / base) * 1000 + count,
    )


def build_adoption_signal(data: dict[str, Any]) -> Finding:
    rows = data["results"].get("adoption_breakdown", [])
    if rows:
        top = max(rows, key=lambda row: (as_int(row.get("devices")), as_int(row.get("events"))))
        event = top.get("event") or "unknown"
        detail = top.get("action_kind") or top.get("agent_target") or top.get("page_id") or top.get("artifact_kind") or "all"
        devices = as_int(top.get("devices"))
        return Finding(
            "Strongest adoption signal",
            f"{event} / {detail}: {devices} devices.",
            "Double down on the surface that already gets used; make its next step obvious.",
            "high" if devices >= 10 else "medium",
            float(devices),
        )
    devices = event_devices(data)
    event = max(devices, key=devices.get) if devices else "unknown"
    count = devices.get(event, 0)
    return Finding(
        "Strongest adoption signal",
        f"{event}: {count} devices.",
        "Use the strongest current behavior as the entry point for the next activation prompt.",
        "medium",
        float(count),
    )


def build_under_discovered_feature(data: dict[str, Any]) -> Finding:
    devices = event_devices(data)
    wau = devices.get("app_launched", 0)
    candidates = [
        ("Agent setup", max(devices.get("activation_agent_setup_cta_clicked", 0), devices.get("onboarding_agent_cta_clicked", 0)), 5, "Surface Claude/MCP setup immediately after the first saved artifact."),
        ("Agent prompt copy", devices.get("activation_agent_prompt_action_clicked", 0), 4, "Put the first sourced question beside Open Markdown."),
        ("Meeting import", devices.get("meeting_file_imported", 0), 3, "Expose imported-audio transcription from Home for users who missed live capture."),
        ("Saved-audio retranscription", devices.get("meeting_saved_audio_retranscription_requested", 0), 2, "Make retry from retained meeting audio clearer after transcript failure."),
        ("Meeting prompt acceptance", devices.get("meeting_prompt_record_selected", 0), 2, "Clarify detected-meeting prompts and route readiness."),
    ]
    under = [
        item for item in candidates
        if wau <= 0 or item[1] <= max(2, int(wau * 0.2))
    ]
    name, count, _, recommendation = min(under or candidates, key=lambda item: (item[1], -item[2], item[0]))
    return Finding(
        "Under-discovered feature",
        f"{name}: {count} devices ({pct(count, wau)} of launch devices).",
        recommendation,
        "high" if wau >= 10 else "medium",
        float(max(wau - count, 0)),
    )


def build_prompt_quality(data: dict[str, Any]) -> Finding:
    rows = data["results"].get("meeting_prompt_quality", [])
    shown = sum(as_int(row.get("shown_events")) for row in rows)
    accepted = sum(as_int(row.get("record_selected_events")) for row in rows)
    dismissed = sum(as_int(row.get("dismissed_events")) for row in rows)
    suppressed = sum(as_int(row.get("suppressed_events")) for row in rows)
    if shown <= 0 and accepted <= 0:
        return Finding(
            "Meeting prompt quality",
            "No meeting prompt rows in this window.",
            "Keep prompt quality UNKNOWN until prompt rows appear.",
            "low",
            0,
        )
    friction = dismissed + suppressed
    return Finding(
        "Meeting prompt quality",
        f"shown={shown}, accepted={accepted}, dismissed_or_suppressed={friction}, acceptance={pct(accepted, shown)}.",
        "If dismissal/suppression beats acceptance, inspect route-ready and missing-permission buckets before changing prompt copy.",
        "high" if shown >= 10 else "medium",
        float(friction - accepted),
    )


def build_speaker_trust(data: dict[str, Any]) -> Finding:
    rows = data["results"].get("speaker_trust", [])
    reviewed = sum(as_int(row.get("events")) for row in rows if row.get("event") == "meeting_speaker_match_reviewed")
    corrected = sum(as_int(row.get("events")) for row in rows if row.get("review_action") == "corrected")
    review_later = sum(as_int(row.get("events")) for row in rows if row.get("completion_kind") == "review_later")
    failures = sum(as_int(row.get("events")) for row in rows if row.get("event") == "meeting_speaker_finalization_failed")
    total_signal = reviewed + review_later + failures
    if total_signal <= 0:
        return Finding(
            "Speaker trust",
            "No speaker review/trust rows in this window.",
            "Keep speaker trust UNKNOWN until review or auto-recognition rows appear.",
            "low",
            0,
        )
    return Finding(
        "Speaker trust",
        f"reviewed={reviewed}, corrected={corrected}, review_later={review_later}, finalization_failures={failures}.",
        "Prioritize speaker trust when corrections, review-later, or finalization failures are visible.",
        "high" if total_signal >= 10 else "medium",
        float(corrected + review_later + failures * 2),
    )


def build_onboarding_friction(data: dict[str, Any]) -> Finding:
    rows = data["results"].get("onboarding_friction", [])
    if not rows:
        return Finding(
            "Onboarding friction",
            "No explicit onboarding-friction rows in this window.",
            "Use the activation ladder until step-level friction rows appear.",
            "low",
            0,
        )
    top = max(rows, key=lambda row: (as_int(row.get("events")), as_int(row.get("devices"))))
    event = top.get("event") or "unknown"
    detail = top.get("step_id") or top.get("stage") or top.get("permission_kind") or top.get("reason_kind") or "all"
    events = as_int(top.get("events"))
    return Finding(
        "Onboarding friction",
        f"{event} / {detail}: {events} events.",
        "Trim or clarify the first-run step that produces the largest explicit friction bucket.",
        "high" if events >= 10 else "medium",
        float(events),
    )


def build_timeline_dayflow(data: dict[str, Any]) -> Finding:
    rows = data["results"].get("timeline_dayflow", [])
    events = sum(as_int(row.get("events")) for row in rows)
    devices = sum(as_int(row.get("devices")) for row in rows)
    if events <= 0:
        return Finding(
            "Timeline Dayflow",
            "No timeline/dayflow analytics rows in this window.",
            "Keep timeline/dayflow UNKNOWN; do not fold planned timeline assumptions into shipped product health.",
            "low",
            0,
        )
    top = max(rows, key=lambda row: (as_int(row.get("events")), as_int(row.get("devices"))))
    return Finding(
        "Timeline Dayflow",
        f"{events} events across up to {devices} aggregate device-buckets; top={top.get('event')}.",
        "Use timeline rows as their own adoption read, separate from meeting/dictation release health.",
        "medium",
        float(events),
    )


def build_release_watch(data: dict[str, Any]) -> Finding:
    rows = [row for row in data["results"].get("release_breakdown", []) if row.get("app_version")]
    if not rows:
        return Finding(
            "Release regression watch",
            "No app-version rows in this window.",
            "Keep release-health UNKNOWN until PostHog app_version rows appear.",
            "low",
            0,
        )
    watched = max(
        rows,
        key=lambda row: (
            as_int(row.get("failure_events")) / max(as_int(row.get("launch_devices")), 1),
            as_int(row.get("failure_events")),
            str(row.get("last_seen") or ""),
        ),
    )
    launches = as_int(watched.get("launch_devices"))
    successes = as_int(watched.get("success_devices"))
    failures = as_int(watched.get("failure_events"))
    version = watched.get("app_version")
    if launches and successes == 0:
        recommendation = "Watch this version for install/update friction: launch exists but no first success signal yet."
    elif failures:
        recommendation = "Compare this version against Sentry and recent PRs before calling the release clean."
    else:
        recommendation = "No release regression from aggregate PostHog counts; keep watching Sentry for sparse fatals."
    return Finding(
        "Release regression watch",
        f"{version}: launches={launches}, success_devices={successes}, failure_events={failures}.",
        recommendation,
        "medium" if launches < 10 or failures else "high",
        (failures / max(launches, 1)) * 1000 + max(0, launches - successes),
    )


def task_priority_score(finding: Finding) -> float:
    if finding.title == "Release regression watch":
        return min(finding.score / 50, 20)
    if finding.title == "Under-discovered feature":
        return min(finding.score, 20)
    if finding.title == "Strongest adoption signal":
        return min(finding.score / 2, 10)
    return min(finding.score, 20)


def task_candidates(findings: dict[str, Finding]) -> list[Finding]:
    pinned = [findings["activation"], findings["reliability"]]
    pool = [findings["release"], findings["under"], findings["adoption"]]
    third = max(pool, key=lambda item: (task_priority_score(item), item.title))
    return sorted([*pinned, third], key=lambda item: (-task_priority_score(item), item.title))


def dashboard_lines(data: dict[str, Any], findings: dict[str, Finding]) -> list[str]:
    devices = event_devices(data)
    events = event_events(data)
    wau = devices.get("app_launched", 0)
    dau_rows = data["results"].get("daily_active", [])
    latest_dau = as_int(dau_rows[-1].get("active_devices")) if dau_rows else 0
    activation = findings["activation"]
    reliability = findings["reliability"]
    adoption = findings["adoption"]
    under = findings["under"]
    release = findings["release"]
    return [
        f"- 100 WAU Operating: {wau} active launch devices; latest DAU row is {latest_dau}.",
        f"- Activation: {activation.metric}",
        f"- Meeting Prompt Quality: {findings['prompt'].metric}",
        f"- Artifact Usefulness: {adoption.metric}",
        f"- Agent Payoff: true_agent_query_devices={devices.get('agent_capture_query_observed', 0)}, agent_prompt_devices={devices.get('activation_agent_prompt_action_clicked', 0)}, return_proxy_devices={devices.get('activation_return_proxy_observed', 0)}.",
        f"- Speaker Trust: {findings['speaker'].metric}",
        f"- Retry Recovery: {reliability.metric}",
        f"- Onboarding Friction: {findings['onboarding'].metric}",
        f"- Timeline Dayflow: {findings['timeline'].metric}",
        f"- Release Health: {release.metric}",
        f"- Core event volume: launches={events.get('app_launched', 0)}, dictations_completed={events.get('dictation_completed', 0)}, meetings_saved={events.get('meeting_transcript_saved', 0)}.",
    ]


def render_json(data: dict[str, Any], findings: dict[str, Finding]) -> dict[str, Any]:
    ordered = [
        findings["activation"],
        findings["reliability"],
        findings["adoption"],
        findings["under"],
        findings["prompt"],
        findings["speaker"],
        findings["onboarding"],
        findings["timeline"],
        findings["release"],
    ]
    return {
        "generated_at": data["generated_at"],
        "window_days": data["window_days"],
        "app_version": data.get("app_version"),
        "source": data.get("source", {}),
        "dashboards": dashboard_lines(data, findings),
        "findings": {
            "biggest_activation_leak": findings["activation"].__dict__,
            "biggest_reliability_leak": findings["reliability"].__dict__,
            "strongest_adoption_signal": findings["adoption"].__dict__,
            "under_discovered_feature": findings["under"].__dict__,
            "meeting_prompt_quality": findings["prompt"].__dict__,
            "speaker_trust": findings["speaker"].__dict__,
            "onboarding_friction": findings["onboarding"].__dict__,
            "timeline_dayflow": findings["timeline"].__dict__,
            "release_regression_watch": findings["release"].__dict__,
        },
        "top_recommended_tasks": [finding.__dict__ for finding in task_candidates(findings)],
    }


def render_markdown(data: dict[str, Any], findings: dict[str, Finding]) -> str:
    result = render_json(data, findings)
    tasks = result["top_recommended_tasks"]
    lines = [
        "# Transcripted PostHog Product Task Report",
        "",
        f"Generated: {data['generated_at']}",
        f"Window: last {data['window_days']} days, {data.get('app_version') or 'all app versions'}",
        "",
        "Source: aggregate PostHog signal only. This report writes counts and enum buckets, not user rows, transcript text, audio references, file paths, meeting titles, URLs, or raw payloads.",
        "",
        "## Dashboard Families",
        "",
        *result["dashboards"],
        "",
        "## Required Read",
        "",
        f"- Biggest activation leak: {findings['activation'].metric} {findings['activation'].recommendation}",
        f"- Biggest reliability leak: {findings['reliability'].metric} {findings['reliability'].recommendation}",
        f"- Meeting prompt quality: {findings['prompt'].metric} {findings['prompt'].recommendation}",
        f"- Strongest adoption signal: {findings['adoption'].metric} {findings['adoption'].recommendation}",
        f"- Under-discovered feature: {findings['under'].metric} {findings['under'].recommendation}",
        f"- Speaker trust: {findings['speaker'].metric} {findings['speaker'].recommendation}",
        f"- Onboarding friction: {findings['onboarding'].metric} {findings['onboarding'].recommendation}",
        f"- Timeline Dayflow: {findings['timeline'].metric} {findings['timeline'].recommendation}",
        f"- Release regression watch: {findings['release'].metric} {findings['release'].recommendation}",
        "",
        "## Top 3 Recommended PR/Task Candidates",
        "",
    ]
    for index, task in enumerate(tasks, start=1):
        lines.append(f"{index}. {task['title']}: {task['recommendation']} ({task['metric']})")
    lines.extend([
        "",
        "## Privacy Boundary",
        "",
        "- Aggregate only. No raw rows or user-level forensics.",
        "- Treat agent setup, prompt copy, and return events as proxies; `agent_capture_query_observed` is the stronger saved-capture query proof, but not answer-quality proof.",
        "",
    ])
    return "\n".join(lines)


def analyze(data: dict[str, Any]) -> dict[str, Finding]:
    return {
        "activation": build_activation_leak(data),
        "reliability": build_reliability_leak(data),
        "adoption": build_adoption_signal(data),
        "under": build_under_discovered_feature(data),
        "prompt": build_prompt_quality(data),
        "speaker": build_speaker_trust(data),
        "onboarding": build_onboarding_friction(data),
        "timeline": build_timeline_dayflow(data),
        "release": build_release_watch(data),
    }


def write_outputs(data: dict[str, Any], markdown: str, summary: dict[str, Any], write_dir: Path | None) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-product-tasks") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    report_path = output_dir / "product-task-report.md"
    data_path = output_dir / "product-task-report.json"
    report_path.write_text(markdown, encoding="utf-8")
    data_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    return report_path, data_path


def run_self_test() -> int:
    fixture_path = Path(__file__).resolve().parents[2] / "Tests" / "Fixtures" / "posthog-product-dashboard-summary.json"
    if not fixture_path.is_file():
        print(f"self-test failed: missing fixture {fixture_path}", file=sys.stderr)
        return 1
    data = load_fixture(fixture_path)
    findings = analyze(data)
    markdown = render_markdown(data, findings)
    summary = render_json(data, findings)
    required = (
        "Biggest activation leak",
        "Biggest reliability leak",
        "Meeting prompt quality",
        "Strongest adoption signal",
        "Under-discovered feature",
        "Speaker trust",
        "Onboarding friction",
        "Timeline Dayflow",
        "Release regression watch",
        "Top 3 Recommended PR/Task Candidates",
    )
    missing = [item for item in required if item not in markdown]
    if missing:
        print(f"self-test failed: missing sections: {', '.join(missing)}", file=sys.stderr)
        return 1
    forbidden = ("distinct_id", "transcript_text", "audio_path", "meeting_title", "raw_url", "person_id")
    lowered = (markdown + json.dumps(summary, sort_keys=True)).lower()
    leaked = [fragment for fragment in forbidden if fragment in lowered]
    if leaked:
        print(f"self-test failed: unsafe fragment in output: {', '.join(leaked)}", file=sys.stderr)
        return 1
    if len(summary["top_recommended_tasks"]) != 3:
        print("self-test failed: expected exactly three top task candidates", file=sys.stderr)
        return 1
    mismatch_data = json.loads(json.dumps(data))
    mismatch_data["results"]["reliability_breakdown"] = [
        {"event": "dictation_no_speech", "events": 99, "failure_kind": "quiet_input", "trigger": "hotkey"},
        {"event": "meeting_transcript_failed", "events": 5, "failure_kind": "decoder_start", "trigger": "menu"},
    ]
    mismatch_metric = build_reliability_leak(mismatch_data).metric
    if "Meeting transcript failure" not in mismatch_metric or "meeting_transcript_failed" not in mismatch_metric or "dictation_no_speech" in mismatch_metric:
        print("self-test failed: reliability breakdown did not stay tied to selected leak", file=sys.stderr)
        return 1
    for query in (
        event_counts_query(30, None),
        daily_active_query(30, None),
        reliability_breakdown_query(30, None),
        adoption_breakdown_query(30, None),
        meeting_prompt_quality_query(30, None),
        speaker_trust_query(30, None),
        onboarding_friction_query(30, None),
        timeline_dayflow_query(30, None),
        release_breakdown_query(30),
    ):
        if "SELECT *" in query.upper():
            print("self-test failed: query uses SELECT *", file=sys.stderr)
            return 1
    print("self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version filter for non-release queries, e.g. 1.1.48.")
    parser.add_argument("--fixture", type=Path, help="Read aggregate fixture JSON instead of querying PostHog.")
    parser.add_argument("--write-dir", type=Path, help="Directory for product-task-report.md and product-task-report.json.")
    parser.add_argument("--json-only", action="store_true", help="Print the JSON summary instead of Markdown.")
    parser.add_argument("--summary-only", action="store_true", help="Print only dashboard and top task lines.")
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
        data = load_fixture(args.fixture) if args.fixture else fetch_report_data(args.days, args.app_version)
        findings = analyze(data)
        markdown = render_markdown(data, findings)
        summary = render_json(data, findings)
        if args.write_dir or not (args.json_only or args.summary_only):
            report_path, data_path = write_outputs(data, markdown, summary, args.write_dir)
        else:
            report_path = None
            data_path = None
    except ProductTaskReportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 3

    if args.json_only:
        print(json.dumps(summary, indent=2, sort_keys=True))
    elif args.summary_only:
        for line in summary["dashboards"]:
            print(line)
        print("Top recommended tasks:")
        for index, task in enumerate(summary["top_recommended_tasks"], start=1):
            print(f"{index}. {task['title']}: {task['recommendation']}")
        if report_path and data_path:
            print(f"Report written: {report_path}")
            print(f"Data written: {data_path}")
    else:
        print(markdown)
        if report_path and data_path:
            print(f"Report written: {report_path}")
            print(f"Data written: {data_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
