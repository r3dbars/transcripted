"""Run a child process in its own process group and kill the whole group on timeout.

subprocess.run(timeout=...) only kills the direct child. When that child is a
bench adapter (or a shell) that started the app, the CLI, or the speaker
harness, the grandchildren keep running into the next trial and skew exactly
the timings the lab is trying to measure. Every bench subprocess goes through
run_group instead.
"""

from __future__ import annotations

import os
import signal
import subprocess
from typing import Mapping, Sequence


def _kill_group(proc: subprocess.Popen) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.kill()
    except ProcessLookupError:
        pass


def run_group(
    argv: Sequence[str],
    *,
    timeout: float | None,
    cwd: str | os.PathLike | None = None,
    env: Mapping[str, str] | None = None,
    stdin_devnull: bool = True,
) -> subprocess.CompletedProcess:
    """Like subprocess.run(capture_output=True, text=True), but group-safe.

    Raises subprocess.TimeoutExpired after killing the whole process group,
    and makes sure the group is gone even if the caller is interrupted.
    """
    proc = subprocess.Popen(
        list(argv),
        cwd=cwd,
        env=dict(env) if env is not None else None,
        stdin=subprocess.DEVNULL if stdin_devnull else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        stdout, stderr = proc.communicate()
        raise subprocess.TimeoutExpired(proc.args, timeout, output=stdout, stderr=stderr)
    except BaseException:
        _kill_group(proc)
        proc.communicate()
        raise
    # A well-behaved child can still leave background grandchildren behind.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
