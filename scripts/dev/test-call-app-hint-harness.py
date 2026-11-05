#!/usr/bin/env python3
"""Exercise the actual wrapper with owned commands; never compile or launch AppKit."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class HintHarnessWrapperTests(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory(prefix="hint-wrapper-test-")
        self.root = Path(self.owned.name).resolve()
        for relative in ["scripts/dev", "scripts/entrypoints/lib", "Sources/App", "bin",
                         "build/Transcripted.app", ".agent-review/visuals"]:
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        for relative in ["scripts/dev/run-call-app-hint-harness.sh", "scripts/entrypoints/lib/fast-test-completion.py"]:
            shutil.copy2(ROOT / relative, self.root / relative)
        (self.root / "Sources/App/TranscriptedApp.swift").write_text("@main\nstruct FictionalApp {}\n")
        (self.root / "scripts/entrypoints/lib/swiftc-app-args.sh").write_text(
            'build_app_swiftc_args() { if [ "$OWNED_HINT_MODE" = "setup-zero-exit" ]; then exit 0; fi; '
            'APP_SOURCE_FILES=(Sources/App/TranscriptedApp.swift); '
            'APP_SWIFTC_LINK_ARGS=(); APP_SWIFTC_TAIL_ARGS=(); }\n')
        self.binary = self.root / "fake-child.py"
        self.binary.write_text('''#!/usr/bin/env python3
import json, os
from pathlib import Path
mode = os.environ.get("OWNED_HINT_MODE", "complete")
root = Path(os.environ["CALL_APP_HINT_RUN_ROOT"])
assert (root / "owned-run").read_text() == os.environ["CALL_APP_HINT_RUN_ID"]
assert os.environ["TRANSCRIPTED_CONTAINER_DIR"] == str(root / "fixture/container")
assert os.environ["TRANSCRIPTED_AUTOMATED_HARNESS"] == "1"
assert os.environ["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1"
if mode == "zero-exit": raise SystemExit(0)
if mode == "failure": raise SystemExit(7)
count = 2 if mode == "partial" else 4
receipt = dict(version=1, run_id=os.environ["TRANSCRIPTED_FAST_TEST_COMPLETION_RUN_ID"],
    selection_digest=os.environ["CALL_APP_HINT_SELECTION_DIGEST"], selected_functions=4,
    executed_functions=count, assertions=10, passed_assertions=10, failed_assertions=0, quarantined_suites=0)
Path(os.environ["TRANSCRIPTED_FAST_TEST_COMPLETION_PATH"]).write_text(json.dumps(receipt))
(root / "output/completion.json").write_text(json.dumps(receipt))
''')
        self.binary.chmod(0o700)
        compiler = self.root / "bin/swiftc"
        compiler.write_text('''#!/usr/bin/env python3
import os, shutil, sys
if os.environ.get("OWNED_HINT_MODE") == "compile-failure": raise SystemExit(6)
shutil.copy2(os.environ["OWNED_HINT_CHILD"], sys.argv[sys.argv.index("-o") + 1])
''')
        compiler.chmod(0o700)
        self.sentinels = [self.root / "build/Transcripted.app/owner-sentinel",
                          self.root / ".agent-review/visuals/call-app-hint-before.png"]
        for path in self.sentinels:
            path.write_text("untouched")

    def tearDown(self):
        self.owned.cleanup()

    def run_wrapper(self, mode="complete"):
        environment = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                           OWNED_HINT_MODE=mode, OWNED_HINT_CHILD=str(self.binary),
                           TRANSCRIPTED_CONTAINER_DIR=str(self.root / "foreign-container"))
        result = subprocess.run(["bash", "scripts/dev/run-call-app-hint-harness.sh"], cwd=self.root,
                                env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        for path in self.sentinels:
            self.assertEqual(path.read_text(), "untouched")
        for run in (self.root / "build/call-app-hint-harness").glob("run.*"):
            self.assertFalse((run / "fixture").exists(), "owned fixture cleaned on every exit")
            self.assertTrue((run / "owned-run").is_file())
        return result

    def test_complete_child_requires_four_groups_and_retains_owned_output(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("4/4 functions, 10 assertions, 0 failed", result.stdout)
        self.assertEqual(len(list((self.root / "build/call-app-hint-harness").glob("run.*/output/completion.json"))), 1)

    def test_zero_exit_without_completion_is_failure(self):
        result = self.run_wrapper("zero-exit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("completion receipt missing or invalid", result.stdout)

    def test_partial_completion_is_failure(self):
        self.assertNotEqual(self.run_wrapper("partial").returncode, 0)

    def test_child_failure_is_preserved(self):
        self.assertEqual(self.run_wrapper("failure").returncode, 7)

    def test_compile_failure_cleans_only_owned_fixture(self):
        self.assertEqual(self.run_wrapper("compile-failure").returncode, 6)

    def test_setup_zero_exit_before_validator_is_failure(self):
        self.assertNotEqual(self.run_wrapper("setup-zero-exit").returncode, 0)

    def test_redirected_build_root_is_refused(self):
        foreign = self.root / "foreign-build"
        foreign.mkdir()
        shutil.rmtree(self.root / "build/call-app-hint-harness", ignore_errors=True)
        (self.root / "build/call-app-hint-harness").symlink_to(foreign, target_is_directory=True)
        self.assertNotEqual(self.run_wrapper().returncode, 0)
        self.assertEqual(list(foreign.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
