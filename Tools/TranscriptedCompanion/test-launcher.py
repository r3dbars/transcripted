#!/usr/bin/env python3
"""Behavioral check: testing the companion never terminates a running app."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


class LaunchSafetyTests(unittest.TestCase):
    def test_running_copy_is_preserved(self):
        source = Path(__file__).resolve().parents[2] / "script/build_and_run.sh"
        with tempfile.TemporaryDirectory(prefix="tc-launch-", dir="/private/tmp") as temporary:
            root = Path(temporary)
            (root / "script").mkdir()
            shutil.copy2(source, root / "script/build_and_run.sh")
            (root / "bin").mkdir()
            marker = root / "build-attempted"
            (root / "build.sh").write_text(f"#!/bin/bash\ntouch '{marker}'\nexit 99\n")
            child = subprocess.Popen(["/bin/sleep", "60"])
            try:
                for command in [str(root / "build/Transcripted.app/Contents/MacOS/Transcripted"),
                                "/Applications/Transcripted.app/Contents/MacOS/Transcripted"]:
                    with self.subTest(command=command):
                        fake_ps = root / "bin/ps"
                        fake_ps.write_text(f"#!/bin/bash\nprintf '%s\\n' '{child.pid} {command}'\n")
                        fake_ps.chmod(0o700)
                        environment = dict(os.environ, PATH=str(root / "bin") + ":" + os.environ["PATH"])
                        result = subprocess.run(["/bin/bash", str(root / "script/build_and_run.sh"), "--launch-only"],
                                                env=environment, text=True, capture_output=True)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("Finish any active meeting", result.stderr)
                        self.assertIsNone(child.poll())
                        self.assertFalse(marker.exists())
            finally:
                child.terminate()
                child.wait()


if __name__ == "__main__":
    unittest.main()
