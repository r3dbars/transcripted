#!/usr/bin/env python3
"""Pure regression tests for the speaker auto-research coordinator."""

from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("run_speaker_autoresearch.py")
SPEC = importlib.util.spec_from_file_location("speaker_autoresearch", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
AUTORESEARCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUTORESEARCH)


def metric(**changes: int) -> dict[str, int]:
    value = {key: 0 for key in AUTORESEARCH.SAFETY_KEYS}
    value.update({"automaticNames": 10, "repeatPrompts": 10})
    value.update(changes)
    return value


def report(config: dict, metrics: dict, slices: dict | None = None) -> dict:
    return {
        "config": config,
        "metrics": metrics,
        "slices": slices or {"clean": metrics.copy()},
    }


def write_json(path: pathlib.Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


class GuardrailTests(unittest.TestCase):
    def test_every_safety_key_is_enforced_inside_each_slice(self) -> None:
        baseline = report(
            copy.deepcopy(AUTORESEARCH.BASELINE),
            metric(),
            {"clean": metric()},
        )
        for key in AUTORESEARCH.SAFETY_KEYS:
            with self.subTest(key=key):
                candidate_slice = metric(**{key: 1})
                candidate = report(
                    {**AUTORESEARCH.BASELINE, "id": f"candidate-{key}"},
                    metric(),
                    {"clean": candidate_slice},
                )
                safe, reasons = AUTORESEARCH.no_safety_regression(candidate, baseline)
                self.assertFalse(safe)
                self.assertTrue(any(f"clean:{key}" in reason for reason in reasons))


class ManifestTests(unittest.TestCase):
    def test_manifest_rejects_path_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            input_root = base / "inputs"
            input_root.mkdir()
            outside = base / "outside.json"
            outside.write_text("outside")
            manifest = base / "manifest.txt"
            manifest.write_text(
                f"{AUTORESEARCH.file_sha256(outside)} ../outside.json\n"
            )

            with self.assertRaises(SystemExit):
                AUTORESEARCH.verify_manifest(manifest, input_root)

    def test_manifest_rejects_duplicate_canonical_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            input_root = base / "inputs"
            input_root.mkdir()
            sample = input_root / "sample.json"
            sample.write_text("sample")
            digest = AUTORESEARCH.file_sha256(sample)
            manifest = base / "manifest.txt"
            manifest.write_text(f"{digest} sample.json\n{digest} ./sample.json\n")

            with self.assertRaises(SystemExit):
                AUTORESEARCH.verify_manifest(manifest, input_root)


class CheckpointIdentityTests(unittest.TestCase):
    def test_checkpoint_rejects_changed_manifest_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = pathlib.Path(temporary)
            result_path = base / "result.json"
            identity_path = base / "identity.json"
            payload = {
                "schemaVersion": AUTORESEARCH.EVALUATOR_SCHEMA_VERSION,
                "split": "dev",
                "reports": [report(AUTORESEARCH.BASELINE, metric())],
            }
            write_json(result_path, payload)
            runtime = {
                "evaluatorSchemaVersion": AUTORESEARCH.EVALUATOR_SCHEMA_VERSION,
                "binarySHA256": "binary",
                "evaluatorSourceSHA256": "source",
                "runnerSHA256": "runner",
                "manifestSHA256": "manifest-a",
                "manifestPath": "/manifest",
                "inputRoot": "/inputs",
            }
            configs = {AUTORESEARCH.BASELINE["id"]: AUTORESEARCH.BASELINE}
            write_json(
                identity_path,
                AUTORESEARCH.checkpoint_identity(
                    runtime=runtime,
                    split="dev",
                    configs=configs,
                    result_path=result_path,
                ),
            )
            self.assertIsNone(AUTORESEARCH.checkpoint_validation_error(
                result_path=result_path,
                identity_path=identity_path,
                runtime=runtime,
                split="dev",
                expected_configs=configs,
            ))

            changed = {**runtime, "manifestSHA256": "manifest-b"}
            self.assertIsNotNone(AUTORESEARCH.checkpoint_validation_error(
                result_path=result_path,
                identity_path=identity_path,
                runtime=changed,
                split="dev",
                expected_configs=configs,
            ))

    def test_skip_build_rejects_stale_source_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "Sources/TranscriptedCore").mkdir(parents=True)
            (root / "Tools/SpeakerEvalHarness/Sources").mkdir(parents=True)
            (root / "Package.swift").write_text("root")
            (root / "Tools/SpeakerEvalHarness/Package.swift").write_text("harness")
            source = root / "Tools/SpeakerEvalHarness/Sources/main.swift"
            source.write_text("first")
            binary = root / "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
            binary.parent.mkdir(parents=True)
            binary.touch()
            AUTORESEARCH.binary_source_stamp(binary).write_text("stale\n")

            with self.assertRaises(SystemExit):
                AUTORESEARCH.require_current_binary_source(root, binary)

            AUTORESEARCH.binary_source_stamp(binary).write_text(
                AUTORESEARCH.evaluator_source_sha256(root) + "\n"
            )
            AUTORESEARCH.require_current_binary_source(root, binary)


class PhaseTests(unittest.TestCase):
    def test_validate_phase_loads_locked_discovery_without_rerunning_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            state = root / "state"
            input_root = root / "inputs"
            input_root.mkdir()
            manifest = root / "manifest.txt"
            manifest.write_text("ignored\n")
            binary = root / "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
            binary.parent.mkdir(parents=True)
            binary.touch()

            candidate = {**AUTORESEARCH.BASELINE, "id": "locked-candidate"}
            (state / "checkpoints").mkdir(parents=True)
            (state / "results").mkdir(parents=True)
            runtime = {
                "evaluatorSchemaVersion": AUTORESEARCH.EVALUATOR_SCHEMA_VERSION,
                "binarySHA256": "binary",
                "evaluatorSourceSHA256": "source",
                "runnerSHA256": "runner",
                "manifestSHA256": "manifest",
                "manifestPath": str(manifest.resolve()),
                "inputRoot": str(input_root.resolve()),
            }
            finalist_path = state / "checkpoints/holdout-finalists.json"
            write_json(finalist_path, [AUTORESEARCH.BASELINE, candidate])
            write_json(state / "checkpoints/holdout-finalists-identity.json", {
                **runtime,
                "topK": 8,
                "finalistsSHA256": AUTORESEARCH.file_sha256(finalist_path),
            })
            dev_path = state / "results/one-knob-dev.json"
            write_json(dev_path, {
                "schemaVersion": AUTORESEARCH.EVALUATOR_SCHEMA_VERSION,
                "split": "dev",
                "reports": [
                    report(AUTORESEARCH.BASELINE, metric()),
                    report(candidate, metric()),
                ]
            })
            dev_configs = {
                AUTORESEARCH.BASELINE["id"]: AUTORESEARCH.BASELINE,
                candidate["id"]: candidate,
            }
            write_json(
                state / "checkpoints/one-knob-dev-identity.json",
                AUTORESEARCH.checkpoint_identity(
                    runtime=runtime,
                    split="dev",
                    configs=dev_configs,
                    result_path=dev_path,
                ),
            )
            args = argparse.Namespace(
                manifest=manifest,
                input_root=input_root,
                state_dir=state,
                phase="validate",
                top_k=8,
                skip_build=True,
                no_resume=False,
            )

            with mock.patch.object(AUTORESEARCH, "parse_args", return_value=args), \
                 mock.patch.object(AUTORESEARCH, "repo_root", return_value=root), \
                 mock.patch.object(AUTORESEARCH, "verify_manifest", return_value=1), \
                 mock.patch.object(AUTORESEARCH, "require_current_binary_source"), \
                 mock.patch.object(AUTORESEARCH, "runtime_identity", return_value=runtime), \
                 mock.patch.object(AUTORESEARCH, "run_holdout_validation", return_value=0) as validate:
                self.assertEqual(AUTORESEARCH.main(), 0)

            validate.assert_called_once()
            call = validate.call_args.kwargs
            self.assertEqual([item["id"] for item in call["finalists"]], ["locked-candidate"])
            self.assertIn(AUTORESEARCH.BASELINE["id"], call["dev_reports"])
            self.assertIn("locked-candidate", call["dev_reports"])


if __name__ == "__main__":
    unittest.main()
