import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("failure_locations", ROOT / "scripts/ci/test-failure-locations.py")
REPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORTER)


class FailureLocationsTests(unittest.TestCase):
    def test_failure_formats_publish_only_allowlisted_locations(self):
        root = Path("/owned/candidate")
        files = {"Tests/Check.swift": 40, "Tests/Other.swift": 10}
        raw = "\n".join([
            "  FAIL [Check.swift:12] PRIVATE_CANARY expected secret, got secret",
            "/owned/candidate/Tests/Other.swift:8: error: PRIVATE_CANARY",
            "✘ Test example() recorded an issue at Check.swift:17: PRIVATE_CANARY",
            "  FAIL [Check.swift:12] duplicate PRIVATE_CANARY",
        ])
        result = REPORTER.locations(raw, root, files)
        self.assertEqual(result, {"failure_locations": [
            {"source": "Tests/Check.swift", "line": 12},
            {"source": "Tests/Check.swift", "line": 17},
            {"source": "Tests/Other.swift", "line": 8},
        ], "locations_truncated": False})
        self.assertNotIn("PRIVATE_CANARY", json.dumps(result))
        self.assertNotIn(str(root), json.dumps(result))

    def test_unknown_external_ambiguous_and_invalid_locations_are_omitted(self):
        files = {"Tests/Check.swift": 20, "Tools/Tests/Check.swift": 20}
        raw = "\n".join([
            "  FAIL [Check.swift:12] ambiguous",
            "/private/Tests/Check.swift:12: error: outside root",
            "/owned/candidate/Tests/Unknown.swift:12: error: untracked",
            "/owned/candidate/Tests/Check.swift:0: error: invalid line",
            "/owned/candidate/Tests/Check.swift:21: error: past source",
            "message containing FAIL [Check.swift:12] is not a failure prefix",
        ])
        self.assertEqual(REPORTER.locations(raw, Path("/owned/candidate"), files)["failure_locations"], [])

    def test_output_is_bounded(self):
        raw = "\n".join(f"  FAIL [Check.swift:{n}] private" for n in range(1, 101))
        result = REPORTER.locations(raw, Path("/owned"), {"Tests/Check.swift": 100})
        self.assertEqual(len(result["failure_locations"]), 64)
        self.assertTrue(result["locations_truncated"])

    def test_cli_uses_only_tracked_owned_source_files(self):
        with tempfile.TemporaryDirectory(prefix="transcripted-failure-locations-") as temporary:
            root = Path(temporary).resolve()
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            (root / "Tests").mkdir()
            (root / "Tests/Check.swift").write_text("fixture\n" * 3)
            (root / "Tests/Untracked.swift").write_text("fixture\n")
            (root / "Tests/Link.swift").symlink_to("Check.swift")
            subprocess.run(["git", "-C", str(root), "add", "Tests/Check.swift", "Tests/Link.swift"], check=True)
            log = root / "input.log"
            log.write_text(f"{root}/Tests/Check.swift:2: error: PRIVATE_CANARY\n"
                           f"{root}/Tests/Untracked.swift:1: error: PRIVATE_CANARY\n"
                           f"{root}/Tests/Link.swift:1: error: PRIVATE_CANARY\n")
            result = subprocess.run(["python3", str(SPEC.origin), "--root", str(root), "--log", str(log)],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout)["failure_locations"], [{"source": "Tests/Check.swift", "line": 2}])
            self.assertNotIn("PRIVATE_CANARY", result.stdout + result.stderr)
            self.assertNotIn(str(root), result.stdout + result.stderr)

    def test_unavailable_input_reports_no_path_or_exception(self):
        with tempfile.TemporaryDirectory(prefix="transcripted-failure-unavailable-") as temporary:
            result = subprocess.run(["python3", str(SPEC.origin), "--root", temporary,
                                     "--log", str(Path(temporary) / "PRIVATE_CANARY.log")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["diagnostic_status"], "unavailable")
            self.assertNotIn(temporary, result.stdout + result.stderr)
            self.assertNotIn("PRIVATE_CANARY", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
