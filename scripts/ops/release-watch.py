#!/usr/bin/env python3
"""Compare a new Transcripted release against the previous one, side by side.

Built for the first couple of days after a release: is the new version
crashing more, failing to start meetings more, losing call audio more, or
starting dictation slower than the version it replaced?

Both versions are measured over the same wall-clock window, starting at the
new version's publish time (its `docs/appcast.xml` pubDate by default, or
``--since`` / ``--hours``), so a quiet weekend hits both columns equally and
release-candidate testing before publish is left out.

Sources, all read-only:
  * Sentry: crash-free sessions and users per release, unhandled issues first
    seen in the new release, and whether their latest events are missing a
    dSYM (Sentry's own processing errors, not a guess from titles).
  * PostHog: one HogQL query grouped by ``app_version``, release builds only
    (``build_channel = 'release'``), covering devices, unclean exits, stalls,
    meeting start failures, call-audio loss (mic-only-by-choice meetings
    excluded), transcript failures, dictation start latency and failures, the
    system-audio prompt answers and launch warmup.

Verdict and exit code follow check-crash-free-rate.py (unknown is never green):
    ok       exit 0  every source answered, enough data, nothing worse
    worse    exit 1  at least one check is worse than the previous version
    unknown  exit 3  a source failed, the new version has no data yet, or
                     there is too little data to judge

Credentials follow the ops-script convention (``SENTRY_AUTH_TOKEN``,
``POSTHOG_PERSONAL_API_KEY``, ``POSTHOG_PROJECT_ID``, from the environment or
the ops env files). ``--print-queries`` prints the HogQL and Sentry searches
without credentials or network, so a Claude session holding the PostHog and
Sentry connectors can run the same checks.

Output is counts and rates only. It never prints transcript text, titles,
names, paths or device names; Sentry issue titles are shown only with
``--show-crash-titles`` and stay on the machine that ran the script.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any

OPS_DIR = Path(__file__).resolve().parent
REPO_ROOT = OPS_DIR.parent.parent
sys.path.insert(0, str(OPS_DIR))

import posthog_common as posthog  # noqa: E402


def _load_crash_free_module() -> Any:
    spec = importlib.util.spec_from_file_location("check_crash_free_rate", OPS_DIR / "check-crash-free-rate.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


crash_free = _load_crash_free_module()

EXIT_CODES = crash_free.EXIT_CODES  # green/ok 0, red/worse 1, yellow/unknown 3
RELEASE_BUILD_CHANNEL = "release"
SYSTEM_AUDIO_START_FAILURES = (
    "system_audio_permission",
    "system_audio_permission_check_inconclusive",
    "system_audio_start_failed",
)
SLOW_START_BUCKETS = ("1_2s", "2_5s", "5s_plus")
# Sentry event processing errors that mean the app's own frames could not be
# symbolicated. System-library variants are left out on purpose.
MISSING_DSYM_ERRORS = ("native_missing_dsym", "native_bad_dsym")
DEFAULT_ORG = crash_free.DEFAULT_ORG
DEFAULT_PROJECT = crash_free.DEFAULT_PROJECT
RELEASE_PREFIX = crash_free.DEFAULT_RELEASE_PREFIX
APPCAST_PATH = REPO_ROOT / "docs" / "appcast.xml"
SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

# Below these a rate is shown but never judged: in the first hours after a
# release one failed meeting out of four is noise, not a regression. The
# session floor matches check-crash-free-rate.py's DEFAULT_MIN_SESSIONS.
MIN_EVENTS = 20
MIN_SESSIONS = crash_free.DEFAULT_MIN_SESSIONS
SYMBOLICATION_SAMPLE = 5
ISSUE_PAGE_LIMIT = 100

# A rate this many points worse than the old version is flagged. Small on
# purpose: the watch is for catching problems early, the table carries detail.
WORSE_BY_POINTS = 2.0
CRASH_FREE_WORSE_BY_POINTS = 0.5

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
    "mic_only_by_choice_starts",
    "meeting_stops_with_call_audio",
    "meeting_stops_call_audio_lost",
    "transcripts_saved",
    "transcripts_failed",
    "dictation_starts",
    "dictation_starts_timed",
    "dictation_starts_slow",
    "dictation_first_starts_timed",
    "dictation_first_starts_slow",
    "dictation_start_fails",
    "prompt_answers",
    "prompt_allowed",
    "prompt_mic_only",
    "launch_warmups",
    "launch_warmups_ready",
)


def window_filter(minutes: int) -> str:
    return (
        f"timestamp >= now() - INTERVAL {int(minutes)} MINUTE "
        f"AND properties['build_channel'] = {posthog.sql_quote(RELEASE_BUILD_CHANNEL)}"
    )


def posthog_versions_query(new: str, old: str, minutes: int) -> str:
    slow = posthog.sql_list(SLOW_START_BUCKETS)
    sys_fail = posthog.sql_list(SYSTEM_AUDIO_START_FAILURES)
    versions = posthog.sql_list((new, old))
    # A mic-only-by-choice meeting (new in 1.1.62) can still end with
    # system_failed = 'true' because the tap is started and refused. The stop
    # event does not carry the choice, so leave out every app session that
    # started a chosen mic-only meeting. That slightly undercounts losses in
    # sessions that also had a normal meeting, which errs toward quiet.
    mic_only_sessions = f"""(
      SELECT properties['session_id'] FROM events
      WHERE event = 'meeting_recording_started'
        AND properties['mic_only_by_choice'] = 'true'
        AND {window_filter(minutes)}
        AND properties['session_id'] IS NOT NULL
    )"""
    with_call_audio = (
        "event = 'meeting_recording_stopped' "
        f"AND coalesce(properties['session_id'], '') NOT IN {mic_only_sessions}"
    )
    return f"""SELECT
  properties['app_version'] AS app_version,
  uniq(distinct_id) AS devices,
  countIf(event = 'app_launched') AS launches,
  countIf(event = 'app_unclean_shutdown_detected') AS unclean_exits,
  countIf(event = 'app_session_stall_detected') AS stalls,
  countIf(event = 'meeting_recording_started') AS meeting_starts,
  countIf(event = 'meeting_recording_start_failed') AS meeting_start_fails,
  countIf(event = 'meeting_recording_start_failed' AND properties['failure_kind'] IN ({sys_fail})) AS meeting_start_fails_system_audio,
  countIf(event = 'meeting_recording_started' AND properties['mic_only_by_choice'] = 'true') AS mic_only_by_choice_starts,
  countIf({with_call_audio}) AS meeting_stops_with_call_audio,
  countIf({with_call_audio} AND properties['system_failed'] = 'true') AS meeting_stops_call_audio_lost,
  countIf(event = 'meeting_transcript_saved') AS transcripts_saved,
  countIf(event = 'meeting_transcript_failed') AS transcripts_failed,
  countIf(event = 'dictation_started') AS dictation_starts,
  countIf(event = 'dictation_started' AND isNotNull(properties['start_latency_bucket'])) AS dictation_starts_timed,
  countIf(event = 'dictation_started' AND properties['start_latency_bucket'] IN ({slow})) AS dictation_starts_slow,
  countIf(event = 'dictation_started' AND properties['first_since_launch'] = 'true' AND isNotNull(properties['start_latency_bucket'])) AS dictation_first_starts_timed,
  countIf(event = 'dictation_started' AND properties['first_since_launch'] = 'true' AND properties['start_latency_bucket'] IN ({slow})) AS dictation_first_starts_slow,
  countIf(event = 'dictation_start_failed') AS dictation_start_fails,
  countIf(event = 'meeting_system_audio_prompt_answered') AS prompt_answers,
  countIf(event = 'meeting_system_audio_prompt_answered' AND properties['tcc_status_after'] = 'authorized') AS prompt_allowed,
  countIf(event = 'meeting_system_audio_prompt_answered' AND properties['outcome'] LIKE 'mic_only%') AS prompt_mic_only,
  countIf(event = 'launch_models_warmed') AS launch_warmups,
  countIf(event = 'launch_models_warmed' AND properties['dictation_ready'] = 'true' AND properties['meeting_recording_ready'] = 'true') AS launch_warmups_ready
FROM events
WHERE {window_filter(minutes)}
  AND properties['app_version'] IN ({versions})
GROUP BY app_version
ORDER BY app_version DESC
LIMIT 10"""


def posthog_breakdown_query(new: str, minutes: int) -> str:
    """What broke, for the new version only: tap step/status and end reasons."""
    return f"""SELECT
  event,
  coalesce(properties['failure_kind'], '') AS failure_kind,
  coalesce(properties['system_tap_step'], '') AS tap_step,
  coalesce(properties['system_tap_status'], '') AS tap_status,
  coalesce(properties['system_end_reason'], '') AS end_reason,
  count() AS events,
  uniq(distinct_id) AS devices
FROM events
WHERE {window_filter(minutes)}
  AND properties['app_version'] = {posthog.sql_quote(new)}
  AND (
    event IN ('meeting_recording_start_failed', 'meeting_transcript_failed', 'dictation_start_failed')
    OR (event = 'meeting_recording_stopped' AND (properties['system_failed'] = 'true'
        OR coalesce(properties['system_end_reason'], '') NOT IN ('', 'none')))
  )
GROUP BY event, failure_kind, tap_step, tap_status, end_reason
ORDER BY events DESC
LIMIT 20"""


def sentry_new_issues_query(new: str) -> str:
    # Unhandled only, so handled errors and warnings don't read as crashes.
    # `!build_channel:local` drops local builds that report the same release
    # name; events without the tag (it arrived with 1.1.62) stay in.
    return f"firstRelease:{RELEASE_PREFIX}@{new} is:unhandled !build_channel:local"


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


def ratio(numerator: int | None, denominator: int | None) -> dict[str, Any]:
    if numerator is None or denominator is None or denominator <= 0:
        return {"value": None, "num": numerator, "den": denominator or 0}
    return {"value": round(numerator / denominator * 100, 1), "num": numerator, "den": denominator}


def metrics_for(counts: dict[str, int] | None, sentry: dict[str, Any] | None) -> dict[str, dict[str, Any]]:
    c = counts or {}
    s = sentry or {}
    get = lambda key: c.get(key, 0)  # noqa: E731
    sessions = s.get("sessions") or 0
    users = s.get("users") or 0
    meeting_attempts = get("meeting_starts") + get("meeting_start_fails")
    return {
        "crash_free_sessions": {"value": s.get("crash_free_sessions"), "num": None, "den": sessions},
        "crash_free_users": {"value": s.get("crash_free_users"), "num": None, "den": users},
        "devices": {"value": get("devices"), "num": None, "den": None},
        "unclean_exit_rate": ratio(get("unclean_exits"), get("launches")),
        "stall_rate": ratio(get("stalls"), get("launches")),
        "meeting_start_fail_rate": ratio(get("meeting_start_fails"), meeting_attempts),
        "meeting_start_blocked_call_audio_rate": ratio(get("meeting_start_fails_system_audio"), meeting_attempts),
        "call_audio_lost_rate": ratio(get("meeting_stops_call_audio_lost"), get("meeting_stops_with_call_audio")),
        "mic_only_by_choice_rate": ratio(get("mic_only_by_choice_starts"), get("meeting_starts")),
        "transcript_fail_rate": ratio(get("transcripts_failed"), get("transcripts_saved") + get("transcripts_failed")),
        "dictation_slow_start_rate": ratio(get("dictation_starts_slow"), get("dictation_starts_timed")),
        "dictation_first_slow_start_rate": ratio(get("dictation_first_starts_slow"), get("dictation_first_starts_timed")),
        # Every dictation_started counts here, not only the ones carrying the
        # latency bucket (#1781), so versions before 1.1.62 get a real rate.
        "dictation_start_fail_rate": ratio(get("dictation_start_fails"), get("dictation_starts") + get("dictation_start_fails")),
        "prompt_allowed_rate": ratio(get("prompt_allowed"), get("prompt_answers")),
        "prompt_mic_only_rate": ratio(get("prompt_mic_only"), get("prompt_answers")),
        "launch_ready_rate": ratio(get("launch_warmups_ready"), get("launch_warmups")),
    }


# (metric key, label, higher is better: True/False, None = shown, never judged)
ROWS = (
    ("crash_free_sessions", "Crash-free sessions %", True),
    ("crash_free_users", "Crash-free users %", True),
    ("devices", "Devices seen", None),
    ("unclean_exit_rate", "Unclean exits per launch %", False),
    ("stall_rate", "App stalls per launch %", False),
    ("meeting_start_fail_rate", "Meeting start failures %", False),
    ("meeting_start_blocked_call_audio_rate", "Meeting starts blocked on call audio %", False),
    ("call_audio_lost_rate", "Meetings that lost call audio %", False),
    ("mic_only_by_choice_rate", "Meetings mic-only by choice %", None),
    ("transcript_fail_rate", "Meeting transcripts failed %", False),
    ("dictation_slow_start_rate", "Dictation starts over 1s %", False),
    ("dictation_first_slow_start_rate", "First dictation after launch over 1s %", False),
    ("dictation_start_fail_rate", "Dictation start failures %", False),
    ("prompt_allowed_rate", "Call-audio prompt: allowed %", True),
    ("prompt_mic_only_rate", "Call-audio prompt: mic only %", None),
    ("launch_ready_rate", "Models ready after launch warmup %", True),
)


def floor_for(key: str) -> int:
    return MIN_SESSIONS if key.startswith("crash_free") else MIN_EVENTS


def compare(new_m: dict[str, dict[str, Any]], old_m: dict[str, dict[str, Any]]) -> tuple[list[str], list[str], int]:
    """Return (flags, thin labels, rows judged).

    A row is judged only when both versions have a value and each side's
    denominator is at or above its floor. Thin rows are listed, never flagged.
    """
    flags: list[str] = []
    thin: list[str] = []
    judged = 0
    for key, label, higher_better in ROWS:
        if higher_better is None:
            continue
        new_c, old_c = new_m.get(key) or {}, old_m.get(key) or {}
        new_v, old_v = new_c.get("value"), old_c.get("value")
        if new_v is None or old_v is None:
            continue
        floor = floor_for(key)
        if (new_c.get("den") or 0) < floor or (old_c.get("den") or 0) < floor:
            thin.append(label)
            continue
        judged += 1
        limit = CRASH_FREE_WORSE_BY_POINTS if key.startswith("crash_free") else WORSE_BY_POINTS
        worse = (old_v - new_v) if higher_better else (new_v - old_v)
        if worse >= limit:
            flags.append(f"{label}: {fmt_cell(new_c)} vs {fmt_cell(old_c)}")
    return flags, thin, judged


def verdict_for(
    flags: list[str],
    problems: list[str],
    new_has_usage: bool,
    new_sessions: int,
    judged: int,
) -> tuple[str, int, str]:
    """(verdict, exit code, one plain line). Worse wins; unknown is never ok."""
    if flags:
        return "worse", EXIT_CODES["red"], f"LOOKS WORSE than the previous version ({len(flags)} check(s))."
    reasons: list[str] = list(problems)
    posthog_failed = any(problem.startswith("PostHog") for problem in problems)
    sentry_failed = any(problem.startswith("Sentry") for problem in problems)
    if not new_has_usage and not posthog_failed:
        reasons.append("no PostHog data for the new version yet")
    if sentry_failed:
        pass
    elif new_sessions <= 0:
        reasons.append("no Sentry sessions for the new release yet")
    elif new_sessions < MIN_SESSIONS:
        reasons.append(f"only {new_sessions} Sentry sessions for the new release (need {MIN_SESSIONS})")
    if judged == 0 and not reasons:
        reasons.append("too little data to compare any check yet")
    if reasons:
        return "unknown", EXIT_CODES["yellow"], "COULD NOT CHECK: " + "; ".join(reasons) + "."
    return "ok", EXIT_CODES["green"], "OK: nothing looks worse than the previous version."


def missing_dsym(event: dict[str, Any]) -> bool:
    errors = event.get("errors") or []
    return any(isinstance(err, dict) and err.get("type") in MISSING_DSYM_ERRORS for err in errors)


def fmt_value(value: Any) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.2f}".rstrip("0").rstrip(".")
    return str(value)


def fmt_cell(cell: dict[str, Any]) -> str:
    text = fmt_value(cell.get("value"))
    if cell.get("num") is not None and cell.get("den"):
        text += f" ({cell['num']}/{cell['den']})"
    elif cell.get("den") and cell.get("num") is None and cell.get("value") is not None:
        text += f" (n={cell['den']})"
    return text


def render_table(new: str, old: str, new_m: dict[str, Any], old_m: dict[str, Any]) -> str:
    lines = [f"| Check | {new} | {old} |", "|---|---|---|"]
    for key, label, _ in ROWS:
        lines.append(f"| {label} | {fmt_cell(new_m.get(key) or {})} | {fmt_cell(old_m.get(key) or {})} |")
    return "\n".join(lines)


def appcast_pub_date(version: str, path: Path = APPCAST_PATH) -> datetime | None:
    """The new version's pubDate from the checked-in appcast, if it's there."""
    if not path.is_file():
        return None
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    for item in root.iter("item"):
        short = item.findtext(f"{SPARKLE_NS}shortVersionString") or item.findtext("title") or ""
        if short.strip() == version:
            raw = item.findtext("pubDate")
            if raw:
                try:
                    return parsedate_to_datetime(raw.strip()).astimezone(timezone.utc)
                except (TypeError, ValueError):
                    return None
    return None


def parse_since(raw: str) -> datetime:
    started = datetime.fromisoformat(raw.strip().replace("Z", "+00:00"))
    if started.tzinfo is None:
        started = started.replace(tzinfo=timezone.utc)
    return started.astimezone(timezone.utc)


def iso_z(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class SentryClient:
    def __init__(self, org: str, project: str, token: str) -> None:
        self.org, self.project, self.token = org, project, token
        self._project_id: str | None = None

    def project_id(self) -> str | None:
        if self._project_id is None:
            self._project_id = crash_free.project_numeric_id(self.org, self.project, self.token)
        return self._project_id

    def release_health(self, version: str, hours: int) -> dict[str, Any]:
        project_id = self.project_id()
        if not project_id:
            return {"error": "Sentry project lookup failed"}
        error, totals = crash_free.fetch_session_totals(
            self.org, project_id, f"{RELEASE_PREFIX}@{version}", f"{hours}h", self.token
        )
        if error:
            return {"error": error}
        return {
            "crash_free_sessions": crash_free.rate_to_pct(totals.get("crash_free_rate(session)")),
            "crash_free_users": crash_free.rate_to_pct(totals.get("crash_free_rate(user)")),
            "sessions": int(totals.get("sum(session)") or 0),
            "users": int(totals.get("count_unique(user)") or 0),
        }

    def new_issues(self, new: str, start: datetime, end: datetime) -> dict[str, Any]:
        project_id = self.project_id()
        if not project_id:
            return {"error": "Sentry project lookup failed"}
        # The org issues endpoint takes start/end as the time filter. The
        # project endpoint's statsPeriod is only a sparkline setting and
        # rejects anything but "", 24h or 14d.
        query = urllib.parse.urlencode(
            [
                ("project", project_id),
                ("query", sentry_new_issues_query(new)),
                ("start", iso_z(start)),
                ("end", iso_z(end)),
                ("sort", "freq"),
                ("limit", str(ISSUE_PAGE_LIMIT)),
            ]
        )
        status, payload = crash_free.sentry_get(
            f"{crash_free.SENTRY_BASE}/organizations/{self.org}/issues/?{query}", self.token
        )
        if status != 200 or not isinstance(payload, list):
            return {"error": f"Sentry issues API returned HTTP {status}"}
        issues = [issue for issue in payload if isinstance(issue, dict)]
        return {
            "count": len(issues),
            "capped": len(issues) >= ISSUE_PAGE_LIMIT,
            "events": sum(int(issue.get("count") or 0) for issue in issues),
            "users": sum(int(issue.get("userCount") or 0) for issue in issues),
            "issues": issues,
        }

    def unsymbolicated_issues(self, issues: list[dict[str, Any]]) -> tuple[int, int, list[str]]:
        """(checked, missing a dSYM, errors) over the most frequent issues."""
        checked = missing = 0
        errors: list[str] = []
        for issue in issues[:SYMBOLICATION_SAMPLE]:
            issue_id = str(issue.get("id") or "")
            if not issue_id:
                continue
            status, event = crash_free.sentry_get(
                f"{crash_free.SENTRY_BASE}/organizations/{self.org}/issues/{urllib.parse.quote(issue_id)}/events/latest/",
                self.token,
            )
            if status != 200 or not isinstance(event, dict):
                errors.append(f"Sentry latest event returned HTTP {status}")
                continue
            checked += 1
            if missing_dsym(event):
                missing += 1
        return checked, missing, errors


def print_queries(new: str, old: str, minutes: int, start: datetime, org: str, project: str) -> None:
    print(f"-- Window: {iso_z(start)} to now ({minutes} minutes). Release builds only.")
    print("-- PostHog: per-version comparison (run with the PostHog connector's HogQL query tool)")
    print("-- Columns, in order:", ", ".join(POSTHOG_FIELDS))
    print(posthog_versions_query(new, old, minutes))
    print()
    print(f"-- PostHog: what broke on {new}")
    print(posthog_breakdown_query(new, minutes))
    print()
    print(f"-- Sentry (org {org}, project {project}), window {iso_z(start)} to now:")
    print(f"--   crash-free sessions/users: release {RELEASE_PREFIX}@{new} and {RELEASE_PREFIX}@{old}")
    print(f"--   new crash issues: {sentry_new_issues_query(new)}")
    print(f"--   symbolication: latest event of the top {SYMBOLICATION_SAMPLE} issues, errors of type "
          + " or ".join(MISSING_DSYM_ERRORS))


def run_self_test() -> int:
    fixture = {
        "results": [
            # new: 40 devices, meetings 30 ok + 3 failed, dictation 200 starts
            ["1.1.62", 40, 120, 1, 0, 30, 3, 1, 4, 24, 1, 26, 1, 200, 200, 10, 40, 6, 2, 12, 9, 3, 110, 104],
            # old: no latency buckets or prompt events yet (pre-#1781)
            ["1.1.61", 60, 200, 2, 1, 50, 1, 0, 0, 49, 2, 45, 2, 300, 0, 0, 0, 0, 30, 0, 0, 0, 0, 0],
        ]
    }
    rows = parse_posthog_rows(fixture)
    assert set(rows) == {"1.1.62", "1.1.61"}, rows
    new_sentry = {"crash_free_sessions": 99.1, "crash_free_users": 98.0, "sessions": 300, "users": 40}
    old_sentry = {"crash_free_sessions": 99.8, "crash_free_users": 99.0, "sessions": 900, "users": 60}
    new_m = metrics_for(rows["1.1.62"], new_sentry)
    old_m = metrics_for(rows["1.1.61"], old_sentry)
    assert new_m["meeting_start_fail_rate"]["value"] == 9.1, new_m
    # S1: the old failure rate uses every dictation_started, not only timed ones.
    assert old_m["dictation_start_fail_rate"]["value"] == 9.1, old_m["dictation_start_fail_rate"]
    assert old_m["dictation_slow_start_rate"]["value"] is None
    assert old_m["prompt_allowed_rate"]["value"] is None

    flags, thin, judged = compare(new_m, old_m)
    joined = "\n".join(flags)
    assert "Crash-free sessions" in joined, flags
    assert "Meeting start failures" in joined, flags
    assert "Call-audio prompt" not in joined, flags  # no old-version baseline
    assert judged > 0
    verdict, code, line = verdict_for(flags, [], True, 300, judged)
    assert (verdict, code) == ("worse", 1), (verdict, code)

    # Same data on both sides: ok, exit 0.
    flags_same, _, judged_same = compare(old_m, old_m)
    assert not flags_same, flags_same
    assert verdict_for(flags_same, [], True, 900, judged_same)[:2] == ("ok", 0)

    # B1: a failed source, a version nobody runs yet, or thin Sentry data is
    # never "all clear".
    assert verdict_for([], ["PostHog unavailable: HTTP 401"], True, 900, judged_same)[:2] == ("unknown", 3)
    empty_m = metrics_for(None, None)
    flags_empty, _, judged_empty = compare(empty_m, old_m)
    assert not flags_empty and judged_empty == 0
    verdict, code, line = verdict_for(flags_empty, [], False, 0, judged_empty)
    assert (verdict, code) == ("unknown", 3) and line.startswith("COULD NOT CHECK"), line
    assert verdict_for([], [], True, 10, 5)[:2] == ("unknown", 3)

    # S2: 1 failure in 4 attempts is shown but not judged.
    tiny_new = metrics_for({"meeting_starts": 3, "meeting_start_fails": 1}, None)
    tiny_old = metrics_for({"meeting_starts": 50, "meeting_start_fails": 0}, None)
    tiny_flags, tiny_thin, _ = compare(tiny_new, tiny_old)
    assert not tiny_flags and "Meeting start failures %" in tiny_thin, (tiny_flags, tiny_thin)
    thin_crash = metrics_for(None, {"crash_free_sessions": 80.0, "sessions": 5})
    assert not compare(thin_crash, metrics_for(None, old_sentry))[0]

    # S4: symbolication comes from Sentry's processing errors, not titles.
    assert missing_dsym({"errors": [{"type": "native_missing_dsym"}]})
    assert not missing_dsym({"errors": [{"type": "native_missing_system_dsym"}]})
    assert not missing_dsym({"title": "EXC_BAD_ACCESS KERN_INVALID_ADDRESS at 0x0000000000000010"})

    table = render_table("1.1.62", "1.1.61", new_m, old_m)
    assert "| Crash-free sessions % | 99.1 (n=300) | 99.8 (n=900) |" in table, table
    assert "9.1 (3/33)" in table, table
    assert "n/a" in table

    query = posthog_versions_query("1.1.62", "1.1.61", 600)
    for field in POSTHOG_FIELDS:
        assert f" AS {field}" in query, field
    assert "INTERVAL 600 MINUTE" in query
    assert "properties['build_channel'] = 'release'" in query
    assert "mic_only_by_choice'] = 'true'" in query and "NOT IN (" in query
    assert "'1.1.62'" in posthog_breakdown_query("1.1.62", 60)
    assert "is:unhandled" in sentry_new_issues_query("1.1.62")

    # S3: the default start comes from the appcast pubDate.
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        appcast = Path(tmp) / "appcast.xml"
        appcast.write_text(
            "<?xml version='1.0'?><rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'>"
            "<channel><item><title>1.1.62</title><pubDate>Wed, 23 Sep 2026 22:04:10 +0000</pubDate>"
            "<sparkle:shortVersionString>1.1.62</sparkle:shortVersionString></item></channel></rss>",
            encoding="utf-8",
        )
        assert iso_z(appcast_pub_date("1.1.62", appcast)) == "2026-09-23T22:04:10Z"
        assert appcast_pub_date("1.1.99", appcast) is None
    assert iso_z(parse_since("2026-09-23T22:04:10Z")) == "2026-09-23T22:04:10Z"
    print("release-watch self-test passed")
    return 0


def resolve_start(args: argparse.Namespace, parser: argparse.ArgumentParser, now: datetime) -> datetime:
    if args.hours is not None:
        if args.hours <= 0:
            parser.error("--hours must be a positive number of hours")
        return now - timedelta(hours=args.hours)
    if args.since:
        try:
            start = parse_since(args.since)
        except ValueError:
            parser.error(f"--since must be an ISO time like 2026-09-23T22:04:10Z, got {args.since!r}")
    else:
        start = appcast_pub_date(args.new)
        if start is None:
            parser.error(
                f"no pubDate for {args.new} in docs/appcast.xml; pass --since <publish time in UTC> or --hours"
            )
    if start >= now:
        parser.error(f"window start {iso_z(start)} is in the future")
    return start


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--new", help="New release version, e.g. 1.1.62.")
    parser.add_argument("--old", help="Previous release version, e.g. 1.1.61.")
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--since", help="Window start in UTC. Default: the new version's appcast pubDate.")
    window.add_argument("--hours", type=int, help="Use the last N hours instead of the publish time.")
    parser.add_argument("--org", default=os.environ.get("SENTRY_ORG", DEFAULT_ORG))
    parser.add_argument("--project", default=os.environ.get("SENTRY_PROJECT", DEFAULT_PROJECT))
    parser.add_argument("--print-queries", action="store_true", help="Print the queries and exit; no network.")
    parser.add_argument("--show-crash-titles", action="store_true", help="List new issue titles (local output only).")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON instead of the table.")
    parser.add_argument("--self-test", action="store_true", help="Run offline checks and exit.")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()
    if not args.new or not args.old:
        parser.error("--new and --old are required")

    now = datetime.now(timezone.utc).replace(microsecond=0)
    start = resolve_start(args, parser, now)
    minutes = max(1, int((now - start).total_seconds() // 60) + 1)
    hours = max(1, -(-minutes // 60))

    if args.print_queries:
        print_queries(args.new, args.old, minutes, start, args.org, args.project)
        return 0

    posthog.load_env()
    crash_free.load_env()
    problems: list[str] = []

    counts: dict[str, dict[str, int]] = {}
    breakdown: list[Any] = []
    try:
        host, project_id, token = posthog.posthog_config(RuntimeError)
        counts = parse_posthog_rows(
            posthog.run_hogql(host, project_id, token, posthog_versions_query(args.new, args.old, minutes), RuntimeError)
        )
        breakdown = (
            posthog.run_hogql(host, project_id, token, posthog_breakdown_query(args.new, minutes), RuntimeError).get(
                "results"
            )
            or []
        )
    except RuntimeError as exc:
        problems.append(f"PostHog unavailable: {exc}")

    sentry: dict[str, dict[str, Any]] = {}
    new_issues: dict[str, Any] = {}
    symbolication = {"checked": 0, "missing": 0}
    sentry_token = os.environ.get("SENTRY_AUTH_TOKEN")
    if sentry_token:
        client = SentryClient(args.org, args.project, sentry_token)
        for version in (args.new, args.old):
            health = client.release_health(version, hours)
            if health.get("error"):
                problems.append(f"Sentry {version}: {health['error']}")
            sentry[version] = health
        new_issues = client.new_issues(args.new, start, now)
        if new_issues.get("error"):
            problems.append(f"Sentry new issues: {new_issues['error']}")
        else:
            checked, missing, errors = client.unsymbolicated_issues(new_issues.get("issues") or [])
            symbolication = {"checked": checked, "missing": missing}
            problems.extend(errors)
    else:
        problems.append("Sentry unavailable: missing SENTRY_AUTH_TOKEN")

    new_m = metrics_for(counts.get(args.new), sentry.get(args.new))
    old_m = metrics_for(counts.get(args.old), sentry.get(args.old))
    flags, thin, judged = compare(new_m, old_m)
    if symbolication["missing"]:
        flags.append(
            f"{symbolication['missing']} of {symbolication['checked']} new crash issues are missing a dSYM: "
            f"run register-sentry-release.sh {args.new} with the release dSYM"
        )
    new_issue_count = new_issues.get("count") or 0
    new_issue_users = new_issues.get("users") or 0
    if new_issue_users >= 3 or (new_issues.get("events") or 0) >= 10:
        flags.append(f"New crash issues in {args.new}: {new_issue_count} ({new_issues.get('events', 0)} events, {new_issue_users} users)")
    new_sessions = int((sentry.get(args.new) or {}).get("sessions") or 0)
    verdict, exit_code, verdict_line = verdict_for(
        flags, problems, bool(counts.get(args.new, {}).get("devices")), new_sessions, judged
    )

    if args.json:
        print(json.dumps({
            "window_start": iso_z(start),
            "window_end": iso_z(now),
            "verdict": verdict,
            "new": {"version": args.new, **new_m},
            "old": {"version": args.old, **old_m},
            "new_crash_issues": new_issues.get("count"),
            "new_crash_issues_capped": new_issues.get("capped"),
            "new_crash_events": new_issues.get("events"),
            "new_crash_users": new_issues.get("users"),
            "symbolication": symbolication,
            "breakdown": breakdown,
            "flags": flags,
            "too_little_data": thin,
            "problems": problems,
        }, indent=2))
        return exit_code

    print(f"Transcripted {args.new} vs {args.old}, release builds, {iso_z(start)} to {iso_z(now)}")
    print()
    print(render_table(args.new, args.old, new_m, old_m))
    print()
    if new_issues.get("count") is not None:
        capped = "+" if new_issues.get("capped") else ""
        print(
            f"New unhandled issues first seen in {args.new}: {new_issues['count']}{capped} "
            f"({new_issues.get('events', 0)} events, {new_issue_users} users); "
            f"dSYM missing on {symbolication['missing']} of {symbolication['checked']} checked"
        )
        if args.show_crash_titles:
            for issue in (new_issues.get("issues") or [])[:10]:
                print(f"  - {issue.get('shortId', '')} {issue.get('count', 0)} events: {issue.get('title', '')}")
    if breakdown:
        print(f"\nWhat broke on {args.new} (event | failure_kind | tap step | tap status | end reason | events | devices):")
        for row in breakdown[:10]:
            print("  " + " | ".join(str(cell) for cell in row))
    if thin:
        print(f"\nToo little data to judge yet (under {MIN_EVENTS} events or {MIN_SESSIONS} sessions): " + ", ".join(thin))
    for problem in problems:
        print(f"Problem: {problem}")
    for flag in flags:
        print(f"Worse: {flag}")
    print()
    print(verdict_line)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
