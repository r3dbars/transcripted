"""HTTP server with SSE streaming for the Draft orchestrator agent.

Endpoints:
- GET /events      — SSE stream of insight cards + chat responses
- POST /apply      — Apply a suggested prompt change
- POST /skip       — Skip a suggested prompt change
- POST /chat       — Send a chat message to the agent
- POST /chat/clear — Clear chat conversation history
- POST /trigger    — Manually trigger analysis (testing)
- GET /health      — Agent status
"""

import asyncio
import json
import os
import time
from pathlib import Path

from aiohttp import web

from .tools import (
    DRAFT_DATA_DIR, PROMPTS_PATH, SUGGESTION_LOG_PATH,
    card_queue, log_suggestion,
)

start_time = time.time()
last_analysis_timestamp: str | None = None
feedback_line_count = 0


def set_analysis_state(timestamp: str, lines: int) -> None:
    global last_analysis_timestamp, feedback_line_count
    last_analysis_timestamp = timestamp
    feedback_line_count = lines


async def sse_handler(request: web.Request) -> web.StreamResponse:
    """SSE endpoint — streams insight cards to Swift client."""
    response = web.StreamResponse(
        status=200,
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*",
        },
    )
    await response.prepare(request)

    # Initial connection event
    await response.write(b'event: connected\ndata: {"status":"ok"}\n\n')

    while True:
        try:
            card = await asyncio.wait_for(card_queue.get(), timeout=15.0)
            # Route by discriminator field
            if "_chat_event" in card:
                event_type = card.pop("_chat_event")
                payload = json.dumps(card)
                await response.write(f"event: {event_type}\ndata: {payload}\n\n".encode())
            else:
                payload = json.dumps(card)
                await response.write(f"event: insight\ndata: {payload}\n\n".encode())
        except asyncio.TimeoutError:
            # Keepalive comment to prevent connection timeout
            await response.write(b": keepalive\n\n")
        except (ConnectionResetError, ConnectionAbortedError):
            break

    return response


def _apply_prompt_change(prompt_key: str, new_value: str) -> bool:
    """Write a prompt change to prompts.json. Returns True on success."""
    if not PROMPTS_PATH.exists():
        return False
    try:
        data = json.loads(PROMPTS_PATH.read_text())
        if prompt_key not in data:
            return False
        data[prompt_key] = new_value
        PROMPTS_PATH.write_text(json.dumps(data, indent=2, sort_keys=True))
        return True
    except (json.JSONDecodeError, OSError):
        return False


async def apply_handler(request: web.Request) -> web.Response:
    """Apply a suggested prompt change — writes to prompts.json + logs outcome."""
    body = await request.json()
    suggestion_id = body.get("suggestion_id", "")
    prompt_key = body.get("prompt_key", "")
    proposed_value = body.get("proposed_value", "")

    success = _apply_prompt_change(prompt_key, proposed_value)

    log_suggestion(
        suggestion_id=suggestion_id,
        prompt_key=prompt_key,
        action="apply",
        saw=body.get("saw", ""),
        why=body.get("why", ""),
        change=body.get("change", ""),
    )

    return web.json_response({"applied": success})


async def skip_handler(request: web.Request) -> web.Response:
    """Skip a suggested prompt change — logs outcome for meta-learning."""
    body = await request.json()

    log_suggestion(
        suggestion_id=body.get("suggestion_id", ""),
        prompt_key=body.get("prompt_key", ""),
        action="skip",
        saw=body.get("saw", ""),
        why=body.get("why", ""),
        change=body.get("change", ""),
    )

    return web.json_response({"skipped": True})


async def chat_handler(request: web.Request) -> web.Response:
    """Accept a chat message — runs agent in background, streams response via SSE."""
    from .chat import run_chat

    body = await request.json()
    message = body.get("message", "").strip()
    if not message:
        return web.json_response({"error": "empty message"}, status=400)

    asyncio.create_task(run_chat(message))
    return web.json_response({"status": "processing"})


async def chat_clear_handler(request: web.Request) -> web.Response:
    """Clear chat conversation history."""
    from .chat import clear_history
    clear_history()
    return web.json_response({"cleared": True})


async def trigger_handler(request: web.Request) -> web.Response:
    """Manually trigger an analysis pass — useful for testing."""
    # Late import to avoid circular dependency (orchestrator imports from server)
    from .orchestrator import run_analysis
    from .tools import FEEDBACK_PATH

    total_lines = sum(1 for _ in open(FEEDBACK_PATH)) if FEEDBACK_PATH.exists() else 0
    if total_lines == 0:
        return web.json_response({"triggered": False, "reason": "no feedback data"})

    asyncio.create_task(run_analysis(total_lines, total_lines))
    return web.json_response({"triggered": True, "entries": total_lines})


async def health_handler(request: web.Request) -> web.Response:
    """Health check — returns agent status."""
    return web.json_response({
        "status": "running",
        "pid": os.getpid(),
        "uptime_seconds": round(time.time() - start_time, 1),
        "last_analysis": last_analysis_timestamp,
        "feedback_lines_seen": feedback_line_count,
    })


def create_app() -> web.Application:
    """Create the aiohttp application with all routes."""
    app = web.Application()
    app.router.add_get("/events", sse_handler)
    app.router.add_post("/apply", apply_handler)
    app.router.add_post("/skip", skip_handler)
    app.router.add_post("/chat", chat_handler)
    app.router.add_post("/chat/clear", chat_clear_handler)
    app.router.add_post("/trigger", trigger_handler)
    app.router.add_get("/health", health_handler)
    return app
