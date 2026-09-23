#!/usr/bin/env python3
"""Compare a new Transcripted release against the previous one, side by side.

Built for the first couple of days after a release: is the new version
crashing more, failing to start meetings more, losing call audio more, or
starting dictation slower than the version it replaced?

Both versions are measured over the same wall-clock window (``--hours``, or
everything since ``--since``), so a quiet weekend hits both columns equally.

Sources, all read-only:
  * Sentry release health: crash-free sessions and users per release, plus
    crash groups first seen in the new release.
  * PostHog: one HogQL query grouped by ``app_version`` (local/dev builds
    excluded), covering launches, unclean exits, meeting start failures,
    call-audio failures, the system-audio prompt answers and dictation start
    latency.

Credentials follow the ops-script convention (``SENTRY_AUTH_TOKEN``,
``POSTHOG_PERSONAL_API_KEY``, ``POSTHOG_PROJECT_ID``, from the environment or
the ops env files). ``--print-queries`` prints the HogQL and Sentry searches
without credentials, so a Claude session holding the PostHog and Sentry
connectors can run the exact same checks.

Output is counts and rates only. It never prints transcript text, titles,
names, paths or device names; Sentry crash titles are shown only with
``--show-crash-titles`` and stay on the machine that ran the script.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

OPS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(OPS_DIR))

import posthog_common as posthog  # noqa: E402


def _load_crash_free_module() -> Any:
    spec = importlib.util.spec_from_file_location("check_crash_free_rate", OPS_DIR / "check-crash-free-rate.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


crash_free = _load_crash_free_module()

LOCAL_BUILD_CHANNELS = ("local", "dev", "debug", "main", "nightly", "unknown")
SYSTEM_AUDIO_START_FAILURES = (
    "system_audio_permission",
    "system_audio_permission_check_inconclusive",
    "system_audio_start_failed",
)
SLOW_START_BUCKETS = ("1_2s", "2_5s", "5s_plus")
DEFAULT_ORG = crash_free.DEFAULT_ORG
DEFAULT_PROJECT = crash_free.DEFAULT_PROJECT
RELEASE_PREFIX = crash_free.DEFAULT_RELEASE_PREFIX

# Column order of the PostHog per-version query. Kept next to the query so a
# fixture or a connector result can be mapped back by position.
POSTHOG_FIELDS = (
    "app_version",
    "devices",
    "launches",
    "unclean_exits",
    "stalls",
    "meeting_starts",
    "meeting_start_fails",
    "meeting_start_fails_system_audio",
    "meeting_stops",
    "meeting_stops_system_failed",
    "meeting_stops_tap_ended",
    "mic_only_by_choice_starts",
    "models_warm_starts",
    "transcripts_saved",
    "transcripts_failed",
    "dictation_starts",
    "dictation_starts_slow",
    "dictation_first_starts",
    "dictation_first_starts_slow",
    "dictation_start_fails",
    "prompt_answers",
    "prompt_allowed",
    "prompt_mic_only",
    "launch_warmups",
    "launch_warmups_ready",
)


def posthog_versions_query(new: str, old: str, hours: int) -> str:
    slow = posthog.sql_list(SLOW_START_BUCKETS)
    sys_fail = posthog.sql_list(SYSTEM_AUDIO_START_FAILURES)
    local = posthog.sql_list(LOCAL_BUILD_CHANNELS)
    versions = posthog.sql_list((new, old))
    return f"""SELECT
  properties['app_version'] AS app_version,
  uniqIf(distinct_id, event = 'app_launched') AS devices,
  countIf(event = 'app_launched') AS launches,
  countIf(event = 'app_unclean_shutdown_detected') AS unclean_exits,
  countIf(event = 'app_session_stall_detected') AS stalls,
  countIf(event = 'meeting_recording_started') AS meeting_starts,
  countIf(event = 'meeting_recording_start_failed') AS meeting_start_fails,
  countIf(event = 'meeting_recording_start_failed' AND properties['failure_kind'] IN ({sys_fail})) AS meeting_start_fails_system_audio,
  countIf(event = 'meeting_recording_stopped') AS meeting_stops,
  countIf(event = 'meeting_recording_stopped' AND properties['system_failed'] = 'true') AS meeting_stops_system_failed,
  countIf(event = 'meeting_recording_stopped' AND coalesce(properties['system_end_reason'], '') NOT IN ('', 'none')) AS meeting_stops_tap_ended,
  countIf(event = 'meeting_recording_started' AND properties['mic_only_by_choice'] = 'true') AS mic_only_by_choice_starts,
  countIf(event = 'meeting_recording_started' AND properties['models_warm'] = 'true') AS models_warm_starts,
  countIf(event = 'meeting_transcript_saved') AS transcripts_saved,
  countIf(event = 'meeting_transcript_failed') AS transcripts_failed,
  countIf(event = 'dictation_started' AND isNotNull(properties['start_latency_bucket'])) AS dictation_starts,
  countIf(event = 'dictation_started' AND properties['start_latency_bucket'] IN ({slow})) AS dictation_starts_slow,
  countIf(event = 'dictation_started' AND properties['first_since_launch'] = 'true' AND isNotNull(properties['start_latency_bucket'])) AS dictation_first_starts,
  countIf(event = 'dictation_started' AND properties['first_since_launch'] = 'true' AND properties['start_latency_bucket'] IN ({slow})) AS dictation_first_starts_slow,
  countIf(event = 'dictation_start_failed') AS dictation_start_fails,
  countIf(event = 'meeting_system_audio_prompt_answered') AS prompt_answers,
  countIf(event = 'meeting_system_audio_prompt_answered' AND properties['tcc_status_after'] = 'authorized') AS prompt_allowed,
  countIf(event = 'meeting_system_audio_prompt_answered' AND properties['outcome'] LIKE 'mic_only%') AS prompt_mic_only,
  countIf(event = 'launch_models_warmed') AS launch_warmups,
  countIf(event = 'launch_models_warmed' AND properties['dictation_ready'] = 'true' AND properties['meeting_recording_ready'] = 'true') AS launch_warmups_ready
FROM events
WHERE timestamp >= now() - INTERVAL {int(hours)} HOUR
  AND properties['app_version'] IN ({versions})
  AND coalesce(properties['build_channel'], 'unknown') NOT IN ({local})
GROUP BY app_version
ORDER BY app_version DESC
LIMIT 10"""


def posthog_breakdown_query(new: str, hours: int) -> str:
    """What broke, for the new version only: tap step/status and end reasons."""
    local = posthog.sql_list(LOCAL_BUILD_CHANNELS)
    return f"""SELECT
  event,
  coalesce(properties['failure_kind'], '') AS failure_kind,
  coalesce(properties['system_tap_step'], '') AS tap_step,
  coalesce(properties['system_tap_status'], '') AS tap_status,
  coalesce(properties['system_end_reason'], '') AS end_reason,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE timestamp >= now() - INTERVAL {int(hours)} HOUR
  AND properties['app_version'] = {posthog.sql_quote(new)}
  AND coalesce(properties['build_channel'], 'unknown') NOT IN ({local})
  AND (
    event IN ('meeting_recording_start_failed', 'meeting_transcript_failed', 'dictation_start_failed')
    OR (event = 'meeting_recording_stopped' AND (properties['system_failed'] = 'true'
        OR coalesce(properties['system_end_reason'], '') NOT IN ('', 'none')))
  )
GROUP BY event, failure_kind, tap_step, tap_status, end_reason
ORDER BY events DESC
LIMIT 20"""


def sentry_new_issues_query(new: str) -> str:
    return f"firstRelease:{RELEASE_PREFIX}@{new} is:unresolved"


def parse_posthog_rows(result: dict[str, Any]) -> dict[str, dict[str, int]]:
    rows = result.get("results") or result.get("data") or []
    parsed: dict[str, dict[str, int]] = {}
    for row in rows:
        if not isinstance(row, list) or len(row) < len(POSTHOG_FIELDS):
            continue
        item = dict(zip(POSTHOG_FIELDS, row))
        version = str(item.pop("app_version") or "unknown")
        parsed[version] = {key: int(value or 0) for key, value in item.items()}
    return parsed


def pct(numerator: int, denominator: int) -> float | None:
    if denominator <= 0:
        return None
    return round(numerator / denominator * 100, 1)


def metrics_for(counts: dict[str, int] | None, sentry: dict[str, Any] | None) -> dict[str, Any]:
    c = counts or {}
    s = sentry or {}
    get = lambda key: c.get(key, 0)  # noqa: E731
    return {
        "crash_free_sessions": s.get("crash_free_sessions"),
        "crash_free_users": s.get("crash_free_users"),
        "sentry_sessions": s.get("sessions"),
        "devices": get("devices"),
        "unclean_exit_rate": pct(get("unclean_exits"), get("launches")),
        "meeting_start_fail_rate": pct(get("meeting_start_fails"), get("meeting_starts") + get("meeting_start_fails")),
        "meeting_start_fails_system_audio": get("meeting_start_fails_system_audio"),
        "call_audio_lost_rate": pct(get("meeting_stops_system_failed"), get("meeting_stops")),
        "transcript_fail_rate": pct(get("transcripts_failed"), get("transcripts_saved") + get("transcripts_failed")),
        "dictation_slow_start_rate": pct(get("dictation_starts_slow"), get("dictation_starts")),
        "dictation_first_slow_start_rate": pct(get("dictation_first_starts_slow"), get("dictation_first_starts")),
        "dictation_start_fail_rate": pct(get("dictation_start_fails"), get("dictation_starts") + get("dictation_start_fails")),
        "prompt_answers": get("prompt_answers"),
        "prompt_allowed_rate": pct(get("prompt_allowed"), get("prompt_answers")),
        "prompt_mic_only_rate": pct(get("prompt_mic_only"), get("prompt_answers")),
        "launch_ready_rate": pct(get("launch_warmups_ready"), get("launch_warmups")),
        "meeting_starts": get("meeting_starts"),
        "dictation_starts": get("dictation_starts"),
    }


# (metric key, label, "higher is better", minimum denominator note)
ROWS = (
    ("crash_free_sessions", "Crash-free sessions %", True),
    ("crash_free_users", "Crash-free users %", True),
    ("devices", "Devices seen", None),
    ("unclean_exit_rate", "Unclean exits per launch %", False),
    ("meeting_start_fail_rate", "Meeting start failures %", False),
    ("meeting_start_fails_system_audio", "Meeting starts blocked on call audio", False),
    ("call_audio_lost_rate", "Meetings that lost call audio %", False),
    ("transcript_fail_rate", "Meeting transcripts failed %", False),
    ("dictation_slow_start_rate", "Dictation starts over 1s %", False),
    ("dictation_first_slow_start_rate", "First dictation after launch over 1s %", False),
    ("dictation_start_fail_rate", "Dictation start failures %", False),
    ("prompt_allowed_rate", "Call-audio prompt: allowed %", True),
    ("prompt_mic_only_rate", "Call-audio prompt: mic only %", None),
    ("launch_ready_rate", "Models ready after launch warmup %", True),
)

# A rate this many points worse than the old version is flagged. Small on
# purpose: the watch is for catching problems early, the table carries detail.
WORSE_BY_POINTS = 2.0
CRASH_FREE_WORSE_BY_POINTS = 0.5


def compare(new_m: dict[str, Any], old_m: dict[str, Any], new_crash_titles: list[str]) -> list[str]:
    """Plain-language flags for anything that looks worse. Empty means fine."""
    flags: list[str] = []
    for key, label, higher_better in ROWS:
        if higher_better is None:
            continue
        new_v, old_v = new_m.get(key), old_m.get(key)
        if new_v is None or old_v is None:
            continue
        limit = CRASH_FREE_WORSE_BY_POINTS if key.startswith("crash_free") else WORSE_BY_POINTS
        if key == "meeting_start_fails_system_audio":
            if new_v > 0 and new_v > old_v:
                flags.append(f"{label}: {new_v} vs {old_v}")
            continue
        worse = (old_v - new_v) if higher_better else (new_v - old_v)
        if worse >= limit:
            flags.append(f"{label}: {new_v} vs {old_v}")
    if looks_unsymbolicated(new_crash_titles):
        flags.append("New crashes look unsymbolicated: upload the dSYM to Sentry")
    return flags


_ADDRESS = re.compile(r"0x[0-9a-fA-F]{6,}|<unknown>|<redacted>|\?\?\?")


def looks_unsymbolicated(titles: list[str]) -> bool:
    return any(_ADDRESS.search(title or "") for title in titles)


def fmt(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}".rstrip("0").rstrip(".") if value < 100 else f"{value:.1f}"
    return str(value)


def render_table(new: str, old: str, new_m: dict[str, Any], old_m: dict[str, Any]) -> str:
    lines = [f"| Check | {new} | {old} |", "|---|---|---|"]
    for key, label, _ in ROWS:
        lines.append(f"| {label} | {fmt(new_m.get(key))} | {fmt(old_m.get(key))} |")
    return "\n".join(lines)


def sentry_release_health(org: str, project: str, release: str, period: str, token: str) -> dict[str, Any]:
    project_id = crash_free.project_numeric_id(org, project, token)
    if not project_id:
        return {"error": "Sentry project lookup failed"}
    error, totals = crash_free.fetch_session_totals(org, project_id, release, period, token)
    if error:
        return {"error": error}
    return {
        "crash_free_sessions": crash_free.rate_to_pct(totals.get("crash_free_rate(session)")),
        "crash_free_users": crash_free.rate_to_pct(totals.get("crash_free_rate(user)")),
        "sessions": int(totals.get("sum(session)") or 0),
    }


def sentry_new_issues(org: str, project: str, new: str, period: str, token: str) -> dict[str, Any]:
    query = urllib.parse.urlencode(
        [("query", sentry_new_issues_query(new)), ("statsPeriod", period), ("limit", "25"), ("sort", "freq")]
    )
    status, payload = crash_free.sentry_get(
        f"{crash_free.SENTRY_BASE}/projects/{org}/{project}/issues/?{query}", token
    )
    if status != 200 or not isinstance(payload, list):
        return {"error": f"Sentry issues API returned HTTP {status}"}
    return {
        "count": len(payload),
        "events": sum(int(issue.get("count") or 0) for issue in payload),
        "titles": [str(issue.get("title") or "") for issue in payload],
    }


def hours_since(since: str) -> int:
    started = datetime.fromisoformat(since.replace("Z", "+00:00"))
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    elapsed = (datetime.now(timezone.utc) - started).total_seconds() / 3600
    return max(1, int(elapsed + 0.999))


def print_queries(new: str, old: str, hours: int) -> None:
    print("-- PostHog: per-version comparison (run with the PostHog connector's HogQL query tool)")
    print("-- Columns, in order:", ", ".join(POSTHOG_FIELDS))
    print(posthog_versions_query(new, old, hours))
    print()
    print(f"-- PostHog: what broke on {new}")
    print(posthog_breakdown_query(new, hours))
    print()
    print("-- Sentry (org r3dbars, project apple-macos):")
    print(f"--   crash-free sessions/users: release {RELEASE_PREFIX}@{new} and {RELEASE_PREFIX}@{old}, last {hours}h")
    print(f"--   new crash groups: {sentry_new_issues_query(new)}")


def run_self_test() -> int:
    fixture = {
        "results": [
            ["1.1.62", 40, 120, 1, 0, 30, 3, 1, 28, 1, 1, 4, 25, 26, 1, 200, 10, 40, 6, 2, 12, 9, 3, 110, 104],
            ["1.1.61", 60, 200, 2, 1, 50, 1, 0, 49, 2, 0, 0, 0, 45, 2, 300, 12, 0, 0, 3, 0, 0, 0, 0, 0],
        ]
    }
    rows = parse_posthog_rows(fixture)
    assert set(rows) == {"1.1.62", "1.1.61"}, rows
    new_m = metrics_for(rows["1.1.62"], {"crash_free_sessions": 99.1, "crash_free_users": 98.0, "sessions": 300})
    old_m = metrics_for(rows["1.1.61"], {"crash_free_sessions": 99.8, "crash_free_users": 99.0, "sessions": 900})
    assert new_m["meeting_start_fail_rate"] == 9.1, new_m
    assert old_m["prompt_allowed_rate"] is None
    flags = compare(new_m, old_m, ["EXC_BAD_ACCESS 0x00000001045a2b10"])
    joined = "\n".join(flags)
    assert "Crash-free sessions" in joined, flags
    assert "Meeting start failures" in joined, flags
    assert "Meeting starts blocked on call audio" in joined, flags
    assert "dSYM" in joined, flags
    assert "Call-audio prompt" not in joined, flags  # no old-version baseline
    assert not compare(old_m, old_m, ["Crash in ParakeetEngine.transcribe"]), "same data must not flag"
    table = render_table("1.1.62", "1.1.61", new_m, old_m)
    assert "| Crash-free sessions % | 99.1 | 99.8 |" in table, table
    assert "n/a" in table
    query = posthog_versions_query("1.1.62", "1.1.61", 48)
    assert query.count(" AS ") >= len(POSTHOG_FIELDS), "every field needs a column"
    for field in POSTHOG_FIELDS:
        assert f" AS {field}" in query, field
    assert "INTERVAL 48 HOUR" in query
    assert "'1.1.62'" in posthog_breakdown_query("1.1.62", 12)
    print("release-watch self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", help="New release version, e.g. 1.1.62.")
    parser.add_argument("--old", help="Previous release version, e.g. 1.1.61.")
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--hours", type=int, help="Lookback window in hours (default 24).")
    window.add_argument("--since", help="Measure from this UTC time, e.g. the release publish time.")
    parser.add_argument("--org", default=os.environ.get("SENTRY_ORG", DEFAULT_ORG))
    parser.add_argument("--project", default=os.environ.get("SENTRY_PROJECT", DEFAULT_PROJECT))
    parser.add_argument("--print-queries", action="store_true", help="Print the queries and exit; no network.")
    parser.add_argument("--show-crash-titles", action="store_true", help="List new crash titles (local output only).")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON instead of the table.")
    parser.add_argument("--self-test", action="store_true", help="Run offline checks and exit.")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if not args.new or not args.old:
        parser.error("--new and --old are required")

    hours = hours_since(args.since) if args.since else (args.hours or 24)
    if args.print_queries:
        print_queries(args.new, args.old, hours)
        return 0

    posthog.load_env()
    crash_free.load_env()
    problems: list[str] = []

    counts: dict[str, dict[str, int]] = {}
    breakdown: list[Any] = []
    try:
        host, project_id, token = posthog.posthog_config(RuntimeError)
        counts = parse_posthog_rows(
            posthog.run_hogql(host, project_id, token, posthog_versions_query(args.new, args.old, hours), RuntimeError)
        )
        breakdown = (
            posthog.run_hogql(host, project_id, token, posthog_breakdown_query(args.new, hours), RuntimeError).get("results")
            or []
        )
    except RuntimeError as exc:
        problems.append(f"PostHog unavailable: {exc}")

    sentry: dict[str, dict[str, Any]] = {}
    new_issues: dict[str, Any] = {}
    sentry_token = os.environ.get("SENTRY_AUTH_TOKEN")
    period = f"{hours}h"
    if sentry_token:
        for version in (args.new, args.old):
            health = sentry_release_health(args.org, args.project, f"{RELEASE_PREFIX}@{version}", period, sentry_token)
            if health.get("error"):
                problems.append(f"Sentry {version}: {health['error']}")
            sentry[version] = health
        new_issues = sentry_new_issues(args.org, args.project, args.new, period, sentry_token)
        if new_issues.get("error"):
            problems.append(f"Sentry new issues: {new_issues['error']}")
    else:
        problems.append("Sentry unavailable: missing SENTRY_AUTH_TOKEN")

    new_m = metrics_for(counts.get(args.new), sentry.get(args.new))
    old_m = metrics_for(counts.get(args.old), sentry.get(args.old))
    titles = new_issues.get("titles") or []
    flags = compare(new_m, old_m, titles)

    if args.json:
        print(json.dumps({
            "window_hours": hours,
            "new": {"version": args.new, **new_m},
            "old": {"version": args.old, **old_m},
            "new_crash_groups": new_issues.get("count"),
            "new_crash_events": new_issues.get("events"),
            "breakdown": breakdown,
            "flags": flags,
            "problems": problems,
        }, indent=2))
        return 1 if flags else 0

    print(f"Transcripted {args.new} vs {args.old}, last {hours}h")
    print()
    print(render_table(args.new, args.old, new_m, old_m))
    print()
    if new_issues.get("count") is not None:
        print(f"New crash groups in {args.new}: {new_issues['count']} ({new_issues.get('events', 0)} events)")
        if args.show_crash_titles:
            for title in titles[:10]:
                print(f"  - {title}")
    if breakdown:
        print(f"\nWhat broke on {args.new} (event | failure_kind | tap step | tap status | end reason | events | devices):")
        for row in breakdown[:10]:
            print("  " + " | ".join(str(cell) for cell in row))
    print()
    print("Looks worse:" if flags else "Nothing looks worse than the previous version.")
    for flag in flags:
        print(f"  - {flag}")
    for problem in problems:
        print(f"Note: {problem}")
    return 1 if flags else 0


if __name__ == "__main__":
    sys.exit(main())
