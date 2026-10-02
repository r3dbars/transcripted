#!/usr/bin/env python3
"""The package rejects unrelated data instead of shipping it silently."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("companion_package", Path(__file__).with_name("package.py"))
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackagePrivacyTests(unittest.TestCase):
    def test_unexpected_data_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="tc-package-", dir="/private/tmp") as temporary:
            root = Path(temporary) / "transcripted"
            shutil.copytree(package.SOURCE, root)
            package.validate(root)
            for name in ["connection.json", ".env", "meeting.wav", "meeting.md", "index.sqlite"]:
                with self.subTest(name=name):
                    unexpected = root / name
                    unexpected.write_text("invented fixture, never a credential")
                    with self.assertRaisesRegex(AssertionError, "Unexpected plugin file"):
                        package.validate(root)
                    unexpected.unlink()


if __name__ == "__main__":
    unittest.main()
