#!/usr/bin/env python3
"""Unit tests for lab_control.py. Run: python3 scripts/hillclimb/lab_control.py --self-test

The real responder is Swift (Sources/Support/LabControlChannel.swift), compiled
only into lab builds, and only runs on a Mac. These tests use a Python stand-in
that follows the same file protocol: read inbox/*.json in name order, move each
to done/, append one response line to responses.jsonl. The launch preflight's
`defaults read` calls are replaced by an injected reader, so nothing here needs
macOS or touches real preferences.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import lab_control  # noqa: E402

# Shared by the in-process thread and the fake app binary, so both behave the
# same way the Swift channel does.
RESPONDER_SOURCE = textwrap.dedent(
    """
    import json, os, time
    from pathlib import Path

    def handle_once(root, answers, split_writes=False):
        inbox, done = root / "inbox", root / "done"
        for directory in (root, inbox, done):
            directory.mkdir(mode=0o700, exist_ok=True)
        names = sorted(n for n in os.listdir(inbox) if n.endswith(".json") and not n.startswith("."))
        for name in names:
            received = time.monotonic() * 1000
            path = inbox / name
            try:
                request = json.loads(path.read_text(encoding="utf-8"))
            except ValueError:
                request = None
            os.replace(path, done / name)
            if not isinstance(request, dict):
                line = {"id": None, "command": None, "ok": False, "error": "malformed_json"}
            else:
                command = request.get("command")
                ok, error = answers.get(command, (False, "unknown_command"))
                line = {"id": request.get("id"), "command": command, "ok": ok}
                if error:
                    line["error"] = error
                if command == "ping":
                    line["result"] = {"pid": os.getpid()}
            line.update({"file": name, "at": "2026-09-23T10:00:00.000Z",
                         "received_monotonic_ms": int(received), "monotonic_ms": int(time.monotonic() * 1000)})
            data = (json.dumps(line, sort_keys=True) + "\\n").encode()
            with open(root / "responses.jsonl", "ab") as handle:
                if split_writes:
                    handle.write(data[:10]); handle.flush(); time.sleep(0.05)
                    handle.write(data[10:])
                else:
                    handle.write(data)
    """
)
_namespace: dict = {}
exec(RESPONDER_SOURCE, _namespace)  # noqa: S102 - test-only helper defined above
handle_once = _namespace["handle_once"]

DEFAULT_ANSWERS = {
    "ping": (True, None),
    "status": (True, None),
    "start_dictation": (True, None),
    "stop_dictation": (False, "dictation_not_active"),
}


class FakeResponder:
    def __init__(self, root: Path, answers=None, split_writes: bool = False, delay_s: float = 0.0):
        self.root = root
        self.answers = answers or DEFAULT_ANSWERS
        self.split_writes = split_writes
        self.delay_s = delay_s
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        if self.delay_s:
            time.sleep(self.delay_s)
        while not self._stop.is_set():
            handle_once(self.root, self.answers, self.split_writes)
            time.sleep(0.01)

    def __enter__(self) -> "FakeResponder":
        self._thread.start()
        return self

    def __exit__(self, *_exc) -> None:
        self._stop.set()
        self._thread.join(timeout=2)


def fake_defaults(values: dict[tuple[str, str], str] | None = None):
    """A `defaults read` stand-in: returns values[(domain, key)] or None, and logs calls."""
    table = dict(values or {})
    calls: list[tuple[str, str]] = []

    def reader(domain: str, key: str) -> str | None:
        calls.append((domain, key))
        return table.get((domain, key))

    reader.calls = calls  # type: ignore[attr-defined]
    return reader


TELEMETRY_OFF = {
    (lab_control.DEFAULTS_DOMAIN, lab_control.ANALYTICS_KEY): "0",
    (lab_control.DEFAULTS_DOMAIN, lab_control.CRASH_REPORTING_KEY): "0",
}


class TempDirCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="lab-control-test-"))
        self.root = self.tmp / "lab"

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


class SendTests(TempDirCase):
    def test_ping_round_trip(self) -> None:
        with FakeResponder(self.root):
            code, report = lab_control.send(self.root, "ping", {}, timeout_s=5)
        self.assertEqual(code, lab_control.EXIT_OK)
        self.assertTrue(report["response"]["ok"])
        self.assertEqual(report["response"]["id"], report["id"])
        self.assertIn("pid", report["response"]["result"])
        self.assertGreaterEqual(report["client"]["round_trip_ms"], 0)
        self.assertEqual(list((self.root / "inbox").iterdir()), [], "inbox is drained")
        self.assertEqual(len(list((self.root / "done").iterdir())), 1, "processed file lands in done/")

    def test_ok_false_maps_to_exit_1(self) -> None:
        with FakeResponder(self.root):
            code, report = lab_control.send(self.root, "stop_dictation", {"paste": False}, timeout_s=5)
        self.assertEqual(code, lab_control.EXIT_NOT_OK)
        self.assertEqual(report["response"]["error"], "dictation_not_active")

    def test_timeout_without_app(self) -> None:
        code, report = lab_control.send(self.root, "ping", {}, timeout_s=0.2)
        self.assertEqual(code, lab_control.EXIT_TIMEOUT)
        self.assertIsNone(report["response"])
        self.assertTrue(report["withdrawn"])
        self.assertEqual(list((self.root / "inbox").iterdir()), [], "an unanswered command never fires later")

    def test_waits_through_partial_lines_and_other_ids(self) -> None:
        with FakeResponder(self.root, split_writes=True):
            first = lab_control.send(self.root, "status", {}, timeout_s=5)
            second = lab_control.send(self.root, "ping", {}, timeout_s=5)
        self.assertEqual(first[0], lab_control.EXIT_OK)
        self.assertEqual(second[1]["response"]["command"], "ping")
        self.assertEqual(second[1]["response"]["id"], second[1]["id"])

    def test_old_responses_with_same_id_are_ignored(self) -> None:
        self.root.mkdir(mode=0o700)
        stale = {"id": "fixed-id", "command": "ping", "ok": False, "error": "stale"}
        (self.root / "responses.jsonl").write_text(json.dumps(stale) + "\n", encoding="utf-8")
        with FakeResponder(self.root):
            code, report = lab_control.send(self.root, "ping", {}, timeout_s=5, command_id="fixed-id")
        self.assertEqual(code, lab_control.EXIT_OK)
        self.assertNotIn("error", report["response"])

    def test_command_file_is_written_atomically(self) -> None:
        path = lab_control.write_command(self.root, "import_audio", {"path": "/tmp/a.wav"}, "abc")
        self.assertTrue(path.name.endswith("-abc.json"))
        self.assertEqual(json.loads(path.read_text()), {"id": "abc", "command": "import_audio", "args": {"path": "/tmp/a.wav"}})
        self.assertEqual([p.name for p in (self.root / "inbox").iterdir()], [path.name], "no .tmp left behind")

    def test_send_order_is_inbox_order(self) -> None:
        first = lab_control.write_command(self.root, "ping", {}, "one")
        second = lab_control.write_command(self.root, "ping", {}, "two")
        self.assertLess(first.name, second.name)

    def test_paste_needs_explicit_opt_in(self) -> None:
        with self.assertRaises(lab_control.LabControlError):
            lab_control.send(self.root, "stop_dictation", {"paste": True}, timeout_s=0.1)
        with self.assertRaises(lab_control.LabControlError):
            lab_control.send(self.root, "stop_dictation", {"paste": 1}, timeout_s=0.1)
        self.assertFalse((self.root / "inbox").exists(), "a refused paste writes nothing")
        self.assertEqual(lab_control.send_args("stop_dictation", None, paste=False), {})
        self.assertEqual(lab_control.send_args("stop_dictation", '{"paste": false}', paste=False), {"paste": False})
        self.assertEqual(lab_control.send_args("stop_dictation", None, paste=True), {"paste": True})
        with self.assertRaises(lab_control.LabControlError):
            lab_control.send_args("stop_dictation", '{"paste": true}', paste=False)
        with self.assertRaises(lab_control.LabControlError):
            lab_control.send_args("start_meeting", None, paste=True)
        with FakeResponder(self.root, answers={"stop_dictation": (True, None)}):
            code, report = lab_control.send(self.root, "stop_dictation", {"paste": True}, timeout_s=5, allow_paste=True)
        self.assertEqual(code, lab_control.EXIT_OK, report)

    def test_cli_refuses_paste_via_args(self) -> None:
        result = subprocess.run(
            [sys.executable, str(HERE / "lab_control.py"), "send", "stop_dictation", "--dir", str(self.root),
             "--args", '{"paste": true}', "--timeout", "0.1"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, lab_control.EXIT_USAGE)
        self.assertIn("--paste", result.stderr)

    def test_args_json_validation(self) -> None:
        self.assertEqual(lab_control.parse_args_json(None), {})
        self.assertEqual(lab_control.parse_args_json('{"paste": false}'), {"paste": False})
        with self.assertRaises(lab_control.LabControlError):
            lab_control.parse_args_json("[1]")
        with self.assertRaises(lab_control.LabControlError):
            lab_control.parse_args_json("{nope")

    def test_cli_send_prints_one_json_object(self) -> None:
        with FakeResponder(self.root):
            result = subprocess.run(
                [sys.executable, str(HERE / "lab_control.py"), "send", "status", "--dir", str(self.root), "--timeout", "5"],
                capture_output=True, text=True, check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["response"]["ok"])


class PrivateDirTests(TempDirCase):
    def test_creates_root_inbox_done_as_0700(self) -> None:
        lab_control.prepare_control_dir(self.root)
        for path in (self.root, self.root / "inbox", self.root / "done"):
            self.assertEqual(os.stat(path).st_mode & 0o7777, 0o700, path)

    def test_existing_dir_with_wrong_mode_is_refused_not_chmodded(self) -> None:
        self.root.mkdir(mode=0o700)
        os.chmod(self.root, 0o755)
        with self.assertRaises(lab_control.LabControlError):
            lab_control.prepare_control_dir(self.root)
        self.assertEqual(os.stat(self.root).st_mode & 0o7777, 0o755, "never chmods an existing dir")

    def test_symlinked_subdir_is_refused(self) -> None:
        self.root.mkdir(mode=0o700)
        target = self.tmp / "elsewhere"
        target.mkdir(mode=0o700)
        (self.root / "inbox").symlink_to(target)
        with self.assertRaises(lab_control.LabControlError):
            lab_control.prepare_control_dir(self.root)

    def test_missing_parent_is_an_error(self) -> None:
        with self.assertRaises(lab_control.LabControlError):
            lab_control.prepare_control_dir(self.tmp / "no" / "such" / "lab")


class LaunchSafetyTests(unittest.TestCase):
    def test_container_required_without_real_library_flag(self) -> None:
        problems = lab_control.launch_safety_problems(None, False, False, fake_defaults(TELEMETRY_OFF))
        self.assertEqual(len(problems), 1)
        self.assertIn("--container", problems[0])
        self.assertEqual(lab_control.launch_safety_problems(Path("/c"), False, False, fake_defaults(TELEMETRY_OFF)), [])

    def test_relocated_library_beats_container(self) -> None:
        values = dict(TELEMETRY_OFF)
        values[(lab_control.DEFAULTS_DOMAIN, lab_control.SAVE_LOCATION_KEY)] = "/Users/me/Notes/Transcripted"
        problems = lab_control.launch_safety_problems(Path("/c"), False, False, fake_defaults(values))
        self.assertEqual(len(problems), 1)
        self.assertIn("transcriptSaveLocation", problems[0])
        self.assertNotIn("/Users/me", problems[0], "the relocated path is not echoed")
        self.assertEqual(lab_control.launch_safety_problems(Path("/c"), True, False, fake_defaults(values)), [])

    def test_blank_save_location_is_not_relocated(self) -> None:
        values = dict(TELEMETRY_OFF)
        values[(lab_control.DEFAULTS_DOMAIN, lab_control.SAVE_LOCATION_KEY)] = ""
        self.assertEqual(lab_control.launch_safety_problems(Path("/c"), False, False, fake_defaults(values)), [])

    def test_telemetry_must_be_explicitly_off(self) -> None:
        # Missing keys mean ON in the app (AnalyticsPreferences / CrashReportingPreferences).
        problems = lab_control.launch_safety_problems(Path("/c"), False, False, fake_defaults({}))
        self.assertEqual(len(problems), 2)
        self.assertTrue(any("analytics" in p for p in problems))
        self.assertTrue(any("crash reporting" in p for p in problems))
        half = {(lab_control.DEFAULTS_DOMAIN, lab_control.ANALYTICS_KEY): "0",
                (lab_control.DEFAULTS_DOMAIN, lab_control.CRASH_REPORTING_KEY): "1"}
        self.assertEqual(len(lab_control.launch_safety_problems(Path("/c"), False, False, fake_defaults(half))), 1)
        self.assertEqual(lab_control.launch_safety_problems(Path("/c"), False, True, fake_defaults({})), [])

    def test_both_overrides_skip_defaults_entirely(self) -> None:
        reader = fake_defaults({})
        self.assertEqual(lab_control.launch_safety_problems(None, True, True, reader), [])
        self.assertEqual(reader.calls, [])  # type: ignore[attr-defined]

    def test_reads_the_app_domain_only(self) -> None:
        reader = fake_defaults(TELEMETRY_OFF)
        lab_control.launch_safety_problems(Path("/c"), False, False, reader)
        self.assertEqual({domain for domain, _ in reader.calls}, {"com.justinbetker.draft"})  # type: ignore[attr-defined]
        self.assertEqual(
            {key for _, key in reader.calls},  # type: ignore[attr-defined]
            {"transcriptSaveLocation", "observability-anonymous-analytics-enabled", "observability-crash-reporting-enabled"},
        )

    def test_preference_is_off(self) -> None:
        self.assertTrue(lab_control.preference_is_off("0"))
        self.assertTrue(lab_control.preference_is_off("false"))
        self.assertFalse(lab_control.preference_is_off("1"))
        self.assertFalse(lab_control.preference_is_off(None))


class ReadLinesTests(TempDirCase):
    def test_partial_line_is_not_consumed(self) -> None:
        path = self.tmp / "x.jsonl"
        path.write_bytes(b'{"a":1}\n{"b":')
        lines, offset = lab_control.read_complete_lines(path, 0)
        self.assertEqual(lines, ['{"a":1}'])
        self.assertEqual(offset, 8)
        with path.open("ab") as handle:
            handle.write(b"2}\n")
        lines, offset = lab_control.read_complete_lines(path, offset)
        self.assertEqual(lines, ['{"b":2}'])

    def test_missing_file_and_truncation(self) -> None:
        path = self.tmp / "x.jsonl"
        self.assertEqual(lab_control.read_complete_lines(path, 50), ([], 0))
        path.write_bytes(b'{"a":1}\n')
        lines, offset = lab_control.read_complete_lines(path, 999)
        self.assertEqual(lines, ['{"a":1}'], "a shrunk file is re-read from 0")


class TailEventsTests(TempDirCase):
    def write_events(self, path: Path, records: list[dict]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            for record in records:
                handle.write(json.dumps(record) + "\n")

    def test_filters_events_and_keeps_only_safe_context(self) -> None:
        path = self.tmp / "logs" / "events.jsonl"
        self.write_events(path, [
            {"timestamp": "2026-09-23T10:00:00.100Z", "level": "info", "engine": "dictation", "event": "dictation_started",
             "context": {"request_to_recording_ms": "412", "audio_device": "Jane's AirPods", "trigger": "menu"}},
            {"timestamp": "2026-09-23T10:00:01.000Z", "level": "info", "engine": "meeting", "event": "meeting_state_changed",
             "context": {"from": "ready", "to": "recording"}},
        ])
        report = lab_control.tail_events(path, 0, ["dictation_started"])
        self.assertEqual(len(report["events"]), 1)
        event = report["events"][0]
        self.assertEqual(event["context"], {"request_to_recording_ms": 412, "trigger": "menu"})
        self.assertNotIn("Jane", json.dumps(report), "device names never reach lab output")
        again = lab_control.tail_events(path, report["next_offset"])
        self.assertEqual(again["events"], [], "offset skips what was already read")

    def test_raw_and_missing_file(self) -> None:
        missing = lab_control.tail_events(self.tmp / "nope.jsonl", 0)
        self.assertFalse(missing["path_exists"])
        path = self.tmp / "events.jsonl"
        self.write_events(path, [{"event": "x", "context": {"audio_device": "Mic"}}])
        raw = lab_control.tail_events(path, 0, raw=True)
        self.assertEqual(raw["events"][0]["context"]["audio_device"], "Mic")

    def test_rotation_is_reported(self) -> None:
        path = self.tmp / "events.jsonl"
        self.write_events(path, [{"event": "x"}])
        report = lab_control.tail_events(path, 10_000)
        self.assertTrue(report["rotated"])
        self.assertEqual(len(report["events"]), 1)

    def test_default_path_follows_container(self) -> None:
        self.assertEqual(lab_control.default_events_path(Path("/c")), Path("/c/logs/events.jsonl"))
        self.assertTrue(str(lab_control.default_events_path(None)).endswith("Transcripted/logs/events.jsonl"))

    def test_number_detection(self) -> None:
        self.assertTrue(lab_control.is_number_text("12"))
        self.assertTrue(lab_control.is_number_text("1.5"))
        self.assertFalse(lab_control.is_number_text("true"))
        self.assertFalse(lab_control.is_number_text(True))
        self.assertFalse(lab_control.is_number_text(""))


class LaunchTests(TempDirCase):
    def make_fake_app(self) -> Path:
        """A fake Transcripted binary: answers the protocol only if the env var is set."""
        script = self.tmp / "FakeTranscripted"
        script.write_text(
            "#!" + sys.executable + "\n"
            + RESPONDER_SOURCE
            + textwrap.dedent(
                """
                import sys
                raw = os.environ.get("TRANSCRIPTED_LAB_CONTROL_DIR")
                if not raw or not raw.startswith("/"):
                    sys.exit(0)
                root = Path(raw)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    handle_once(root, {"ping": (True, None)})
                    time.sleep(0.02)
                """
            ),
            encoding="utf-8",
        )
        script.chmod(0o755)
        return script

    def test_plan_for_bundle_uses_open_with_env(self) -> None:
        plan = lab_control.launch_plan(Path("/lab"), Path("/Apps/Transcripted.app"), use_open=True)
        self.assertEqual(plan["argv"][:4], ["open", "-n", "-a", "/Apps/Transcripted.app"])
        self.assertIn("TRANSCRIPTED_LAB_CONTROL_DIR=/lab", plan["argv"])
        self.assertNotIn(lab_control.GUARD_ENV, plan["env"], "guard stays on unless asked")

    def test_plan_flags(self) -> None:
        plan = lab_control.launch_plan(Path("/lab"), Path("/bin/app"), allow_second_instance=True, container=Path("/c"))
        self.assertEqual(plan["argv"], ["/bin/app"])
        self.assertEqual(plan["env"], {
            "TRANSCRIPTED_LAB_CONTROL_DIR": "/lab",
            "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD": "1",
            "TRANSCRIPTED_CONTAINER_DIR": "/c",
        })

    def test_bundle_executable_comes_from_info_plist(self) -> None:
        bundle = self.tmp / "Transcripted.app"
        (bundle / "Contents" / "MacOS").mkdir(parents=True)
        with (bundle / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleExecutable": "RealName"}, handle)
        self.assertEqual(lab_control.resolve_executable(bundle), bundle / "Contents" / "MacOS" / "RealName")
        plan = lab_control.launch_plan(self.root, bundle, use_open=False)
        self.assertEqual(plan["argv"], [str(bundle / "Contents" / "MacOS" / "RealName")])

    def test_launch_refuses_before_starting_anything(self) -> None:
        app = self.make_fake_app()
        with self.assertRaises(lab_control.LabControlError):
            lab_control.launch(self.root, app, wait_s=1, use_open=False, reader=fake_defaults(TELEMETRY_OFF))
        with self.assertRaises(lab_control.LabControlError):
            lab_control.launch(self.root, app, wait_s=1, container=self.tmp / "c", use_open=False, reader=fake_defaults({}))
        self.assertFalse(self.root.exists(), "a refused launch creates nothing")

    def test_launch_fake_binary_and_ping(self) -> None:
        app = self.make_fake_app()
        container = self.tmp / "container"
        stale = lab_control.write_command(self.root, "start_meeting", {}, "stale")
        code, report = lab_control.launch(
            self.root, app, wait_s=8, container=container, use_open=False, reader=fake_defaults(TELEMETRY_OFF)
        )
        try:
            self.assertEqual(code, lab_control.EXIT_OK, report)
            self.assertTrue(report["ping"]["response"]["ok"])
            self.assertEqual(report["plan"]["env"]["TRANSCRIPTED_LAB_CONTROL_DIR"], str(self.root))
            self.assertEqual(report["plan"]["env"]["TRANSCRIPTED_CONTAINER_DIR"], str(container))
            self.assertEqual(report["stale_commands_removed"], 1)
            self.assertFalse((self.root / "done" / stale.name).exists(), "the stale command never ran")
        finally:
            try:
                os.killpg(report["launcher_pid"], signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass

    def test_cli_dry_run(self) -> None:
        base = [sys.executable, str(HERE / "lab_control.py"), "launch", "--dir", str(self.root), "--app", "/bin/true", "--dry-run"]
        result = subprocess.run(base + ["--container", str(self.tmp / "c")], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = json.loads(result.stdout)
        self.assertEqual(plan["env"]["TRANSCRIPTED_LAB_CONTROL_DIR"], str(self.root.resolve()))
        self.assertEqual(plan["env"]["TRANSCRIPTED_CONTAINER_DIR"], str((self.tmp / "c").resolve()))

        refused = subprocess.run(base, capture_output=True, text=True, check=False)
        self.assertEqual(refused.returncode, lab_control.EXIT_USAGE, "no --container and no --use-real-library")
        self.assertIn("--container", refused.stderr)

        real = subprocess.run(base + ["--use-real-library"], capture_output=True, text=True, check=False)
        self.assertEqual(real.returncode, 0, real.stderr)
        self.assertNotIn("TRANSCRIPTED_CONTAINER_DIR", json.loads(real.stdout)["env"])


if __name__ == "__main__":
    unittest.main()
