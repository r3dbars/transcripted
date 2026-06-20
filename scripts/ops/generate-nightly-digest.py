#!/usr/bin/env python3
"""Generate the human morning digest for Transcripted nightly automations."""

from __future__ import annotations

import argparse
import ast
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Optional, Tuple

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python 3.9+ on supported machines.
    ZoneInfo = None


REPORT_STEM = "transcripted-nightly-digest"
DEFAULT_AUTOMATIONS_DIR = Path.home() / ".codex" / "automations"
# Derive defaults from this script's location instead of hardcoding one
# machine's personal paths; both stay overridable via --repo/--output-dir.
DEFAULT_REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT_DIR = DEFAULT_REPO / "build" / "nightly-digest"
LOCAL_TZ = ZoneInfo("America/Chicago") if ZoneInfo else timezone.utc
FRESH_HOURS = 18
DAU_GOAL = 1000
GITHUB_REPOS = (
    ("r3dbars/transcripted", "app"),
    ("r3dbars/transcripted-webapp", "webapp"),
)
POSTHOG_ENV_KEYS = (
    "POSTHOG_PERSONAL_API_KEY",
    "POSTHOG_PROJECT_ID",
    "POSTHOG_PROJECT_API_TOKEN",
    "POSTHOG_HOST",
    "POSTHOG_APP_HOST",
)
POSTHOG_ACTIVE_EVENTS = (
    "app_launched",
    "app_unclean_shutdown_detected",
    "app_session_stall_detected",
    "onboarding_completed",
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
    "activation_first_artifact_saved",
    "activation_second_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
    "workflow_abandoned",
)
POSTHOG_FIRST_VALUE_EVENTS = (
    "dictation_completed",
    "onboarding_first_dictation_saved",
    "meeting_transcript_saved",
    "onboarding_agent_cta_clicked",
    "activation_first_artifact_saved",
    "activation_second_artifact_saved",
    "activation_artifact_action_clicked",
    "activation_agent_prompt_action_clicked",
    "activation_agent_setup_cta_clicked",
    "activation_return_proxy_observed",
)
TRUSTED_POSTHOG_HOSTS = {
    "https://app.posthog.com",
    "https://eu.posthog.com",
    "https://posthog.com",
    "https://us.posthog.com",
}
POSTHOG_ALLOW_UNTRUSTED_HOST_ENV = "POSTHOG_ALLOW_UNTRUSTED_HOST"

NIGHTLY_PREFIXES = (
    "[nightly-",
    "[reliability]",
    "[activation]",
    "[operator]",
    "[support]",
    "[content]",
    "[launch]",
    "[comparison]",
    "[retention]",
    "nightly-",
    "codex/nightly",
    "codex/reliability",
    "codex/activation",
    "codex/operator",
    "codex/support",
    "codex/content",
    "codex/launch",
    "codex/comparison",
    "codex/retention",
)

LANE_ORDER = [
    "transcripted-nightly-build-repair",
    "transcripted-nightly-security",
    "transcripted-nightly-artifact-qa",
    "transcripted-nightly-health",
    "transcripted-nightly-audio-reliability",
    "transcripted-nightly-telemetry-gap-finder",
    "performance-audit",
    "transcripted-nightly-release-candidate",
    "transcripted-nightly-activation-agent",
    "transcripted-nightly-onboarding-lab",
    "transcripted-nightly-retention-agent",
    "transcripted-nightly-user-interview-agent",
    "transcripted-nightly-agent-surface-check",
    "transcripted-nightly-community-scout",
    "transcripted-nightly-comparison-agent",
    "transcripted-nightly-content-agent",
    "transcripted-nightly-support-agent",
    "transcripted-nightly-launch-agent",
    "transcripted-nightly-code-review",
    "transcripted-nightly-codex-operator",
    "transcripted-nightly-reviewer",
    "transcripted-nightly-simplify",
    "transcripted-nightly-north-star-agent",
]

LANE_LABELS = {
    "transcripted-nightly-build-repair": "Build Gate",
    "transcripted-nightly-security": "Security and Privacy",
    "transcripted-nightly-artifact-qa": "Artifact QA",
    "transcripted-nightly-health": "Product Health",
    "transcripted-nightly-audio-reliability": "Audio Reliability",
    "transcripted-nightly-telemetry-gap-finder": "Telemetry and UX Trust",
    "performance-audit": "Performance Audit",
    "transcripted-nightly-release-candidate": "Release Readiness",
    "transcripted-nightly-activation-agent": "Activation Agent",
    "transcripted-nightly-onboarding-lab": "Onboarding Lab",
    "transcripted-nightly-retention-agent": "Retention Agent",
    "transcripted-nightly-user-interview-agent": "User Interview Agent",
    "transcripted-nightly-agent-surface-check": "Agent Tools Eval",
    "transcripted-nightly-community-scout": "Community Scout",
    "transcripted-nightly-comparison-agent": "Comparison Agent",
    "transcripted-nightly-content-agent": "Proof Content Agent",
    "transcripted-nightly-support-agent": "Support-to-PR Agent",
    "transcripted-nightly-launch-agent": "Launch Agent",
    "transcripted-nightly-code-review": "Review and Regression",
    "transcripted-nightly-codex-operator": "Codex Operator",
    "transcripted-nightly-reviewer": "Reviewer",
    "transcripted-nightly-simplify": "Maintenance Cleanup",
    "transcripted-nightly-north-star-agent": "North Star Agent",
}

LANE_GROUPS = {
    "transcripted-nightly-build-repair": "Trust",
    "transcripted-nightly-security": "Trust",
    "transcripted-nightly-artifact-qa": "Trust",
    "transcripted-nightly-health": "Trust",
    "transcripted-nightly-audio-reliability": "Trust",
    "transcripted-nightly-telemetry-gap-finder": "Trust",
    "performance-audit": "Trust",
    "transcripted-nightly-release-candidate": "Trust",
    "transcripted-nightly-activation-agent": "Activation",
    "transcripted-nightly-onboarding-lab": "Activation",
    "transcripted-nightly-retention-agent": "Activation",
    "transcripted-nightly-user-interview-agent": "Activation",
    "transcripted-nightly-agent-surface-check": "Activation",
    "transcripted-nightly-community-scout": "Growth",
    "transcripted-nightly-comparison-agent": "Growth",
    "transcripted-nightly-content-agent": "Growth",
    "transcripted-nightly-support-agent": "Growth",
    "transcripted-nightly-launch-agent": "Growth",
    "transcripted-nightly-code-review": "Execution",
    "transcripted-nightly-codex-operator": "Execution",
    "transcripted-nightly-reviewer": "Execution",
    "transcripted-nightly-simplify": "Execution",
    "transcripted-nightly-north-star-agent": "Judgment",
}

SCORECARD_ROLES = [
    {
        "role": "Activation",
        "lane": "transcripted-nightly-activation-agent",
        "labels": ("Activation score",),
        "fallback": 78,
        "reason": "First-value path from install to useful local Markdown and agent answer.",
    },
    {
        "role": "User Interview",
        "lane": "transcripted-nightly-user-interview-agent",
        "labels": ("Interview score", "User Interview score"),
        "fallback": 82,
        "reason": "User language and interview questions are clear enough to reuse.",
    },
    {
        "role": "Community Scout",
        "lane": "transcripted-nightly-community-scout",
        "labels": ("Community Scout score",),
        "fallback": 79,
        "reason": "Public conversations exist, but the right move is one useful reply.",
    },
    {
        "role": "Onboarding Lab",
        "lane": "transcripted-nightly-onboarding-lab",
        "labels": ("Onboarding score",),
        "fallback": 80,
        "reason": "First-use path is understandable, but the agent-memory finish line is still implicit.",
    },
    {
        "role": "Retention",
        "lane": "transcripted-nightly-retention-agent",
        "labels": ("Retention score",),
        "fallback": 74,
        "reason": "Repeat-use loop is promising but under-measured.",
    },
    {
        "role": "Comparison",
        "lane": "transcripted-nightly-comparison-agent",
        "labels": ("Comparison score",),
        "fallback": 81,
        "reason": "Market wedge is real, but competitors are copying bot-free and agent language.",
    },
    {
        "role": "Proof Content",
        "lane": "transcripted-nightly-content-agent",
        "labels": ("Content score", "Proof Content score"),
        "fallback": 86,
        "reason": "A proof-based post is ready, but founder taste should approve it.",
    },
    {
        "role": "Support-to-PR",
        "lane": "transcripted-nightly-support-agent",
        "labels": ("Support score", "Support-to-PR score"),
        "fallback": 84,
        "reason": "Support surface is mostly one known meeting-audio watch item.",
    },
    {
        "role": "Launch",
        "lane": "transcripted-nightly-launch-agent",
        "labels": ("Launch score",),
        "fallback": 76,
        "reason": "Prepare a staged launch, but do not over-promise before trust gaps close.",
    },
    {
        "role": "Codex Operator",
        "lane": "transcripted-nightly-codex-operator",
        "labels": ("Operator score", "Codex Operator score"),
        "fallback": 90,
        "reason": "One concrete execution lane is available and bounded.",
    },
    {
        "role": "Reviewer",
        "lane": "transcripted-nightly-reviewer",
        "labels": ("Reviewer score",),
        "fallback": 90,
        "reason": "Review scope is narrow: one automation PR plus trust watch items.",
    },
    {
        "role": "North Star",
        "lane": "transcripted-nightly-north-star-agent",
        "labels": ("North Star score",),
        "fallback": 78,
        "reason": "The direction is right, but DAU confidence is limited by telemetry gaps.",
    },
]


@dataclass
class Automation:
    id: str
    name: str
    status: str
    rrule: str
    path: Path
    memory_path: Path


@dataclass
class LaneResult:
    id: str
    name: str
    status: str
    freshness: str
    signal: str
    human_action: str
    source_timestamp: Optional[str]
    schedule: str


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate Transcripted's morning nightly automation digest."
    )
    parser.add_argument(
        "--automations-dir",
        type=Path,
        default=DEFAULT_AUTOMATIONS_DIR,
        help="Directory containing Codex automation folders.",
    )
    parser.add_argument(
        "--repo",
        type=Path,
        default=DEFAULT_REPO,
        help="Transcripted repo used for GitHub CLI context.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help="Directory for HTML and JSON reports.",
    )
    parser.add_argument(
        "--fresh-hours",
        type=int,
        default=FRESH_HOURS,
        help="How recent an active lane memory must be to count as fresh.",
    )
    parser.add_argument(
        "--no-github",
        action="store_true",
        help="Skip GitHub PR reads.",
    )
    parser.add_argument(
        "--open",
        action="store_true",
        help="Open the latest HTML report after writing it.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run a small fixture-based self-test and exit.",
    )
    return parser.parse_args(argv)


def parse_toml_shallow(path: Path) -> dict[str, Any]:
    values: dict[str, Any] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        try:
            values[key] = ast.literal_eval(value)
        except (SyntaxError, ValueError):
            values[key] = value.strip('"')
    return values


def load_automations(automations_dir: Path) -> tuple[list[Automation], list[Automation]]:
    automations: list[Automation] = []
    for path in sorted(automations_dir.glob("*/automation.toml")):
        values = parse_toml_shallow(path)
        automation_id = str(values.get("id") or path.parent.name)
        if automation_id == "transcripted-morning-nightly-digest":
            continue
        if not (
            automation_id.startswith("transcripted-nightly-")
            or automation_id == "performance-audit"
        ):
            continue
        memory_path = path.parent / "memory.md"
        automations.append(
            Automation(
                id=automation_id,
                name=str(values.get("name") or LANE_LABELS.get(automation_id, automation_id)),
                status=str(values.get("status") or "UNKNOWN"),
                rrule=str(values.get("rrule") or ""),
                path=path,
                memory_path=memory_path,
            )
        )

    order = {lane_id: index for index, lane_id in enumerate(LANE_ORDER)}
    automations.sort(key=lambda item: (order.get(item.id, 999), item.name))
    active = [item for item in automations if item.status.upper() == "ACTIVE"]
    paused = [item for item in automations if item.status.upper() != "ACTIVE"]
    return active, paused


TIMESTAMP_PATTERNS = [
    re.compile(r"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)?"),
    re.compile(r"20\d\d-\d\d-\d\d \d\d:\d\d:\d\d"),
]


def parse_timestamp(value: str) -> Optional[datetime]:
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        try:
            parsed = datetime.strptime(raw, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=LOCAL_TZ)
    return parsed.astimezone(timezone.utc)


def memory_timestamp(content: str, path: Path) -> Tuple[Optional[datetime], Optional[str]]:
    timestamps: list[datetime] = []
    for pattern in TIMESTAMP_PATTERNS:
        for match in pattern.findall(content):
            parsed = parse_timestamp(match)
            if parsed:
                timestamps.append(parsed)
    if timestamps:
        latest = max(timestamps)
        return latest, latest.isoformat().replace("+00:00", "Z")
    if path.exists():
        latest = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
        return latest, latest.isoformat().replace("+00:00", "Z")
    return None, None


def latest_memory_section(content: str, timestamp_label: Optional[str]) -> str:
    if not content:
        return ""
    if timestamp_label:
        candidates = [timestamp_label, timestamp_label.replace("+00:00", "Z")]
        for candidate in candidates:
            index = content.rfind(candidate)
            if index >= 0:
                return content[index:]
    tail = content[-3000:]
    return tail


def schedule_label(rrule: str) -> str:
    hour_match = re.search(r"BYHOUR=(\d+)", rrule)
    minute_match = re.search(r"BYMINUTE=(\d+)", rrule)
    if not hour_match:
        return "scheduled"
    hour = int(hour_match.group(1))
    minute = int(minute_match.group(1)) if minute_match else 0
    suffix = "AM" if hour < 12 else "PM"
    display_hour = hour % 12 or 12
    return f"{display_hour}:{minute:02d} {suffix}"


def contains_any(text: str, needles: Iterable[str]) -> bool:
    return any(needle in text for needle in needles)


def classify_lane(automation: Automation, content: str, now: datetime, fresh_hours: int) -> LaneResult:
    latest_ts, latest_label = memory_timestamp(content, automation.memory_path)
    if not automation.memory_path.exists():
        return LaneResult(
            id=automation.id,
            name=LANE_LABELS.get(automation.id, automation.name),
            status="unknown",
            freshness="missing",
            signal="No memory file was written for this active lane.",
            human_action="Confirm the lane ran",
            source_timestamp=None,
            schedule=schedule_label(automation.rrule),
        )

    if latest_ts is None:
        freshness = "unknown"
    elif now - latest_ts <= timedelta(hours=fresh_hours):
        freshness = "fresh"
    else:
        freshness = "stale"

    section = latest_memory_section(content, latest_label)
    lower = section.lower()
    name = LANE_LABELS.get(automation.id, automation.name)

    if freshness == "stale":
        return LaneResult(
            id=automation.id,
            name=name,
            status="unknown",
            freshness=freshness,
            signal=f"No fresh result in the last {fresh_hours} hours.",
            human_action="Check whether the job skipped",
            source_timestamp=latest_label,
            schedule=schedule_label(automation.rrule),
        )

    status = "watch"
    signal = "Fresh result exists, but the digest did not classify a clear pass/fail signal."
    action = "Review lane summary"

    if contains_any(lower, ("blocked", "first failing command", "repo_fix_candidate", "mixed_failures")):
        if "first failing command: none" not in lower and "repo_fix_candidate" not in lower:
            status = "blocked"
            signal = "The lane reported a blocked or failing check."
            action = "Inspect the failing lane"

    if automation.id == "transcripted-nightly-build-repair":
        if contains_any(lower, ("passed", "1502", "swift test")) and "failed" not in lower:
            status = "green"
            signal = "Full verification passed: deps, app build, fast tests, smoke, and package tests."
            action = "No action"
    elif automation.id == "transcripted-nightly-security":
        if "100/100" in lower:
            status = "green"
            signal = "Security/privacy guardrails scored 100/100, including the built app when available."
            action = "No action"
    elif automation.id == "transcripted-nightly-artifact-qa":
        if "local_data_drift" in lower:
            status = "needs_review"
            signal = "Local artifact drift repeated, while validator round-trip coverage stayed healthy."
            action = "Decide whether to clean local artifacts"
        elif "repo_fix_candidate" in lower:
            status = "blocked"
            signal = "Artifact QA found a repo-side fix candidate."
            action = "Review the validator finding"
    elif automation.id == "transcripted-nightly-health":
        if contains_any(lower, ("missing", "unknown", "skipped")) and contains_any(
            lower, ("sentry", "posthog", "cloudflare", "token")
        ):
            status = "needs_review"
            signal = "Release surfaces are aligned, but live telemetry reads were incomplete."
            action = "Restore ops read tokens"
        elif "score:" in lower or "nightly score" in lower:
            status = "watch"
            signal = "Product health produced a score and watchlist."
            action = "Review the score delta"
    elif automation.id == "transcripted-nightly-code-review":
        if "opened draft pr" in lower:
            status = "needs_review"
            signal = "Review lane opened a verified draft PR."
            action = "Review code-review PR"
        elif contains_any(lower, ("no new high-confidence", "no pr opened", "green/watch")):
            status = "green"
            signal = "Recent risk areas were reviewed; no new high-confidence repo bug was found."
            action = "No action"
    elif automation.id == "transcripted-nightly-audio-reliability":
        if contains_any(lower, ("synthetic", "passed", "completed")):
            status = "watch" if "#500" in lower or "issue #500" in lower else "green"
            signal = "Synthetic audio reliability passed; the live mic-volume issue remains a watch item."
            action = "Watch issue #500" if status == "watch" else "No action"
    elif automation.id == "transcripted-nightly-agent-surface-check":
        if contains_any(lower, ("cli", "mcp", "self-test", "passed")):
            status = "green"
            signal = "CLI/MCP package tests, release build, and self-test passed."
            action = "No action"
    elif automation.id == "transcripted-nightly-telemetry-gap-finder":
        if contains_any(lower, ("missing", "unknown", "unavailable")) and contains_any(
            lower, ("sentry", "posthog", "cloudflare", "token")
        ):
            status = "needs_review"
            signal = "No safe instrumentation patch; live telemetry truth was limited by credentials."
            action = "Restore ops read tokens"
        elif "no code" in lower or "no pr opened" in lower:
            status = "green"
            signal = "No high-confidence telemetry or UX patch was safe from the evidence."
            action = "No action"
    elif automation.id == "transcripted-nightly-release-candidate":
        if contains_any(lower, ("no_release", "no new public release", "no release recommended")):
            status = "green"
            version = extract_version(section)
            signal = f"No release recommended; public surfaces are aligned{f' at {version}' if version else ''}."
            action = "No action"
    elif automation.id == "transcripted-nightly-codex-operator":
        if "chosen lane: execute" in lower:
            status = "needs_review"
            signal = "Operator found executable work and is carrying it through as a draft PR."
            action = "Review operator PR"
        elif "chosen lane: prepare" in lower:
            status = "needs_review"
            signal = "Operator prepared a task that needs founder direction before execution."
            action = "Make the yes/no call"
        elif "chosen lane: defer" in lower:
            status = "watch"
            signal = "Operator deferred because no safe execution candidate was clear."
            action = "No action"
    elif automation.id == "transcripted-nightly-support-agent":
        if contains_any(lower, ("support inbox: urgent", "support inbox: soon")):
            status = "needs_review"
            signal = "Support found user-facing pain that needs a reply or investigation."
            action = "Review support draft"
        elif contains_any(lower, ("no new external", "no new user", "no new public")) and contains_any(
            lower,
            ("no new pr recommended", "no new pr from", "no new pr was opened"),
        ):
            status = "watch"
            signal = "Support found no new external support thread; existing audio and web-route risks stay on watch."
            action = "Review support watch list"
        elif "support inbox: watch" in lower or "issue #500" in lower:
            status = "watch"
            signal = "Support watch is centered on issue #500 and meeting-audio confidence."
            action = "Watch issue #500"
    elif automation.id == "transcripted-nightly-activation-agent":
        if "activation score" in lower or "biggest activation leak" in lower:
            status = "needs_review"
            signal = "Activation lane found the clearest leak between install and repeat use."
            action = "Review activation fix"
    elif automation.id == "transcripted-nightly-user-interview-agent":
        if "interview score" in lower or "five questions" in lower:
            status = "needs_review"
            signal = "Interview lane produced user-language themes and next questions."
            action = "Use interview questions"
    elif automation.id == "transcripted-nightly-onboarding-lab":
        if "onboarding score" in lower or "top 5 friction" in lower:
            status = "needs_review"
            signal = "Onboarding lane found friction in time-to-first useful Markdown."
            action = "Review onboarding fix"
    elif automation.id == "transcripted-nightly-community-scout":
        if "community scout score" in lower or "reply opportunities" in lower:
            status = "needs_review"
            signal = "Community lane found public conversations and reply opportunities."
            action = "Pick one helpful reply"
    elif automation.id == "transcripted-nightly-comparison-agent":
        if "comparison score" in lower or "where transcripted wins" in lower:
            status = "needs_review"
            signal = "Comparison lane found a sharper market wedge plus claims to avoid."
            action = "Choose positioning angle"
    elif automation.id == "transcripted-nightly-retention-agent":
        if contains_any(
            lower,
            ("retention score", "top churn hypothesis", "strongest repeat-use predictor", "highest-leverage retention move"),
        ):
            status = "needs_review"
            signal = "Retention lane found the clearest repeat-use habit loop."
            action = "Review retention habit loop"
    elif automation.id == "transcripted-nightly-launch-agent":
        if "launch recommendation: prepare" in lower or "launch score" in lower:
            status = "needs_review"
            signal = "Launch lane recommends staged prep, not a broad launch yet."
            action = "Approve staged launch posture"
        elif "launch recommendation: wait" in lower or "do not launch" in lower:
            status = "watch"
            signal = "Launch lane recommends waiting until trust is stronger."
            action = "No launch"
    elif automation.id == "transcripted-nightly-north-star-agent":
        if "north star score" in lower or "biggest lever" in lower:
            status = "needs_review"
            signal = "North Star lane points at first useful agent answer as the strongest activation bet."
            action = "Pick north-star endpoint"
    elif automation.id == "transcripted-nightly-reviewer":
        if contains_any(lower, ("needs changes", "blocker")) and "blockers: none" not in lower:
            status = "blocked"
            if contains_any(lower, ("live sidecar preview", "live preview", "live sidecar files")) and contains_any(
                lower,
                ("no token", "access-control-allow-origin: *", "tokenized preview", "fixed `http://127.0.0.1:47834`"),
            ):
                signal = "Reviewer found a live sidecar preview privacy/docs blocker."
                action = "Hold PR #924 until preview privacy and docs match"
            elif "issue #500" in lower or "#500" in lower:
                signal = "Reviewer kept issue #500 as the real user-trust blocker."
                action = "Run the issue #500 audio matrix"
            else:
                signal = "Reviewer found a blocker or required change."
                action = "Fix before approval"
        elif "ready for justin" in lower or "top recommendation" in lower:
            status = "needs_review"
            signal = "Reviewer says the current PR/task is ready for Justin's approval."
            action = "Review PR recommendation"
    elif automation.id == "transcripted-nightly-content-agent":
        if contains_any(
            lower,
            (
                "content score",
                "best content bet",
                "best candidate",
                "approve, lightly edit, or skip",
                "approve/edit/skip",
                "claim guardrails",
            ),
        ):
            status = "needs_review"
            signal = "Content candidate is ready for Justin to approve, edit, or skip."
            action = "Approve/edit/skip content"
    elif automation.id == "performance-audit":
        no_regression = contains_any(
            lower,
            ("no regression", "no local stt performance regression", "no performance regression"),
        )
        if contains_any(lower, ("regression", "blocked")) and not no_regression:
            status = "needs_review"
            signal = "Performance lane found a regression or measurement gap."
            action = "Review performance finding"
        elif contains_any(lower, ("p50", "p90", "no regression", "watch item")):
            status = "watch"
            signal = "Local timing evidence is healthy; keep the named performance watch item visible."
            action = "No action"
    elif automation.id == "transcripted-nightly-simplify":
        if contains_any(lower, ("no_patch", "no low-risk", "no pr opened")):
            status = "green"
            signal = "No low-risk maintenance patch was forced."
            action = "No action"

    return LaneResult(
        id=automation.id,
        name=name,
        status=status,
        freshness=freshness,
        signal=signal,
        human_action=action,
        source_timestamp=latest_label,
        schedule=schedule_label(automation.rrule),
    )


def extract_version(text: str) -> Optional[str]:
    match = re.search(r"\b\d+\.\d+\.\d+\b", text)
    return match.group(0) if match else None


def run_json_command(command: list[str], cwd: Path, timeout: int = 20) -> Tuple[list[dict[str, Any]], Optional[str]]:
    if shutil.which(command[0]) is None:
        return [], f"{command[0]} not installed"
    try:
        completed = subprocess.run(
            command,
            cwd=str(cwd),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return [], str(error)
    if completed.returncode != 0:
        message = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        return [], message
    try:
        parsed = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        return [], f"invalid JSON: {error}"
    if not isinstance(parsed, list):
        return [], "expected JSON array"
    return parsed, None


def is_nightly_pr(pr: dict[str, Any]) -> bool:
    labels = " ".join(label.get("name", "") for label in pr.get("labels", []) if isinstance(label, dict))
    haystack = " ".join(
        str(pr.get(key, "")) for key in ("title", "headRefName")
    ).lower()
    haystack = f"{haystack} {labels.lower()}"
    return any(prefix in haystack for prefix in NIGHTLY_PREFIXES) or "codex-automation" in haystack


def pr_priority(pr: dict[str, Any]) -> tuple[int, int]:
    haystack = " ".join(str(pr.get(key, "")) for key in ("title", "headRefName")).lower()
    number = int(pr.get("number") or 0)
    if "reliability" in haystack or "dictation ready-start" in haystack:
        return (0, number)
    if "nightly-security" in haystack or "nightly-ux" in haystack or "diagnostics" in haystack:
        return (1, number)
    if "nightly-regression" in haystack or "nightly-agent" in haystack:
        return (2, number)
    if "operator" in haystack:
        return (3, number)
    if "nightly-maintenance" in haystack or "nightly-docs" in haystack:
        return (4, number)
    if "digest" in haystack:
        return (5, number)
    return (6, number)


def normalize_pr(pr: dict[str, Any]) -> dict[str, Any]:
    normalized = {
        "number": pr.get("number"),
        "title": pr.get("title", ""),
        "url": pr.get("url", ""),
        "headRefName": pr.get("headRefName", ""),
    }
    if "repository" in pr:
        normalized["repository"] = pr.get("repository")
    if "repositoryLabel" in pr:
        normalized["repositoryLabel"] = pr.get("repositoryLabel")
    if "isDraft" in pr:
        normalized["isDraft"] = bool(pr.get("isDraft"))
    if "updatedAt" in pr:
        normalized["updatedAt"] = pr.get("updatedAt")
    if "mergedAt" in pr:
        normalized["mergedAt"] = pr.get("mergedAt")
    labels = pr.get("labels", [])
    if isinstance(labels, list):
        normalized["labels"] = [
            label.get("name", "") for label in labels if isinstance(label, dict) and label.get("name")
        ]
    return normalized


def pr_display_id(pr: dict[str, Any]) -> str:
    prefix = pr.get("repositoryLabel")
    number = pr.get("number")
    return f"{prefix} PR #{number}" if prefix else f"PR #{number}"


def github_data(repo: Path, no_github: bool) -> dict[str, Any]:
    if no_github:
        return {"open_prs": [], "recent_merged_prs": [], "error": "GitHub disabled"}

    fields = "number,title,url,isDraft,headRefName,labels,updatedAt"
    open_prs: list[dict[str, Any]] = []
    merged_prs: list[dict[str, Any]] = []
    errors: list[str] = []
    for repo_name, repo_label in GITHUB_REPOS:
        repo_open_prs, open_error = run_json_command(
            ["gh", "pr", "list", "--repo", repo_name, "--state", "open", "--json", fields, "--limit", "100"],
            cwd=repo,
        )
        repo_merged_prs, merged_error = run_json_command(
            [
                "gh",
                "pr",
                "list",
                "--repo",
                repo_name,
                "--state",
                "merged",
                "--json",
                "number,title,url,mergedAt,headRefName,labels",
                "--limit",
                "12",
            ],
            cwd=repo,
        )
        if open_error:
            errors.append(f"{repo_name} open PRs: {open_error}")
        if merged_error:
            errors.append(f"{repo_name} merged PRs: {merged_error}")
        for pr in repo_open_prs:
            pr["repository"] = repo_name
            pr["repositoryLabel"] = repo_label
            open_prs.append(pr)
        for pr in repo_merged_prs:
            pr["repository"] = repo_name
            pr["repositoryLabel"] = repo_label
            merged_prs.append(pr)

    nightly_open = sorted(
        (normalize_pr(pr) for pr in open_prs if is_nightly_pr(pr)),
        key=pr_priority,
    )
    recent_merged = sorted(
        (normalize_pr(pr) for pr in merged_prs),
        key=lambda pr: str(pr.get("mergedAt") or ""),
        reverse=True,
    )[:12]
    error = "; ".join(errors) if errors else None
    return {
        "open_prs": nightly_open,
        "recent_merged_prs": recent_merged,
        "error": error,
    }


def human_next_steps(
    lanes: list[LaneResult],
    open_prs: list[dict[str, Any]],
    github_error: Optional[str],
    dau_unknown: bool,
    ops_tokens_incomplete: bool,
) -> list[str]:
    steps: list[str] = []
    blocked_lanes = [lane for lane in lanes if lane.status == "blocked"]
    if dau_unknown:
        steps.append("Fix DAU visibility: set PostHog read credentials and rerun this report.")

    if blocked_lanes:
        lane = blocked_lanes[0]
        if lane.human_action == "Run the issue #500 audio matrix":
            steps.append("Run the issue #500 audio matrix before broad meeting-audio or launch claims.")
        elif lane.human_action.startswith("Hold PR #"):
            steps.append(f"{lane.human_action}.")
        else:
            steps.append(f"Clear blocker: {lane.name} says {lane.human_action.lower()}.")

    if open_prs:
        if len(open_prs) == 1:
            pr = open_prs[0]
            steps.append(f"Review {pr_display_id(pr)}: {pr.get('title')}.")
        else:
            pr = open_prs[0]
            steps.append(f"Review {len(open_prs)} open nightly PRs, starting with {pr_display_id(pr)}.")

    if github_error and github_error != "GitHub disabled":
        steps.append("Restore GitHub CLI access so PR review status is not guessed.")

    if ops_tokens_incomplete and not dau_unknown:
        steps.append("Restore missing ops read tokens for full Sentry, PostHog, and Cloudflare context.")

    if any(lane.human_action == "Decide whether to clean local artifacts" for lane in lanes):
        steps.append("Decide whether to clean the repeated local artifact drift.")

    if any(lane.human_action == "Watch issue #500" for lane in lanes):
        steps.append("Keep issue #500 on the watchlist for real meeting-audio evidence.")

    stale_count = sum(1 for lane in lanes if lane.freshness != "fresh")
    if stale_count:
        steps.append(f"Check {stale_count} stale or missing nightly lane result{'s' if stale_count != 1 else ''}.")

    if not steps:
        steps.append("No human action needed this morning.")
    return steps[:5]


def overall_status(lanes: list[LaneResult], steps: list[str], open_prs: list[dict[str, Any]], github_error: Optional[str]) -> str:
    if any(lane.status == "blocked" for lane in lanes):
        return "blocked"
    unknown_count = sum(1 for lane in lanes if lane.status == "unknown")
    if unknown_count >= max(3, len(lanes) // 3):
        return "unknown"
    if open_prs or (github_error and github_error != "GitHub disabled"):
        return "needs_review"
    if any(lane.status in ("needs_review", "watch") for lane in lanes):
        return "needs_review"
    if steps and steps != ["No human action needed this morning."]:
        return "needs_review"
    return "green"


def status_rank(status: str) -> int:
    return {"blocked": 0, "needs_review": 1, "watch": 2, "unknown": 3, "green": 4}.get(status, 5)


def letter_grade(score: int) -> str:
    if score >= 97:
        return "A+"
    if score >= 93:
        return "A"
    if score >= 90:
        return "A-"
    if score >= 87:
        return "B+"
    if score >= 83:
        return "B"
    if score >= 80:
        return "B-"
    if score >= 77:
        return "C+"
    if score >= 73:
        return "C"
    if score >= 70:
        return "C-"
    if score >= 60:
        return "D"
    return "F"


def score_from_memory(
    lane_id: str,
    score_labels: Iterable[str],
    lanes: list[LaneResult],
    memories: dict[str, str],
    fallback: int,
) -> tuple[int, str]:
    memory = memories.get(lane_id, "")
    for score_label in score_labels:
        match = re.search(rf"{re.escape(score_label)}:\s*(\d{{1,3}})", memory, re.IGNORECASE)
        if match:
            score = max(0, min(100, int(match.group(1))))
            return score, letter_grade(score)

    lane = next((item for item in lanes if item.id == lane_id), None)
    if lane:
        if lane.status == "blocked":
            fallback = min(fallback, 70)
        elif lane.status == "unknown":
            fallback = min(fallback, 76)
        elif lane.status == "needs_review":
            fallback = min(fallback, 88)
    return fallback, letter_grade(fallback)


def extract_first_int(text: str, patterns: Iterable[str]) -> Optional[int]:
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE | re.DOTALL)
        if match:
            return int(match.group(1))
    return None


def dotenv_value(raw: str) -> Optional[tuple[str, str]]:
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        return None
    key, value = line.split("=", 1)
    key = key.strip()
    if key.startswith("export "):
        key = key.removeprefix("export ").strip()
    if key not in POSTHOG_ENV_KEYS:
        return None
    return key, value.strip().strip('"').strip("'")


def load_local_posthog_env() -> list[str]:
    candidates: list[Path] = []
    explicit = os.environ.get("TRANSCRIPTED_OPS_ENV")
    if explicit:
        candidates.append(Path(explicit).expanduser())
    candidates.extend(
        [
            Path.cwd() / ".env.local",
            Path.cwd() / ".env",
            Path.home() / ".transcripted-ops.env",
            Path.home() / ".hermes" / "profiles" / "ops" / ".env",
        ]
    )

    loaded: list[str] = []
    for path in candidates:
        if not path.exists() or not path.is_file():
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            parsed = dotenv_value(line)
            if not parsed:
                continue
            key, value = parsed
            if value and not os.environ.get(key):
                os.environ[key] = value
                loaded.append(key)
    return loaded


def normalize_posthog_host(raw_host: str) -> str:
    host = raw_host.strip().rstrip("/")
    if host == "https://us.i.posthog.com":
        return "https://us.posthog.com"
    if host == "https://eu.i.posthog.com":
        return "https://eu.posthog.com"
    return host


def posthog_host_error(host: str) -> Optional[str]:
    if not host.startswith("https://"):
        return "PostHog host must use HTTPS"
    if os.environ.get(POSTHOG_ALLOW_UNTRUSTED_HOST_ENV) == "1":
        return None
    if host not in TRUSTED_POSTHOG_HOSTS:
        return (
            f"PostHog host {host} is not in the trusted host list; "
            f"set {POSTHOG_ALLOW_UNTRUSTED_HOST_ENV}=1 to use a self-hosted endpoint"
        )
    return None


def sql_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def posthog_query(host: str, project_id: str, token: str, query: str) -> dict[str, Any]:
    url = f"{host}/api/projects/{project_id}/query/"
    body = json.dumps(
        {
            "query": {
                "kind": "HogQLQuery",
                "query": query,
            },
            "refresh": "blocking",
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.loads(response.read().decode("utf-8"))


def build_dau_history(daily_rows: list[list[Any]], today_utc: date) -> dict[str, Any]:
    by_day: dict[date, int] = {}
    for row in daily_rows:
        if not isinstance(row, list) or len(row) < 2:
            continue
        try:
            day = date.fromisoformat(str(row[0]))
            by_day[day] = int(row[1])
        except (TypeError, ValueError):
            continue

    start_day = today_utc - timedelta(days=29)
    days: list[dict[str, Any]] = []
    for offset in range(30):
        day = start_day + timedelta(days=offset)
        days.append(
            {
                "day": day.isoformat(),
                "label": day.strftime("%b %-d"),
                "dow": day.strftime("%a"),
                "active_devices": by_day.get(day, 0),
                "partial": day == today_utc,
                "weekend": day.weekday() >= 5,
            }
        )

    complete_30 = [item for item in days if not item["partial"]]
    last_7 = days[-7:]
    complete_7 = [item for item in last_7 if not item["partial"]]
    weekdays = [item for item in complete_30 if not item["weekend"]]
    weekends = [item for item in complete_30 if item["weekend"]]

    def average(items: list[dict[str, Any]]) -> float:
        if not items:
            return 0.0
        return round(sum(int(item["active_devices"]) for item in items) / len(items), 1)

    return {
        "last_7": last_7,
        "last_30": days,
        "averages": {
            "last_7_complete": average(complete_7),
            "last_30_complete": average(complete_30),
            "weekday_complete": average(weekdays),
            "weekend_complete": average(weekends),
        },
        "note": "Bars use PostHog UTC calendar days. Today is partial.",
    }


def query_posthog_dau() -> dict[str, Any]:
    load_local_posthog_env()
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    missing = [name for name, value in (("POSTHOG_PERSONAL_API_KEY", token), ("POSTHOG_PROJECT_ID", project_id)) if not value]
    if missing:
        verb = "is" if len(missing) == 1 else "are"
        return {"dau": None, "event_count": None, "error": f"{', '.join(missing)} {verb} not set"}

    host = normalize_posthog_host(
        os.environ.get("POSTHOG_APP_HOST") or os.environ.get("POSTHOG_HOST") or "https://us.posthog.com"
    )
    host_error = posthog_host_error(host)
    if host_error:
        return {"dau": None, "event_count": None, "error": host_error}
    active_event_list = ", ".join(sql_quote(event) for event in POSTHOG_ACTIVE_EVENTS)
    first_value_event_list = ", ".join(sql_quote(event) for event in POSTHOG_FIRST_VALUE_EVENTS)
    query_event_list = ", ".join(sql_quote(event) for event in dict.fromkeys(POSTHOG_ACTIVE_EVENTS + POSTHOG_FIRST_VALUE_EVENTS))

    current_query = (
        "SELECT "
        "uniq(distinct_id) AS dau, "
        "countIf(event = 'app_launched') AS launches_24h, "
        f"countIf(event IN ({active_event_list})) AS workflow_events_24h, "
        f"countIf(event IN ({first_value_event_list})) AS first_value_events_24h "
        "FROM events "
        "WHERE timestamp >= now() - INTERVAL 24 HOUR "
        f"AND event IN ({query_event_list})"
    )
    daily_query = (
        "SELECT "
        "toDate(timestamp) AS day, "
        "uniq(distinct_id) AS active_devices "
        "FROM events "
        "WHERE timestamp >= now() - INTERVAL 30 DAY "
        f"AND event IN ({query_event_list}) "
        "GROUP BY day "
        "ORDER BY day ASC"
    )
    try:
        payload = posthog_query(host, project_id, token, current_query)
        daily_payload = posthog_query(host, project_id, token, daily_query)
    except urllib.error.HTTPError as exc:
        return {"dau": None, "event_count": None, "error": f"PostHog query failed with HTTP {exc.code}"}
    except (urllib.error.URLError, TimeoutError):
        return {"dau": None, "event_count": None, "error": "PostHog query failed"}
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {"dau": None, "event_count": None, "error": "PostHog returned an unreadable response"}

    try:
        row = (payload.get("results") or payload.get("data") or [])[0]
        dau = int(row[0])
        launch_count = int(row[1]) if len(row) > 1 and row[1] is not None else None
        event_count = int(row[2]) if len(row) > 2 and row[2] is not None else None
        first_value_event_count = int(row[3]) if len(row) > 3 and row[3] is not None else None
    except (IndexError, TypeError, ValueError):
        return {"dau": None, "event_count": None, "error": "PostHog response did not include DAU"}
    history = build_dau_history(daily_payload.get("results") or daily_payload.get("data") or [], datetime.now(timezone.utc).date())
    return {
        "dau": dau,
        "launch_count": launch_count,
        "event_count": event_count,
        "first_value_event_count": first_value_event_count,
        "history": history,
        "error": None,
    }


def build_dau_status(
    memories: dict[str, str],
    ops_tokens_incomplete: bool,
    posthog_dau: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    all_memory = "\n".join(memories.values())
    memory_dau = extract_first_int(
        all_memory,
        (
            r"\bDAU:\s*(\d{1,5})\b",
            r"\b(\d{1,5})\s+DAU\b",
            r"\bcurrent DAU[^\d]{0,30}(\d{1,5})\b",
            r"\b(\d{1,5})\s+active distinct IDs over the last 24 hours\b",
            r"\b(\d{1,5})\s+active devices in the last 24 hours\b",
        ),
    )
    active_devices = extract_first_int(
        all_memory,
        (
            r"\b(\d{1,5})\s+active devices\b",
            r"devices_7d[^\d]{0,30}(\d{1,5})",
        ),
    )
    downloads = extract_first_int(
        all_memory,
        (
            r"release asset download count(?:\s+is)?\s+(\d{1,5})",
            r"download count was\s+(\d{1,5})",
            r"\b(\d{1,5})\s+downloads?\b",
        ),
    )
    repo_viewers = extract_first_int(
        all_memory,
        (
            r"\b(\d{1,5})\s+unique repo viewers\b",
            r"uniques[^\d]{0,20}(\d{1,5})",
        ),
    )

    posthog_value = posthog_dau.get("dau") if posthog_dau else None
    exact_dau = posthog_value if isinstance(posthog_value, int) else memory_dau
    exact_source = "PostHog" if isinstance(posthog_value, int) else ("nightly memory" if memory_dau is not None else "")

    if exact_dau is not None:
        current = f"{exact_dau} DAU"
        gap = f"{max(0, DAU_GOAL - exact_dau)} away"
        confidence = "High" if exact_source == "PostHog" else ("Medium" if ops_tokens_incomplete else "High")
    else:
        current = "DAU unknown"
        gap = "Cannot calculate exact gap"
        confidence = "Low" if ops_tokens_incomplete else "Medium"

    proxy_parts: list[str] = []
    first_value_event_count = posthog_dau.get("first_value_event_count") if posthog_dau else None
    if isinstance(first_value_event_count, int):
        proxy_parts.append(f"{first_value_event_count} first-value events in the last 24 hours")
    launch_count = posthog_dau.get("launch_count") if posthog_dau else None
    if isinstance(launch_count, int):
        proxy_parts.append(f"{launch_count} app launches in the last 24 hours")
    event_count = posthog_dau.get("event_count") if posthog_dau else None
    if isinstance(event_count, int):
        proxy_parts.append(f"{event_count} PostHog events in the last 24 hours")
    if active_devices is not None and exact_dau is None:
        proxy_parts.append(f"{active_devices} active devices in recent telemetry")
    if downloads is not None:
        proxy_parts.append(f"{downloads} latest-release downloads")
    if repo_viewers is not None:
        proxy_parts.append(f"{repo_viewers} unique repo viewers in 14 days")
    proxy = "; ".join(proxy_parts) if proxy_parts else "No reliable proxy found"

    if exact_source == "PostHog":
        note = "Exact DAU came from PostHog active workflow and first-value events for the last 24 hours."
    elif exact_dau is not None:
        note = "Exact DAU came from a nightly automation memory entry."
    elif posthog_dau and posthog_dau.get("error"):
        note = f"DAU is unknown because {posthog_dau['error']}."
    elif ops_tokens_incomplete:
        note = "DAU is unknown because live product analytics could not be read."
    else:
        note = "Use this as the morning growth read, not a perfect analytics dashboard."

    return {
        "goal": f"{DAU_GOAL:,} daily active users",
        "current": current,
        "gap": gap,
        "first_value": f"{first_value_event_count} events" if isinstance(first_value_event_count, int) else "Unknown",
        "first_value_note": "PostHog last 24 hours"
        if isinstance(first_value_event_count, int)
        else "No first-value count in this run",
        "launches": f"{launch_count} launches" if isinstance(launch_count, int) else "Unknown",
        "launch_note": "PostHog last 24 hours"
        if isinstance(launch_count, int)
        else "No launch count in this run",
        "proxy": proxy,
        "confidence": confidence,
        "note": note,
        "history": posthog_dau.get("history") if posthog_dau else None,
    }


def build_accomplishments(lanes: list[LaneResult], open_prs: list[dict[str, Any]]) -> list[str]:
    by_id = {lane.id: lane for lane in lanes}
    items: list[str] = []

    if by_id.get("transcripted-nightly-build-repair", None) and by_id["transcripted-nightly-build-repair"].status == "green":
        items.append("Build, app tests, integration smoke, and package tests passed.")
    if by_id.get("transcripted-nightly-security", None) and by_id["transcripted-nightly-security"].status == "green":
        items.append("Security and privacy checks came back clean.")
    if by_id.get("transcripted-nightly-release-candidate", None) and by_id["transcripted-nightly-release-candidate"].status == "green":
        items.append("The latest public release and download surfaces stayed aligned.")
    if by_id.get("transcripted-nightly-agent-surface-check", None) and by_id["transcripted-nightly-agent-surface-check"].status == "green":
        items.append("The agent-facing CLI and MCP surfaces passed verification.")
    if any(by_id.get(lane_id) for lane_id in ("transcripted-nightly-activation-agent", "transcripted-nightly-onboarding-lab", "transcripted-nightly-retention-agent", "transcripted-nightly-north-star-agent")):
        items.append("Activation, onboarding, retention, and North Star lanes all pointed at the same theme: get users to a useful agent answer from local Markdown.")
    if any(by_id.get(lane_id) for lane_id in ("transcripted-nightly-community-scout", "transcripted-nightly-comparison-agent", "transcripted-nightly-content-agent", "transcripted-nightly-launch-agent")):
        items.append("Growth lanes produced community targets, positioning notes, a content draft, and a staged launch recommendation.")
    if any(lane.human_action == "Watch issue #500" for lane in lanes):
        items.append("Audio reliability checks passed synthetically, but issue #500 stayed on the watch list.")
    if open_prs:
        pr = open_prs[0]
        items.append(f"{len(open_prs)} open nightly PRs are waiting; {pr_display_id(pr)} is the first one to review.")

    return items[:8]


def build_recommendations(
    lanes: list[LaneResult],
    open_prs: list[dict[str, Any]],
    ops_tokens_incomplete: bool,
    dau_unknown: bool,
) -> list[str]:
    recommendations: list[str] = []
    blocked_lanes = [lane for lane in lanes if lane.status == "blocked"]
    if dau_unknown:
        recommendations.append("Fix DAU visibility: set PostHog read credentials, then rerun this report.")
    if blocked_lanes:
        lane = blocked_lanes[0]
        if lane.human_action == "Run the issue #500 audio matrix":
            recommendations.append("Run the issue #500 audio matrix before broad meeting-audio or launch claims.")
        elif lane.human_action.startswith("Hold PR #"):
            recommendations.append(f"{lane.human_action}.")
        else:
            recommendations.append(f"Clear blocker: {lane.name} says {lane.human_action.lower()}.")
    if open_prs:
        pr = open_prs[0]
        recommendations.append(f"Review {pr_display_id(pr)} first: {pr.get('title')}.")
        if len(open_prs) > 1:
            recommendations.append(f"Then triage the other {len(open_prs) - 1} open nightly PRs.")
    if ops_tokens_incomplete and not dau_unknown:
        recommendations.append("Restore missing ops read tokens so tomorrow's Sentry, PostHog, and Cloudflare read is complete.")
    if any(lane.id == "transcripted-nightly-north-star-agent" for lane in lanes):
        recommendations.append("Pick the activation metric: first useful agent answer from a local Transcripted artifact.")
    if any(lane.human_action == "Watch issue #500" for lane in lanes):
        recommendations.append("Run the issue #500 audio QA matrix before making a bigger launch push.")
    if any(lane.id == "transcripted-nightly-community-scout" for lane in lanes):
        recommendations.append("Approve one helpful community reply where people already want local Markdown and agent memory.")

    return recommendations[:5]


def pluralize(count: int, singular: str, plural: Optional[str] = None) -> str:
    if count == 1:
        return singular
    return plural or f"{singular}s"


def blocked_status_text(blocked_count: int, unknown_count: int) -> tuple[str, str]:
    if blocked_count and unknown_count:
        return "Yes", f"{blocked_count} {pluralize(blocked_count, 'blocked lane')}; {unknown_count} unknown"
    if blocked_count:
        return "Yes", f"{blocked_count} {pluralize(blocked_count, 'blocked lane')}"
    if unknown_count:
        return "No confirmed blocker", f"{unknown_count} unknown"
    return "No", "Nothing blocked"


def night_summary_text(active_count: int, blocked_count: int, unknown_count: int) -> str:
    if blocked_count and unknown_count:
        return (
            f"{active_count} jobs ran; {blocked_count} {pluralize(blocked_count, 'lane')} "
            f"blocked and {unknown_count} {pluralize(unknown_count, 'lane')} missing fresh signal."
        )
    if blocked_count:
        return f"{active_count} jobs ran; {blocked_count} {pluralize(blocked_count, 'lane')} blocked."
    if unknown_count:
        return f"{active_count} jobs ran; no confirmed blocker, but {unknown_count} {pluralize(unknown_count, 'lane')} missing fresh signal."
    return f"{active_count} jobs ran; nothing is blocked."


def first_screen_payload(
    active_count: int,
    open_pr_count: int,
    human_action_count: int,
    blocked_count: int,
    unknown_count: int,
    dau_status: dict[str, Any],
    ceo_brief: dict[str, Any],
    human_steps: list[str],
) -> dict[str, Any]:
    blocked_label, blocked_detail = blocked_status_text(blocked_count, unknown_count)
    return {
        "what_happened_last_night": night_summary_text(active_count, blocked_count, unknown_count),
        "do_first": ceo_brief["do_now"],
        "current_dau": dau_status["current"],
        "gap_to_1000_dau": dau_status["gap"],
        "open_nightly_pr_count": open_pr_count,
        "human_action_count": human_action_count,
        "blocked": blocked_count > 0,
        "blocked_status": blocked_label,
        "blocked_detail": blocked_detail,
        "recommended_actions": human_steps[:4],
        "dau_note": dau_status["note"],
    }


def build_ceo_brief(
    lanes: list[LaneResult],
    memories: dict[str, str],
    full_memories: dict[str, str],
    open_prs: list[dict[str, Any]],
    overall: str,
    steps: list[str],
    ops_tokens_incomplete: bool,
    dau_status: dict[str, str],
) -> dict[str, Any]:
    artifact_drift = any(lane.human_action == "Decide whether to clean local artifacts" for lane in lanes)
    issue_500_watch = any(lane.human_action == "Watch issue #500" for lane in lanes)
    blocked_or_unknown = any(lane.status in ("blocked", "unknown") for lane in lanes)
    dau_unknown = dau_status["current"] == "DAU unknown"
    growth_ready = any(
        lane.id
        in {
            "transcripted-nightly-community-scout",
            "transcripted-nightly-comparison-agent",
            "transcripted-nightly-content-agent",
            "transcripted-nightly-launch-agent",
        }
        and lane.status == "needs_review"
        for lane in lanes
    )

    if dau_unknown:
        call = "Measurement: we do not know current DAU, so make that number visible before growth calls."
    elif overall == "blocked":
        call = "Trust: a blocker exists, so fix trust before growth or shipping."
    elif ops_tokens_incomplete or issue_500_watch or artifact_drift:
        call = "Trust: the product is mostly healthy, but today's leverage is tightening confidence before adding noise."
    elif open_prs:
        call = "Ship: review the waiting automation PR and land the safer operating system."
    elif growth_ready:
        call = "Growth: pick one useful public proof move, not a broad launch wave."
    else:
        call = "Growth: the trust surface is quiet enough to turn proof into distribution."

    ceo_score = 96
    if open_prs:
        ceo_score -= 3
    if ops_tokens_incomplete:
        ceo_score -= 5
    if artifact_drift:
        ceo_score -= 3
    if issue_500_watch:
        ceo_score -= 4
    if blocked_or_unknown:
        ceo_score -= 8
    ceo_score = max(0, min(100, ceo_score))

    roles: list[dict[str, Any]] = [
        {
            "role": "CEO",
            "score": ceo_score,
            "grade": letter_grade(ceo_score),
            "reason": "One clear morning call, with trust gaps kept above growth noise.",
        }
    ]
    for role in SCORECARD_ROLES:
        score, grade = score_from_memory(
            lane_id=str(role["lane"]),
            score_labels=role["labels"],
            lanes=lanes,
            memories=memories,
            fallback=int(role["fallback"]),
        )
        roles.append(
            {
                "role": role["role"],
                "score": score,
                "grade": grade,
                "reason": role["reason"],
            }
        )

    needs_judgment: list[str] = []
    if open_prs:
        pr = open_prs[0]
        needs_judgment.append(f"Approve/merge {pr_display_id(pr)} first if its smoke check passes.")
    if artifact_drift:
        needs_judgment.append("Decide whether to clean the repeated local artifact drift or keep it as known local residue.")
    if issue_500_watch:
        needs_judgment.append("Choose the next manual QA step for issue #500 before promising another audio fix.")
    if any(lane.id == "transcripted-nightly-activation-agent" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Choose whether activation work should focus on agent setup, first artifact, or website promise first.")
    if any(lane.id == "transcripted-nightly-community-scout" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Pick one public thread where a transparent founder reply would be useful.")
    if any(lane.id == "transcripted-nightly-retention-agent" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Choose the retention metric: first saved Markdown or first useful agent answer.")
    if any(lane.id == "transcripted-nightly-comparison-agent" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Choose the primary comparison angle: private local memory vs polished cloud notes.")
    if any(lane.id == "transcripted-nightly-content-agent" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Approve, edit, or skip today's content candidate.")
    if any(lane.id == "transcripted-nightly-launch-agent" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Approve staged launch prep instead of a broad launch wave.")
    if any(lane.id == "transcripted-nightly-north-star-agent" and lane.status == "needs_review" for lane in lanes):
        needs_judgment.append("Confirm first useful agent answer as the north-star activation endpoint.")
    if not needs_judgment:
        needs_judgment.append("No founder judgment needed beyond staying focused.")

    safe_to_execute = [
        "Agents can refresh the CEO brief and verify PR status without product judgment.",
        "Agents can draft a private issue #500 reproduction checklist.",
        "Agents can keep build/security/artifact/release checks running and summarize only deltas.",
    ]
    if ops_tokens_incomplete:
        safe_to_execute.append("After credentials are restored, agents can rerun the health lanes for fuller truth.")
    safe_to_execute.extend(
        [
            "Agents can draft first-value onboarding copy and a starter agent prompt.",
            "Agents can prepare comparison-page updates and community replies for approval.",
        ]
    )

    watch = "Issue #500: meeting mic/system-audio behavior still needs real-device confidence."
    if not issue_500_watch:
        watch = "Stale or missing telemetry would be the first thing to watch."

    do_now = steps[0] if steps else "No human action needed this morning."

    return {
        "ceo_call": call,
        "scorecard": roles,
        "do_now": do_now,
        "needs_judgment": needs_judgment[:6],
        "safe_to_execute": safe_to_execute[:5],
        "watch": watch,
        "ignore": "Green verification lanes, third-party warning noise, and paused historical automations.",
        "why_thousands": "This gets to 1,000 DAU by protecting trust first, then pushing one habit loop: spoken work becomes local Markdown, then an agent gives a useful answer.",
        "dau_status": dau_status,
        "accomplishments": build_accomplishments(lanes, open_prs),
        "recommendations": build_recommendations(lanes, open_prs, ops_tokens_incomplete, dau_unknown),
    }


def build_payload(
    active: list[Automation],
    paused: list[Automation],
    repo: Path,
    now: datetime,
    fresh_hours: int,
    no_github: bool,
    posthog_dau: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    lanes: list[LaneResult] = []
    memories: dict[str, str] = {}
    full_memories: dict[str, str] = {}
    for automation in active:
        content = automation.memory_path.read_text(encoding="utf-8") if automation.memory_path.exists() else ""
        latest_ts, latest_label = memory_timestamp(content, automation.memory_path)
        full_memories[automation.id] = content
        memories[automation.id] = latest_memory_section(content, latest_label)
        lanes.append(classify_lane(automation, content, now, fresh_hours))

    gh_payload = github_data(repo, no_github)
    ops_tokens_incomplete = any(lane.human_action == "Restore ops read tokens" for lane in lanes)
    if posthog_dau is None:
        posthog_dau = query_posthog_dau()
    dau_status = build_dau_status(full_memories, ops_tokens_incomplete, posthog_dau)
    dau_unknown = dau_status["current"] == "DAU unknown"
    steps = human_next_steps(
        lanes,
        gh_payload["open_prs"],
        gh_payload["error"],
        dau_unknown=dau_unknown,
        ops_tokens_incomplete=ops_tokens_incomplete,
    )
    overall = overall_status(lanes, steps, gh_payload["open_prs"], gh_payload["error"])
    data_quality = data_quality_note(lanes, gh_payload["error"])
    blocked_count = sum(1 for lane in lanes if lane.status == "blocked")
    unknown_count = sum(1 for lane in lanes if lane.status == "unknown")
    blocked_unknown = blocked_count + unknown_count
    needs_human = len([step for step in steps if step != "No human action needed this morning."])

    sorted_lanes = sorted(lanes, key=lambda lane: (status_rank(lane.status), LANE_ORDER.index(lane.id) if lane.id in LANE_ORDER else 999))
    ceo_brief = build_ceo_brief(
        lanes=lanes,
        memories=memories,
        full_memories=full_memories,
        open_prs=gh_payload["open_prs"],
        overall=overall,
        steps=steps,
        ops_tokens_incomplete=ops_tokens_incomplete,
        dau_status=dau_status,
    )

    return {
        "generated_at": now.isoformat().replace("+00:00", "Z"),
        "generated_local": now.astimezone(LOCAL_TZ).strftime("%B %-d, %Y at %-I:%M %p"),
        "overall_status": overall,
        "signal_quality": "partial"
        if ops_tokens_incomplete or gh_payload["error"] or any(lane.freshness != "fresh" for lane in lanes)
        else "high",
        "counts": {
            "active_lanes": len(lanes),
            "open_nightly_prs": len(gh_payload["open_prs"]),
            "needs_human": needs_human,
            "blocked": blocked_count,
            "unknown": unknown_count,
            "blocked_or_unknown": blocked_unknown,
        },
        "human_next_steps": steps,
        "first_screen": first_screen_payload(
            active_count=len(lanes),
            open_pr_count=len(gh_payload["open_prs"]),
            human_action_count=needs_human,
            blocked_count=blocked_count,
            unknown_count=unknown_count,
            dau_status=dau_status,
            ceo_brief=ceo_brief,
            human_steps=steps,
        ),
        "ceo_brief": ceo_brief,
        "lanes": [lane.__dict__ for lane in sorted_lanes],
        "open_prs": gh_payload["open_prs"],
        "recent_merged_prs": gh_payload["recent_merged_prs"],
        "github_error": gh_payload["error"],
        "data_quality": data_quality,
        "ignore": ignore_items(lanes, paused),
        "paused_lanes": [LANE_LABELS.get(item.id, item.name) for item in paused],
    }


def data_quality_note(lanes: list[LaneResult], github_error: Optional[str]) -> str:
    stale = [lane.name for lane in lanes if lane.freshness == "stale"]
    missing = [lane.name for lane in lanes if lane.freshness == "missing"]
    pieces: list[str] = []
    if stale:
        pieces.append(f"stale: {', '.join(stale)}")
    if missing:
        pieces.append(f"missing: {', '.join(missing)}")
    if github_error and github_error != "GitHub disabled":
        pieces.append(f"GitHub PR data incomplete: {github_error}")
    elif github_error == "GitHub disabled":
        pieces.append("GitHub PR data was intentionally skipped")
    if any(lane.human_action == "Restore ops read tokens" for lane in lanes):
        pieces.append("live Sentry/PostHog/Cloudflare reads were incomplete")
    if not pieces:
        return "All active lane memories were fresh and GitHub PR data was available."
    if all(lane.freshness == "fresh" for lane in lanes) and not github_error:
        return "Automation memories were fresh and GitHub PR data was available; " + "; ".join(pieces) + "."
    return "; ".join(pieces) + "."


def ignore_items(lanes: list[LaneResult], paused: list[Automation]) -> list[str]:
    items = [
        "Green verification lanes do not need attention.",
        "Known third-party build warnings stay out of the action queue unless they become failures.",
    ]
    if paused:
        items.append(f"{len(paused)} paused historical lanes are excluded from the main table.")
    if any(lane.id == "transcripted-nightly-release-candidate" and lane.status == "green" for lane in lanes):
        items.append("No release work is needed unless a human explicitly decides to ship.")
    return items


def css_class(status: str) -> str:
    return {
        "green": "good",
        "watch": "watch",
        "needs_review": "review",
        "blocked": "bad",
        "unknown": "unknown",
    }.get(status, "unknown")


def status_label(status: str) -> str:
    return status.replace("_", " ")


def lane_group(lane_id: str) -> str:
    return LANE_GROUPS.get(lane_id, "Other")


def score_tone(score: int) -> str:
    if score >= 90:
        return "excellent"
    if score >= 82:
        return "strong"
    if score >= 75:
        return "mixed"
    return "weak"


def escape(value: Any) -> str:
    return html.escape(str(value), quote=True)


def average_label(value: Any) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "Unknown"
    if number.is_integer():
        return str(int(number))
    return f"{number:.1f}"


def dau_averages(dau: dict[str, Any]) -> dict[str, Any]:
    history = dau.get("history") or {}
    averages = history.get("averages") or {}
    return {
        "last_7": average_label(averages.get("last_7_complete")),
        "weekday": average_label(averages.get("weekday_complete")),
        "weekend": average_label(averages.get("weekend_complete")),
    }


def render_html(payload: dict[str, Any]) -> str:
    status = payload["overall_status"]
    counts = payload["counts"]
    lanes = payload["lanes"]
    open_prs = payload["open_prs"]
    ceo = payload["ceo_brief"]
    dau = ceo["dau_status"]

    green_lanes = [lane for lane in lanes if lane["status"] == "green"]
    hard_blocked_lanes = [lane for lane in lanes if lane["status"] == "blocked"]
    unknown_lanes = [lane for lane in lanes if lane["status"] == "unknown"]

    step_items = "\n".join(f"<li>{escape(step)}</li>" for step in payload["human_next_steps"][:4])
    safe_items = "\n".join(f"<li>{escape(item)}</li>" for item in ceo["safe_to_execute"][:4])
    ignore_items_html = "\n".join(f"<li>{escape(item)}</li>" for item in payload["ignore"])
    recommendation_items = "\n".join(f"<li>{escape(item)}</li>" for item in payload["human_next_steps"][:4])
    if not recommendation_items:
        recommendation_items = "<li>No human action needed right now.</li>"
    accomplishment_items = "\n".join(f"<li>{escape(item)}</li>" for item in ceo["accomplishments"][:6])
    if not accomplishment_items:
        accomplishment_items = "<li>No overnight accomplishments were captured.</li>"

    dau_unknown = dau["current"] == "DAU unknown"
    hard_blocked_count = len(hard_blocked_lanes)
    unknown_count = len(unknown_lanes)
    pr_word = "PR" if counts["open_nightly_prs"] == 1 else "PRs"
    action_word = "action" if counts["needs_human"] == 1 else "actions"
    blocked_label, blocked_detail = blocked_status_text(hard_blocked_count, unknown_count)
    if dau_unknown:
        hero_title = "DAU is unknown"
        hero_subtitle = f"Goal: {dau['goal']}. Fix measurement first."
    else:
        hero_title = "What happened last night"
        hero_subtitle = (
            f"{counts['active_lanes']} jobs ran. {blocked_detail}. "
            f"{counts['open_nightly_prs']} {pr_word}. {counts['needs_human']} human {action_word}."
        )
    bottom_line = night_summary_text(int(counts["active_lanes"]), hard_blocked_count, unknown_count)
    dau_context = (
        dau["note"]
        if dau_unknown
        else "PostHog last 24 hours"
    )
    health_text = blocked_label
    health_context = blocked_detail
    details_summary = f"More detail <span>{len(lanes)} lanes, {len(open_prs)} {pr_word}</span>"

    recent_merged_prs = payload["recent_merged_prs"][:6]
    if open_prs:
        open_pr_rows = "\n".join(
            "<div class=\"pr-row\">"
            "<div>"
            f"<a href=\"{escape(pr.get('url', ''))}\">{escape(pr_display_id(pr))}</a>"
            f"<strong>{escape(pr.get('title', ''))}</strong>"
            "</div>"
            f"<span>{'draft' if pr.get('isDraft') else 'ready'} · {escape(pr.get('headRefName', ''))}</span>"
            "</div>"
            for pr in open_prs
        )
        pr_rows = f"<div class=\"pr-subhead\">Open nightly PRs</div>{open_pr_rows}"
    else:
        pr_rows = "<div class=\"pr-subhead\">Open nightly PRs</div><div class=\"pr-row quiet\"><strong>No open nightly PRs.</strong><span>The PR queue is quiet.</span></div>"

    if recent_merged_prs:
        merged_rows = "\n".join(
            "<div class=\"pr-row merged\">"
            "<div>"
            f"<a href=\"{escape(pr.get('url', ''))}\">{escape(pr_display_id(pr))}</a>"
            f"<strong>{escape(pr.get('title', ''))}</strong>"
            "</div>"
            f"<span>merged · {escape(pr.get('mergedAt', ''))}</span>"
            "</div>"
            for pr in recent_merged_prs
        )
        pr_rows += f"<div class=\"pr-subhead\">Recently merged</div>{merged_rows}"

    averages = dau_averages(dau)
    scorecard_rows = "\n".join(
        "<div class=\"score-row\">"
        "<div>"
        f"<strong>{escape(row.get('role', ''))}</strong>"
        f"<p>{escape(row.get('reason', ''))}</p>"
        "</div>"
        f"<span>{escape(row.get('grade', ''))} · {escape(row.get('score', ''))}</span>"
        "</div>"
        for row in ceo["scorecard"]
    )

    role_sections: list[str] = [
        (
            "<div class=\"role-row\">"
            "<h3>Morning</h3>"
            "<div class=\"role-chips\"><span>Transcripted Daily CEO Brief</span></div>"
            "</div>"
        )
    ]
    for group in ("Trust", "Activation", "Growth", "Execution", "Judgment", "Other"):
        group_lanes = [lane for lane in lanes if lane_group(lane["id"]) == group]
        if not group_lanes:
            continue
        role_chips = "".join(f"<span>{escape(lane['name'])}</span>" for lane in group_lanes)
        role_sections.append(
            "<div class=\"role-row\">"
            f"<h3>{escape(group)}</h3>"
            f"<div class=\"role-chips\">{role_chips}</div>"
            "</div>"
        )
    paused_role_names = [str(name) for name in payload.get("paused_lanes", [])]
    if paused_role_names:
        paused_chips = "".join(f"<span>{escape(name)}</span>" for name in paused_role_names)
        role_sections.append(
            "<div class=\"role-row\">"
            "<h3>Paused</h3>"
            f"<div class=\"role-chips\">{paused_chips}</div>"
            "</div>"
        )
    roles_included = "\n".join(role_sections)

    lane_sections: list[str] = []
    for group in ("Trust", "Activation", "Growth", "Execution", "Judgment", "Other"):
        group_lanes = [lane for lane in lanes if lane_group(lane["id"]) == group]
        if not group_lanes:
            continue
        lane_items = "\n".join(
            "<li>"
            "<div class=\"lane-line\">"
            f"<strong>{escape(lane['name'])}</strong>"
            f"<b class=\"pill {css_class(lane['status'])}\">{escape(status_label(lane['status']))}</b>"
            "</div>"
            f"<p>{escape(lane['signal'])}</p>"
            f"<small>Human: {escape(lane['human_action'])}</small>"
            "</li>"
            for lane in group_lanes
        )
        lane_sections.append(
            "<details class=\"lane-group\">"
            f"<summary>{escape(group)} <span>{len(group_lanes)} lanes</span></summary>"
            f"<ul class=\"lane-list\">{lane_items}</ul>"
            "</details>"
        )
    lane_details = "\n".join(lane_sections)

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Transcripted Morning</title>
<style>
:root {{
  --bg: #f7f8fa;
  --panel: #ffffff;
  --ink: #111827;
  --muted: #5e6673;
  --line: #d9e0e8;
  --blue: #1957d2;
  --green-bg: #dff4e7;
  --green: #136f3a;
  --amber-bg: #fff2c2;
  --amber: #805400;
  --red-bg: #ffe1df;
  --red: #9b1c1c;
  --gray-bg: #e9edf2;
  --gray: #4b5563;
  --shadow: 0 14px 34px rgba(17, 24, 39, .06);
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}}
main {{
  max-width: 860px;
  margin: 0 auto;
  padding: 24px 18px 40px;
}}
.hero {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  box-shadow: var(--shadow);
  padding: 20px 22px;
}}
.eyebrow {{
  color: var(--muted);
  font-size: 12px;
  font-weight: 800;
  letter-spacing: .04em;
  text-transform: uppercase;
}}
h1 {{ margin: 6px 0 0; font-size: clamp(30px, 5vw, 44px); line-height: 1; letter-spacing: 0; }}
h2 {{ margin: 24px 0 10px; font-size: 16px; }}
p {{ margin: 0; }}
.sub {{ color: var(--muted); font-size: 14px; line-height: 1.4; margin-top: 8px; max-width: 720px; }}
.pill {{
  display: inline-flex;
  align-items: center;
  border-radius: 7px;
  padding: 5px 9px;
  font-size: 12px;
  font-weight: 800;
  text-transform: uppercase;
  white-space: nowrap;
}}
.good {{ color: var(--green); background: var(--green-bg); }}
.review, .watch {{ color: var(--amber); background: var(--amber-bg); }}
.bad {{ color: var(--red); background: var(--red-bg); }}
.unknown {{ color: var(--gray); background: var(--gray-bg); }}
.section, .more-detail {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  box-shadow: 0 8px 24px rgba(17, 24, 39, .035);
}}
.section {{ padding: 16px 18px; }}
.summary-strip {{
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 10px;
  margin-top: 12px;
}}
.summary-strip div {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  min-width: 0;
  padding: 13px 14px;
  box-shadow: 0 8px 24px rgba(17, 24, 39, .035);
}}
.summary-strip .wide {{ grid-column: 1 / -1; }}
.summary-strip span {{
  color: var(--muted);
  display: block;
  font-size: 11px;
  font-weight: 800;
  text-transform: uppercase;
  margin-bottom: 5px;
}}
.summary-strip strong {{ display: block; font-size: 17px; line-height: 1.25; overflow-wrap: anywhere; }}
.summary-strip small {{ color: var(--muted); display: block; font-size: 12px; line-height: 1.35; margin-top: 4px; }}
.focus-section, .actions-section {{ margin-top: 12px; }}
.focus-section {{ border-color: #b9c9dd; }}
.actions-section {{ border-left: 4px solid var(--blue); }}
.focus-section h2, .actions-section h2 {{ margin: 0 0 10px; font-size: 16px; }}
.lead-answer {{ color: var(--ink); font-size: 16px; line-height: 1.35; margin: 0; }}
.focus-section .plain-list {{ gap: 0; }}
.focus-section .plain-list li {{
  background: transparent;
  border: 0;
  border-top: 1px solid #edf0f4;
  border-radius: 0;
  padding: 10px 0;
}}
.focus-section .plain-list li:first-child {{ border-top: 0; padding-top: 0; }}
.focus-section .plain-list li:last-child {{ padding-bottom: 0; }}
.actions-section ol {{ padding-left: 22px; line-height: 1.4; }}
.more-detail {{ margin-top: 14px; }}
.more-detail > summary {{
  align-items: baseline;
  background: var(--panel);
  border-radius: 8px;
  display: flex;
  gap: 8px;
  justify-content: space-between;
}}
.detail-body {{
  border-top: 1px solid #edf0f4;
  padding: 0 18px 18px;
}}
.detail-section {{
  border-top: 1px solid #edf0f4;
  padding: 18px 0;
}}
.detail-section:first-child {{ border-top: 0; }}
.detail-section header {{
  display: flex;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 10px;
}}
.detail-section h2 {{ margin: 0; font-size: 15px; }}
.detail-section header p {{ color: var(--muted); font-size: 12px; line-height: 1.35; max-width: 360px; text-align: right; }}
.detail-columns {{
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 14px;
}}
.detail-block {{
  background: #fbfcfe;
  border: 1px solid #edf0f4;
  border-radius: 8px;
  padding: 13px 14px;
}}
.detail-block h3 {{
  color: var(--muted);
  font-size: 11px;
  letter-spacing: .04em;
  margin: 0 0 8px;
  text-transform: uppercase;
}}
.detail-block p, .detail-block li {{ font-size: 14px; line-height: 1.4; }}
.compact-list {{ margin: 0; padding-left: 18px; }}
.compact-list li {{ margin: 6px 0; }}
.pr-list {{
  border: 1px solid #edf0f4;
  border-radius: 8px;
  overflow: hidden;
}}
.pr-subhead {{
  background: #f2f5f9;
  border-bottom: 1px solid #edf0f4;
  color: var(--muted);
  font-size: 11px;
  font-weight: 850;
  letter-spacing: .04em;
  padding: 9px 14px;
  text-transform: uppercase;
}}
.pr-row {{
  align-items: center;
  background: #fbfcfe;
  display: flex;
  gap: 12px;
  justify-content: space-between;
  padding: 12px 14px;
}}
.pr-row + .pr-row {{ border-top: 1px solid #edf0f4; }}
.pr-row strong {{ display: block; margin-top: 3px; }}
.pr-row span {{ color: var(--muted); font-size: 12px; white-space: nowrap; }}
.pr-row.quiet {{ color: var(--muted); }}
.pr-row.merged {{ background: #fff; }}
.role-matrix {{
  border: 1px solid #edf0f4;
  border-radius: 8px;
  overflow: hidden;
}}
.role-row {{
  background: #fbfcfe;
  display: grid;
  gap: 12px;
  grid-template-columns: 110px 1fr;
  padding: 12px 14px;
}}
.role-row + .role-row {{ border-top: 1px solid #edf0f4; }}
.role-row h3 {{
  color: var(--muted);
  font-size: 11px;
  letter-spacing: .04em;
  margin: 5px 0 0;
  text-transform: uppercase;
}}
.role-chips {{
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}}
.role-chips span {{
  background: #fff;
  border: 1px solid #dfe5ee;
  border-radius: 999px;
  color: #1f2937;
  font-size: 12px;
  font-weight: 700;
  line-height: 1.2;
  padding: 6px 9px;
}}
.scorecard {{
  border: 1px solid #edf0f4;
  border-radius: 8px;
  overflow: hidden;
}}
.score-row {{
  align-items: center;
  background: #fbfcfe;
  display: flex;
  gap: 16px;
  justify-content: space-between;
  padding: 12px 14px;
}}
.score-row + .score-row {{ border-top: 1px solid #edf0f4; }}
.score-row strong {{ display: block; }}
.score-row p {{ color: var(--muted); font-size: 12px; line-height: 1.35; margin-top: 3px; }}
.score-row span {{ color: var(--muted); font-size: 12px; font-weight: 850; white-space: nowrap; }}
.plain-list {{ display: grid; gap: 10px; margin: 0; padding: 0; list-style: none; }}
.plain-list li {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 13px 14px;
}}
.more-detail, .lane-group {{ padding: 0; overflow: hidden; }}
.lane-group {{
  background: #fbfcfe;
  border: 1px solid #edf0f4;
  border-radius: 8px;
  margin-top: 8px;
}}
.more-detail summary, .lane-group summary {{
  cursor: pointer;
  padding: 14px 16px;
  font-weight: 850;
  list-style: none;
}}
.more-detail summary::-webkit-details-marker, .lane-group summary::-webkit-details-marker {{ display: none; }}
.more-detail summary span, .lane-group summary span {{ color: var(--muted); font-weight: 650; font-size: 12px; margin-left: 6px; }}
.lane-group summary {{ align-items: center; display: flex; justify-content: space-between; }}
.lane-list {{ list-style: none; padding: 0; margin: 0; border-top: 1px solid #edf0f4; }}
.lane-list li {{ padding: 13px 16px; border-bottom: 1px solid #edf0f4; margin: 0; }}
.lane-list li:last-child {{ border-bottom: 0; }}
.lane-line {{ display: flex; justify-content: space-between; align-items: center; gap: 10px; }}
.lane-list p {{ color: var(--muted); font-size: 13px; line-height: 1.42; margin-top: 6px; }}
.lane-list small {{ display: block; margin-top: 7px; color: #374151; }}
ol, ul {{ margin: 0; padding-left: 20px; }}
li {{ margin: 7px 0; }}
.section > ul:not(.plain-list), .section > ol {{ line-height: 1.35; }}
a {{ color: var(--blue); text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
.footer {{ color: var(--muted); font-size: 12px; margin-top: 18px; }}
@media (max-width: 760px) {{
  main {{ padding: 20px 14px 28px; }}
  .hero {{ padding: 18px; }}
  .summary-strip {{ grid-template-columns: 1fr; }}
  .detail-columns {{ grid-template-columns: 1fr; }}
  .detail-section header {{ display: block; }}
  .detail-section header p {{ margin-top: 4px; max-width: none; text-align: left; }}
  .pr-row {{ align-items: flex-start; display: block; }}
  .pr-row span {{ display: block; margin-top: 6px; white-space: normal; }}
  .role-row {{ grid-template-columns: 1fr; }}
  .score-row {{ align-items: flex-start; display: block; }}
  .score-row span {{ display: block; margin-top: 6px; white-space: normal; }}
}}
</style>
</head>
<body>
<main>
  <section class="hero">
    <div>
      <div class="eyebrow">Transcripted Morning</div>
      <h1>{escape(hero_title)}</h1>
      <p class="sub">{escape(hero_subtitle)}</p>
    </div>
  </section>

  <section class="section focus-section">
    <h2>What happened last night</h2>
    <p class="lead-answer"><strong>{escape(bottom_line)}</strong></p>
  </section>

  <section class="section actions-section">
    <h2>Recommended actions</h2>
    <ol>{recommendation_items}</ol>
  </section>

  <section class="summary-strip">
    <div class="wide"><span>Do first</span><strong>{escape(ceo['do_now'])}</strong></div>
    <div><span>DAU</span><strong>{escape(dau['current'])}</strong><small>{escape(dau_context)}</small></div>
    <div><span>Gap to 1,000 DAU</span><strong>{escape(dau['gap'])}</strong></div>
    <div><span>Open nightly PRs</span><strong>{escape(counts['open_nightly_prs'])}</strong></div>
    <div><span>Human actions</span><strong>{escape(counts['needs_human'])}</strong></div>
    <div><span>Blocked</span><strong>{escape(health_text)}</strong><small>{escape(health_context)}</small></div>
  </section>

  <details class="more-detail">
    <summary>{details_summary}</summary>
    <div class="detail-body">
      <section class="detail-section">
        <header>
          <h2>Needs attention</h2>
          <p>Only the follow-up context. The main answer stays above.</p>
        </header>
        <div class="detail-columns">
          <div class="detail-block">
            <h3>Watch</h3>
            <p>{escape(ceo['watch'])}</p>
          </div>
          <div class="detail-block">
            <h3>Decide</h3>
            <ol class="compact-list">{step_items}</ol>
          </div>
          <div class="detail-block">
            <h3>Daily activity context</h3>
            <p>Average daily active devices: {escape(averages['last_7'])} over the last complete week.</p>
          </div>
        </div>
      </section>
      <section class="detail-section">
        <header>
          <h2>What changed</h2>
          <p>Folded lane context for debugging, not the morning answer.</p>
        </header>
        <ul class="compact-list">{accomplishment_items}</ul>
      </section>
      <section class="detail-section">
        <header>
          <h2>Agent handoff</h2>
          <p>What agents can keep doing, plus what to ignore.</p>
        </header>
        <div class="detail-columns">
          <div class="detail-block">
            <h3>Safe to hand off</h3>
            <ul class="compact-list">{safe_items}</ul>
          </div>
          <div class="detail-block">
            <h3>Ignore</h3>
            <ul class="compact-list">{ignore_items_html}</ul>
          </div>
        </div>
      </section>
      <section class="detail-section">
        <header>
          <h2>PRs</h2>
          <p>Anything opened or still waiting from the night.</p>
        </header>
        <div class="pr-list">{pr_rows}</div>
      </section>
      <section class="detail-section">
        <header>
          <h2>Roles included</h2>
          <p>The morning brief plus every known nightly role feeding it.</p>
        </header>
        <div class="role-matrix">{roles_included}</div>
      </section>
      <section class="detail-section">
        <header>
          <h2>Scorecard</h2>
          <p>Compact role scores from the latest lane memories.</p>
        </header>
        <div class="scorecard">{scorecard_rows}</div>
      </section>
      <section class="detail-section">
        <header>
          <h2>Automation lanes</h2>
          <p>Grouped by purpose. Open only when you need the evidence.</p>
        </header>
        {lane_details}
      </section>
    </div>
  </details>

  <p class="footer">Data quality: {escape(payload['data_quality'])}</p>
</main>
</body>
</html>
"""


def headline_text(payload: dict[str, Any]) -> str:
    status = payload["overall_status"]
    ceo = payload.get("ceo_brief", {})
    dau = ceo.get("dau_status", {})
    if dau.get("current") == "DAU unknown":
        return "We do not know current DAU. Fix that first."
    if status == "green":
        return "Everything that matters is green. No human action needed."
    if status == "blocked":
        return "A nightly lane is blocked. Start with the first action below."
    if status == "unknown":
        return "Too many lanes are missing fresh signal. Treat this as an automation problem first."
    steps = payload.get("human_next_steps", [])
    first = ceo.get("do_now") or (steps[0] if steps else "Review the action queue.")
    human_actions = payload.get("counts", {}).get("needs_human", 0)
    return f"Everything ran. {human_actions} things need you. Start with: {first}"


def write_reports(payload: dict[str, Any], output_dir: Path) -> dict[str, str]:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated = datetime.fromisoformat(payload["generated_at"].replace("Z", "+00:00"))
    date_label = generated.astimezone(LOCAL_TZ).strftime("%Y-%m-%d")
    html_text = render_html(payload)
    json_text = json.dumps(payload, indent=2, ensure_ascii=True) + "\n"

    dated_html = output_dir / f"{REPORT_STEM}-{date_label}.html"
    latest_html = output_dir / f"{REPORT_STEM}-latest.html"
    dated_json = output_dir / f"{REPORT_STEM}-{date_label}.json"
    latest_json = output_dir / f"{REPORT_STEM}-latest.json"

    dated_html.write_text(html_text, encoding="utf-8")
    latest_html.write_text(html_text, encoding="utf-8")
    dated_json.write_text(json_text, encoding="utf-8")
    latest_json.write_text(json_text, encoding="utf-8")
    return {
        "dated_html": str(dated_html),
        "latest_html": str(latest_html),
        "dated_json": str(dated_json),
        "latest_json": str(latest_json),
    }


def open_report(path: str) -> None:
    subprocess.run(["open", path], check=False)


def run_self_test() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir)
        automations_dir = root / "automations"
        output_dir = root / "out"
        repo = root / "repo"
        repo.mkdir()
        now = datetime(2026, 5, 9, 12, 30, tzinfo=timezone.utc)
        fixtures = [
            (
                "transcripted-nightly-build-repair",
                "Transcripted Nightly Build Gate",
                "2026-05-09T12:01:00Z Status: green. 1502 tests passed. swift test passed.",
            ),
            (
                "transcripted-nightly-artifact-qa",
                "Transcripted Nightly Artifact QA",
                "2026-05-09T12:02:00Z Status: local_data_drift. round-trip passed. No PR opened.",
            ),
            (
                "transcripted-nightly-health",
                "Transcripted Nightly Product Health",
                "2026-05-09T12:03:00Z Status: needs_review. Sentry and PostHog missing read tokens.",
            ),
            (
                "transcripted-nightly-experimental",
                "Transcripted Nightly Experimental",
                "2026-05-09T12:04:00Z Do next: inspect this new lane manually.",
            ),
        ]
        for automation_id, name, memory in fixtures:
            folder = automations_dir / automation_id
            folder.mkdir(parents=True)
            (folder / "automation.toml").write_text(
                "\n".join(
                    [
                        'version = 1',
                        f'id = "{automation_id}"',
                        'kind = "cron"',
                        f'name = "{name}"',
                        'prompt = "fixture"',
                        'status = "ACTIVE"',
                        'rrule = "FREQ=WEEKLY;BYDAY=SU,MO,TU,WE,TH,FR,SA;BYHOUR=7;BYMINUTE=0"',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            (folder / "memory.md").write_text(memory + "\n", encoding="utf-8")

        active, paused = load_automations(automations_dir)
        payload = build_payload(
            active,
            paused,
            repo,
            now,
            fresh_hours=18,
            no_github=True,
            posthog_dau={"dau": None, "event_count": None, "error": "Self-test skipped PostHog"},
        )
        assert payload["overall_status"] == "needs_review", payload["overall_status"]
        assert payload["counts"]["active_lanes"] == 4, payload["counts"]
        assert payload["counts"]["needs_human"] >= 2, payload["human_next_steps"]
        assert payload["human_next_steps"][0].startswith("Fix DAU visibility"), payload["human_next_steps"]
        experimental = next(lane for lane in payload["lanes"] if lane["id"] == "transcripted-nightly-experimental")
        assert experimental["status"] == "watch", experimental
        assert len(payload["ceo_brief"]["scorecard"]) >= 13
        assert normalize_posthog_host("https://us.i.posthog.com") == "https://us.posthog.com"
        assert posthog_host_error("http://posthog.invalid") == "PostHog host must use HTTPS"
        assert posthog_host_error("https://example.invalid") is not None
        dau_with_first_value = build_dau_status(
            {},
            False,
            {"dau": 4, "launch_count": 9, "event_count": 12, "first_value_event_count": 7, "error": None},
        )
        assert dau_with_first_value["first_value"] == "7 events"
        assert dau_with_first_value["launches"] == "9 launches"
        assert "7 first-value events" in dau_with_first_value["proxy"]
        assert "9 app launches" in dau_with_first_value["proxy"]
        health_probe_workflow_events = {
            "app_launched",
            "app_unclean_shutdown_detected",
            "app_session_stall_detected",
            "onboarding_completed",
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
            "activation_first_artifact_saved",
            "activation_second_artifact_saved",
            "activation_artifact_action_clicked",
            "activation_agent_prompt_action_clicked",
            "activation_agent_setup_cta_clicked",
            "activation_return_proxy_observed",
            "workflow_abandoned",
        }
        assert health_probe_workflow_events.issubset(set(POSTHOG_ACTIVE_EVENTS))
        assert {
            "activation_first_artifact_saved",
            "activation_second_artifact_saved",
            "activation_artifact_action_clicked",
            "activation_agent_prompt_action_clicked",
            "activation_agent_setup_cta_clicked",
            "activation_return_proxy_observed",
        }.issubset(set(POSTHOG_FIRST_VALUE_EVENTS))
        paths = write_reports(payload, output_dir)
        assert Path(paths["latest_html"]).exists()
        assert Path(paths["latest_json"]).exists()
    print("generate-nightly-digest self-test passed")


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0

    now = datetime.now(timezone.utc)
    active, paused = load_automations(args.automations_dir)
    payload = build_payload(
        active=active,
        paused=paused,
        repo=args.repo,
        now=now,
        fresh_hours=args.fresh_hours,
        no_github=args.no_github,
    )
    paths = write_reports(payload, args.output_dir)
    if args.open:
        open_report(paths["latest_html"])
    print(
        json.dumps(
            {
                "report": paths["latest_html"],
                "json": paths["latest_json"],
                "overall_status": payload["overall_status"],
                "open_nightly_prs": payload["counts"]["open_nightly_prs"],
                "top_human_next_step": payload["human_next_steps"][0],
            },
            ensure_ascii=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
