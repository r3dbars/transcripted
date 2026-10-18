#!/usr/bin/env python3
"""Exercise launch-script isolation with inert tools, never a native app."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LaunchBenchmarkIsolationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.trace = self.root / "events"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.environment = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                            "TEST_TRACE": str(self.trace), "TEST_ROOT": str(self.root),
                            "TEST_ISOLATION_STATUS": "0", "TEST_APP_RUNNING": "0"}
        self.write("scripts/ops/native-smoke-isolation.py", "import os, sys\nwith open(os.environ['TEST_TRACE'], 'a') as f: f.write('isolation\\n')\nsys.exit(int(os.environ['TEST_ISOLATION_STATUS']))\n")
        self.write("bin/open-fixture", """#!/bin/bash
echo open >> "$TEST_TRACE"
for argument in "$@"; do
  case "$argument" in TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT=*)
    printf '{"launchToInteractiveMs":40}' > "${argument#*=}" ;;
  esac
done
""", executable=True)
        self.write("bin/pgrep", """#!/bin/bash
echo pgrep >> "$TEST_TRACE"
count=0
[ ! -f "$TEST_ROOT/pgrep-count" ] || read -r count < "$TEST_ROOT/pgrep-count"
count=$((count + 1))
echo "$count" > "$TEST_ROOT/pgrep-count"
[ "$TEST_APP_RUNNING" = 1 ] && exit 0
[ -z "${TEST_RUNNING_AFTER:-}" ] || [ "$count" -le "$TEST_RUNNING_AFTER" ] || exit 0
exit 1
""", executable=True)
        self.write("bin/pkill", '#!/bin/bash\necho pkill >> "$TEST_TRACE"\n', executable=True)
        self.write("bin/sleep", "#!/bin/bash\nexit 0\n", executable=True)
        self.write("bin/mktemp", '#!/bin/bash\nmkdir -p "$TEST_ROOT/runtime"\nprintf "%s\\n" "$TEST_ROOT/runtime"\n', executable=True)
        self.write("bin/git", '#!/bin/bash\n[ "$1" != rev-parse ] || printf "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n"\nexit 0\n', executable=True)
        self.write("bin/swift", '#!/bin/bash\necho unexpected-swift >> "$TEST_TRACE"\nexit 91\n', executable=True)
        self.write("build.sh", '#!/bin/bash\necho build >> "$TEST_TRACE"\n', executable=True)
        self.write("deps-libs/fixture", "fixture")
        self.write("deps-modules/fixture", "fixture")
        self.write("build/Transcripted.app/Contents/MacOS/Transcripted", "not executable; never launched")
        self.write("scripts/dev/verify-change.sh", (ROOT / "scripts/dev/verify-change.sh").read_text())

        # Preserve real control flow; intercept native tools in this scratch
        # copy. Deliberate guard mutations cannot launch apps or signal an
        # unrelated process. Reject unexpected launch spelling before running.
        benchmark = (ROOT / "scripts/dev/bench-launch-latency.sh").read_text()
        self.assertEqual(benchmark.count("/usr/bin/open "), 1)
        benchmark = benchmark.replace("/usr/bin/open ", shlex.quote(str(self.bin / "open-fixture")) + " ")
        self.assertNotIn("/usr/bin/open", benchmark)
        benchmark = benchmark.replace("set -euo pipefail", 'set -euo pipefail\nkill() { echo kill >> "$TEST_TRACE"; }', 1)
        self.write("scripts/dev/bench-launch-latency.sh", benchmark)

    def write(self, relative, contents, *, executable=False):
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        if executable:
            target.chmod(0o700)

    def events(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def run_script(self, name, *arguments):
        return subprocess.run(["bash", str(self.root / "scripts/dev" / name), *arguments],
                              cwd=self.root, env=self.environment, capture_output=True, text=True, timeout=10)

    def benchmark(self, *arguments):
        return self.run_script("bench-launch-latency.sh", "--samples", "1", "--warmups", "1", *arguments)

    def verify(self):
        result = self.run_script("verify-change.sh", "--base", "fixture", "--only", "speed", "--samples", "1")
        return result, (self.root / ".build/verify/summary.md").read_text()

    def test_blocked_account_never_stages_or_launches_benchmark(self):
        self.environment["TEST_ISOLATION_STATUS"] = "3"
        result = self.benchmark()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.events(), ["isolation"])
        self.assertFalse((self.root / "build/benchmarks").exists())

    def test_existing_app_blocks_direct_benchmark_without_launch_or_signal(self):
        self.environment["TEST_APP_RUNNING"] = "1"
        result = self.benchmark()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertNotIn("open", self.events())
        self.assertNotIn("pkill", self.events())

    def test_each_sample_rechecks_owner_app_before_launch(self):
        self.environment["TEST_RUNNING_AFTER"] = "2"
        result = self.benchmark("--samples", "2")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(self.events().count("open"), 1)

    def test_allowed_benchmark_still_collects_real_report_values(self):
        result = self.benchmark()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((self.root / "build/benchmarks/launch-latency-launch.json").read_text())
        self.assertEqual(report["collectedSamples"], 1)
        self.assertEqual(report["launchToInteractiveMs"]["p95"], 40)
        self.assertEqual(self.events().count("open"), 2)

    def test_verify_marks_blocked_account_skip_before_build(self):
        self.environment["TEST_ISOLATION_STATUS"] = "3"
        result, summary = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| speed | SKIP |", summary)
        self.assertNotIn("| speed | PASS |", summary)
        self.assertNotIn("build", self.events())
        self.assertNotIn("open", self.events())

    def test_verify_preserves_running_app_and_skips_before_build(self):
        self.environment["TEST_APP_RUNNING"] = "1"
        result, summary = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| speed | SKIP |", summary)
        self.assertNotIn("build", self.events())
        self.assertNotIn("open", self.events())

    def test_verify_reports_broken_preflight_as_failure_not_permission_skip(self):
        self.environment["TEST_ISOLATION_STATUS"] = "1"
        result, summary = self.verify()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("| speed | FAIL |", summary)
        self.assertNotIn("build", self.events())
        self.assertNotIn("open", self.events())

    def test_verify_keeps_successful_speed_budget_measurement(self):
        result, summary = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| speed | PASS |", summary)
        self.assertIn("p95 40", summary)
        self.assertEqual(self.events().count("open"), 3)

    def test_verify_marks_mid_benchmark_owner_launch_incomplete(self):
        self.environment["TEST_RUNNING_AFTER"] = "3"
        result, summary = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| speed | SKIP |", summary)
        self.assertNotIn("| speed | PASS |", summary)
        self.assertEqual(self.events().count("open"), 1)


if __name__ == "__main__":
    unittest.main()
