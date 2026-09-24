#!/usr/bin/env python3
"""Drive the real running Transcripted app through its lab control channel.

The channel exists only in lab builds (`bash build.sh --lab`), and even there
the app only listens when it was launched with TRANSCRIPTED_LAB_CONTROL_DIR set
to a private (0700, owned by you, not a symlink) directory. See
Sources/Support/LabControlChannel.swift and docs/lab-control-channel.md.
This client speaks that file-drop protocol so the lab can time the real app:

    lab_control.py launch --dir DIR --app PATH --container CDIR
                                                    start the app with the channel on
    lab_control.py send COMMAND [--args JSON] [--paste] --dir DIR [--timeout S]
    lab_control.py tail-events [--offset N] [--event NAME ...]

`launch` isolates by default. It needs --container (a throwaway
TRANSCRIPTED_CONTAINER_DIR) unless --use-real-library is given. It refuses when
the app's `transcriptSaveLocation` preference names a relocated library (that
beats the container) and when anonymous analytics or crash reporting is on,
unless --use-real-library / --allow-telemetry say that's intended. It reads
preferences with `defaults read` and never writes them.

`send stop_dictation` never pastes unless --paste is given. Pasting types the
transcript into whatever app is frontmost (and presses Return if auto-send is on).

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
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

HERE = Path(__file__).resolve().parent
CONTROL_ENV = "TRANSCRIPTED_LAB_CONTROL_DIR"
GUARD_ENV = "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"
CONTAINER_ENV = "TRANSCRIPTED_CONTAINER_DIR"
# The app's UserDefaults domain (Info.plist CFBundleIdentifier) and the keys the
# launch preflight reads. Sources: TranscriptedStoragePaths.swift
# (captureLibraryLocationKey), AnalyticsPreferences.swift and
# CrashReportingPreferences.swift (enabledKey; a missing key means ON).
DEFAULTS_DOMAIN = "com.justinbetker.draft"
SAVE_LOCATION_KEY = "transcriptSaveLocation"
ANALYTICS_KEY = "observability-anonymous-analytics-enabled"
CRASH_REPORTING_KEY = "observability-crash-reporting-enabled"
PRIVATE_DIR_MODE = 0o700
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


def ensure_private_dir(path: Path) -> None:
    """Create `path` as a 0700 dir, or check an existing one the way the app does.

    The app refuses to start the channel unless the control dir, inbox/ and
    done/ are real directories (not symlinks) owned by this user with mode
    0700 exactly. An existing directory is never chmod-ed here: a wrong mode
    means the caller pointed --dir somewhere unexpected, so this refuses.
    """
    try:
        path.mkdir(mode=PRIVATE_DIR_MODE)
    except FileExistsError:
        pass
    except FileNotFoundError as error:
        raise LabControlError(f"parent of {path} does not exist") from error
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        raise LabControlError(f"{path} is a symlink; the app refuses symlinked control dirs")
    if not stat.S_ISDIR(info.st_mode):
        raise LabControlError(f"{path} is not a directory")
    if info.st_uid != os.getuid():
        raise LabControlError(f"{path} is not owned by you")
    if stat.S_IMODE(info.st_mode) != PRIVATE_DIR_MODE:
        raise LabControlError(f"{path} must be mode 0700 (it is {stat.S_IMODE(info.st_mode):o}); run: chmod 700 {path}")


def prepare_control_dir(root: Path) -> None:
    """Root, inbox/ and done/ as private dirs, matching the app's startup check."""
    ensure_private_dir(root)
    ensure_private_dir(root / "inbox")
    ensure_private_dir(root / "done")


# --- send -------------------------------------------------------------------


def new_command_id() -> str:
    return uuid.uuid4().hex[:16]


def write_command(root: Path, command: str, args: Mapping[str, Any] | None, command_id: str) -> Path:
    """Atomically drop one command file into <root>/inbox and return its path."""
    prepare_control_dir(root)
    inbox = root / "inbox"
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


def check_paste(args: Mapping[str, Any] | None, allow_paste: bool) -> None:
    """Refuse any `paste` other than false unless the caller explicitly allowed it."""
    if args and "paste" in args and args["paste"] is not False and not allow_paste:
        raise LabControlError(
            "refusing paste: it types the transcript into the frontmost app; pass --paste to mean it"
        )


def send(
    root: Path,
    command: str,
    args: Mapping[str, Any] | None,
    timeout_s: float,
    command_id: str | None = None,
    allow_paste: bool = False,
) -> tuple[int, dict[str, Any]]:
    """Send one command and wait for its response. Returns (exit code, report)."""
    check_paste(args, allow_paste)
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


def send_args(command: str, raw_args: str | None, paste: bool) -> dict[str, Any]:
    """The args object for `send`: --args JSON, plus paste:true only via --paste."""
    args = parse_args_json(raw_args)
    check_paste(args, allow_paste=False)
    if paste:
        if command != "stop_dictation":
            raise LabControlError("--paste only applies to stop_dictation")
        args["paste"] = True
    return args


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


DefaultsReader = Callable[[str, str], "str | None"]


def read_default(domain: str, key: str) -> str | None:
    """`defaults read DOMAIN KEY` stripped, or None when the key is not set.

    Read-only. Raises LabControlError when the `defaults` tool is missing
    (not macOS), because then the preflight cannot vouch for anything.
    """
    try:
        result = subprocess.run(
            ["defaults", "read", domain, key],
            capture_output=True, text=True, timeout=10, check=False,
        )
    except FileNotFoundError as error:
        raise LabControlError(
            "`defaults` not found, so the launch preflight cannot read the app's preferences (macOS only)"
        ) from error
    except subprocess.TimeoutExpired as error:
        raise LabControlError(f"`defaults read {domain} {key}` timed out") from error
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def preference_is_off(value: str | None) -> bool:
    """A bool preference that defaults to ON is off only when explicitly false."""
    return value is not None and value.strip().lower() in {"0", "false", "no"}


def launch_safety_problems(
    container: Path | None,
    use_real_library: bool,
    allow_telemetry: bool,
    reader: DefaultsReader | None = None,
) -> list[str]:
    """Why `launch` must not start the app, or [] when it may.

    Isolation: without --use-real-library a container is required, and a
    relocated capture library (transcriptSaveLocation) is refused because the
    app prefers it over the container's default library. Telemetry: both
    analytics and crash reporting must be explicitly off unless
    --allow-telemetry. `reader` is injectable so tests run without `defaults`.
    """
    problems: list[str] = []
    if container is None and not use_real_library:
        problems.append(
            "--container DIR is required (or pass --use-real-library to drive the real library, "
            "speaker database and dictation history on purpose)"
        )
    if use_real_library and allow_telemetry:
        return problems
    read = reader or read_default
    if not use_real_library:
        location = read(DEFAULTS_DOMAIN, SAVE_LOCATION_KEY)
        if location:
            problems.append(
                f"{SAVE_LOCATION_KEY} is set, so the app would save into that relocated library even "
                "with --container; clear it in Settings or pass --use-real-library"
            )
    if not allow_telemetry:
        for key, label in ((ANALYTICS_KEY, "anonymous analytics"), (CRASH_REPORTING_KEY, "crash reporting")):
            if not preference_is_off(read(DEFAULTS_DOMAIN, key)):
                problems.append(f"{label} is on ({key}); turn it off in Settings or pass --allow-telemetry")
    return problems


def check_launch_safety(
    container: Path | None,
    use_real_library: bool,
    allow_telemetry: bool,
    reader: DefaultsReader | None = None,
) -> None:
    problems = launch_safety_problems(container, use_real_library, allow_telemetry, reader)
    if problems:
        raise LabControlError("refusing to launch: " + "; ".join(problems))


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


def launch(
    root: Path,
    app: Path,
    wait_s: float,
    allow_second_instance: bool = False,
    container: Path | None = None,
    use_open: bool | None = None,
    use_real_library: bool = False,
    allow_telemetry: bool = False,
    reader: DefaultsReader | None = None,
) -> tuple[int, dict[str, Any]]:
    check_launch_safety(container, use_real_library, allow_telemetry, reader)
    prepare_control_dir(root)
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
            "no ping reply. Is this a lab build (bash build.sh --lab)? Release builds have no channel. "
            "If Transcripted was already running, quit it first: the single-instance guard makes the "
            "new copy exit. Check app-stdio.log for 'LAB_CONTROL | enabled' or 'LAB_CONTROL | disabled: ...'."
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
    p_send.add_argument("--args", default=None, help='JSON object, e.g. \'{"path": "/abs/file.wav"}\'')
    p_send.add_argument(
        "--paste",
        action="store_true",
        help="stop_dictation only: paste into the frontmost app (and auto-send if that setting is on). Off by default.",
    )
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
    p_launch.add_argument(
        "--container",
        default=None,
        help=f"set {CONTAINER_ENV} to isolate captures/logs/state from the real library (required unless --use-real-library)",
    )
    p_launch.add_argument(
        "--use-real-library",
        action="store_true",
        help="allow launching without --container or with a relocated transcriptSaveLocation (writes the real library)",
    )
    p_launch.add_argument(
        "--allow-telemetry",
        action="store_true",
        help="launch even if anonymous analytics or crash reporting is on (lab events then reach PostHog/Sentry)",
    )
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
            command_args = send_args(args.command, args.args, args.paste)
            code, report = send(control_dir(args.dir), args.command, command_args, args.timeout, args.id, allow_paste=args.paste)
        elif args.action == "launch":
            container = Path(args.container).expanduser().resolve() if args.container else None
            use_open = False if args.use_exec else None
            root, app = control_dir(args.dir), Path(args.app).expanduser().resolve()
            if args.dry_run:
                # The container requirement still applies; the `defaults`
                # checks are skipped so a dry run works off the Mac.
                check_launch_safety(container, args.use_real_library, allow_telemetry=True, reader=lambda _d, _k: None)
                code, report = EXIT_OK, launch_plan(root, app, args.allow_second_instance, container, use_open)
                report["preflight"] = "defaults checks skipped (dry run)"
            else:
                code, report = launch(
                    root, app, args.wait, args.allow_second_instance, container, use_open,
                    use_real_library=args.use_real_library, allow_telemetry=args.allow_telemetry,
                )
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
