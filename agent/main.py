"""Entry point for the Draft orchestrator agent.

Starts three concurrent tasks:
1. HTTP server (SSE + apply/skip + health) on port 19832
2. Feedback file watcher (polls every 5s)
3. Debounce loop (waits for quiet period before triggering analysis)

Run: python3 -m agent.main
"""

import asyncio
import logging
import signal
import sys
from pathlib import Path

from aiohttp import web

from .server import create_app
from .watcher import FeedbackWatcher
from .orchestrator import run_analysis
from .tools import DRAFT_DATA_DIR, FEEDBACK_PATH

# Set up file logging so we can see output even when stdout/stderr are piped
_log_path = Path.home() / "draft-agent.log"
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.FileHandler(_log_path, mode="w"),
        logging.StreamHandler(sys.stderr),
    ],
)
log = logging.getLogger("agent")

PORT = 19832

# Debounce state
_pending_new_count = 0
_last_trigger_time = 0.0
_total_lines = 0
DEBOUNCE_SECONDS = 30
MIN_ENTRIES_FOR_TRIGGER = 3


async def _on_new_feedback(new_lines: int) -> None:
    """Called by watcher when new feedback lines detected."""
    global _pending_new_count, _last_trigger_time, _total_lines
    _pending_new_count += new_lines
    _total_lines += new_lines
    _last_trigger_time = asyncio.get_event_loop().time()


async def _debounce_loop() -> None:
    """Check if enough time has passed since last feedback to trigger analysis.

    Policy: wait for DEBOUNCE_SECONDS of quiet after the last new entry,
    and require at least MIN_ENTRIES_FOR_TRIGGER new entries.
    """
    global _pending_new_count, _last_trigger_time
    while True:
        await asyncio.sleep(5)
        now = asyncio.get_event_loop().time()
        if (
            _pending_new_count >= MIN_ENTRIES_FOR_TRIGGER
            and _last_trigger_time > 0
            and (now - _last_trigger_time) > DEBOUNCE_SECONDS
        ):
            count = _pending_new_count
            _pending_new_count = 0
            try:
                await run_analysis(count, _total_lines)
            except Exception as e:
                log.error(f"❌ Analysis error: {e}")


async def main() -> None:
    """Start the orchestrator agent."""
    # Ensure data directory exists
    DRAFT_DATA_DIR.mkdir(parents=True, exist_ok=True)

    log.info(f"🤖 Draft Orchestrator Agent starting...")
    log.info(f"   Data dir: {DRAFT_DATA_DIR}")
    log.info(f"   Port: {PORT}")

    # Start HTTP server
    app = create_app()
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", PORT)
    await site.start()
    log.info(f"✅ Server running on http://127.0.0.1:{PORT}")

    # Start feedback watcher
    watcher = FeedbackWatcher(FEEDBACK_PATH, _on_new_feedback, poll_interval=5.0)

    # Handle graceful shutdown
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: asyncio.create_task(_shutdown(runner)))

    # Run watcher + debounce in parallel (both run forever)
    await asyncio.gather(
        watcher.start(),
        _debounce_loop(),
    )


async def _shutdown(runner: web.AppRunner) -> None:
    """Graceful shutdown."""
    log.info("🛑 Shutting down...")
    await runner.cleanup()
    # Cancel all running tasks to exit cleanly
    for task in asyncio.all_tasks():
        if task is not asyncio.current_task():
            task.cancel()
    asyncio.get_event_loop().stop()


if __name__ == "__main__":
    asyncio.run(main())
