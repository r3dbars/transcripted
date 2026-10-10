#!/usr/bin/env python3
"""Drive a debug Transcripted build through the test control surface.

The app side is Sources/App/DebugControlChannel.swift, compiled only into
`build.sh` (not `build-beta.sh`). Protocol: docs/debug-control-surface.md.

    python3 scripts/dev/transcripted-debug.py --self-test
    python3 scripts/dev/transcripted-debug.py launch --app build/Transcripted.app --dir DIR --container DIR
    python3 scripts/dev/transcripted-debug.py state --dir DIR
    python3 scripts/dev/transcripted-debug.py dictation start --dir DIR
    python3 scripts/dev/transcripted-debug.py dictation stop --dir DIR
    python3 scripts/dev/transcripted-debug.py meeting start --dir DIR
    python3 scripts/dev/transcripted-debug.py meeting stop --dir DIR

Stdlib only. Writes only under the control dir the caller names.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
CONTROL_ENV = "TRANSCRIPTED_DEBUG_CONTROL_DIR"
HARNESS_ENV = "TRANSCRIPTED_AUTOMATED_HARNESS"
CONTAINER_ENV = "TRANSCRIPTED_CONTAINER_DIR"
GUARD_ENV = "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"
DEFAULTS_DOMAIN = "com.justinbetker.draft"
SAVE_LOCATION_KEY = "transcriptSaveLocation"
PRIVATE_DIR_MODE = 0o700
TELEMETRY_OFF_ARGS = [
    "-observability-anonymous-analytics-enabled",
    "NO",
    "-observability-crash-reporting-enabled",
    "NO",
]
SCHEMA_VERSION = 1
EXIT_OK = 0
EXIT_NOT_OK = 2
EXIT_TIMEOUT = 3
EXIT_USAGE = 64

COMMANDS = {
    ("state",): ("state", {}),
    ("status",): ("state", {}),
    ("ping",): ("ping", {}),
    ("dictation", "start"): ("start_dictation", {}),
    ("dictation", "stop"): ("stop_dictation", {}),
    ("meeting", "start"): ("start_meeting", {}),
    ("meeting", "stop"): ("stop_meeting", {}),
    ("paste-target", "open"): ("paste_target_open", {}),
}


class DebugControlError(RuntimeError):
    pass


def control_dir(raw: str | os.PathLike[str]) -> Path:
    return Path(raw).expanduser().resolve()


def ensure_private_dir(path: Path) -> None:
    try:
        path.mkdir(mode=PRIVATE_DIR_MODE)
    except FileExistsError:
        pass
    except FileNotFoundError as error:
        raise DebugControlError(f"parent of {path} does not exist") from error
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode):
        raise DebugControlError(f"{path} is a symlink; the app refuses symlinked control dirs")
    if not stat.S_ISDIR(info.st_mode):
        raise DebugControlError(f"{path} is not a directory")
    if info.st_uid != os.getuid():
        raise DebugControlError(f"{path} is not owned by you")
    if stat.S_IMODE(info.st_mode) != PRIVATE_DIR_MODE:
        raise DebugControlError(f"{path} must be mode 0700 (it is {stat.S_IMODE(info.st_mode):o})")


def prepare_control_dir(root: Path) -> None:
    ensure_private_dir(root)
    ensure_private_dir(root / "inbox")
    ensure_private_dir(root / "done")


def new_command_id() -> str:
    return uuid.uuid4().hex[:16]


def argv_to_command(argv: list[str], paste: bool = False) -> tuple[str, dict[str, Any]]:
    if not argv:
        raise DebugControlError("missing command")
    if argv[0] == "import":
        if len(argv) != 2:
            raise DebugControlError("import needs one absolute path")
        return "import_audio", {"path": argv[1]}
    if argv[0] == "open":
        if len(argv) != 2:
            raise DebugControlError("open needs a screen id")
        return "open_screen", {"screen": argv[1]}
    if argv[:1] == ["settings"] and len(argv) >= 3 and argv[1] == "get":
        if len(argv) != 3:
            raise DebugControlError("settings get needs one key")
        return "settings_get", {"key": argv[2]}
    if argv[:1] == ["settings"] and len(argv) >= 3 and argv[1] == "set":
        if len(argv) != 4:
            raise DebugControlError("settings set needs a key and a value")
        return "settings_set", {"key": argv[2], "value": argv[3]}
    key = tuple(argv)
    if key == ("dictation", "stop") and paste:
        return "stop_dictation", {"paste": True}
    if key in COMMANDS:
        return COMMANDS[key]
    raise DebugControlError(f"unknown command: {' '.join(argv)}")


def write_command(root: Path, command: str, args: Mapping[str, Any], command_id: str) -> Path:
    prepare_control_dir(root)
    payload = {"id": command_id, "command": command, "args": dict(args)}
    name = f"{time.time_ns():020d}-{command_id}.json"
    final = root / "inbox" / name
    staging = root / "inbox" / (name + ".tmp")
    staging.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    os.replace(staging, final)
    return final


def read_complete_lines(path: Path, offset: int) -> tuple[list[str], int]:
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


def wait_for_response(root: Path, command_id: str, timeout_s: float, start_offset: int = 0) -> dict[str, Any] | None:
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
        time.sleep(0.02)


def responses_size(root: Path) -> int:
    try:
        return (root / "responses.jsonl").stat().st_size
    except FileNotFoundError:
        return 0


def send(root: Path, command: str, args: Mapping[str, Any], timeout_s: float, command_id: str | None = None) -> tuple[int, dict[str, Any]]:
    command_id = command_id or new_command_id()
    start_offset = responses_size(root)
    path = write_command(root, command, args, command_id)
    response = wait_for_response(root, command_id, timeout_s, start_offset=start_offset)
    report: dict[str, Any] = {"id": command_id, "command": command, "response": response}
    if response is None:
        report["error"] = f"timeout after {timeout_s:g}s (is the debug app running with {CONTROL_ENV}={root}?)"
        try:
            path.unlink()
            report["withdrawn"] = True
        except FileNotFoundError:
            report["withdrawn"] = False
        return EXIT_TIMEOUT, report
    return (EXIT_OK if response.get("ok") is True else EXIT_NOT_OK), report


def resolve_executable(app: Path) -> Path:
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


def launch_plan(
    root: Path,
    app: Path,
    container: Path | None = None,
    allow_second_instance: bool = False,
    use_open: bool | None = None,
    telemetry_off: bool = True,
) -> dict[str, Any]:
    app_args = list(TELEMETRY_OFF_ARGS) if telemetry_off else []
    extra_env = {CONTROL_ENV: str(root), HARNESS_ENV: "1"}
    if allow_second_instance:
        extra_env[GUARD_ENV] = "1"
    if container is not None:
        extra_env[CONTAINER_ENV] = str(container)
    extra_env["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    if use_open is None:
        use_open = app.suffix == ".app" and sys.platform == "darwin"
    if use_open:
        argv = ["open", "-n", "-a", str(app)]
        for key, value in extra_env.items():
            argv += ["--env", f"{key}={value}"]
        if app_args:
            argv += ["--args", *app_args]
    else:
        argv = [str(resolve_executable(app)), *app_args]
    return {"argv": argv, "env": extra_env, "uses_open": use_open}


DefaultsReader = Callable[[str, str], str | None]


def read_default(domain: str, key: str) -> str | None:
    try:
        result = subprocess.run(
            ["defaults", "read", domain, key],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except FileNotFoundError as error:
        raise DebugControlError("`defaults` not found; launch preflight is macOS only") from error
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def launch_safety_problems(
    container: Path | None,
    use_real_library: bool,
    reader: DefaultsReader | None = None,
) -> list[str]:
    problems: list[str] = []
    if container is None and not use_real_library:
        problems.append("--container DIR is required (or pass --use-real-library)")
    if use_real_library:
        return problems
    location = (reader or read_default)(DEFAULTS_DOMAIN, SAVE_LOCATION_KEY)
    if location:
        problems.append(
            f"{SAVE_LOCATION_KEY} is set, so captures would land in that relocated library; "
            "clear it or pass --use-real-library"
        )
    return problems


def clear_stale_inbox(root: Path) -> int:
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
    container: Path | None = None,
    use_real_library: bool = False,
    allow_second_instance: bool = False,
    use_open: bool | None = None,
    reader: DefaultsReader | None = None,
) -> tuple[int, dict[str, Any]]:
    problems = launch_safety_problems(container, use_real_library, reader)
    if problems:
        raise DebugControlError("refusing to launch: " + "; ".join(problems))
    prepare_control_dir(root)
    stale = clear_stale_inbox(root)
    plan = launch_plan(root, app, container, allow_second_instance, use_open)
    env = dict(os.environ)
    env.update(plan["env"])
    log_path = root / "app-stdio.log"
    with log_path.open("ab") as log:
        process = subprocess.Popen(
            plan["argv"],
            env=env,
            stdout=log,
            stderr=log,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    code, ping = send(root, "ping", {}, wait_s)
    return code, {
        "plan": plan,
        "launcher_pid": process.pid,
        "ping": ping,
        "stdio_log": str(log_path),
        "stale_commands_removed": stale,
        "schema_version": SCHEMA_VERSION,
    }


def print_report(report: Mapping[str, Any]) -> None:
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


class DebugControlSelfTests(unittest.TestCase):
    def test_argv_maps_every_command(self) -> None:
        self.assertEqual(argv_to_command(["state"]), ("state", {}))
        self.assertEqual(argv_to_command(["dictation", "start"]), ("start_dictation", {}))
        self.assertEqual(argv_to_command(["dictation", "stop"]), ("stop_dictation", {}))
        self.assertEqual(argv_to_command(["dictation", "stop"], paste=True), ("stop_dictation", {"paste": True}))
        self.assertEqual(argv_to_command(["meeting", "start"]), ("start_meeting", {}))
        self.assertEqual(argv_to_command(["meeting", "stop"]), ("stop_meeting", {}))
        self.assertEqual(argv_to_command(["import", "/tmp/x.wav"]), ("import_audio", {"path": "/tmp/x.wav"}))
        self.assertEqual(argv_to_command(["paste-target", "open"]), ("paste_target_open", {}))
        self.assertEqual(argv_to_command(["open", "today"]), ("open_screen", {"screen": "today"}))
        self.assertEqual(argv_to_command(["settings", "get", "show_in_dock"]), ("settings_get", {"key": "show_in_dock"}))
        self.assertEqual(
            argv_to_command(["settings", "set", "show_in_dock", "false"]),
            ("settings_set", {"key": "show_in_dock", "value": "false"}),
        )
        with self.assertRaises(DebugControlError):
            argv_to_command(["launch-rockets"])

    def test_launch_plan_sets_harness_and_control_dir(self) -> None:
        root = Path("/tmp/debug-ctrl")
        plan = launch_plan(root, Path("/tmp/Transcripted.app"), container=Path("/tmp/container"), use_open=True)
        self.assertEqual(plan["env"][CONTROL_ENV], str(root))
        self.assertEqual(plan["env"][HARNESS_ENV], "1")
        self.assertEqual(plan["env"][CONTAINER_ENV], "/tmp/container")
        self.assertIn("--env", plan["argv"])
        self.assertTrue(any(item.startswith(f"{CONTROL_ENV}=") for item in plan["argv"]))

    def test_launch_safety_requires_container(self) -> None:
        problems = launch_safety_problems(None, False, reader=lambda *_: None)
        self.assertTrue(problems)
        self.assertEqual(launch_safety_problems(Path("/tmp/c"), False, reader=lambda *_: None), [])
        relocated = launch_safety_problems(Path("/tmp/c"), False, reader=lambda *_: "/Users/me/Captures")
        self.assertTrue(any(SAVE_LOCATION_KEY in item for item in relocated))

    def test_send_roundtrip_against_a_fake_responder(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            os.chmod(root, PRIVATE_DIR_MODE)
            prepare_control_dir(root)

            def responder() -> None:
                inbox = root / "inbox"
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    files = [path for path in inbox.iterdir() if path.name.endswith(".json")]
                    if files:
                        payload = json.loads(files[0].read_text(encoding="utf-8"))
                        line = json.dumps(
                            {
                                "schema_version": SCHEMA_VERSION,
                                "id": payload["id"],
                                "command": payload["command"],
                                "ok": True,
                                "result": {"pid": 1, "dictation_active": False, "schema_version": SCHEMA_VERSION},
                            }
                        )
                        with (root / "responses.jsonl").open("a", encoding="utf-8") as handle:
                            handle.write(line + "\n")
                        files[0].rename(root / "done" / files[0].name)
                        return
                    time.sleep(0.01)

            import threading

            thread = threading.Thread(target=responder)
            thread.start()
            code, report = send(root, "state", {}, timeout_s=2)
            thread.join()
            self.assertEqual(code, EXIT_OK)
            self.assertEqual(report["response"]["schema_version"], SCHEMA_VERSION)
            self.assertTrue(report["response"]["ok"])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", help=f"control directory ({CONTROL_ENV})")
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--paste", action="store_true", help="stop_dictation only: paste into the frontmost app")
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="verb")
    launch_cmd = sub.add_parser("launch")
    launch_cmd.add_argument("--app", required=True)
    launch_cmd.add_argument("--container")
    launch_cmd.add_argument("--use-real-library", action="store_true")
    launch_cmd.add_argument("--allow-second-instance", action="store_true")
    launch_cmd.add_argument("--exec", action="store_true", help="run the binary directly instead of open -n")
    launch_cmd.add_argument("--wait", type=float, default=30.0)
    sub.add_parser("state")
    sub.add_parser("status")
    sub.add_parser("ping")
    dictation = sub.add_parser("dictation")
    dictation.add_argument("action", choices=["start", "stop"])
    meeting = sub.add_parser("meeting")
    meeting.add_argument("action", choices=["start", "stop"])
    import_cmd = sub.add_parser("import")
    import_cmd.add_argument("path")
    paste_target = sub.add_parser("paste-target")
    paste_target.add_argument("action", choices=["open"])
    open_cmd = sub.add_parser("open")
    open_cmd.add_argument("screen")
    settings = sub.add_parser("settings")
    settings.add_argument("action", choices=["get", "set"])
    settings.add_argument("key")
    settings.add_argument("value", nargs="?")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(DebugControlSelfTests)
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        return EXIT_OK if result.wasSuccessful() else 1
    if args.verb == "launch":
        root = control_dir(args.dir or tempfile.mkdtemp(prefix="transcripted-debug-"))
        container = Path(args.container).expanduser().resolve() if args.container else None
        try:
            code, report = launch(
                root,
                Path(args.app).expanduser().resolve(),
                wait_s=args.wait,
                container=container,
                use_real_library=args.use_real_library,
                allow_second_instance=args.allow_second_instance,
                use_open=False if args.exec else None,
            )
        except DebugControlError as error:
            print(error, file=sys.stderr)
            return EXIT_USAGE
        print_report(report)
        return code
    if not args.verb:
        parser.print_help()
        return EXIT_USAGE
    if not args.dir:
        print("--dir is required unless launching with a generated dir", file=sys.stderr)
        return EXIT_USAGE
    argv_parts = [args.verb]
    if args.verb in {"dictation", "meeting", "paste-target"}:
        argv_parts.append(args.action)
    elif args.verb == "import":
        argv_parts.append(args.path)
    elif args.verb == "open":
        argv_parts.append(args.screen)
    elif args.verb == "settings":
        argv_parts.append(args.action)
        argv_parts.append(args.key)
        if args.value is not None:
            argv_parts.append(args.value)
    try:
        command, command_args = argv_to_command(argv_parts, paste=args.paste)
        code, report = send(control_dir(args.dir), command, command_args, timeout_s=args.timeout)
    except DebugControlError as error:
        print(error, file=sys.stderr)
        return EXIT_USAGE
    print_report(report)
    return code


if __name__ == "__main__":
    sys.exit(main())
