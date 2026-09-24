"""Run a child process in its own process group and kill the whole group on timeout.

subprocess.run(timeout=...) only kills the direct child. When that child is a
bench adapter (or a shell) that started the app, the CLI, or the speaker
harness, the grandchildren keep running into the next trial and skew exactly
the timings the lab is trying to measure. Every bench subprocess goes through
run_group instead.

Only the outermost run_group starts a new session. It marks the child's
environment with OWNER_ENV, and a nested run_group (an adapter running the
app, CLI or harness) sees the mark and keeps its child in the same group. So
when the climber's timeout kills the adapter's group, the real work dies with
it. A separate inner session would survive that kill (review N1).
"""

from __future__ import annotations

import os
import signal
import subprocess
from typing import Mapping, Sequence

# Set in a child's environment by the run_group that made it a group leader.
OWNER_ENV = "TRANSCRIPTED_HILLCLIMB_GROUP_OWNED"


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

    Raises subprocess.TimeoutExpired after killing the child (and, when this
    call owns the group, everything in it), and makes sure the child is gone
    even if the caller is interrupted.
    """
    nested = os.environ.get(OWNER_ENV) == "1"
    child_env = dict(env) if env is not None else dict(os.environ)
    child_env[OWNER_ENV] = "1"
    proc = subprocess.Popen(
        list(argv),
        cwd=cwd,
        env=child_env,
        stdin=subprocess.DEVNULL if stdin_devnull else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=not nested,
    )
    kill = _kill_child if nested else _kill_group
    try:
        stdout, stderr = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill(proc)
        stdout, stderr = proc.communicate()
        raise subprocess.TimeoutExpired(proc.args, timeout, output=stdout, stderr=stderr)
    except BaseException:
        kill(proc)
        proc.communicate()
        raise
    if not nested:
        # A well-behaved child can still leave background grandchildren behind.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    # Nested: leftovers share the outer group, which the owner kills when this
    # process exits or times out.
    return subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)


def _kill_child(proc: subprocess.Popen) -> None:
    try:
        proc.kill()
    except ProcessLookupError:
        pass
