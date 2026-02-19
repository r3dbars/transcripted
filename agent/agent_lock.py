"""Shared lock to prevent concurrent Claude Agent SDK sessions.

Both the autonomous analysis (orchestrator.py) and interactive chat (chat.py)
use Claude Agent SDK, which spawns a CLI subprocess. Running two simultaneously
would interleave SSE events and double API costs. This lock serializes access.
"""

import asyncio

agent_lock = asyncio.Lock()
