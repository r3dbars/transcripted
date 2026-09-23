#!/usr/bin/env python3
"""Drive the real running Transcripted app through its lab control channel.

The app only listens when it was launched with TRANSCRIPTED_LAB_CONTROL_DIR set
(see Sources/Support/LabControlChannel.swift and docs/lab-control-channel.md).
This client speaks that file-drop protocol so the lab can time the real app:

    lab_control.py launch --dir DIR --app PATH      start the app with the channel on
    lab_control.py send COMMAND [--args JSON] --dir DIR [--timeout S]
    lab_control.py tail-events [--offset N] [--event NAME ...]

`send` writes <dir>/inbox/<ns>-<id>.json atomically (tmp file + rename) and
waits for the response line with the same id in <dir>/responses.jsonl. It
prints one JSON object: the app's response plus client-side monotonic times.

`tail-events` reads the app's own events.jsonl from a byte offset. Timings
(press-to-recording, Stop-to-notes) come from those events; the channel never
duplicates them. By default only numeric context values and a few short
labels are printed, so nothing like device names or text leaks into lab logs.

Stdlib only. `--self-test` runs test_lab_control.py (works on Linux).
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Mapping, Sequence

HERE = Path(__file__).resolve().parent
CONTROL_ENV = "TRANSCRIPTED_LAB_CONTROL_DIR"
GUARD_ENV = "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"
CONTAINER_ENV = "TRANSCRIPTED_CONTAINER_DIR"
COMMANDS = (
    "ping",
    "status",
    "start_dictation",
    "stop_dictation",
    "start_meeting",
    "stop_meeting",
    "import_audio",
)
DEFAULT_EVENTS = Path.home() / "Library/Application Support/Transcripted/logs/events.jsonl"
# Short, non-identifying context labels that tail-events keeps next to numbers.
SAFE_CONTEXT_LABELS = frozenset(
    {
        "trigger", "stop_trigger", "reason", "outcome", "delivery", "save_outcome",
        "session_state", "from", "to", "session_id", "correlation_id",
    }
)
EXIT_OK, EXIT_NOT_OK, EXIT_TIMEOUT, EXIT_USAGE = 0, 1, 2, 3


class LabControlError(RuntimeError):
    pass


def monotonic_ms() -> float:
    return round(time.monotonic() * 1000.0, 3)


def control_dir(raw: str | os.PathLike[str]) -> Path:
    # The app requires an absolute path; resolve here so --dir can be relative.
    return Path(raw).expanduser().resolve()


# --- send -------------------------------------------------------------------


def new_command_id() -> str:
    return uuid.uuid4().hex[:16]


def write_command(root: Path, command: str, args: Mapping[str, Any] | None, command_id: str) -> Path:
    """Atomically drop one command file into <root>/inbox and return its path."""
    inbox = root / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    payload = {"id": command_id, "command": command, "args": dict(args or {})}
    # Nanosecond prefix keeps inbox order == send order (the app sorts by name).
    name = f"{time.time_ns():020d}-{command_id}.json"
    final = inbox / name
    staging = inbox / (name + ".tmp")
    staging.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    os.replace(staging, final)
    return final


def read_complete_lines(path: Path, offset: int) -> tuple[list[str], int]:
    """Complete (newline-terminated) lines after `offset`, and the new offset.

    A trailing partial line is left for the next read, so a reader racing the
    app's append never sees half a JSON object. If the file shrank (rotation or
    truncation) reading restarts at 0.
    """
    try:
        size = path.stat().st_size
    except FileNotFoundError:
        return [], 0
    if size < offset:
        offset = 0
    with path.open("rb") as handle:
        handle.seek(offset)
        chunk = handle.read()
    end = chunk.rfind(b"\n")
    if end < 0:
        return [], offset
    complete = chunk[: end + 1]
    lines = [line.decode("utf-8", errors="replace") for line in complete.split(b"\n") if line.strip()]
    return lines, offset + len(complete)


def wait_for_response(root: Path, command_id: str, timeout_s: float, start_offset: int = 0, poll_s: float = 0.02) -> dict[str, Any] | None:
    responses = root / "responses.jsonl"
    offset = start_offset
    deadline = time.monotonic() + timeout_s
    while True:
        lines, offset = read_complete_lines(responses, offset)
        for line in lines:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict) and record.get("id") == command_id:
                return record
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_s)


def responses_size(root: Path) -> int:
    try:
        return (root / "responses.jsonl").stat().st_size
    except FileNotFoundError:
        return 0


def send(root: Path, command: str, args: Mapping[str, Any] | None, timeout_s: float, command_id: str | None = None) -> tuple[int, dict[str, Any]]:
    """Send one command and wait for its response. Returns (exit code, report)."""
    command_id = command_id or new_command_id()
    # Only look at responses written after this send, so a reused id from an
    # older run in the same dir can never match.
    start_offset = responses_size(root)
    sent_ms = monotonic_ms()
    path = write_command(root, command, args, command_id)
    response = wait_for_response(root, command_id, timeout_s, start_offset=start_offset)
    received_ms = monotonic_ms()
    report: dict[str, Any] = {
        "id": command_id,
        "command": command,
        "client": {"sent_monotonic_ms": sent_ms, "received_monotonic_ms": received_ms, "round_trip_ms": round(received_ms - sent_ms, 3)},
        "response": response,
    }
    if response is None:
        report["error"] = f"timeout after {timeout_s:g}s (is the app running with {CONTROL_ENV}={root}?)"
        # Withdraw the unanswered command so a later launch cannot run a stale
        # start_meeting by surprise. If the app picked it up at this instant,
        # the unlink simply fails and the app's response still lands.
        try:
            path.unlink()
            report["withdrawn"] = True
        except FileNotFoundError:
            report["withdrawn"] = False
        return EXIT_TIMEOUT, report
    return (EXIT_OK if response.get("ok") is True else EXIT_NOT_OK), report


def parse_args_json(raw: str | None) -> dict[str, Any]:
    if raw is None or raw.strip() == "":
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise LabControlError(f"--args is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise LabControlError("--args must be a JSON object")
    return value


# --- launch -----------------------------------------------------------------


def resolve_executable(app: Path) -> Path:
    """An .app bundle -> its main executable (from Info.plist); anything else as-is."""
    if app.suffix == ".app" and app.is_dir():
        info = app / "Contents" / "Info.plist"
        name = None
        if info.is_file():
            with info.open("rb") as handle:
                name = plistlib.load(handle).get("CFBundleExecutable")
        if not name:
            name = app.stem
        return app / "Contents" / "MacOS" / str(name)
    return app


def launch_plan(root: Path, app: Path, allow_second_instance: bool = False, container: Path | None = None, use_open: bool | None = None) -> dict[str, Any]:
    """The exact argv + extra env `launch` would use. Pure, so it is testable."""
    extra_env = {CONTROL_ENV: str(root)}
    if allow_second_instance:
        extra_env[GUARD_ENV] = "1"
    if container is not None:
        extra_env[CONTAINER_ENV] = str(container)
    if use_open is None:
        use_open = app.suffix == ".app" and sys.platform == "darwin"
    if use_open:
        # `open -n` so the env is applied even if another copy is running
        # (without -n, open just activates the running copy and drops --env).
        # Launching through LaunchServices also keeps the app, not Terminal,
        # as the TCC-responsible process for mic / system-audio permission.
        argv = ["open", "-n", "-a", str(app)]
        for key, value in extra_env.items():
            argv += ["--env", f"{key}={value}"]
    else:
        argv = [str(resolve_executable(app))]
    return {"argv": argv, "env": extra_env, "uses_open": use_open}


def clear_stale_inbox(root: Path) -> int:
    """Delete command files left from an earlier run so they cannot fire on launch."""
    inbox = root / "inbox"
    removed = 0
    if inbox.is_dir():
        for entry in inbox.iterdir():
            if entry.is_file() and entry.name.endswith((".json", ".json.tmp")):
                entry.unlink(missing_ok=True)
                removed += 1
    return removed


def launch(root: Path, app: Path, wait_s: float, allow_second_instance: bool = False, container: Path | None = None, use_open: bool | None = None) -> tuple[int, dict[str, Any]]:
    root.mkdir(parents=True, exist_ok=True)
    stale = clear_stale_inbox(root)
    plan = launch_plan(root, app, allow_second_instance, container, use_open)
    env = dict(os.environ)
    env.update(plan["env"])
    log_path = root / "app-stdio.log"
    with log_path.open("ab") as log:
        process = subprocess.Popen(plan["argv"], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    code, ping = send(root, "ping", {}, wait_s)
    report = {"plan": plan, "launcher_pid": process.pid, "ping": ping, "stdio_log": str(log_path), "stale_commands_removed": stale}
    if code == EXIT_TIMEOUT:
        report["hint"] = (
            "no ping reply. If Transcripted was already running, quit it first: the single-instance "
            "guard makes the new copy exit. Check app-stdio.log for 'LAB_CONTROL | enabled'."
        )
    return code, report


# --- tail-events -------------------------------------------------------------


def default_events_path(container: Path | None) -> Path:
    if container is not None:
        return container / "logs" / "events.jsonl"
    return DEFAULT_EVENTS


def is_number_text(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return True
    if not isinstance(value, str) or not value.strip():
        return False
    try:
        float(value)
    except ValueError:
        return False
    return True


def reduce_event(record: Mapping[str, Any]) -> dict[str, Any]:
    """Keep the timing-relevant, non-identifying parts of one events.jsonl line."""
    context = record.get("context") or {}
    kept: dict[str, Any] = {}
    if isinstance(context, Mapping):
        for key, value in context.items():
            if is_number_text(value):
                kept[key] = float(value) if "." in str(value) else int(float(value))
            elif key in SAFE_CONTEXT_LABELS and isinstance(value, str) and len(value) <= 64:
                kept[key] = value
    return {
        "timestamp": record.get("timestamp"),
        "engine": record.get("engine"),
        "event": record.get("event"),
        "level": record.get("level"),
        "context": kept,
    }


def tail_events(path: Path, offset: int, events: Sequence[str] | None = None, raw: bool = False) -> dict[str, Any]:
    rotated = False
    try:
        if path.stat().st_size < offset:
            rotated = True
    except FileNotFoundError:
        return {"path_exists": False, "next_offset": 0, "rotated": False, "events": []}
    lines, next_offset = read_complete_lines(path, offset)
    wanted = set(events or ())
    out: list[Any] = []
    for line in lines:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        if wanted and record.get("event") not in wanted:
            continue
        out.append(record if raw else reduce_event(record))
    return {"path_exists": True, "next_offset": next_offset, "rotated": rotated, "events": out}


# --- CLI --------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true", help="run test_lab_control.py")
    sub = parser.add_subparsers(dest="action")

    p_send = sub.add_parser("send", help="send one command and wait for its response")
    p_send.add_argument("command", choices=COMMANDS)
    p_send.add_argument("--args", default=None, help='JSON object, e.g. \'{"paste": false}\'')
    p_send.add_argument("--dir", required=True, help="the app's TRANSCRIPTED_LAB_CONTROL_DIR")
    p_send.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for the response")
    p_send.add_argument("--id", default=None, help="command id (default: random)")

    p_launch = sub.add_parser("launch", help="start the app with the lab channel on, then ping it")
    p_launch.add_argument("--dir", required=True)
    p_launch.add_argument("--app", required=True, help="Transcripted.app bundle or its Contents/MacOS binary")
    p_launch.add_argument("--wait", type=float, default=60.0, help="seconds to wait for the first ping")
    p_launch.add_argument(
        "--allow-second-instance",
        action="store_true",
        help=f"set {GUARD_ENV}=1 (only when a normal copy must keep running; two copies share hotkeys and state)",
    )
    p_launch.add_argument("--container", default=None, help=f"set {CONTAINER_ENV} to isolate captures/logs from the real library")
    p_launch.add_argument("--exec", dest="use_exec", action="store_true", help="exec the binary directly instead of `open -n`")
    p_launch.add_argument("--dry-run", action="store_true", help="print the launch plan and exit")

    p_tail = sub.add_parser("tail-events", help="read new events.jsonl lines since a byte offset")
    p_tail.add_argument("--events-file", default=None)
    p_tail.add_argument("--container", default=None, help="read <container>/logs/events.jsonl")
    p_tail.add_argument("--offset", type=int, default=0)
    p_tail.add_argument("--event", action="append", default=None, help="only this event name (repeatable)")
    p_tail.add_argument("--raw", action="store_true", help="print whole lines (may include device names)")
    return parser


def run_self_test() -> int:
    import unittest

    sys.path.insert(0, str(HERE))
    suite = unittest.defaultTestLoader.loadTestsFromName("test_lab_control")
    outcome = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if outcome.wasSuccessful() else 1


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        return run_self_test()
    if not args.action:
        parser.print_help()
        return EXIT_USAGE
    try:
        if args.action == "send":
            code, report = send(control_dir(args.dir), args.command, parse_args_json(args.args), args.timeout, args.id)
        elif args.action == "launch":
            container = Path(args.container).expanduser().resolve() if args.container else None
            use_open = False if args.use_exec else None
            root, app = control_dir(args.dir), Path(args.app).expanduser().resolve()
            if args.dry_run:
                code, report = EXIT_OK, launch_plan(root, app, args.allow_second_instance, container, use_open)
            else:
                code, report = launch(root, app, args.wait, args.allow_second_instance, container, use_open)
        else:
            container = Path(args.container).expanduser().resolve() if args.container else None
            path = Path(args.events_file).expanduser() if args.events_file else default_events_path(container)
            code, report = EXIT_OK, tail_events(path, args.offset, args.event, args.raw)
    except LabControlError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return EXIT_USAGE
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
