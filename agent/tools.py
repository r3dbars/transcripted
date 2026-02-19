"""Custom tools for the Draft orchestrator agent.

Only one tool: propose_prompt_change. All file reading is handled by
Claude Code's built-in tools (Read, Bash, Glob). We only need a custom
tool for pushing insight cards to the SSE queue — something built-in
tools can't do.

Minimal tool philosophy inspired by agent-native architecture:
the fewer tools you give the agent, the more creatively it uses them.
"""

import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from claude_agent_sdk import tool, create_sdk_mcp_server

log = logging.getLogger("agent")

# Data directory — all Draft app files live here
DRAFT_DATA_DIR = Path.home() / "Library" / "Application Support" / "Draft"
FEEDBACK_PATH = DRAFT_DATA_DIR / "feedback.jsonl"
PROMPTS_PATH = DRAFT_DATA_DIR / "prompts.json"
STYLE_PATH = DRAFT_DATA_DIR / "style.md"
SUGGESTION_LOG_PATH = DRAFT_DATA_DIR / "suggestion_log.jsonl"

# Shared queue — propose_prompt_change pushes cards here, SSE endpoint reads them
card_queue: asyncio.Queue = asyncio.Queue()


# ---------- The one tool ----------


@tool("propose_prompt_change", "Propose a prompt change as an insight card for the user", {
    "prompt_key": {"type": "string", "description": "Which key in prompts.json to change"},
    "saw": {"type": "string", "description": "Evidence from feedback data"},
    "why": {"type": "string", "description": "Reasoning about what the prompt is getting wrong"},
    "current_value": {"type": "string", "description": "Current prompt text (relevant section)"},
    "proposed_value": {"type": "string", "description": "Full new value for the prompt key"},
})
async def propose_prompt_change(args: dict[str, Any]) -> dict[str, Any]:
    log.info(f"  📤 propose_prompt_change called: prompt_key={args.get('prompt_key')}")
    suggestion_id = str(uuid.uuid4())
    card = {
        "suggestion_id": suggestion_id,
        "prompt_key": args["prompt_key"],
        "saw": args["saw"],
        "why": args["why"],
        "current_value": args.get("current_value", ""),
        "proposed_value": args["proposed_value"],
        "change_description": args.get("why", "")[:200],
    }
    await card_queue.put(card)
    return {"content": [{"type": "text", "text": f"Card emitted with suggestion_id: {suggestion_id}"}]}


# ---------- Suggestion logger (called by server.py, not a tool) ----------


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

ALL_TOOLS = [propose_prompt_change]

draft_tools_server = create_sdk_mcp_server(
    name="draft-tools",
    version="1.0.0",
    tools=ALL_TOOLS,
)
