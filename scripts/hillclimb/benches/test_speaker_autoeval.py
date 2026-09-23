#!/usr/bin/env python3
"""Tests for the speaker-autoeval bench adapter, using a fake harness (runs on Linux).

Run: python3 scripts/hillclimb/benches/speaker_autoeval.py --self-test
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import speaker_autoeval as adapter  # noqa: E402
from hc_benches import RESULT_SCHEMA, validate_result  # noqa: E402
from hc_splits import DEV, HOLDOUT, Suite, check_split_health  # noqa: E402

SUITE_PATH = HERE.parents[2] / "config" / "hillclimb" / "suites" / "speaker-identities.json"
OBJECTIVES_PATH = HERE.parents[2] / "config" / "hillclimb" / "objectives.json"

# The fake harness validates its argv like the Swift CLI, echoes the config,
# and writes a schema-3 report whose numbers depend on autoSimilarity. Slice
# sizes per split come from FAKE_HARNESS_CORPORA: {split: {corpus: returning}}.
FAKE_HARNESS = textwrap.dedent(
    """
    import json, os, sys
    args = sys.argv[1:]
    assert args[0] == "autoeval", args
    def value(flag):
        index = args.index(flag)
        return args[index + 1]
    manifest, root, configs_path, split, out = (
        value("--manifest"), value("--input-root"), value("--configs"), value("--split"), value("--out"))
    assert os.path.isfile(manifest) and os.path.isdir(root)
    assert split in ("train", "dev", "holdout"), split
    assert os.environ.get("TRANSCRIPTED_DISABLE_FILE_LOGGER") == "1"
    with open(os.environ["FAKE_HARNESS_LOG"], "a") as log:
        log.write(split + "\\n")
    if split in os.environ.get("FAKE_HARNESS_FAIL", "").split(","):
        sys.stderr.write("manifest checksum mismatch: fake\\n")
        sys.exit(1)
    configs = json.load(open(configs_path))
    assert isinstance(configs, list) and len(configs) == 1
    config = configs[0]
    required = json.loads(os.environ["FAKE_HARNESS_FIELDS"])
    assert sorted(config) == sorted(required), sorted(set(config) ^ set(required))
    similarity = config["autoSimilarity"]
    counts = ("observations scorableObservations recurringSpeakerUnits returningOpportunities asks "
              "suggestions automaticNames correctAutomaticNames falseAutomaticNames "
              "falseAutomaticNamesAllPurities automaticNamesOnLowPurity wrongSuggestions repeatPrompts "
              "openSetTrials openSetFalseAutomaticNames openSetWrongSuggestions falseMergeIndicators "
              "withinMeetingFalseMergeIndicators crossMeetingFalseMergeIndicators fragmentationExcess "
              "contaminatedProfiles profilesAtEnd identitiesReachingAuto").split()
    def snapshot(returning):
        row = {name: 0 for name in counts}
        if returning:
            correct = int(round(returning * (1.0 - similarity) * 5))
            false_autos = 2 if similarity < 0.9 else 0
            row.update(observations=returning + 4, scorableObservations=returning + 4,
                       recurringSpeakerUnits=4, returningOpportunities=returning,
                       automaticNames=correct + false_autos, correctAutomaticNames=correct,
                       falseAutomaticNames=false_autos, falseAutomaticNamesAllPurities=false_autos + 1,
                       openSetFalseAutomaticNames=false_autos // 2, repeatPrompts=returning - correct,
                       falseMergeIndicators=false_autos, contaminatedProfiles=1 if false_autos else 0,
                       wrongSuggestions=3)
        row.update(meanAppearanceToFirstAuto=None, meanConfirmedMeetingsAtFirstAuto=None,
                   promptsPerRecurringSpeaker=None, autoCoverage=None, autoPrecision=None,
                   falseAutoUpper95WhenZero=None)
        return row
    corpora = json.loads(os.environ["FAKE_HARNESS_CORPORA"]).get(split, {})
    slices = {corpus: snapshot(returning) for corpus, returning in corpora.items()}
    slices["condition/purity/low"] = snapshot(99)
    echoed = dict(config)
    if os.environ.get("FAKE_HARNESS_MANGLE"):
        echoed["autoSimilarity"] = 0.5
    report = {"schemaVersion": int(os.environ.get("FAKE_HARNESS_SCHEMA", "3")), "generatedAt": "x",
              "split": split, "manifestPath": manifest, "inputRoot": root, "scoringPurityFloor": 0.8,
              "splitContract": "fake", "reports": [{"config": echoed, "metrics": snapshot(10), "slices": slices}]}
    with open(out, "w") as handle:
        json.dump(report, handle)
    print("AUTOEVAL fake split=" + split)
    """
)

CORPORA = {
    "train": {"ami_orig": 20, "ami_mp3_32": 10, "voxceleb_orig": 10},
    "dev": {"ami_orig": 20, "voxceleb_orig": 0},
    "holdout": {"ami_orig": 10},
}


def item(corpus: str, harness_split: str) -> dict[str, Any]:
    split = HOLDOUT if harness_split == "holdout" else DEV
    return {"id": f"{corpus}-{harness_split}", "corpus": corpus, "harness_split": harness_split, "split": split}


class Fixture:
    """A temp dir with a fake harness, one fingerprint cache and its manifest."""

    def __init__(self, root: Path):
        self.root = root
        self.harness = root / "speaker-eval-harness"
        self.harness.write_text(f"#!{sys.executable}\n" + FAKE_HARNESS)
        self.harness.chmod(self.harness.stat().st_mode | stat.S_IXUSR)
        self.inputs = root / "qmatrix"
        (self.inputs / "ami_orig").mkdir(parents=True)
        cache = self.inputs / "ami_orig" / "fingerprints.json"
        cache.write_text(json.dumps({"corpus": "ami_orig", "meetings": []}))
        self.manifest = root / "qmatrix-manifest.sha256"
        digest = hashlib.sha256(cache.read_bytes()).hexdigest()
        self.manifest.write_text(f"{digest}  ami_orig/fingerprints.json\n")
        self.log = root / "harness.log"
        self.work = root / "work"
        self.work.mkdir()
        os.environ["FAKE_HARNESS_LOG"] = str(self.log)
        os.environ["FAKE_HARNESS_CORPORA"] = json.dumps(CORPORA)
        os.environ["FAKE_HARNESS_FIELDS"] = json.dumps(sorted(adapter.BASELINE))

    def request(self, items: list[dict], *, split: str = DEV, knobs: dict | None = None, **options: Any) -> dict:
        bench_options = {
            "harness_binary": str(self.harness),
            "manifest": str(self.manifest),
            "input_root": str(self.inputs),
        }
        bench_options.update(options)
        return {
            "schema": "transcripted.hillclimb.request.v1",
            "trial_id": "t0001",
            "objective": "speaker-naming-across-calls",
            "suite": "speaker-identities",
            "split": split,
            "repetition": 0,
            "knobs": knobs if knobs is not None else {"speaker.naming.auto_similarity": 0.92},
            "items": items,
            "bench_options": bench_options,
            "result_path": str(self.work / "result.json"),
        }

    def harness_runs(self) -> list[str]:
        return self.log.read_text().split() if self.log.exists() else []


class AdapterTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._env = dict(os.environ)
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()


class KnobMappingTests(unittest.TestCase):
    def test_every_objective_knob_maps_to_a_config_field(self) -> None:
        objectives = json.loads(OBJECTIVES_PATH.read_text())["objectives"]
        speaker = next(o for o in objectives if o["id"] == "speaker-naming-across-calls")
        self.assertEqual(sorted(speaker["knobs"]), sorted(adapter.KNOB_FIELDS))
        self.assertEqual(sorted(adapter.KNOB_FIELDS.values()), sorted(k for k in adapter.BASELINE if k != "id"))

    def test_mapping_and_baseline_fill(self) -> None:
        config = adapter.build_config({
            "speaker.naming.auto_similarity": 0.95,
            "speaker.naming.required_maturity_count": 3.0,
            "speaker.writeback.evidence": "confirmed-only",
            "speaker.exemplar.blend_alpha": 0.2,
        })
        self.assertEqual(config["autoSimilarity"], 0.95)
        self.assertEqual(config["requiredMaturityCount"], 3)
        self.assertIsInstance(config["requiredMaturityCount"], int)
        self.assertEqual(config["writeBackEvidence"], "confirmed_only")
        self.assertEqual(config["exemplarBlendAlpha"], 0.2)
        self.assertEqual(config["autoMargin"], adapter.BASELINE["autoMargin"])
        self.assertEqual(config["autoMaturityEvidence"], "confirmed_meetings")
        self.assertEqual(config["id"], adapter.CONFIG_ID)
        self.assertEqual(sorted(config), sorted(adapter.BASELINE))

    def test_empty_knobs_is_the_production_baseline(self) -> None:
        config = adapter.build_config({})
        self.assertEqual({k: v for k, v in config.items() if k != "id"},
                         {k: v for k, v in adapter.BASELINE.items() if k != "id"})

    def test_numeric_enum_knob_passes_through_as_float(self) -> None:
        # knobs.json declares minimum_average_similarity as an enum of numbers (-1 means off).
        for value in (-1.0, 0.80, 0.92):
            config = adapter.build_config({"speaker.naming.minimum_average_similarity": value})
            self.assertEqual(config["minimumAverageSimilarity"], value)
            self.assertIsInstance(config["minimumAverageSimilarity"], float)

    def test_unknown_knob_rejected(self) -> None:
        with self.assertRaisesRegex(adapter.AdapterError, "unknown knob"):
            adapter.build_config({"speech.parakeet.encoder_compute_units": "all"})

    def test_bad_values_rejected(self) -> None:
        for knob, value in (
            ("speaker.naming.auto_maturity_evidence", "sometimes"),
            ("speaker.naming.required_maturity_count", 2.5),
            ("speaker.naming.auto_similarity", True),
            ("speaker.naming.auto_similarity", float("nan")),
            ("speaker.exemplar.max_count", "3"),
        ):
            with self.subTest(knob=knob, value=value):
                with self.assertRaises(adapter.AdapterError):
                    adapter.build_config({knob: value})


class RunTests(AdapterTestCase):
    def test_one_harness_run_per_harness_split(self) -> None:
        items = [item("ami_orig", "train"), item("ami_mp3_32", "train"), item("ami_orig", "dev"),
                 item("voxceleb_orig", "train")]
        result = adapter.run(self.fx.request(items))
        self.assertEqual(sorted(self.fx.harness_runs()), ["dev", "train"])
        self.assertEqual([row["id"] for row in result["items"]], [i["id"] for i in items])
        self.assertEqual(validate_result(result, [i["id"] for i in items]), [])
        self.assertEqual(result["schema"], RESULT_SCHEMA)
        self.assertEqual(result["bench"], "speaker-autoeval")

    def test_per_corpus_metrics_and_gates(self) -> None:
        result = adapter.run(self.fx.request([item("ami_orig", "train")]))
        row = result["items"][0]
        self.assertIsNone(row["error"])
        correct = int(round(20 * (1.0 - 0.92) * 5))  # fake harness formula, returning=20
        self.assertAlmostEqual(row["metrics"]["auto_coverage"], correct / 20)
        self.assertAlmostEqual(row["metrics"]["prompts_per_recurring_speaker"], (20 - correct) / 4)
        self.assertEqual(row["metrics"]["repeat_prompts"], 20 - correct)
        self.assertEqual(row["metrics"]["correct_automatic_names"], correct)
        self.assertEqual(row["metrics"]["auto_precision"], 1.0)
        self.assertEqual(row["gates"], {
            "false_automatic_name": 0,
            "false_automatic_name_all_purities": 1,
            "open_set_false_automatic_name": 0,
            "cross_person_merge": 0,
            "contaminated_profile": 0,
            "wrong_suggestion": 3,
            "open_set_wrong_suggestion": 0,
        })
        for value in row["gates"].values():
            self.assertIs(type(value), int)

    def test_gates_fire_when_the_knob_crosses_the_danger_line(self) -> None:
        knobs = {"speaker.naming.auto_similarity": 0.85}
        row = adapter.run(self.fx.request([item("ami_orig", "train")], knobs=knobs))["items"][0]
        self.assertEqual(row["gates"]["false_automatic_name"], 2)
        self.assertEqual(row["gates"]["open_set_false_automatic_name"], 1)
        self.assertEqual(row["gates"]["cross_person_merge"], 2)
        self.assertEqual(row["gates"]["contaminated_profile"], 1)
        self.assertLess(row["metrics"]["auto_precision"], 1.0)

    def test_knob_value_reaches_the_harness(self) -> None:
        low = adapter.run(self.fx.request([item("ami_orig", "train")],
                                          knobs={"speaker.naming.auto_similarity": 0.94}))
        high = adapter.run(self.fx.request([item("ami_orig", "train")],
                                           knobs={"speaker.naming.auto_similarity": 0.90}))
        self.assertGreater(high["items"][0]["metrics"]["auto_coverage"],
                           low["items"][0]["metrics"]["auto_coverage"])
        sent = json.loads((self.fx.work / "autoeval-train-configs.json").read_text())
        self.assertEqual(sent[0]["autoSimilarity"], 0.90)

    def test_family_item_sums_quality_slices(self) -> None:
        row = adapter.run(self.fx.request([item("ami", "train")]))["items"][0]
        correct = int(round(20 * 0.08 * 5)) + int(round(10 * 0.08 * 5))
        self.assertAlmostEqual(row["metrics"]["auto_coverage"], correct / 30)
        self.assertEqual(row["metrics"]["returning_opportunities"], 30)
        self.assertEqual(adapter.corpus_family("voxconverse_dev"), "voxconverse")
        self.assertEqual(adapter.corpus_family("icsi_orig"), "icsi")
        self.assertEqual(adapter.corpus_family("ami"), "ami")

    def test_missing_corpus_or_empty_split_is_an_item_error_not_zeros(self) -> None:
        items = [item("ami_orig", "dev"), item("icsi_orig", "dev"), item("voxceleb_orig", "dev")]
        result = adapter.run(self.fx.request(items))
        rows = {row["id"]: row for row in result["items"]}
        self.assertIsNone(rows["ami_orig-dev"]["error"])
        self.assertIn("no slice for corpus 'icsi_orig'", rows["icsi_orig-dev"]["error"])
        self.assertIn("ami_orig", rows["icsi_orig-dev"]["error"])  # lists what the report has
        self.assertIn("no scored identities", rows["voxceleb_orig-dev"]["error"])
        for bad in ("icsi_orig-dev", "voxceleb_orig-dev"):
            self.assertEqual(rows[bad]["metrics"], {})
            self.assertEqual(rows[bad]["gates"], {})
        self.assertEqual(validate_result(result, list(rows)), [])

    def test_condition_slices_are_never_items(self) -> None:
        row = adapter.run(self.fx.request([item("condition/purity/low", "train")]))["items"][0]
        self.assertIn("no slice", row["error"])

    def test_failed_split_only_errors_its_own_items(self) -> None:
        os.environ["FAKE_HARNESS_FAIL"] = "dev"
        result = adapter.run(self.fx.request([item("ami_orig", "train"), item("ami_orig", "dev")]))
        rows = {row["id"]: row for row in result["items"]}
        self.assertIsNone(rows["ami_orig-train"]["error"])
        self.assertIn("harness split dev exited 1", rows["ami_orig-dev"]["error"])

    def test_holdout_identities_never_measured_in_dev_and_vice_versa(self) -> None:
        leak = item("ami_orig", "holdout") | {"split": DEV}
        result = adapter.run(self.fx.request([item("ami_orig", "train"), leak]))
        self.assertIn("may not be measured", result["items"][1]["error"])
        self.assertEqual(self.fx.harness_runs(), ["train"])
        result = adapter.run(self.fx.request([item("ami_orig", "dev")], split=HOLDOUT))
        self.assertIn("may not be measured", result["items"][0]["error"])
        result = adapter.run(self.fx.request([item("ami_orig", "holdout")], split=HOLDOUT))
        self.assertIsNone(result["items"][0]["error"])

    def test_app_revision_binds_binary_and_manifest(self) -> None:
        first = adapter.run(self.fx.request([item("ami_orig", "train")]))["environment"]["app_revision"]
        binary = hashlib.sha256(self.fx.harness.read_bytes()).hexdigest()[:16]
        manifest = hashlib.sha256(self.fx.manifest.read_bytes()).hexdigest()[:12]
        self.assertEqual(first, f"sha256:{binary}+{manifest}")
        cache = self.fx.inputs / "ami_orig" / "fingerprints.json"
        cache.write_text(json.dumps({"corpus": "ami_orig", "meetings": [], "v": 2}))
        digest = hashlib.sha256(cache.read_bytes()).hexdigest()
        self.fx.manifest.write_text(f"{digest}  ami_orig/fingerprints.json\n")
        second = adapter.run(self.fx.request([item("ami_orig", "train")]))["environment"]["app_revision"]
        self.assertTrue(second.startswith(f"sha256:{binary}+"))
        self.assertNotEqual(first, second)

    def test_manifest_mismatch_stops_before_the_harness_runs(self) -> None:
        (self.fx.inputs / "ami_orig" / "fingerprints.json").write_text("tampered")
        with self.assertRaisesRegex(adapter.AdapterError, "checksum mismatch"):
            adapter.run(self.fx.request([item("ami_orig", "train")]))
        self.assertEqual(self.fx.harness_runs(), [])

    def test_env_fallbacks_for_manifest_and_input_root(self) -> None:
        os.environ[adapter.MANIFEST_ENV] = str(self.fx.manifest)
        os.environ[adapter.INPUT_ROOT_ENV] = str(self.fx.inputs)
        request = self.fx.request([item("ami_orig", "train")])
        del request["bench_options"]["manifest"], request["bench_options"]["input_root"]
        self.assertIsNone(adapter.run(request)["items"][0]["error"])

    def test_missing_harness_is_a_request_error(self) -> None:
        request = self.fx.request([item("ami_orig", "train")], harness_binary=str(self.fx.root / "nope"))
        with self.assertRaisesRegex(adapter.AdapterError, "harness binary missing"):
            adapter.run(request)

    def test_report_shape_is_checked(self) -> None:
        os.environ["FAKE_HARNESS_SCHEMA"] = "2"
        row = adapter.run(self.fx.request([item("ami_orig", "train")]))["items"][0]
        self.assertIn("schemaVersion 2", row["error"])
        os.environ["FAKE_HARNESS_SCHEMA"] = "3"
        os.environ["FAKE_HARNESS_MANGLE"] = "1"
        row = adapter.run(self.fx.request([item("ami_orig", "train")]))["items"][0]
        self.assertIn("does not match", row["error"])

    def test_command_line_writes_a_valid_result(self) -> None:
        items = [item("ami_orig", "train"), item("ami_orig", "dev")]
        request = self.fx.request(items)
        request_path = self.fx.work / "request.json"
        request_path.write_text(json.dumps(request))
        completed = subprocess.run(
            [sys.executable, str(HERE / "speaker_autoeval.py"), "--request", str(request_path)],
            capture_output=True, text=True, env=dict(os.environ),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(Path(request["result_path"]).read_text())
        self.assertEqual(validate_result(result, [i["id"] for i in items]), [])

    def test_command_line_rejects_unknown_knob(self) -> None:
        request = self.fx.request([item("ami_orig", "train")], knobs={"speaker.naming.bogus": 1})
        request_path = self.fx.work / "request.json"
        request_path.write_text(json.dumps(request))
        completed = subprocess.run(
            [sys.executable, str(HERE / "speaker_autoeval.py"), "--request", str(request_path)],
            capture_output=True, text=True, env=dict(os.environ),
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("unknown knob", completed.stderr)
        self.assertFalse(Path(request["result_path"]).exists())


class SuiteFileTests(unittest.TestCase):
    def test_suite_pins_harness_holdout_to_climber_holdout(self) -> None:
        raw = json.loads(SUITE_PATH.read_text())
        suite = Suite.from_dict(raw)
        self.assertEqual(check_split_health(suite), [])
        for entry in raw["items"]:
            with self.subTest(item=entry["id"]):
                self.assertIn(entry["harness_split"], adapter.HARNESS_SPLITS)
                expected = HOLDOUT if entry["harness_split"] == "holdout" else DEV
                self.assertEqual(entry["split"], expected)
                self.assertIsNone(adapter.item_problem(entry, expected))
        self.assertIn("ladder-fingerprints", raw["notes"])


if __name__ == "__main__":
    unittest.main()
