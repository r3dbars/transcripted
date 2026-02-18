"""Orchestrator — runs Claude Agent SDK analysis when new feedback arrives.

Uses ClaudeSDKClient with custom tools to analyze feedback patterns and
propose prompt improvements via the propose_prompt_change tool.
"""

import asyncio
from datetime import datetime, timezone

from claude_agent_sdk import (
    ClaudeSDKClient,
    ClaudeAgentOptions,
    AssistantMessage,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
)

from .prompts import ORCHESTRATOR_SYSTEM_PROMPT
from .tools import draft_tools_server, card_queue
from .server import set_analysis_state


async def run_analysis(new_entry_count: int, total_lines: int) -> None:
    """Run a single analysis pass using the Claude Agent SDK.

    Called by the debounce loop when enough new feedback has accumulated.
    The agent reads feedback, identifies patterns, and proposes prompt changes
    via the propose_prompt_change tool (which pushes cards to the SSE queue).
    """
    print(f"\n🧠 Starting analysis — {new_entry_count} new entries to analyze...")

    # Emit analyzing event to SSE
    await card_queue.put({"_event": "analyzing", "entry_count": new_entry_count})

    options = ClaudeAgentOptions(
        system_prompt=ORCHESTRATOR_SYSTEM_PROMPT,
        mcp_servers={"draft-tools": draft_tools_server},
        allowed_tools=[
            "mcp__draft-tools__read_feedback",
            "mcp__draft-tools__read_prompts",
            "mcp__draft-tools__read_style_profile",
            "mcp__draft-tools__read_suggestion_log",
            "mcp__draft-tools__get_edit_patterns",
            "mcp__draft-tools__get_platform_stats",
            "mcp__draft-tools__propose_prompt_change",
        ],
        model="claude-sonnet-4-5",
        max_turns=10,
        max_budget_usd=0.50,
    )

    query_text = f"""{new_entry_count} new feedback entries have arrived since your last analysis.

Steps:
1. Read your suggestion history first to understand what the user has accepted/skipped before
2. Read the recent feedback entries and compute edit patterns
3. Read the current prompts.json to see what's being used
4. Read the style profile for context on the user's voice
5. Identify the highest-impact pattern in the feedback (biggest recurring edit delta)
6. Propose 1-3 focused prompt changes, each as a separate card via propose_prompt_change

Focus on the pattern that would reduce the most edit distance if fixed."""

    cost = 0.0
    turns = 0

    try:
        async with ClaudeSDKClient(options=options) as client:
            await client.query(query_text)

            async for msg in client.receive_messages():
                if isinstance(msg, AssistantMessage):
                    for block in msg.content:
                        if isinstance(block, TextBlock):
                            # Agent's reasoning — log it
                            print(f"  💭 {block.text[:120]}...")
                        elif isinstance(block, ToolUseBlock):
                            print(f"  🔧 {block.name}")
                elif isinstance(msg, ResultMessage):
                    cost = getattr(msg, "total_cost_usd", 0.0) or 0.0
                    turns = getattr(msg, "num_turns", 0) or 0
                    break

    except Exception as e:
        print(f"  ❌ Analysis error: {e}")
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

    print(f"🧠 Analysis complete — cost: ${cost:.3f}, turns: {turns}")
