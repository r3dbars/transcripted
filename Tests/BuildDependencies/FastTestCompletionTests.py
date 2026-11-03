#!/usr/bin/env python3
"""Runtime regression checks for fast-test completion proof, using fake children."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / "scripts/entrypoints/lib/fast-test-completion.py"
DIGEST = "a" * 64


class FastTestCompletionTests(unittest.TestCase):
    def child(self, change="", status=0, emit=True):
        script = '''
import json, os, pathlib, sys
p = pathlib.Path(os.environ["TRANSCRIPTED_FAST_TEST_COMPLETION_PATH"])
receipt = {
    "version": 1,
    "run_id": os.environ["TRANSCRIPTED_FAST_TEST_COMPLETION_RUN_ID"],
    "selection_digest": "a" * 64,
    "selected_functions": 2, "executed_functions": 2,
    "assertions": 3, "passed_assertions": 3, "failed_assertions": 0,
    "quarantined_suites": 0,
}
'''
        script += change + "\n"
        if emit:
            script += 'p.write_text(json.dumps(receipt))\n'
        script += f"sys.exit({status})\n"
        return script

    def run_child(self, script, expected_functions=2):
        with tempfile.TemporaryDirectory(prefix="fast-completion-test-") as directory:
            command = [sys.executable, str(HELPER), "--run-root", directory,
                       "--expected-functions", str(expected_functions), "--selection-digest", DIGEST,
                       "--", sys.executable, "-c", script]
            result = subprocess.run(command, capture_output=True, text=True)
            # The guard owns only its unique subroot, never leaves stale proof.
            self.assertEqual(list(Path(directory).iterdir()), [])
            return result

    def test_clean_early_exit_without_completion_receipt_fails(self):
        result = self.run_child(self.child(emit=False))
        self.assertEqual(result.returncode, 1)
        self.assertIn("completion receipt missing or invalid", result.stderr)

    def test_fake_success_stdout_never_substitutes_for_receipt(self):
        result = self.run_child(self.child('print("ALL TESTS PASSED")', emit=False))
        self.assertEqual(result.returncode, 1)
        self.assertIn("completion receipt missing or invalid", result.stderr)

    def test_matching_complete_receipt_and_zero_failures_pass(self):
        result = self.run_child(self.child())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2/2 functions, 3 assertions, 0 failed", result.stdout)

    def test_failed_assertions_fail_even_when_child_exits_zero(self):
        result = self.run_child(self.child('receipt.update(passed_assertions=2, failed_assertions=1)'))
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 failed", result.stderr)

    def test_incomplete_mismatched_or_invalid_counts_fail(self):
        changes = [
            'receipt["executed_functions"] = 1',
            'receipt["selected_functions"] = 1',
            'receipt["executed_functions"] = 0',
            'receipt["executed_functions"] = True',
            'receipt["assertions"] = 4',
            'receipt["failed_assertions"] = -1',
            'receipt["quarantined_suites"] = -1',
            'receipt["selection_digest"] = "b" * 64',
            'receipt["run_id"] = "stale-run"',
            'receipt["version"] = 2',
            'receipt["private_extra"] = "untrusted_marker"',
            'del receipt["failed_assertions"]',
        ]
        for change in changes:
            with self.subTest(change=change):
                result = self.run_child(self.child(change))
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("untrusted_marker", result.stderr)

    def test_nonzero_child_status_remains_failure_even_with_valid_receipt(self):
        result = self.run_child(self.child(status=7))
        self.assertEqual(result.returncode, 7)

    def test_nonzero_child_without_receipt_keeps_original_status(self):
        self.assertEqual(self.run_child(self.child(status=9, emit=False)).returncode, 9)

    def test_child_signal_keeps_shell_signal_status(self):
        script = self.child('os.kill(os.getpid(), 15)', emit=False)
        self.assertEqual(self.run_child(script).returncode, 143)

    def test_no_selected_functions_cannot_claim_empty_success(self):
        self.assertNotEqual(self.run_child(self.child(), expected_functions=0).returncode, 0)

    def test_malformed_receipt_is_rejected_without_echoing_content(self):
        result = self.run_child(self.child('p.write_text("untrusted_marker")', emit=False))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("untrusted_marker", result.stderr)

    def test_duplicate_json_fields_cannot_supply_ambiguous_proof(self):
        change = '''encoded = json.dumps(receipt)
p.write_text(encoded[:-1] + ', "executed_functions": 2}')'''
        self.assertEqual(self.run_child(self.child(change, emit=False)).returncode, 1)

    def test_symlink_receipt_is_rejected_and_external_target_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix="fast-completion-outside-") as directory:
            outside = Path(directory) / "outside.json"
            outside.write_text("external_marker")
            change = f"p.symlink_to({str(outside)!r})"
            result = self.run_child(self.child(change, emit=False))
            self.assertEqual(result.returncode, 1)
            self.assertEqual(outside.read_text(), "external_marker")

    def test_quarantined_entries_may_return_without_assertions(self):
        change = 'receipt.update(assertions=0, passed_assertions=0, quarantined_suites=2)'
        self.assertEqual(self.run_child(self.child(change)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
