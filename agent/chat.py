"""Chat agent — handles free-form user conversations with the Draft agent.

The user types messages in the Agent tab's chat input. Each message triggers
a Claude Agent SDK session with the CHAT_SYSTEM_PROMPT. Responses stream back
through the shared card_queue as _chat_event items, which the SSE handler
routes to the Swift client.

The agent_lock prevents concurrent SDK sessions (chat vs. analysis).
"""

import asyncio
import logging
import os
import uuid

from claude_agent_sdk import (
    ClaudeSDKClient,
    ClaudeAgentOptions,
    AssistantMessage,
    ResultMessage,
    TextBlock,
    ToolUseBlock,
)

from .agent_lock import agent_lock
from .prompts import CHAT_SYSTEM_PROMPT
from .tools import DRAFT_DATA_DIR, draft_tools_server, card_queue

log = logging.getLogger("agent")

# Conversation history — persists across messages until cleared
chat_history: list[dict] = []

MAX_HISTORY_TURNS = 20


def clear_history() -> None:
    """Reset chat conversation."""
    global chat_history
    chat_history = []
    log.info("💬 Chat history cleared")


async def run_chat(user_message: str) -> None:
    """Run a single chat turn using Claude Agent SDK."""
    message_id = str(uuid.uuid4())

    # Add user message to history
    chat_history.append({"role": "user", "content": user_message})

    # Trim history if too long (keep last N*2 entries for N turns)
    if len(chat_history) > MAX_HISTORY_TURNS * 2:
        chat_history[:] = chat_history[-(MAX_HISTORY_TURNS * 2):]

    # Build query with conversation context
    context_lines = []
    for turn in chat_history[:-1]:
        role = turn["role"].upper()
        context_lines.append(f"{role}: {turn['content']}")

    if context_lines:
        query = "Previous conversation:\n" + "\n".join(context_lines) + f"\n\nUSER: {user_message}"
    else:
        query = user_message

    async with agent_lock:
        # Strip Claude Code env vars (same as orchestrator)
        os.environ.pop("CLAUDECODE", None)
        os.environ.pop("CLAUDE_CODE_SESSION", None)

        try:
            options = ClaudeAgentOptions(
                system_prompt=CHAT_SYSTEM_PROMPT,
                mcp_servers={"draft-tools": draft_tools_server},
                permission_mode="bypassPermissions",
                disallowed_tools=["Write", "Edit", "MultiEdit"],
                add_dirs=[str(DRAFT_DATA_DIR)],
                model="sonnet",
                max_turns=5,
                max_budget_usd=0.25,
            )

            full_text = ""
            has_sent_text = False  # Track whether we've emitted text before

            async with ClaudeSDKClient(options=options) as client:
                await client.query(query)

                async for msg in client.receive_messages():
                    if isinstance(msg, AssistantMessage):
                        for block in msg.content:
                            if isinstance(block, TextBlock):
                                # Add separator between text from different messages
                                # (e.g., before and after tool use)
                                prefix = "\n\n" if has_sent_text else ""
                                full_text += prefix + block.text
                                has_sent_text = True
                                await card_queue.put({
                                    "_chat_event": "chat_token",
                                    "text": prefix + block.text,
                                    "message_id": message_id,
                                })
                            elif isinstance(block, ToolUseBlock):
                                log.info(f"  💬🔧 Chat tool: {block.name}")
                                tool_input = {}
                                if hasattr(block, "input") and isinstance(block.input, dict):
                                    tool_input = block.input
                                await card_queue.put({
                                    "_chat_event": "chat_tool",
                                    "tool_name": block.name,
                                    "tool_input": tool_input,
                                    "message_id": message_id,
                                })
                    elif isinstance(msg, ResultMessage):
                        cost = getattr(msg, "total_cost_usd", 0.0) or 0.0
                        log.info(f"💬 Chat complete — cost: ${cost:.3f}")
                        break

            # Send completion signal
            await card_queue.put({
                "_chat_event": "chat_done",
                "message_id": message_id,
                "full_text": full_text,
            })

            # Add assistant response to history
            chat_history.append({"role": "assistant", "content": full_text})

        except Exception as e:
            log.error(f"💬 Chat error: {e}", exc_info=True)
            await card_queue.put({
                "_chat_event": "chat_error",
                "error": str(e),
                "message_id": message_id,
            })
