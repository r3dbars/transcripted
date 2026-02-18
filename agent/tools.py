"""Custom tools for the Draft orchestrator agent.

Each tool reads/writes files in ~/Library/Application Support/Draft/.
Tools are bundled into an in-process MCP server via create_sdk_mcp_server.
"""

import asyncio
import json
import uuid
import difflib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from claude_agent_sdk import tool, create_sdk_mcp_server

# Data directory — all Draft app files live here
DRAFT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Draft"
FEEDBACK_PATH = DRAFT_DATA_DIR / "feedback.jsonl"
PROMPTS_PATH = DRAFT_DATA_DIR / "prompts.json"
STYLE_PATH = DRAFT_DATA_DIR / "style.md"
SUGGESTION_LOG_PATH = DRAFT_DATA_DIR / "suggestion_log.jsonl"

# Shared queue — propose_prompt_change pushes cards here, SSE endpoint reads them
card_queue: asyncio.Queue = asyncio.Queue()


def _read_jsonl(path: Path, count: int = 0, since_line: int = 0) -> list[dict]:
    """Read JSONL file, optionally slicing by line number and count."""
    if not path.exists():
        return []
    lines = path.read_text().strip().split("\n")
    lines = [l for l in lines if l.strip()]  # skip empty lines
    if since_line > 0:
        lines = lines[since_line:]
    if count > 0:
        lines = lines[-count:]
    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def _word_edit_distance(a: str, b: str) -> float:
    """Compute word-level edit distance ratio (0 = identical, 1 = completely different)."""
    words_a = a.lower().split()
    words_b = b.lower().split()
    if not words_a and not words_b:
        return 0.0
    matcher = difflib.SequenceMatcher(None, words_a, words_b)
    return 1.0 - matcher.ratio()


# ---------- Tool definitions ----------


@tool("read_feedback", "Read recent feedback entries from feedback.jsonl", {
    "count": {"type": "integer", "description": "Number of recent entries to return (default 20)"},
    "since_line": {"type": "integer", "description": "Start reading from this line number (0-indexed)"},
})
async def read_feedback(args: dict[str, Any]) -> dict[str, Any]:
    count = args.get("count", 20)
    since_line = args.get("since_line", 0)
    entries = _read_jsonl(FEEDBACK_PATH, count=count, since_line=since_line)
    return {"content": [{"type": "text", "text": json.dumps(entries, indent=2)}]}


@tool("read_prompts", "Read the current prompts.json configuration", {})
async def read_prompts(args: dict[str, Any]) -> dict[str, Any]:
    if not PROMPTS_PATH.exists():
        return {"content": [{"type": "text", "text": "prompts.json not found"}]}
    data = json.loads(PROMPTS_PATH.read_text())
    return {"content": [{"type": "text", "text": json.dumps(data, indent=2)}]}


@tool("read_style_profile", "Read the user's writing style profile from style.md", {})
async def read_style_profile(args: dict[str, Any]) -> dict[str, Any]:
    if not STYLE_PATH.exists():
        return {"content": [{"type": "text", "text": "style.md not found — user hasn't completed onboarding yet"}]}
    text = STYLE_PATH.read_text()
    # Truncate if very long (keep style summary, limit examples)
    if len(text) > 8000:
        # Find ## Examples and truncate
        idx = text.find("## Examples")
        if idx > 0:
            text = text[:idx + 200] + "\n\n[... truncated, use read_feedback for raw data ...]"
    return {"content": [{"type": "text", "text": text}]}


@tool("read_suggestion_log", "Read past suggestion outcomes from suggestion_log.jsonl", {
    "count": {"type": "integer", "description": "Number of recent entries (default 50)"},
})
async def read_suggestion_log(args: dict[str, Any]) -> dict[str, Any]:
    count = args.get("count", 50)
    entries = _read_jsonl(SUGGESTION_LOG_PATH, count=count)
    if not entries:
        return {"content": [{"type": "text", "text": "No suggestion history yet — this is the first analysis run."}]}
    # Summarize
    applied = sum(1 for e in entries if e.get("action") == "apply")
    skipped = sum(1 for e in entries if e.get("action") == "skip")
    summary = f"Suggestion history: {applied} applied, {skipped} skipped out of {len(entries)} total.\n\n"
    summary += json.dumps(entries, indent=2)
    return {"content": [{"type": "text", "text": summary}]}


@tool("get_edit_patterns", "Analyze edit patterns across recent feedback entries", {
    "count": {"type": "integer", "description": "Number of recent entries to analyze (default 30)"},
})
async def get_edit_patterns(args: dict[str, Any]) -> dict[str, Any]:
    count = args.get("count", 30)
    entries = _read_jsonl(FEEDBACK_PATH, count=count)
    if not entries:
        return {"content": [{"type": "text", "text": "No feedback entries found."}]}

    # Compute edit distances
    distances = []
    zero_edit_count = 0
    heavy_edit_count = 0
    common_additions = {}
    common_removals = {}

    for entry in entries:
        drafted = entry.get("drafted_text", "")
        accepted = entry.get("accepted_text", "")
        dist = _word_edit_distance(drafted, accepted)
        distances.append(dist)

        if dist < 0.05:
            zero_edit_count += 1
        elif dist > 0.3:
            heavy_edit_count += 1

        # Word-level diff for common changes
        drafted_words = set(drafted.lower().split())
        accepted_words = set(accepted.lower().split())
        for word in accepted_words - drafted_words:
            if len(word) > 2:
                common_additions[word] = common_additions.get(word, 0) + 1
        for word in drafted_words - accepted_words:
            if len(word) > 2:
                common_removals[word] = common_removals.get(word, 0) + 1

    avg_dist = sum(distances) / len(distances) if distances else 0
    # Trend: compare first half vs second half
    mid = len(distances) // 2
    if mid > 0:
        early_avg = sum(distances[:mid]) / mid
        recent_avg = sum(distances[mid:]) / (len(distances) - mid)
        trend = "improving" if recent_avg < early_avg else "degrading" if recent_avg > early_avg else "stable"
        trend_detail = f"early avg: {early_avg:.3f}, recent avg: {recent_avg:.3f}"
    else:
        trend = "insufficient data"
        trend_detail = ""

    # Top additions/removals
    top_additions = sorted(common_additions.items(), key=lambda x: -x[1])[:10]
    top_removals = sorted(common_removals.items(), key=lambda x: -x[1])[:10]

    result = {
        "entries_analyzed": len(entries),
        "average_edit_distance": round(avg_dist, 3),
        "trend": trend,
        "trend_detail": trend_detail,
        "zero_edit_entries": zero_edit_count,
        "heavy_edit_entries": heavy_edit_count,
        "common_additions": [{"word": w, "count": c} for w, c in top_additions],
        "common_removals": [{"word": w, "count": c} for w, c in top_removals],
    }
    return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}


@tool("get_platform_stats", "Get per-platform edit distance statistics", {
    "count": {"type": "integer", "description": "Number of recent entries to analyze (default 50)"},
})
async def get_platform_stats(args: dict[str, Any]) -> dict[str, Any]:
    count = args.get("count", 50)
    entries = _read_jsonl(FEEDBACK_PATH, count=count)
    if not entries:
        return {"content": [{"type": "text", "text": "No feedback entries found."}]}

    # Group by platform (detected from raw_text which includes context)
    platforms: dict[str, list[float]] = {}
    for entry in entries:
        raw = entry.get("raw_text", "").lower()
        drafted = entry.get("drafted_text", "")
        accepted = entry.get("accepted_text", "")

        # Detect platform from context in raw_text
        platform = "unknown"
        for p in ["slack", "imessage", "email", "discord", "teams"]:
            if f"platform: {p}" in raw or f"platform:{p}" in raw:
                platform = p
                break

        dist = _word_edit_distance(drafted, accepted)
        platforms.setdefault(platform, []).append(dist)

    result = {}
    for platform, dists in platforms.items():
        avg = sum(dists) / len(dists)
        worst_idx = dists.index(max(dists))
        result[platform] = {
            "count": len(dists),
            "avg_edit_distance": round(avg, 3),
            "max_edit_distance": round(max(dists), 3),
        }

    return {"content": [{"type": "text", "text": json.dumps(result, indent=2)}]}


@tool("propose_prompt_change", "Propose a prompt change as an insight card for the user", {
    "prompt_key": {"type": "string", "description": "Which key in prompts.json to change"},
    "saw": {"type": "string", "description": "Evidence from feedback data"},
    "why": {"type": "string", "description": "Reasoning about what the prompt is getting wrong"},
    "current_value": {"type": "string", "description": "Current prompt text (relevant section)"},
    "proposed_value": {"type": "string", "description": "Full new value for the prompt key"},
})
async def propose_prompt_change(args: dict[str, Any]) -> dict[str, Any]:
    suggestion_id = str(uuid.uuid4())
    card = {
        "suggestion_id": suggestion_id,
        "prompt_key": args["prompt_key"],
        "saw": args["saw"],
        "why": args["why"],
        "current_value": args.get("current_value", ""),
        "proposed_value": args["proposed_value"],
        "change_description": args.get("why", "")[:200],  # Short summary for card
    }
    await card_queue.put(card)
    return {"content": [{"type": "text", "text": f"Card emitted with suggestion_id: {suggestion_id}"}]}


def log_suggestion(suggestion_id: str, prompt_key: str, action: str,
                   saw: str = "", why: str = "", change: str = "") -> None:
    """Append a suggestion outcome to suggestion_log.jsonl."""
    DRAFT_DATA_DIR.mkdir(parents=True, exist_ok=True)
    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "suggestion_id": suggestion_id,
        "prompt_key": prompt_key,
        "action": action,
        "saw": saw,
        "why": why,
        "change": change,
    }
    with open(SUGGESTION_LOG_PATH, "a") as f:
        f.write(json.dumps(entry) + "\n")


# ---------- MCP Server ----------

ALL_TOOLS = [
    read_feedback,
    read_prompts,
    read_style_profile,
    read_suggestion_log,
    get_edit_patterns,
    get_platform_stats,
    propose_prompt_change,
]

draft_tools_server = create_sdk_mcp_server(
    name="draft-tools",
    version="1.0.0",
    tools=ALL_TOOLS,
)
