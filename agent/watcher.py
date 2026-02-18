"""Feedback file watcher — polls feedback.jsonl for new entries.

Uses file size comparison (not fsevents) because the file is append-only.
Triggers a callback when new lines are detected.
"""

import asyncio
from pathlib import Path
from typing import Callable, Awaitable


class FeedbackWatcher:
    def __init__(
        self,
        feedback_path: Path,
        callback: Callable[[int], Awaitable[None]],
        poll_interval: float = 5.0,
    ):
        self.feedback_path = feedback_path
        self.callback = callback
        self.poll_interval = poll_interval
        self.last_line_count = 0
        self.last_size = 0

    def _file_size(self) -> int:
        if not self.feedback_path.exists():
            return 0
        return self.feedback_path.stat().st_size

    def _count_lines(self) -> int:
        if not self.feedback_path.exists():
            return 0
        with open(self.feedback_path) as f:
            return sum(1 for line in f if line.strip())

    async def start(self) -> None:
        """Start polling. On startup, count existing lines without triggering."""
        self.last_line_count = self._count_lines()
        self.last_size = self._file_size()
        print(f"👁️  Watcher started — {self.last_line_count} existing feedback entries")

        while True:
            await asyncio.sleep(self.poll_interval)
            current_size = self._file_size()
            if current_size > self.last_size:
                current_count = self._count_lines()
                new_lines = current_count - self.last_line_count
                if new_lines > 0:
                    self.last_line_count = current_count
                    self.last_size = current_size
                    print(f"👁️  Detected {new_lines} new feedback entries")
                    await self.callback(new_lines)
