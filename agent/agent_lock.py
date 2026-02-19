"""Locks to prevent concurrent Claude Agent SDK sessions.

Previously a single lock was shared between analysis (orchestrator.py) and
interactive chat (chat.py). This caused chat to block for up to 30–60 seconds
whenever a background analysis run was in progress.

We now use separate locks:
- analysis_lock: held during autonomous feedback analysis runs
- chat_lock: held during interactive chat turns

The two can now run concurrently. SSE event types are discriminated by the
_chat_event field in server.py, so there is no interleaving on the Swift side.
"""

import asyncio

analysis_lock = asyncio.Lock()
chat_lock = asyncio.Lock()

# Backward-compat alias — remove once all callers are updated
agent_lock = analysis_lock
