#!/usr/bin/env python3
"""Beta-build names are explicit; legacy token arguments stay ignored."""

import subprocess
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parents[2] / "scripts/entrypoints/lib/beta-build-arguments.sh"
PARSE = """source "$1"; shift; parse_beta_build_arguments "$@"; printf '%s' "$USER_NAME";"""


class BetaBuildArgumentsTests(unittest.TestCase):
    def parse(self, *arguments):
        with tempfile.TemporaryDirectory() as owned:
            return subprocess.run(
                ["/bin/bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", PARSE,
                 "beta-build-argument-test", str(HELPER), *arguments],
                cwd=owned, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C",
                                "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"},
                capture_output=True, text=True, timeout=10,
            )

    def expect_name(self, expected, *arguments):
        result = self.parse(*arguments)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, expected)
        self.assertEqual(result.stderr, "")

    def test_no_arguments_retains_beta_default(self):
        self.expect_name("beta")

    def test_single_legacy_argument_never_becomes_a_name(self):
        for token in ("invented-legacy-secret", "tiny", "--invented-legacy-token", ""):
            with self.subTest(token_shape=token[:2]):
                self.expect_name("beta", token)

    def test_legacy_second_argument_remains_the_name(self):
        self.expect_name("Synthetic Builder", "invented-legacy-secret", "Synthetic Builder")
        self.expect_name("beta", "invented-legacy-secret", "")

    def test_extra_legacy_arguments_remain_ignored(self):
        self.expect_name("Synthetic Builder", "invented-legacy-secret", "Synthetic Builder", "ignored-extra")

    def test_explicit_name_preserves_literal_data(self):
        for name in ("Synthetic Builder", "--literal-name", "$(printf invented)", "name\n\n"):
            with self.subTest(name_shape=name[:2]):
                self.expect_name(name, "--user-name", name)

    def test_empty_explicit_name_retains_beta_default(self):
        self.expect_name("beta", "--user-name", "")

    def test_missing_explicit_operand_fails_without_reflecting_input(self):
        result = self.parse("--user-name")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Usage: build-beta.sh --user-name <user-name>\n")

    def test_extra_explicit_operand_fails_without_reflecting_input(self):
        result = self.parse("--user-name", "invented-private-name", "invented-legacy-secret")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "Usage: build-beta.sh --user-name <user-name>\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
