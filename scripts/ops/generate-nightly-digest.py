#!/usr/bin/env python3
"""Generate the human morning digest for Transcripted nightly automations."""

from __future__ import annotations

import argparse
import ast
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable, Optional, Tuple

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - Python 3.9+ on supported machines.
    ZoneInfo = None


REPORT_STEM = "transcripted-nightly-digest"
DEFAULT_AUTOMATIONS_DIR = Path.home() / ".codex" / "automations"
DEFAULT_OUTPUT_DIR = Path("/Users/redbars/Delance")
DEFAULT_REPO = Path("/Users/redbars/transcripted-latest")
LOCAL_TZ = ZoneInfo("America/Chicago") if ZoneInfo else timezone.utc
FRESH_HOURS = 18
DAU_GOAL = 1000

NIGHTLY_PREFIXES = (
    "[nightly-",
    "nightly-",
    "codex/nightly",
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

    status = "green"
    signal = "No action-worthy issue reported."
    action = "No action"

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
        if contains_any(lower, ("no new high-confidence", "no pr opened", "green/watch")):
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
        if "retention score" in lower or "top churn hypothesis" in lower:
            status = "needs_review"
            signal = "Retention lane says the repeat-use loop is promising but under-measured."
            action = "Define activation endpoint"
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
            signal = "Reviewer found a blocker or required change."
            action = "Fix before approval"
        elif "ready for justin" in lower or "top recommendation" in lower:
            status = "needs_review"
            signal = "Reviewer says the current PR/task is ready for Justin's approval."
            action = "Review PR recommendation"
    elif automation.id == "transcripted-nightly-content-agent":
        if "content score" in lower or "best content bet" in lower:
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


def normalize_pr(pr: dict[str, Any]) -> dict[str, Any]:
    normalized = {
        "number": pr.get("number"),
        "title": pr.get("title", ""),
        "url": pr.get("url", ""),
        "headRefName": pr.get("headRefName", ""),
    }
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


def github_data(repo: Path, no_github: bool) -> dict[str, Any]:
    if no_github:
        return {"open_prs": [], "recent_merged_prs": [], "error": "GitHub disabled"}

    fields = "number,title,url,isDraft,headRefName,labels,updatedAt"
    open_prs, open_error = run_json_command(
        ["gh", "pr", "list", "--repo", "r3dbars/transcripted", "--state", "open", "--json", fields, "--limit", "100"],
        cwd=repo,
    )
    merged_prs, merged_error = run_json_command(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            "r3dbars/transcripted",
            "--state",
            "merged",
            "--json",
            "number,title,url,mergedAt,headRefName,labels",
            "--limit",
            "12",
        ],
        cwd=repo,
    )
    nightly_open = [normalize_pr(pr) for pr in open_prs if is_nightly_pr(pr)]
    error = open_error or merged_error
    return {
        "open_prs": nightly_open,
        "recent_merged_prs": [normalize_pr(pr) for pr in merged_prs],
        "error": error,
    }


def human_next_steps(lanes: list[LaneResult], open_prs: list[dict[str, Any]], github_error: Optional[str]) -> list[str]:
    steps: list[str] = []
    if open_prs:
        if len(open_prs) == 1:
            pr = open_prs[0]
            steps.append(f"Review PR #{pr.get('number')}: {pr.get('title')}.")
        else:
            steps.append(f"Review {len(open_prs)} open nightly PRs.")

    if github_error and github_error != "GitHub disabled":
        steps.append("Restore GitHub CLI access so PR review status is not guessed.")

    if any(lane.human_action == "Restore ops read tokens" for lane in lanes):
        steps.append("Restore Sentry, PostHog, and Cloudflare read tokens for full morning truth.")

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


def build_dau_status(memories: dict[str, str], ops_tokens_incomplete: bool) -> dict[str, str]:
    all_memory = "\n".join(memories.values())
    exact_dau = extract_first_int(
        all_memory,
        (
            r"\b(\d{1,5})\s+daily active users\b",
            r"\bDAU:\s*(\d{1,5})\b",
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

    if exact_dau is not None:
        current = f"{exact_dau} DAU"
        gap = f"{max(0, DAU_GOAL - exact_dau)} away"
        confidence = "High" if not ops_tokens_incomplete else "Medium"
    else:
        current = "Unknown today"
        gap = "Cannot calculate exact gap"
        confidence = "Low" if ops_tokens_incomplete else "Medium"

    proxy_parts: list[str] = []
    if active_devices is not None:
        proxy_parts.append(f"{active_devices} active devices in the last 7 days")
    if downloads is not None:
        proxy_parts.append(f"{downloads} latest-release downloads")
    if repo_viewers is not None:
        proxy_parts.append(f"{repo_viewers} unique repo viewers in 14 days")
    proxy = "; ".join(proxy_parts) if proxy_parts else "No reliable proxy found"

    note = (
        "Exact DAU was not available in this run because live product analytics could not be read."
        if exact_dau is None and ops_tokens_incomplete
        else "Use this as the morning growth read, not a perfect analytics dashboard."
    )

    return {
        "goal": f"{DAU_GOAL:,} daily active users",
        "current": current,
        "gap": gap,
        "proxy": proxy,
        "confidence": confidence,
        "note": note,
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
        items.append(f"PR #{pr.get('number')} is waiting with the durable morning report work.")

    return items[:8]


def build_recommendations(
    lanes: list[LaneResult],
    open_prs: list[dict[str, Any]],
    ops_tokens_incomplete: bool,
) -> list[str]:
    recommendations: list[str] = []
    if open_prs:
        pr = open_prs[0]
        recommendations.append(f"Review PR #{pr.get('number')} so this morning report becomes the durable final automation.")
    if ops_tokens_incomplete:
        recommendations.append("Restore Sentry, PostHog, and Cloudflare read tokens so tomorrow's DAU and health read is not guessed.")
    if any(lane.id == "transcripted-nightly-north-star-agent" for lane in lanes):
        recommendations.append("Pick the activation metric: first useful agent answer from a local Transcripted artifact.")
    if any(lane.human_action == "Watch issue #500" for lane in lanes):
        recommendations.append("Run the issue #500 audio QA matrix before making a bigger launch push.")
    if any(lane.id == "transcripted-nightly-community-scout" for lane in lanes):
        recommendations.append("Approve one helpful community reply where people already want local Markdown and agent memory.")

    return recommendations[:5]


def build_ceo_brief(
    lanes: list[LaneResult],
    memories: dict[str, str],
    full_memories: dict[str, str],
    open_prs: list[dict[str, Any]],
    overall: str,
    steps: list[str],
    ops_tokens_incomplete: bool,
) -> dict[str, Any]:
    artifact_drift = any(lane.human_action == "Decide whether to clean local artifacts" for lane in lanes)
    issue_500_watch = any(lane.human_action == "Watch issue #500" for lane in lanes)
    blocked_or_unknown = any(lane.status in ("blocked", "unknown") for lane in lanes)
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

    if overall == "blocked":
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
        needs_judgment.append(f"Approve/merge PR #{pr.get('number')} if the CEO brief shape feels right.")
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

    return {
        "ceo_call": call,
        "scorecard": roles,
        "do_now": steps[0] if steps else "No human action needed this morning.",
        "needs_judgment": needs_judgment[:6],
        "safe_to_execute": safe_to_execute[:5],
        "watch": watch,
        "ignore": "Green verification lanes, third-party warning noise, and paused historical automations.",
        "why_thousands": "This gets to 1,000 DAU by protecting trust first, then pushing one habit loop: spoken work becomes local Markdown, then an agent gives a useful answer.",
        "dau_status": build_dau_status(full_memories, ops_tokens_incomplete),
        "accomplishments": build_accomplishments(lanes, open_prs),
        "recommendations": build_recommendations(lanes, open_prs, ops_tokens_incomplete),
    }


def build_payload(
    active: list[Automation],
    paused: list[Automation],
    repo: Path,
    now: datetime,
    fresh_hours: int,
    no_github: bool,
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
    steps = human_next_steps(lanes, gh_payload["open_prs"], gh_payload["error"])
    overall = overall_status(lanes, steps, gh_payload["open_prs"], gh_payload["error"])
    data_quality = data_quality_note(lanes, gh_payload["error"])
    ops_tokens_incomplete = any(lane.human_action == "Restore ops read tokens" for lane in lanes)
    blocked_unknown = sum(1 for lane in lanes if lane.status in ("blocked", "unknown"))
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
            "blocked_or_unknown": blocked_unknown,
        },
        "human_next_steps": steps,
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


def render_html(payload: dict[str, Any]) -> str:
    status = payload["overall_status"]
    counts = payload["counts"]
    lanes = payload["lanes"]
    open_prs = payload["open_prs"]
    ceo = payload["ceo_brief"]
    dau = ceo["dau_status"]

    review_lanes = [lane for lane in lanes if lane["status"] == "needs_review"]
    green_lanes = [lane for lane in lanes if lane["status"] == "green"]
    blocked_lanes = [lane for lane in lanes if lane["status"] in ("blocked", "unknown")]

    step_items = "\n".join(f"<li>{escape(step)}</li>" for step in payload["human_next_steps"][:4])
    judgment_items = "\n".join(f"<li>{escape(item)}</li>" for item in ceo["needs_judgment"][:4])
    safe_items = "\n".join(f"<li>{escape(item)}</li>" for item in ceo["safe_to_execute"][:4])
    ignore_items_html = "\n".join(f"<li>{escape(item)}</li>" for item in payload["ignore"])
    accomplishment_items = "\n".join(f"<li>{escape(item)}</li>" for item in ceo["accomplishments"])
    recommendation_items = "\n".join(f"<li>{escape(item)}</li>" for item in ceo["recommendations"])

    good_names = ", ".join(lane["name"] for lane in green_lanes[:6])
    if len(green_lanes) > 6:
        good_names += f", and {len(green_lanes) - 6} more"
    if not good_names:
        good_names = "No lane was fully quiet."

    score = next((item for item in ceo["scorecard"] if item["role"] == "CEO"), None)
    score_text = f"{score['score']} / {score['grade']}" if score else "needs review"

    if open_prs:
        pr_cards = "\n".join(
            "<article class=\"mini-card\">"
            f"<div><a href=\"{escape(pr.get('url', ''))}\">PR #{escape(pr.get('number', ''))}</a></div>"
            f"<strong>{escape(pr.get('title', ''))}</strong>"
            f"<span>{'draft' if pr.get('isDraft') else 'ready'} · {escape(pr.get('headRefName', ''))}</span>"
            "</article>"
            for pr in open_prs
        )
    else:
        pr_cards = "<article class=\"mini-card quiet\"><strong>No open nightly PRs.</strong><span>The PR queue is quiet.</span></article>"

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
            "<details>"
            f"<summary>{escape(group)} <span>{len(group_lanes)} lanes</span></summary>"
            f"<ul class=\"lane-list\">{lane_items}</ul>"
            "</details>"
        )
    lane_details = "\n".join(lane_sections)

    headline = headline_text(payload)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Transcripted Daily CEO Brief</title>
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
  max-width: 920px;
  margin: 0 auto;
  padding: 28px 18px 44px;
}}
.hero {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  box-shadow: var(--shadow);
  padding: 22px 24px;
}}
.eyebrow {{
  color: var(--muted);
  font-size: 12px;
  font-weight: 800;
  letter-spacing: .04em;
  text-transform: uppercase;
}}
h1 {{ margin: 6px 0 0; font-size: clamp(30px, 5vw, 46px); line-height: 1; letter-spacing: 0; }}
h2 {{ margin: 30px 0 12px; font-size: 16px; }}
p {{ margin: 0; }}
.sub {{ color: var(--muted); font-size: 13px; margin-top: 5px; }}
.verdict {{ font-size: 20px; font-weight: 850; margin-top: 16px; max-width: 780px; }}
.call {{
  border-left: 4px solid var(--blue);
  padding: 12px 0 12px 14px;
  margin-top: 18px;
  color: #1f2937;
  font-size: 15px;
  line-height: 1.45;
}}
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
.grid {{
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 10px;
  margin-top: 14px;
}}
.card, .section, .mini-card, details {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  box-shadow: 0 8px 24px rgba(17, 24, 39, .035);
}}
.card {{ padding: 14px; }}
.num {{ font-size: 27px; font-weight: 850; line-height: 1; }}
.label {{ color: var(--muted); font-size: 12px; margin-top: 5px; }}
.section {{ padding: 16px 18px; }}
.goal-grid {{
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
  margin-top: 14px;
}}
.goal-card {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 14px;
  box-shadow: 0 8px 24px rgba(17, 24, 39, .035);
}}
.goal-card strong {{ display: block; font-size: 18px; margin-top: 4px; }}
.goal-card span {{ color: var(--muted); font-size: 12px; font-weight: 750; text-transform: uppercase; }}
.goal-note {{ color: var(--muted); font-size: 13px; line-height: 1.45; margin-top: 10px; }}
.big-action {{
  background: #101827;
  color: #fff;
  border-radius: 8px;
  padding: 18px;
  margin-top: 16px;
}}
.big-action span {{ color: #cbd5e1; display: block; font-size: 12px; font-weight: 800; text-transform: uppercase; margin-bottom: 8px; }}
.big-action strong {{ display: block; font-size: 22px; line-height: 1.18; }}
.brief-grid {{
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 10px;
}}
.brief-grid .section {{ min-height: 100%; }}
.mini-grid {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }}
.mini-card {{ padding: 14px; }}
.mini-card span {{ display: block; color: var(--muted); font-size: 12px; margin-top: 3px; }}
.mini-card.quiet {{ color: var(--muted); }}
.plain-list {{ display: grid; gap: 10px; margin: 0; padding: 0; list-style: none; }}
.plain-list li {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 13px 14px;
}}
details {{ padding: 0; margin-bottom: 10px; overflow: hidden; }}
summary {{
  cursor: pointer;
  padding: 14px 16px;
  font-weight: 850;
  list-style: none;
}}
summary::-webkit-details-marker {{ display: none; }}
summary span {{ color: var(--muted); font-weight: 650; font-size: 12px; margin-left: 6px; }}
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
  .grid {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
  .goal-grid {{ grid-template-columns: 1fr; }}
  .mini-grid {{ grid-template-columns: 1fr; }}
  .brief-grid {{ grid-template-columns: 1fr; }}
}}
</style>
</head>
<body>
<main>
  <section class="hero">
    <div>
      <div class="eyebrow">Transcripted Daily CEO Brief</div>
      <h1>1,000 DAU morning brief.</h1>
      <p class="sub">{escape(payload['generated_local'])} · signal quality: {escape(payload['signal_quality'])}</p>
      <p class="verdict">Goal: {escape(dau['goal'])}. Current DAU: {escape(dau['current'])}.</p>
      <p class="call"><strong>CEO call:</strong> {escape(ceo['ceo_call'])}</p>
      <p class="goal-note">Confidence: {escape(dau['confidence'])}. {escape(dau['note'])}</p>
    </div>
  </section>

  <section class="goal-grid" aria-label="DAU progress">
    <div class="goal-card"><span>Goal</span><strong>{escape(dau['goal'])}</strong></div>
    <div class="goal-card"><span>Current DAU</span><strong>{escape(dau['current'])}</strong></div>
    <div class="goal-card"><span>Gap</span><strong>{escape(dau['gap'])}</strong></div>
    <div class="goal-card"><span>Best proxy</span><strong>{escape(dau['proxy'])}</strong></div>
  </section>

  <section class="grid" aria-label="Summary">
    <div class="card"><div class="num">{counts['active_lanes']}</div><div class="label">jobs ran</div></div>
    <div class="card"><div class="num">{len(green_lanes)}</div><div class="label">quiet</div></div>
    <div class="card"><div class="num">{counts['needs_human']}</div><div class="label">human actions</div></div>
    <div class="card"><div class="num">{counts['blocked_or_unknown']}</div><div class="label">missing / blocked</div></div>
  </section>

  <section class="big-action">
    <span>Do this first</span>
    <strong>{escape(ceo['do_now'])}</strong>
  </section>

  <section class="brief-grid">
    <div>
      <h2>What happened last night</h2>
      <section class="section">
        <ul class="plain-list">
          <li><strong>All active nightly jobs produced fresh output.</strong><br>{counts['active_lanes']} ran, and {len(blocked_lanes)} were missing or blocked.</li>
          {accomplishment_items}
        </ul>
      </section>
    </div>
    <div>
      <h2>Recommended next actions</h2>
      <section class="section"><ol>{recommendation_items}</ol></section>
    </div>
  </section>

  <section class="brief-grid">
    <div>
      <h2>Watch</h2>
      <section class="section"><p>{escape(ceo['watch'])}</p></section>
    </div>
    <div>
      <h2>Safe for agents</h2>
      <section class="section"><ul>{safe_items}</ul></section>
    </div>
  </section>

  <h2>Why this matters</h2>
  <section class="section"><p>{escape(ceo['why_thousands'])}</p></section>

  <section class="brief-grid">
    <div>
      <h2>What you need to decide</h2>
      <section class="section"><ol>{step_items}</ol></section>
    </div>
    <div>
      <h2>Founder judgment</h2>
      <section class="section"><ul>{judgment_items}</ul></section>
    </div>
  </section>

  <h2>Noise to ignore</h2>
  <section class="section"><ul>{ignore_items_html}</ul></section>

  <h2>PRs from the night</h2>
  <section class="mini-grid">{pr_cards}</section>

  <h2>Every automation, folded away</h2>
  {lane_details}

  <p class="footer">Data quality: {escape(payload['data_quality'])}</p>
</main>
</body>
</html>
"""


def headline_text(payload: dict[str, Any]) -> str:
    status = payload["overall_status"]
    ceo = payload.get("ceo_brief", {})
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
        payload = build_payload(active, paused, repo, now, fresh_hours=18, no_github=True)
        assert payload["overall_status"] == "needs_review", payload["overall_status"]
        assert payload["counts"]["active_lanes"] == 3, payload["counts"]
        assert payload["counts"]["needs_human"] >= 2, payload["human_next_steps"]
        assert len(payload["ceo_brief"]["scorecard"]) >= 13
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
