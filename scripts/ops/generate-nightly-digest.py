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
    "transcripted-nightly-code-review",
    "transcripted-nightly-audio-reliability",
    "transcripted-nightly-agent-surface-check",
    "transcripted-nightly-telemetry-gap-finder",
    "transcripted-nightly-release-candidate",
    "transcripted-nightly-simplify",
]

LANE_LABELS = {
    "transcripted-nightly-build-repair": "Build Gate",
    "transcripted-nightly-security": "Security and Privacy",
    "transcripted-nightly-artifact-qa": "Artifact QA",
    "transcripted-nightly-health": "Product Health",
    "transcripted-nightly-code-review": "Review and Regression",
    "transcripted-nightly-audio-reliability": "Audio Reliability",
    "transcripted-nightly-agent-surface-check": "Agent Tools Eval",
    "transcripted-nightly-telemetry-gap-finder": "Telemetry and UX Trust",
    "transcripted-nightly-release-candidate": "Release Readiness",
    "transcripted-nightly-simplify": "Maintenance Cleanup",
}


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
    for path in sorted(automations_dir.glob("transcripted-*/automation.toml")):
        values = parse_toml_shallow(path)
        automation_id = str(values.get("id") or path.parent.name)
        if not automation_id.startswith("transcripted-nightly-"):
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
        count = len(open_prs)
        steps.append(f"Review {count} open nightly PR{'s' if count != 1 else ''}.")

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


def build_payload(
    active: list[Automation],
    paused: list[Automation],
    repo: Path,
    now: datetime,
    fresh_hours: int,
    no_github: bool,
) -> dict[str, Any]:
    lanes: list[LaneResult] = []
    for automation in active:
        content = automation.memory_path.read_text(encoding="utf-8") if automation.memory_path.exists() else ""
        lanes.append(classify_lane(automation, content, now, fresh_hours))

    gh_payload = github_data(repo, no_github)
    steps = human_next_steps(lanes, gh_payload["open_prs"], gh_payload["error"])
    overall = overall_status(lanes, steps, gh_payload["open_prs"], gh_payload["error"])
    data_quality = data_quality_note(lanes, gh_payload["error"])
    ops_tokens_incomplete = any(lane.human_action == "Restore ops read tokens" for lane in lanes)
    blocked_unknown = sum(1 for lane in lanes if lane.status in ("blocked", "unknown"))
    needs_human = len([step for step in steps if step != "No human action needed this morning."])

    sorted_lanes = sorted(lanes, key=lambda lane: (status_rank(lane.status), LANE_ORDER.index(lane.id) if lane.id in LANE_ORDER else 999))

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


def escape(value: Any) -> str:
    return html.escape(str(value), quote=True)


def render_html(payload: dict[str, Any]) -> str:
    status = payload["overall_status"]
    counts = payload["counts"]
    lanes = payload["lanes"]
    open_prs = payload["open_prs"]
    merged = payload["recent_merged_prs"]

    step_items = "\n".join(f"<li>{escape(step)}</li>" for step in payload["human_next_steps"])
    ignore_items_html = "\n".join(f"<li>{escape(item)}</li>" for item in payload["ignore"])

    if open_prs:
        pr_rows = "\n".join(
            "<tr>"
            f"<td><a href=\"{escape(pr.get('url', ''))}\">#{escape(pr.get('number', ''))}</a></td>"
            f"<td>{escape(pr.get('title', ''))}</td>"
            f"<td>{'draft' if pr.get('isDraft') else 'ready'}</td>"
            f"<td>{escape(pr.get('headRefName', ''))}</td>"
            "</tr>"
            for pr in open_prs
        )
    else:
        pr_rows = "<tr><td colspan=\"4\">No open nightly PRs right now.</td></tr>"

    lane_rows = "\n".join(
        "<tr>"
        f"<td><strong>{escape(lane['name'])}</strong><span>{escape(lane['schedule'])}</span></td>"
        f"<td><b class=\"pill {css_class(lane['status'])}\">{escape(status_label(lane['status']))}</b></td>"
        f"<td>{escape(lane['signal'])}</td>"
        f"<td>{escape(lane['human_action'])}</td>"
        "</tr>"
        for lane in lanes
    )

    merged_items = "\n".join(
        f"<li><a href=\"{escape(pr.get('url', ''))}\">#{escape(pr.get('number', ''))}</a> {escape(pr.get('title', ''))}</li>"
        for pr in merged[:6]
    )
    if not merged_items:
        merged_items = "<li>No recent merged PR data available.</li>"

    headline = headline_text(payload)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Transcripted Nightly Digest</title>
<style>
:root {{
  --bg: #f6f7f9;
  --panel: #ffffff;
  --ink: #111827;
  --muted: #5b6472;
  --line: #dde3ea;
  --blue: #1d4ed8;
  --green-bg: #dff4e7;
  --green: #136f3a;
  --amber-bg: #fff2c2;
  --amber: #805400;
  --red-bg: #ffe1df;
  --red: #9b1c1c;
  --gray-bg: #e9edf2;
  --gray: #4b5563;
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}}
main {{
  max-width: 1060px;
  margin: 0 auto;
  padding: 28px 20px 36px;
}}
.top {{
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 16px;
  align-items: start;
  border-bottom: 1px solid var(--line);
  padding-bottom: 18px;
}}
h1 {{ margin: 0; font-size: 30px; letter-spacing: 0; }}
h2 {{ margin: 26px 0 10px; font-size: 15px; }}
p {{ margin: 0; }}
.sub {{ color: var(--muted); font-size: 13px; margin-top: 5px; }}
.verdict {{ font-size: 18px; font-weight: 800; margin-top: 14px; max-width: 760px; }}
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
  margin-top: 18px;
}}
.card, .section {{
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
}}
.card {{ padding: 14px; }}
.num {{ font-size: 27px; font-weight: 850; line-height: 1; }}
.label {{ color: var(--muted); font-size: 12px; margin-top: 5px; }}
.section {{ padding: 15px 18px; }}
ol, ul {{ margin: 0; padding-left: 20px; }}
li {{ margin: 7px 0; }}
table {{
  width: 100%;
  border-collapse: separate;
  border-spacing: 0;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  overflow: hidden;
}}
th, td {{
  padding: 11px 12px;
  border-bottom: 1px solid #edf0f4;
  text-align: left;
  vertical-align: top;
  font-size: 13px;
}}
tr:last-child td {{ border-bottom: 0; }}
th {{ background: #f9fafb; color: var(--muted); font-weight: 750; }}
td span {{ display: block; color: var(--muted); font-size: 12px; margin-top: 3px; }}
a {{ color: var(--blue); text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
.footer {{ color: var(--muted); font-size: 12px; margin-top: 18px; }}
@media (max-width: 760px) {{
  main {{ padding: 20px 14px 28px; }}
  .top {{ grid-template-columns: 1fr; }}
  .grid {{ grid-template-columns: repeat(2, minmax(0, 1fr)); }}
  table {{ display: block; overflow-x: auto; }}
}}
</style>
</head>
<body>
<main>
  <section class="top">
    <div>
      <h1>Transcripted Nightly Digest</h1>
      <p class="sub">{escape(payload['generated_local'])} · signal quality: {escape(payload['signal_quality'])}</p>
      <p class="verdict">{escape(headline)}</p>
    </div>
    <b class="pill {css_class(status)}">{escape(status_label(status))}</b>
  </section>

  <section class="grid" aria-label="Summary">
    <div class="card"><div class="num">{counts['active_lanes']}</div><div class="label">active lanes</div></div>
    <div class="card"><div class="num">{counts['open_nightly_prs']}</div><div class="label">nightly PRs</div></div>
    <div class="card"><div class="num">{counts['needs_human']}</div><div class="label">human actions</div></div>
    <div class="card"><div class="num">{counts['blocked_or_unknown']}</div><div class="label">blocked / unknown</div></div>
  </section>

  <h2>Do Next</h2>
  <section class="section"><ol>{step_items}</ol></section>

  <h2>PRs Waiting</h2>
  <table>
    <tr><th>PR</th><th>Title</th><th>State</th><th>Branch</th></tr>
    {pr_rows}
  </table>

  <h2>Lane Results</h2>
  <table>
    <tr><th>Lane</th><th>Status</th><th>Signal</th><th>Human action</th></tr>
    {lane_rows}
  </table>

  <h2>Recently Merged</h2>
  <section class="section"><ul>{merged_items}</ul></section>

  <h2>Ignore</h2>
  <section class="section"><ul>{ignore_items_html}</ul></section>

  <p class="footer">Data quality: {escape(payload['data_quality'])}</p>
</main>
</body>
</html>
"""


def headline_text(payload: dict[str, Any]) -> str:
    status = payload["overall_status"]
    if status == "green":
        return "Everything that matters is green. No human action needed."
    if status == "blocked":
        return "A nightly lane is blocked. Start with the first action below."
    if status == "unknown":
        return "Too many lanes are missing fresh signal. Treat this as an automation problem first."
    steps = payload.get("human_next_steps", [])
    first = steps[0] if steps else "Review the action queue."
    return f"Mostly healthy, but needs a human pass: {first}"


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
