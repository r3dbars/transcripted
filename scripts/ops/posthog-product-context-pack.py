#!/usr/bin/env python3
"""Build a compact, privacy-safe PostHog product context pack for agents."""

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

SAFE_EVENTS = (
    "app_launched",
    "onboarding_shown",
    "onboarding_step_viewed",
    "onboarding_completed",
    "dictation_started",
    "dictation_start_failed",
    "dictation_completed",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "activation_first_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "onboarding_agent_cta_clicked",
    "activation_return_proxy_observed",
    "agent_capture_query_observed",
    "update_check_finished",
    "update_download_finished",
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
)

FAILURE_EVENTS = (
    "dictation_start_failed",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_start_failed",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
    "update_check_finished",
    "update_download_finished",
)

NON_UPDATE_FAILURE_EVENTS = (
    "dictation_start_failed",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_start_failed",
    "meeting_transcript_failed",
    "meeting_transcript_skipped",
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
    "payload",
    "properties",
}


class ContextPackError(RuntimeError):
    pass


@dataclass(frozen=True)
class UnknownReason:
    field: str
    reason: str


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
        raise ContextPackError("missing " + ", ".join(missing))
    if not host.startswith("https://"):
        raise ContextPackError(f"refusing non-HTTPS PostHog host: {host}")
    if host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1":
        raise ContextPackError(
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
        raise ContextPackError(f"PostHog query failed with HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ContextPackError(f"PostHog query failed: {exc}") from exc


def rows_as_dicts(response: dict[str, Any]) -> list[dict[str, Any]]:
    columns = response.get("columns") or []
    rows = response.get("results") or response.get("data") or []
    unsafe = [
        str(column)
        for column in columns
        if any(fragment in str(column).lower() for fragment in DISALLOWED_OUTPUT_COLUMNS)
    ]
    if unsafe:
        raise ContextPackError(f"query attempted to expose unsafe output columns: {', '.join(unsafe)}")
    return [
        {str(column): row[index] if index < len(row) else None for index, column in enumerate(columns)}
        for row in rows
    ]


def overview_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  uniqIf(distinct_id, event = 'app_launched') AS launch_devices,
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event = 'activation_agent_prompt_action_clicked') AS agent_prompt_devices,
  uniqIf(distinct_id, event IN ('activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked')) AS agent_setup_devices,
  uniqIf(distinct_id, event = 'agent_capture_query_observed') AS true_agent_query_devices,
  uniqIf(distinct_id, event = 'activation_return_proxy_observed') AS return_proxy_devices,
  uniqIf(distinct_id, event = 'dictation_completed') AS dictation_completed_devices,
  uniqIf(distinct_id, event = 'meeting_transcript_saved') AS meeting_saved_devices,
  uniqIf(distinct_id, event IN ({sql_list(WORKFLOW_EVENTS)})) AS workflow_devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(SAFE_EVENTS)})
  {app_version_filter(app_version)}
"""


def event_counts_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT event, count() AS events, uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(SAFE_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY event
ORDER BY devices DESC, events DESC
"""


def reliability_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  event,
  coalesce(properties['failure_kind'], properties['reason'], properties['failure_code'], 'unknown') AS failure_kind,
  coalesce(properties['capture_quality'], 'unknown') AS capture_quality,
  coalesce(properties['result'], 'unknown') AS result,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND (
    event IN ({sql_list(NON_UPDATE_FAILURE_EVENTS)})
    OR (
      event IN ('update_check_finished', 'update_download_finished')
      AND (
        isNotNull(properties['failure_kind'])
        OR isNotNull(properties['failure_code'])
        OR properties['result'] IN ('failed', 'error')
      )
    )
  )
  {app_version_filter(app_version)}
GROUP BY event, failure_kind, capture_quality, result
ORDER BY devices DESC, events DESC
LIMIT 20
"""


def release_versions_query(days: int) -> str:
    return f"""
SELECT
  coalesce(properties['app_version'], 'unknown') AS app_version,
  uniq(distinct_id) AS active_devices,
  countIf(event IN ({sql_list(WORKFLOW_EVENTS)})) AS workflow_events,
  uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices,
  uniqIf(distinct_id, event IN ('dictation_completed', 'meeting_transcript_saved')) AS success_devices,
  uniqIf(
    distinct_id,
    event IN ({sql_list(NON_UPDATE_FAILURE_EVENTS)})
    OR (
      event IN ('update_check_finished', 'update_download_finished')
      AND (
        isNotNull(properties['failure_kind'])
        OR isNotNull(properties['failure_code'])
        OR properties['result'] IN ('failed', 'error')
      )
    )
  ) AS failure_devices,
  countIf(
    event IN ({sql_list(NON_UPDATE_FAILURE_EVENTS)})
    OR (
      event IN ('update_check_finished', 'update_download_finished')
      AND (
        isNotNull(properties['failure_kind'])
        OR isNotNull(properties['failure_code'])
        OR properties['result'] IN ('failed', 'error')
      )
    )
  ) AS failure_events
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(SAFE_EVENTS)})
GROUP BY app_version
ORDER BY active_devices DESC, workflow_events DESC
LIMIT 12
"""


def feature_breakdown_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT
  multiIf(
    event IN ('dictation_started', 'dictation_completed'), 'dictation',
    event IN ('meeting_recording_started', 'meeting_transcript_saved'), 'meetings',
    event IN ('activation_artifact_action_clicked', 'activation_first_artifact_saved'), 'artifact_actions',
    event IN ('activation_agent_prompt_action_clicked', 'activation_agent_setup_cta_clicked', 'onboarding_agent_cta_clicked'), 'agent_bridge',
    event IN ('update_check_finished', 'update_download_finished'), 'updates',
    'other'
  ) AS feature,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(days)} DAY
  AND event IN ({sql_list(SAFE_EVENTS)})
  {app_version_filter(app_version)}
GROUP BY feature
HAVING feature NOT IN ('other', 'updates')
ORDER BY devices DESC, events DESC
"""


def repeat_breakdown_query(days: int, app_version: str | None) -> str:
    return f"""
SELECT signal, events, devices
FROM (
  SELECT 'activation_return_proxy_observed' AS signal, count() AS events, uniq(distinct_id) AS devices
  FROM events
  WHERE timestamp >= now() - INTERVAL {int(days)} DAY
    AND event = 'activation_return_proxy_observed'
    {app_version_filter(app_version)}
  UNION ALL
  SELECT 'multi_artifact_proxy' AS signal, sum(artifact_events) AS events, count() AS devices
  FROM (
    SELECT distinct_id, count() AS artifact_events
    FROM events
    WHERE timestamp >= now() - INTERVAL {int(days)} DAY
      AND event IN ('activation_first_artifact_saved', 'meeting_transcript_saved', 'dictation_completed')
      {app_version_filter(app_version)}
    GROUP BY distinct_id
    HAVING artifact_events >= 2
  )
)
ORDER BY devices DESC, events DESC
"""


def fetch_report_data(days: int, app_version: str | None, fixture_path: Path | None) -> dict[str, Any]:
    if fixture_path:
        return json.loads(fixture_path.read_text(encoding="utf-8"))

    load_env()
    host, project_id, token = posthog_config()
    queries = {
        "overview": overview_query(days, app_version),
        "event_counts": event_counts_query(days, app_version),
        "reliability_breakdown": reliability_query(days, app_version),
        "release_versions": release_versions_query(days),
        "feature_breakdown": feature_breakdown_query(days, app_version),
        "repeat_breakdown": repeat_breakdown_query(days, app_version),
    }
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "posthog_hogql_aggregate",
            "host": host,
            "project": "configured PostHog project",
            "privacy": "aggregate counts and enum breakdowns only; no distinct IDs, people rows, transcript text, paths, titles, URLs, raw payloads, or identifying event properties are written",
        },
        "results": {
            name: rows_as_dicts(run_hogql(host, project_id, token, query))
            for name, query in queries.items()
        },
    }


def unknown_data(reason: str, days: int, app_version: str | None) -> dict[str, Any]:
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window_days": days,
        "app_version": app_version,
        "source": {
            "kind": "unknown",
            "privacy": "aggregate-only context pack was requested, but PostHog aggregate data was unavailable",
            "error": reason,
        },
        "results": {
            "overview": [],
            "event_counts": [],
            "reliability_breakdown": [],
            "release_versions": [],
            "feature_breakdown": [],
            "repeat_breakdown": [],
        },
    }


def as_int(value: Any) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def pct(numerator: int, denominator: int) -> float | None:
    if denominator <= 0:
        return None
    return round((numerator / denominator) * 100, 1)


def status_label(value: Any) -> str:
    return "UNKNOWN" if value is None else "OBSERVED"


def top_row(rows: list[dict[str, Any]], metric: str = "devices") -> dict[str, Any] | None:
    if not rows:
        return None
    return max(rows, key=lambda row: (as_int(row.get(metric)), as_int(row.get("events"))))


def event_count(results: dict[str, Any], event: str) -> int:
    for row in results.get("event_counts", []):
        if row.get("event") == event:
            return as_int(row.get("events"))
    return 0


def event_devices(results: dict[str, Any], event: str) -> int:
    for row in results.get("event_counts", []):
        if row.get("event") == event:
            return as_int(row.get("devices"))
    return 0


def reliability_descriptor(row: dict[str, Any] | None) -> str:
    if not row:
        return "UNKNOWN: no reliability failure rows in this window."
    event = str(row.get("event") or "unknown")
    failure_kind = str(row.get("failure_kind") or "unknown")
    result = str(row.get("result") or "unknown")
    if failure_kind != "unknown":
        return f"{event} / {failure_kind}"
    if result != "unknown":
        return f"{event} / result={result}"
    return event


def build_context_pack(data: dict[str, Any]) -> dict[str, Any]:
    results = data.get("results", {})
    overview = (results.get("overview") or [{}])[0]
    launch = as_int(overview.get("launch_devices"))
    first_artifact = as_int(overview.get("first_artifact_devices"))
    agent_prompt = as_int(overview.get("agent_prompt_devices"))
    agent_setup = as_int(overview.get("agent_setup_devices"))
    true_agent_query = as_int(overview.get("true_agent_query_devices"))
    return_proxy = as_int(overview.get("return_proxy_devices"))
    dictation_completed = as_int(overview.get("dictation_completed_devices"))
    meeting_saved = as_int(overview.get("meeting_saved_devices"))
    workflow_devices = as_int(overview.get("workflow_devices"))

    unknowns: list[UnknownReason] = []
    if not results.get("overview"):
        unknowns.append(UnknownReason("activation", "PostHog overview query did not return aggregate rows."))
    if launch <= 0:
        unknowns.append(UnknownReason("activation.bottleneck", "No launch devices were available for the selected window."))
    if true_agent_query == 0:
        unknowns.append(UnknownReason("activation.true_agent_use", "`agent_capture_query_observed` is missing or zero; prompt/setup clicks are intent proxies only."))

    artifact_rate = pct(first_artifact, launch)
    prompt_rate = pct(agent_prompt, first_artifact)
    return_rate = pct(return_proxy, first_artifact)

    if artifact_rate is None:
        bottleneck = "UNKNOWN: missing launch denominator."
    elif artifact_rate < 20:
        bottleneck = "Too few launch devices reach first saved Markdown."
    elif true_agent_query == 0 and agent_prompt > 0:
        bottleneck = "Saved artifacts and agent intent exist, but true sourced-agent-use is still unproven."
    elif agent_prompt < first_artifact:
        bottleneck = "Saved Markdown is not consistently turning into agent handoff."
    else:
        bottleneck = "No obvious activation bottleneck in aggregate PostHog data."

    reliability_top = top_row(results.get("reliability_breakdown", []))
    if reliability_top:
        reliability_status = "OBSERVED"
        reliability_pain = reliability_descriptor(reliability_top)
    else:
        reliability_status = "UNKNOWN"
        reliability_pain = "UNKNOWN: no reliability failure rows in this window."
        unknowns.append(UnknownReason("reliability.highest_pain", "No reliability failure aggregates were returned."))

    release_rows = results.get("release_versions", [])
    release_top = top_row(release_rows, "active_devices")
    release_anomaly = "UNKNOWN: release-version aggregates missing."
    release_status = "UNKNOWN"
    latest_release = data.get("app_version") or (release_top or {}).get("app_version") or "UNKNOWN"
    if release_rows:
        release_status = "OBSERVED"
        active_total = sum(as_int(row.get("active_devices")) for row in release_rows)
        unknown_release = next((row for row in release_rows if str(row.get("app_version")) == "unknown"), None)
        unknown_share = pct(as_int((unknown_release or {}).get("active_devices")), active_total)
        failing_versions = sorted(
            [
                row for row in release_rows
                if as_int(row.get("active_devices")) >= 3
                and as_int(row.get("failure_devices", row.get("failure_events"))) > as_int(row.get("success_devices"))
            ],
            key=lambda row: (
                as_int(row.get("failure_devices", row.get("failure_events"))) - as_int(row.get("success_devices")),
                as_int(row.get("failure_devices", row.get("failure_events"))),
            ),
            reverse=True,
        )
        if unknown_share is not None and unknown_share >= 10:
            release_anomaly = f"{unknown_share}% of active devices have unknown app_version."
        elif failing_versions:
            failing = failing_versions[0]
            release_anomaly = f"{failing.get('app_version')} has more failure devices than success devices."
        else:
            release_anomaly = "No obvious release-version anomaly in aggregate PostHog data."
    else:
        unknowns.append(UnknownReason("release.anomaly", "No app_version aggregate rows were returned."))

    feature_top = top_row(results.get("feature_breakdown", []))
    if feature_top:
        feature_status = "OBSERVED"
        feature_signal = f"{feature_top.get('feature')} leads adoption by active devices."
    else:
        feature_status = "UNKNOWN"
        feature_signal = "UNKNOWN: no feature adoption aggregates returned."
        unknowns.append(UnknownReason("feature_adoption.strongest_signal", "No feature adoption aggregate rows were returned."))

    repeat_top = top_row(results.get("repeat_breakdown", []))
    if repeat_top:
        repeat_status = "OBSERVED"
        repeat_signal = f"{repeat_top.get('signal')} with {as_int(repeat_top.get('devices'))} devices."
    else:
        repeat_status = "UNKNOWN"
        repeat_signal = "UNKNOWN: no repeat-use aggregates returned."
        unknowns.append(UnknownReason("activation.strongest_repeat_use_signal", "No repeat-use aggregate rows were returned."))

    recommendations = build_recommendations(
        launch=launch,
        first_artifact=first_artifact,
        agent_prompt=agent_prompt,
        true_agent_query=true_agent_query,
        return_proxy=return_proxy,
        reliability_top=reliability_top,
        release_anomaly=release_anomaly,
        feature_top=feature_top,
    )

    return {
        "generated_at": data.get("generated_at"),
        "release": {
            "status": release_status,
            "current": latest_release,
            "window_days": data.get("window_days"),
            "anomaly": release_anomaly,
            "versions": release_rows[:5],
        },
        "activation": {
            "status": status_label(artifact_rate),
            "current_bottleneck": bottleneck,
            "launch_devices": launch,
            "first_artifact_devices": first_artifact,
            "first_artifact_rate_pct": artifact_rate,
            "agent_prompt_devices": agent_prompt,
            "agent_setup_devices": agent_setup,
            "agent_prompt_per_first_artifact_pct": prompt_rate,
            "true_agent_query_devices": true_agent_query,
            "return_proxy_devices": return_proxy,
            "return_proxy_per_first_artifact_pct": return_rate,
            "strongest_repeat_use_signal": {
                "status": repeat_status,
                "summary": repeat_signal,
                "top_row": repeat_top,
            },
        },
        "reliability": {
            "status": reliability_status,
            "highest_pain": reliability_pain,
            "top_row": reliability_top,
            "failure_rows": results.get("reliability_breakdown", [])[:5],
        },
        "feature_adoption": {
            "status": feature_status,
            "strongest_signal": feature_signal,
            "dictation_completed_devices": dictation_completed,
            "meeting_saved_devices": meeting_saved,
            "workflow_devices": workflow_devices,
            "features": results.get("feature_breakdown", [])[:8],
        },
        "data_quality": {
            "source": data.get("source", {}),
            "unknowns": [reason.__dict__ for reason in unknowns],
            "privacy": "Aggregate counts and enum properties only. No raw user rows, distinct IDs, transcript text, titles, paths, URLs, names, emails, tokens, or raw payloads.",
        },
        "recommendations": recommendations,
    }


def build_recommendations(
    *,
    launch: int,
    first_artifact: int,
    agent_prompt: int,
    true_agent_query: int,
    return_proxy: int,
    reliability_top: dict[str, Any] | None,
    release_anomaly: str,
    feature_top: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    recs: list[dict[str, Any]] = []
    if true_agent_query == 0:
        recs.append({
            "rank": len(recs) + 1,
            "title": "Add privacy-safe sourced-agent-use proof",
            "why": "`agent_capture_query_observed` is missing or zero, so agents still cannot tell whether saved Markdown produced a sourced answer.",
            "suggested_pr": "Emit aggregate-only `agent_capture_query_observed` from the read-only MCP/agent surface with enum result, query kind, agent target, artifact kind, and age buckets.",
        })
    elif launch > 0 and first_artifact / launch < 0.2:
        recs.append({
            "rank": len(recs) + 1,
            "title": "Improve first saved Markdown reach",
            "why": "Launch volume is not turning into first saved artifacts at a healthy rate.",
            "suggested_pr": "Tighten Home/onboarding first-artifact guidance and failure recovery copy, then measure `activation_first_artifact_saved`.",
        })
    elif first_artifact > agent_prompt:
        recs.append({
            "rank": len(recs) + 1,
            "title": "Make agent handoff more obvious after save",
            "why": "Saved artifacts outnumber agent prompt/setup actions.",
            "suggested_pr": "Add a post-save agent question/action row for the newest artifact without exposing content.",
        })

    if reliability_top:
        recs.append({
            "rank": len(recs) + 1,
            "title": f"Fix top reliability pain: {reliability_top.get('event')}",
            "why": f"The largest aggregate pain bucket is `{reliability_descriptor(reliability_top)}` across {as_int(reliability_top.get('devices'))} devices.",
            "suggested_pr": "Add a focused recovery or explanation fix for this failure bucket, with tests around the coarse failure kind.",
        })

    if "unknown app_version" in release_anomaly or "failure devices" in release_anomaly:
        recs.append({
            "rank": len(recs) + 1,
            "title": "Tighten release-version health visibility",
            "why": release_anomaly,
            "suggested_pr": "Patch release/version metadata reporting or update-health handling so version-scoped PostHog reads stay trustworthy.",
        })

    if feature_top and feature_top.get("feature") == "dictation" and return_proxy == 0:
        recs.append({
            "rank": len(recs) + 1,
            "title": "Convert dictation usage into return habit",
            "why": "Dictation leads adoption, but no return proxy was observed.",
            "suggested_pr": "Surface recent dictations on Home with a copyable agent question and keep measuring `activation_return_proxy_observed`.",
        })

    fallback_recs = [
        {
            "title": "Keep the product-context pack in nightly health",
            "why": "Agents need a compact decision artifact, not a raw dashboard export.",
            "suggested_pr": "Have the health lane attach the generated JSON and Markdown paths when PostHog credentials are present.",
        },
        {
            "title": "Add second-artifact retention proof",
            "why": "Return proxy helps, but second saved artifact is a clearer habit signal.",
            "suggested_pr": "Add aggregate-only `activation_second_artifact_saved` with first/second artifact kinds and coarse days-since-first bucket.",
        },
    ]
    for item in fallback_recs:
        if len(recs) >= 3:
            break
        recs.append({"rank": len(recs) + 1, **item})
    return recs[:3]


def md_value(value: Any) -> str:
    if value is None:
        return "UNKNOWN"
    if isinstance(value, float):
        return f"{value:.1f}%"
    return str(value)


def render_markdown(pack: dict[str, Any]) -> str:
    rec_lines = [
        f"{item['rank']}. {item['title']} - {item['why']} PR: {item['suggested_pr']}"
        for item in pack.get("recommendations", [])
    ]
    unknowns = pack.get("data_quality", {}).get("unknowns", [])
    unknown_lines = [
        f"- {item.get('field')}: {item.get('reason')}"
        for item in unknowns
    ] or ["- none"]
    lines = [
        "# Transcripted PostHog Product Context Pack",
        "",
        f"Generated: {pack.get('generated_at')}",
        f"Release: {pack['release'].get('current')} ({pack['release'].get('status')})",
        "",
        "Source: aggregate PostHog data only. No raw users, distinct IDs, transcript text, file paths, meeting titles, URLs, names, emails, tokens, or raw payloads are exported.",
        "",
        "## Agent Read",
        "",
        f"- Activation bottleneck: {pack['activation'].get('current_bottleneck')}",
        f"- Strongest repeat-use signal: {pack['activation']['strongest_repeat_use_signal'].get('summary')}",
        f"- Highest reliability pain: {pack['reliability'].get('highest_pain')}",
        f"- Release-version anomaly: {pack['release'].get('anomaly')}",
        f"- Feature adoption signal: {pack['feature_adoption'].get('strongest_signal')}",
        "",
        "## Key Counts",
        "",
        f"- Launch devices: {pack['activation'].get('launch_devices')}",
        f"- First artifact devices: {pack['activation'].get('first_artifact_devices')} ({md_value(pack['activation'].get('first_artifact_rate_pct'))} of launch)",
        f"- Agent prompt devices: {pack['activation'].get('agent_prompt_devices')} ({md_value(pack['activation'].get('agent_prompt_per_first_artifact_pct'))} of first artifact)",
        f"- True agent-query devices: {pack['activation'].get('true_agent_query_devices')} (UNKNOWN if zero because the event may not exist yet)",
        f"- Return proxy devices: {pack['activation'].get('return_proxy_devices')} ({md_value(pack['activation'].get('return_proxy_per_first_artifact_pct'))} of first artifact)",
        "",
        "## Recommended Next PRs",
        "",
        "\n".join(rec_lines),
        "",
        "## UNKNOWN States",
        "",
        "\n".join(unknown_lines),
        "",
    ]
    return "\n".join(lines)


def write_outputs(pack: dict[str, Any], markdown: str, write_dir: Path | None) -> tuple[Path, Path]:
    output_dir = write_dir or Path("/tmp/transcripted-posthog-product-context") / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "product-context-pack.json"
    md_path = output_dir / "product-context-pack.md"
    json_path.write_text(json.dumps(pack, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(markdown, encoding="utf-8")
    return json_path, md_path


def run_self_test() -> int:
    fixture = Path("Tests/Fixtures/posthog-product-context-pack-fixture.json")
    data = fetch_report_data(30, None, fixture)
    pack = build_context_pack(data)
    markdown = render_markdown(pack)
    rendered = json.dumps(pack, sort_keys=True) + markdown
    forbidden = ("person_id", "transcript_text", "audio_path", "meeting_title", "raw_url", "@example", "@")
    leaked = [fragment for fragment in forbidden if fragment in rendered.lower()]
    if leaked:
        print(f"self-test failed: unsafe fragment in rendered output: {', '.join(leaked)}", file=sys.stderr)
        return 1
    if pack["activation"]["true_agent_query_devices"] != 0:
        print("self-test failed: fixture should preserve zero true-agent-query proof", file=sys.stderr)
        return 1
    if "onboarding_agent_cta_clicked" not in SAFE_EVENTS:
        print("self-test failed: onboarding agent setup events should be queryable", file=sys.stderr)
        return 1
    if not pack["recommendations"] or "sourced-agent-use" not in pack["recommendations"][0]["title"]:
        print("self-test failed: first recommendation should close agent-use proof", file=sys.stderr)
        return 1
    unknown = unknown_data("missing POSTHOG_PERSONAL_API_KEY", 30, None)
    unknown_pack = build_context_pack(unknown)
    if unknown_pack["activation"]["status"] != "UNKNOWN":
        print("self-test failed: missing-data pack should keep activation UNKNOWN", file=sys.stderr)
        return 1
    for query in (
        overview_query(30, None),
        event_counts_query(30, None),
        reliability_query(30, None),
        release_versions_query(30),
        feature_breakdown_query(30, None),
        repeat_breakdown_query(30, None),
    ):
        if "SELECT *" in query.upper():
            print("self-test failed: query uses SELECT *", file=sys.stderr)
            return 1
    print("product-context self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="Lookback window in days.")
    parser.add_argument("--app-version", help="Optional app_version filter, e.g. 1.1.48.")
    parser.add_argument("--fixture", type=Path, help="Read aggregate fixture JSON instead of querying PostHog.")
    parser.add_argument("--write-dir", type=Path, help="Directory for product-context-pack.json and product-context-pack.md.")
    parser.add_argument("--json-only", action="store_true", help="Print the JSON context pack instead of Markdown.")
    parser.add_argument("--strict", action="store_true", help="Return non-zero when PostHog aggregate data cannot be read.")
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
        data = fetch_report_data(args.days, args.app_version, args.fixture)
    except ContextPackError as exc:
        if args.strict:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 3
        data = unknown_data(str(exc), args.days, args.app_version)

    pack = build_context_pack(data)
    markdown = render_markdown(pack)
    json_path, md_path = write_outputs(pack, markdown, args.write_dir)

    if args.json_only:
        print(json.dumps(pack, indent=2, sort_keys=True))
    else:
        print(markdown)
        print(f"JSON written: {json_path}")
        print(f"Markdown written: {md_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
