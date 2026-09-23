#!/usr/bin/env python3
"""Tests for hc_proc.run_group, plus the grandchild helpers the bench adapter tests share.

Run: python3 -m unittest scripts/hillclimb/test_hc_proc.py

The failure run_group exists to prevent (review S8): a bench binary starts a
background child (the app, the CLI, the speaker harness), the timeout fires,
and only the direct child dies, so the grandchild keeps burning CPU/ANE into
the next trial. The fake binaries here spawn a real `sleep 30` grandchild,
write its pid to a file, and the tests check that pid is gone afterwards.
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from hc_proc import run_group  # noqa: E402

GRANDCHILD_SLEEP_SECONDS = 30


def grandchild_snippet(pid_file_expr: str) -> str:
    """Python lines that start a background `sleep 30` and write its pid.

    `pid_file_expr` is a Python expression (evaluated in the fake) giving the
    pid file path. The grandchild's stdio goes to /dev/null, like a daemon's,
    so a normal exit of the fake does not hold run_group's pipes open. The pid
    file is written via rename so a reader never sees a partial number.
    """
    return (
        "import os as _os, subprocess as _sp\n"
        f"_gc = _sp.Popen(['sleep', '{GRANDCHILD_SLEEP_SECONDS}'], stdin=_sp.DEVNULL, "
        "stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)\n"
        f"_pid_path = str({pid_file_expr})\n"
        "with open(_pid_path + '.tmp', 'w') as _h:\n"
        "    _h.write(str(_gc.pid))\n"
        "_os.replace(_pid_path + '.tmp', _pid_path)\n"
    )


def read_pid(path: Path, wait_s: float = 5.0) -> int:
    deadline = time.monotonic() + wait_s
    while time.monotonic() < deadline:
        if path.exists():
            return int(path.read_text())
        time.sleep(0.02)
    raise AssertionError(f"grandchild never wrote its pid to {path}")


def _is_zombie(pid: int) -> bool:
    """A killed, not-yet-reaped process still answers kill(pid, 0); it is not running."""
    stat_path = Path(f"/proc/{pid}/stat")
    if stat_path.exists():
        try:
            return stat_path.read_text().rsplit(")", 1)[1].split()[0] == "Z"
        except (OSError, IndexError):
            return False
    try:
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return state.stdout.strip().startswith("Z")


def process_running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return not _is_zombie(pid)


def wait_until_gone(pid: int, wait_s: float = 5.0) -> bool:
    """True once `pid` is no longer running (SIGKILL delivery is async, so poll briefly)."""
    deadline = time.monotonic() + wait_s
    while time.monotonic() < deadline:
        if not process_running(pid):
            return True
        time.sleep(0.05)
    return not process_running(pid)


def kill_quietly(pid: int) -> None:
    """Test cleanup: never leave a grandchild behind even when an assertion failed."""
    try:
        os.kill(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass


class GrandchildMixin:
    """Shared by the adapter tests: assert that the pid in `pid_file` did not survive."""

    def assert_grandchild_gone(self, pid_file: Path) -> None:
        pid = read_pid(pid_file)
        self.addCleanup(kill_quietly, pid)  # type: ignore[attr-defined]
        self.assertTrue(wait_until_gone(pid), f"grandchild {pid} survived")  # type: ignore[attr-defined]


class RunGroupTests(GrandchildMixin, unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.pid_file = self.root / "grandchild.pid"

    def script(self, body: str) -> list[str]:
        path = self.root / "fake.py"
        path.write_text(body)
        return [sys.executable, str(path)]

    def test_normal_exit_returns_output_and_code(self) -> None:
        argv = self.script(
            "import os, sys\n"
            "print('out ' + os.getcwd() + ' ' + os.environ.get('HC_PROC_TEST', '-'))\n"
            "print('err', file=sys.stderr)\n"
            "sys.exit(3)\n"
        )
        env = dict(os.environ, HC_PROC_TEST="seen")
        completed = run_group(argv, timeout=30, cwd=self.root, env=env)
        self.assertEqual(completed.returncode, 3)
        self.assertEqual(completed.stdout.strip(), f"out {os.path.realpath(self.root)} seen")
        self.assertEqual(completed.stderr.strip(), "err")
        self.assertIsInstance(completed.stdout, str)

    def test_stdin_is_not_inherited(self) -> None:
        completed = run_group(self.script("import sys\nprint(repr(sys.stdin.read()))\n"), timeout=30)
        self.assertEqual(completed.stdout.strip(), "''")

    def test_timeout_kills_the_whole_group(self) -> None:
        argv = self.script(
            grandchild_snippet(repr(str(self.pid_file)))
            + "import sys, time\nprint('started', flush=True)\nprint('late', file=sys.stderr, flush=True)\n"
            + f"time.sleep({GRANDCHILD_SLEEP_SECONDS})\n"
        )
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            run_group(argv, timeout=1.5)
        self.assertLess(time.monotonic() - started, 10.0)
        self.assertIn("started", caught.exception.output or "")
        self.assertIn("late", caught.exception.stderr or "")
        self.assert_grandchild_gone(self.pid_file)

    def test_grandchild_killed_after_normal_exit(self) -> None:
        argv = self.script(grandchild_snippet(repr(str(self.pid_file))) + "print('done')\n")
        completed = run_group(argv, timeout=30)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout.strip(), "done")
        self.assert_grandchild_gone(self.pid_file)

    def test_missing_binary_raises_oserror(self) -> None:
        with self.assertRaises(OSError):
            run_group([str(self.root / "absent")], timeout=5)


if __name__ == "__main__":
    unittest.main()
