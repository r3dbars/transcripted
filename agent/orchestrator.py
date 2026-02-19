"""Orchestrator — runs Claude Agent SDK analysis when new feedback arrives.

Uses ClaudeSDKClient with custom tools to analyze feedback patterns and
propose prompt improvements via the propose_prompt_change tool.
"""

import asyncio
import logging
import os
from datetime import datetime, timezone

log = logging.getLogger("agent")

from claude_agent_sdk import (
    ClaudeSDKClient,
    ClaudeAgentOptions,
    AssistantMessage,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
)

from .agent_lock import agent_lock
from .prompts import ORCHESTRATOR_SYSTEM_PROMPT
from .tools import DRAFT_DATA_DIR, draft_tools_server, card_queue
from .server import set_analysis_state


async def run_analysis(new_entry_count: int, total_lines: int) -> None:
    """Run a single analysis pass using the Claude Agent SDK.

    Called by the debounce loop when enough new feedback has accumulated.
    The agent reads feedback, identifies patterns, and proposes prompt changes
    via the propose_prompt_change tool (which pushes cards to the SSE queue).
    """
    log.info(f"🧠 Starting analysis — {new_entry_count} new entries to analyze...")

    # Emit analyzing event to SSE
    await card_queue.put({"_event": "analyzing", "entry_count": new_entry_count})

    cost = 0.0
    turns = 0

    async with agent_lock:
        # Strip Claude Code session env vars so the Agent SDK CLI doesn't refuse to start
        os.environ.pop("CLAUDECODE", None)
        os.environ.pop("CLAUDE_CODE_SESSION", None)

        options = ClaudeAgentOptions(
            system_prompt=ORCHESTRATOR_SYSTEM_PROMPT,
            mcp_servers={"draft-tools": draft_tools_server},
            permission_mode="acceptEdits",
            add_dirs=[str(DRAFT_DATA_DIR)],
            model="sonnet",
            max_turns=10,
        )

        query_text = f"""{new_entry_count} new feedback entries have arrived since your last analysis.

Read the data files, find the highest-impact pattern (biggest recurring edit delta),
and propose 1-3 focused prompt changes via propose_prompt_change."""

        try:
            async with ClaudeSDKClient(options=options) as client:
                await client.query(query_text)

                async for msg in client.receive_messages():
                    if isinstance(msg, AssistantMessage):
                        for block in msg.content:
                            if isinstance(block, TextBlock):
                                log.info(f"  💭 {block.text[:200]}")
                            elif isinstance(block, ToolUseBlock):
                                log.info(f"  🔧 {block.name}")
                    elif isinstance(msg, ResultMessage):
                        cost = getattr(msg, "total_cost_usd", 0.0) or 0.0
                        turns = getattr(msg, "num_turns", 0) or 0
                        break

        except Exception as e:
            log.error(f"  ❌ Analysis error: {e}", exc_info=True)
            cost = 0.0
            turns = 0

    timestamp = datetime.now(timezone.utc).isoformat()
    set_analysis_state(timestamp, total_lines)

    # Emit analysis_complete event to SSE
    await card_queue.put({
        "_event": "analysis_complete",
        "cost_usd": cost,
        "turns": turns,
    })

    log.info(f"🧠 Analysis complete — cost: ${cost:.3f}, turns: {turns}")
