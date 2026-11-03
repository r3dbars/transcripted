#!/usr/bin/env python3
"""Fixed synthetic inputs verify completeness, ordering and bounded output."""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "paired_launch", ROOT / "scripts/ci/paired-launch-diagnostics.py")
DIAGNOSTICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIAGNOSTICS)


def fixture():
    blocks = []
    for index, arm in enumerate(DIAGNOSTICS.ORDER):
        start = 1000 + index * 10 + (100 if arm == "candidate" else 0)
        blocks.append({
            "label": f"{arm}-block-{index + 1}", "homeMode": "fresh",
            "requestedSamples": 5, "collectedSamples": 5,
            "samples": [start + number for number in range(5)],
        })
    return blocks


class PairedLaunchDiagnosticsTests(unittest.TestCase):
    def receipt(self, blocks=None):
        return DIAGNOSTICS.aggregate(fixture() if blocks is None else blocks, "a" * 40)

    def test_all_observations_survive_in_prescribed_source_order(self):
        payloads = fixture()
        receipt = self.receipt(payloads)
        self.assertTrue(receipt["complete"])
        self.assertEqual(receipt["order"], ["base", "candidate", "candidate", "base",
                                            "candidate", "base", "base", "candidate"])
        self.assertEqual([block["samples_ms"] for block in receipt["blocks"]],
                         [block["samples"] for block in payloads])
        self.assertEqual([block["warmup_launches_requested"] for block in receipt["blocks"]],
                         [0, 0, 0, 0, 0, 0, 0, 0])
        self.assertEqual(receipt["warmup_launches_requested"], 0)
        for arm, sha in (("base", DIAGNOSTICS.BASE_SHA), ("candidate", DIAGNOSTICS.CANDIDATE_SHA)):
            self.assertEqual(receipt["summary"][arm]["count"], 20)
            self.assertTrue(all(block["source_sha"] == sha for block in receipt["blocks"]
                                if block["arm"] == arm))

    def test_paired_differences_follow_head_minus_base_in_both_orders(self):
        pairs = self.receipt()["paired_block_differences"]
        self.assertEqual([pair["candidate_minus_base_mean_ms"] for pair in pairs],
                         [110, 90, 90, 110])
        self.assertEqual([pair["candidate_minus_base_p50_ms"] for pair in pairs],
                         [110, 90, 90, 110])

    def test_summary_keeps_first_scored_sample_and_observed_nearest_rank(self):
        result = DIAGNOSTICS.summary(list(range(20, 0, -1)))
        self.assertEqual(result["first_scored_sample_ms"], 20)
        self.assertEqual(result["p50_ms"], 10)
        self.assertEqual(result["p90_ms"], 18)
        self.assertEqual(result["p95_ms"], 19)
        self.assertEqual(result["max_ms"], 20)

    def test_missing_extra_or_reordered_blocks_never_count_as_complete(self):
        blocks = fixture()
        for invalid in (blocks[:-1], blocks + [blocks[0]], list(reversed(blocks))):
            with self.subTest(block_count=len(invalid)):
                with self.assertRaises(DIAGNOSTICS.InvalidEvidence):
                    self.receipt(invalid)

    def test_incomplete_or_warm_home_samples_are_rejected(self):
        for field, value in (("requestedSamples", 4), ("collectedSamples", 4),
                             ("samples", [1, 2, 3, 4]), ("homeMode", "shared"),
                             ("requestedSamples", True), ("samples", "private")):
            with self.subTest(field=field, value=value):
                blocks = fixture()
                blocks[0][field] = value
                with self.assertRaises(DIAGNOSTICS.InvalidEvidence):
                    self.receipt(blocks)

    def test_nonfinite_negative_boolean_or_string_samples_are_rejected(self):
        for value in (float("nan"), float("inf"), float("-inf"), -1, True, "private", 10 ** 1000):
            with self.subTest(value=value):
                blocks = fixture()
                blocks[0]["samples"][0] = value
                with self.assertRaises(DIAGNOSTICS.InvalidEvidence):
                    self.receipt(blocks)

    def test_untrusted_metadata_is_not_copied_to_bounded_receipt(self):
        blocks = fixture()
        for block in blocks:
            block["private_metadata"] = "private_marker"
            block["launchToInteractiveMs"] = {"private": "private_marker"}
        encoded = json.dumps(self.receipt(blocks), allow_nan=False)
        self.assertNotIn("private_marker", encoded)
        self.assertNotIn("private_metadata", encoded)

    def test_invalid_identity_is_rejected_without_echoing_input(self):
        for value in ("", "a" * 39, "A" * 40, "private_marker", None):
            with self.subTest(value=value):
                with self.assertRaisesRegex(DIAGNOSTICS.InvalidEvidence, "^invalid_workflow_identity$"):
                    DIAGNOSTICS.aggregate(fixture(), value)

    def test_successful_measurement_does_not_clear_required_check(self):
        receipt = self.receipt()
        self.assertEqual(receipt["purpose"], "diagnosis_only")
        self.assertEqual(receipt["original_required_check"]["status"], "failed")
        self.assertEqual(receipt["original_required_check"]["budget_ms"], 3000)
        self.assertTrue(receipt["release_verdict"].startswith("HOLD:"))

    def test_owner_environment_is_rejected_before_any_output_or_source_access(self):
        with tempfile.TemporaryDirectory(prefix="paired-launch-test-") as directory:
            root = Path(directory)
            args = SimpleNamespace(base_root=root / "absent-base", candidate_root=root / "absent-candidate",
                                   out_dir=root / "output", workflow_sha="a" * 40)
            with patch.dict(os.environ, {}, clear=True):
                with self.assertRaisesRegex(DIAGNOSTICS.InvalidEvidence, "^requires_hosted_apple_silicon$"):
                    DIAGNOSTICS.run(args)
            self.assertFalse(args.out_dir.exists())


if __name__ == "__main__":
    unittest.main()
