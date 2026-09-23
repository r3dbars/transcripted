#!/usr/bin/env python3
"""Tests for the speaker-lab bench adapter (runs on Linux, no Swift, no audio).

Run: python3 scripts/hillclimb/benches/speaker_lab.py --self-test
  or python3 scripts/hillclimb/benches/test_speaker_lab.py

Two layers:
* a fake driver (stands in for run_speaker_lab.sh) that records argv/env and writes a
  scores.json + recognition-events.json whose outcomes depend on the knobs, and
* the REAL run_speaker_lab.sh + score_speaker_lab.py driven by the fake harness from
  scripts/test_score_speaker_lab.py, so the adapter is checked against the real schema.

Works before and after the hill-climb lab (scripts/hillclimb/hc_*.py, config/hillclimb/*)
lands on this branch: registry/suite checks use the real hc_registry / hc_splits when they
import, and a local mirror of their rules otherwise.
"""

from __future__ import annotations

import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import speaker_lab as adapter  # noqa: E402

try:
    import hc_registry  # noqa: E402
except ImportError:  # pragma: no cover - before the hill-climb lab merges
    hc_registry = None
try:
    from hc_splits import Suite, check_split_health  # noqa: E402
except ImportError:  # pragma: no cover
    Suite = check_split_health = None

validate_result = adapter.validate_result
RESULT_SCHEMA = adapter.RESULT_SCHEMA
SUITE_PATH = REPO_ROOT / "config" / "hillclimb" / "suites" / "speaker-lab-ami.json"
README_PATH = HERE / "speaker_lab.README.md"
DOWNLOADER = REPO_ROOT / "scripts" / "download_ami.sh"
REAL_DRIVER = REPO_ROOT / "scripts" / "run_speaker_lab.sh"

# ---------------------------------------------------------------- fake driver

FAKE_DRIVER = textwrap.dedent(
    r'''
    import json, os, re, sys
    args = sys.argv[1:]
    WATCH = ("MATCH", "SERIES", "VARIANTS", "BACKEND", "DEDUP", "OUT_DIR", "HARNESS_BIN", "LAB_DATA_DIR",
             "ALLOW_PARTIAL_CORPUS", "TRANSCRIPTED_NEMOTRON_PRESET", "TRANSCRIPTED_SPEAKER_EMBEDDER",
             "TRANSCRIPTED_DIARIZATION_BACKEND", "TRANSCRIPTED_DISABLE_FILE_LOGGER", "EMBEDDING_PARITY")
    with open(os.environ["FAKE_LAB_LOG"], "a") as log:
        log.write(json.dumps({"argv": args, "env": {k: os.environ.get(k) for k in WATCH}}) + "\n")
    if os.environ.get("FAKE_LAB_FAIL"):
        sys.stderr.write("==> dump pyannote-wespeaker\nerror: dump failures (fix them)\n")
        sys.exit(1)
    def val(flag, default=None):
        return args[args.index(flag) + 1] if flag in args else default
    assert "--single" in args and "--skip-build" in args, args
    assert val("--corpus") == "ami"
    data = os.environ["LAB_DATA_DIR"]
    rttm_dir = os.path.join(data, "ami", "rttm")
    series = val("--series").split()
    match = val("--match", "adaptive")
    blend = float(val("--blend-confident", "0.15"))
    no_returning = os.environ.get("FAKE_LAB_NO_RETURNING", "").split()
    false_match = os.environ.get("FAKE_LAB_FALSE_MATCH", "").split()
    meetings, events, pipe, raw = [], [], [], []
    for s in series:
        sessions = sorted(n[:-5] for n in os.listdir(rttm_dir) if re.match("^" + s + "[a-z][.]rttm$", n))
        for i, m in enumerate(sessions):
            meetings.append(m)
            pipe.append({"meeting": m, "der": 0.1 + 0.01 * i, "refSpeakers": 4,
                         "hypSpeakers": 5 if (match != "adaptive" and float(match) < 0.5) else 4,
                         "countError": 1 if (match != "adaptive" and float(match) < 0.5) else 0})
            raw.append({"meeting": m, "der": 0.2, "refSpeakers": 4, "rawSpeakers": 3, "countError": -1})
            if i > 0 and s in no_returning:
                continue
            for spk in "ABCD":
                if i == 0:
                    outcome = "false_match" if (s in false_match and spk == "A") else "new_ok"
                elif match != "adaptive" and float(match) >= 0.7:
                    outcome = "asked_again"
                elif blend > 0.3 and spk == "A":
                    outcome = "wrong_person"
                elif spk == "D" and i == 1:
                    outcome = "undetected"
                else:
                    outcome = "recognized"
                events.append({"meeting": m, "speaker": s + "_" + spk, "returning": i > 0,
                               "outcome": outcome, "speechSeconds": 30.0})
    knobs = {
        "match": "adaptive" if match == "adaptive" else round(float(match), 4),
        "sameVoice": float(val("--same-voice", "0.88")),
        "dedup": float(val("--dedup", "0.6")) + (0.1 if os.environ.get("FAKE_LAB_MANGLE") else 0.0),
        "writePathFixes": val("--write-path-fixes", "on") == "on",
        "blendConfident": blend,
        "blendCautious": float(val("--blend-cautious", "0.05")),
        "writebackConfidentSim": float(val("--writeback-confident-sim", "0.8")),
        "writebackCautiousSim": float(val("--writeback-cautious-sim", "0.72")),
        "writebackMargin": float(val("--writeback-margin", "0.12")),
        "consolidation": None, "thresholds": "weSpeaker",
    }
    backend, embedder, preset = val("--backend", "pyannote"), val("--embedder", "native"), val("--preset")
    reported_preset = preset or (os.environ.get("FAKE_LAB_REPORT_PRESET") if backend == "nemotron" else None)
    name = backend + "-" + ("eres2net" if embedder == "eres2net" else "wespeaker") + ("-" + preset if preset else "")
    tag = "fake-setting"
    scores = {"schema": "transcripted.speaker-lab.scores",
              "schemaVersion": int(os.environ.get("FAKE_LAB_SCHEMA_VERSION", "1")),
              "mode": "corpus", "single": True, "corpus": "ami", "collar": 0.25,
              "minAppearanceSeconds": float(val("--min-appearance-sec", "5")),
              "wrongPenalty": float(val("--wrong-penalty", "2")), "gitRevision": "fake", "gitDirty": False,
              "meetings": meetings,
              "variants": [{"name": name, "backend": backend, "embedder": embedder, "nemotronPreset": reported_preset,
                            "meetingsScored": len(meetings), "raw": {"perMeeting": raw},
                            "settings": [{"tag": tag, "knobs": knobs, "perMeeting": pipe}]}]}
    out = val("--out-dir")
    os.makedirs(out, exist_ok=True)
    json.dump(scores, open(os.path.join(out, "scores.json"), "w"))
    json.dump({name: {tag: events}}, open(os.path.join(out, "recognition-events.json"), "w"))
    sys.stderr.write("==> score\n")
    print("progress line that is not the path")
    print(os.path.join(out, "scores.json"))
    '''
)


def item(series: str, split: str = "dev") -> dict[str, Any]:
    return {"id": f"ami-{series}", "corpus": "ami", "series": series, "split": split}


def write_session(data: Path, meeting: str, *, audio: bool = True, rttm_text: str | None = None) -> None:
    rttm = data / "ami" / "rttm" / f"{meeting}.rttm"
    rttm.parent.mkdir(parents=True, exist_ok=True)
    rttm.write_text(rttm_text if rttm_text is not None else f"SPEAKER {meeting} 1 0.0 30.0 <NA> <NA> A <NA> <NA>\n")
    if audio:
        wav = data / "ami" / "audio" / f"{meeting}{adapter.AUDIO_SUFFIX}"
        wav.parent.mkdir(parents=True, exist_ok=True)
        wav.write_bytes(b"RIFF" + meeting.encode() * 10)


class Fixture:
    """Temp dir: fake driver, fake harness binary, and an AMI-shaped data dir."""

    def __init__(self, root: Path):
        self.root = root
        self.data = root / "data"
        for series in ("ES2002", "ES2003"):
            for session in "abcd":
                write_session(self.data, series + session)
        for session in "abc":  # some AMI series really do miss a session
            write_session(self.data, "IS1000" + session)
        write_session(self.data, "TS3003a")
        write_session(self.data, "TS3003b", audio=False)
        write_session(self.data, "TS3004a")  # only one session
        self.harness = root / "speaker-eval-harness"
        self.harness.write_text("#!/bin/sh\nexit 0\n")
        self.harness.chmod(self.harness.stat().st_mode | stat.S_IXUSR)
        (root / "fake_driver.py").write_text(FAKE_DRIVER)
        self.driver = root / "run_speaker_lab.sh"
        self.driver.write_text(f'#!/bin/bash\nexec "{sys.executable}" "{root / "fake_driver.py"}" "$@"\n')
        self.log = root / "driver.log"
        self.work = root / "work"
        self.work.mkdir()
        os.environ["FAKE_LAB_LOG"] = str(self.log)

    def request(self, items: list[dict], *, split: str = "dev", knobs: dict | None = None, **options: Any) -> dict:
        bench_options = {"driver": str(self.driver), "harness_binary": str(self.harness), "data_dir": str(self.data)}
        bench_options.update(options)
        return {
            "schema": "transcripted.hillclimb.request.v1",
            "trial_id": "t0001",
            "objective": "speaker-lab-recognition",
            "suite": "speaker-lab-ami",
            "split": split,
            "repetition": 0,
            "knobs": knobs if knobs is not None else {},
            "items": items,
            "bench_options": bench_options,
            "result_path": str(self.work / "result.json"),
        }

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    def last_argv(self) -> list[str]:
        return self.calls()[-1]["argv"]


def flag(argv: list[str], name: str) -> str | None:
    return argv[argv.index(name) + 1] if name in argv else None


class AdapterTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._env = dict(os.environ)
        self._tmp = tempfile.TemporaryDirectory()
        self.fx = Fixture(Path(self._tmp.name))

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()


# ---------------------------------------------------------------- knob mapping


class KnobMappingTests(unittest.TestCase):
    def test_empty_knobs_pass_only_the_production_variant(self) -> None:
        flags, expected, ignored = adapter.build_invocation({})
        self.assertEqual(flags, ["--backend", "pyannote", "--embedder", "native", "--match", "adaptive"])
        self.assertEqual(expected, {"backend": "pyannote", "embedder": "native", "nemotronPreset": None,
                                    "match": "adaptive"})
        self.assertEqual(ignored, [])

    def test_every_knob_reaches_its_flag(self) -> None:
        flags, expected, ignored = adapter.build_invocation({
            "diarization.backend": "nemotron",
            "diarization.nemotron.preset": "fast32",
            "speaker.embedder": "eres2net",
            "speaker.match.mode": "fixed",
            "speaker.match.fixed_floor": 0.55,
            "speaker.cluster.same_voice_consolidation.wespeaker": 0.9,
            "speaker.cluster.same_voice_consolidation.eres2net": 0.61,
            "speaker.profile.duplicate_merge_similarity_replay": 0.7,
            "speaker.writeback.path_fixes": False,
            "speaker.writeback.confident_blend_alpha": 0.1,
            "speaker.writeback.cautious_blend_alpha": 0,
            "speaker.writeback.confident_similarity": 0.84,
            "speaker.writeback.cautious_similarity": 0.68,
            "speaker.writeback.margin": 0.08,
        })
        pairs = dict(zip(flags[::2], flags[1::2]))
        self.assertEqual(pairs, {
            "--backend": "nemotron", "--preset": "fast32", "--embedder": "eres2net", "--match": "0.55",
            "--same-voice": "0.61", "--write-path-fixes": "off", "--dedup": "0.7", "--blend-confident": "0.1",
            "--blend-cautious": "0.0", "--writeback-confident-sim": "0.84", "--writeback-cautious-sim": "0.68",
            "--writeback-margin": "0.08",
        })
        self.assertEqual(expected["nemotronPreset"], "fast32")
        self.assertEqual(expected["sameVoice"], 0.61)
        self.assertIs(expected["writePathFixes"], False)
        self.assertEqual(ignored, ["speaker.cluster.same_voice_consolidation.wespeaker"])

    def test_default_preset_is_not_passed_and_preset_ignored_under_pyannote(self) -> None:
        flags, expected, ignored = adapter.build_invocation(
            {"diarization.backend": "nemotron", "diarization.nemotron.preset": "fast128"})
        self.assertNotIn("--preset", flags)
        self.assertIsNone(expected["nemotronPreset"])
        self.assertEqual(ignored, [])
        flags, _, ignored = adapter.build_invocation(
            {"diarization.backend": "pyannote", "diarization.nemotron.preset": "fast32"})
        self.assertNotIn("--preset", flags)
        self.assertEqual(ignored, ["diarization.nemotron.preset"])

    def test_match_floor_only_counts_in_fixed_mode(self) -> None:
        flags, _, ignored = adapter.build_invocation({"speaker.match.fixed_floor": 0.65})
        self.assertEqual(flag(flags, "--match"), "adaptive")
        self.assertEqual(ignored, ["speaker.match.fixed_floor"])
        with self.assertRaisesRegex(adapter.AdapterError, "needs speaker.match.fixed_floor"):
            adapter.build_invocation({"speaker.match.mode": "fixed"})

    def test_same_voice_follows_the_embedder(self) -> None:
        knobs = {"speaker.cluster.same_voice_consolidation.wespeaker": 0.86,
                 "speaker.cluster.same_voice_consolidation.eres2net": 0.63}
        flags, _, ignored = adapter.build_invocation(knobs)
        self.assertEqual(flag(flags, "--same-voice"), "0.86")
        self.assertEqual(ignored, ["speaker.cluster.same_voice_consolidation.eres2net"])

    def test_unknown_and_bad_values_rejected(self) -> None:
        with self.assertRaisesRegex(adapter.AdapterError, "unknown knob"):
            adapter.build_invocation({"speaker.naming.auto_similarity": 0.9})
        for knob, value in (
            ("diarization.backend", "sortformer"),
            ("diarization.nemotron.preset", "turbo"),  # would silently fall back to fast128
            ("speaker.embedder", "native"),
            ("speaker.match.mode", "fixed"),
            ("speaker.writeback.margin", True),
            ("speaker.writeback.margin", float("nan")),
            ("speaker.writeback.path_fixes", "on"),
        ):
            with self.subTest(knob=knob, value=value):
                with self.assertRaises(adapter.AdapterError):
                    adapter.build_invocation({knob: value})


# ---------------------------------------------------------------- runs (fake driver)


class RunTests(AdapterTestCase):
    def test_only_requested_series_reach_the_driver(self) -> None:
        items = [item("ES2003"), item("ES2002")]
        result = adapter.run(self.fx.request(items))
        self.assertEqual(len(self.fx.calls()), 1)
        argv = self.fx.last_argv()
        self.assertEqual(flag(argv, "--series"), "ES2002 ES2003")
        self.assertIn("--single", argv)
        self.assertIn("--skip-build", argv)
        self.assertEqual(flag(argv, "--corpus"), "ami")
        self.assertEqual(flag(argv, "--out-dir"), str(self.fx.work / "speaker-lab-run"))
        self.assertEqual([row["id"] for row in result["items"]], ["ami-ES2003", "ami-ES2002"])
        self.assertEqual(validate_result(result, [i["id"] for i in items]), [])
        self.assertEqual(result["schema"], RESULT_SCHEMA)
        self.assertEqual(result["bench"], "speaker-lab")
        self.assertEqual(result["environment"]["series"], ["ES2002", "ES2003"])
        self.assertEqual(result["environment"]["meetings"], 8)

    def test_per_series_metrics_and_int_gates(self) -> None:
        os.environ["FAKE_LAB_FALSE_MATCH"] = "ES2003"
        result = adapter.run(self.fx.request([item("ES2002"), item("ES2003")],
                                             knobs={"speaker.writeback.confident_blend_alpha": 0.35}))
        rows = {row["id"]: row for row in result["items"]}
        for row in rows.values():
            self.assertIsNone(row["error"])
            self.assertEqual(sorted(row["gates"]), ["new_person_false_match", "wrong_person"])
            for value in row["gates"].values():
                self.assertIs(type(value), int)
        es2002 = rows["ami-ES2002"]
        # sessions b-d: 12 returning appearances; A is wrong every time (blend > 0.3), D undetected in b
        self.assertEqual(es2002["metrics"]["returning_appearances"], 12)
        self.assertEqual(es2002["metrics"]["recognized"], 8)
        self.assertEqual(es2002["metrics"]["undetected"], 1)
        self.assertEqual(es2002["metrics"]["asked_again"], 0)
        self.assertEqual(es2002["metrics"]["first_appearances"], 4)
        self.assertAlmostEqual(es2002["metrics"]["recognition_rate"], 8 / 12)
        self.assertEqual(es2002["gates"], {"wrong_person": 3, "new_person_false_match": 0})
        self.assertAlmostEqual(es2002["metrics"]["pipeline_der"], (0.10 + 0.11 + 0.12 + 0.13) / 4)
        self.assertAlmostEqual(es2002["metrics"]["raw_der"], 0.2)
        self.assertEqual(es2002["metrics"]["speaker_count_abs_error"], 0)
        self.assertEqual(es2002["metrics"]["raw_speaker_count_abs_error"], 1)
        self.assertAlmostEqual(es2002["metrics"]["objective"], 8 / 12 - 2 * (3 / 12))
        self.assertEqual(rows["ami-ES2003"]["gates"], {"wrong_person": 3, "new_person_false_match": 1})
        self.assertAlmostEqual(rows["ami-ES2003"]["metrics"]["objective"], 8 / 12 - 2 * (3 / 12 + 1 / 4))

    def test_knobs_move_the_numbers(self) -> None:
        strict = adapter.run(self.fx.request([item("ES2002")], knobs={
            "speaker.match.mode": "fixed", "speaker.match.fixed_floor": 0.75}))["items"][0]
        self.assertEqual(strict["metrics"]["recognition_rate"], 0.0)
        self.assertEqual(strict["metrics"]["asked_again"], 12)
        self.assertEqual(flag(self.fx.last_argv(), "--match"), "0.75")
        loose = adapter.run(self.fx.request([item("ES2002")], knobs={
            "speaker.match.mode": "fixed", "speaker.match.fixed_floor": 0.45}))["items"][0]
        self.assertEqual(loose["metrics"]["speaker_count_abs_error"], 1)

    def test_missing_or_incomplete_series_are_item_errors_not_zeros(self) -> None:
        items = [item("ES2002"), item("ES2005"), item("TS3003"), item("TS3004"), item("IS1000")]
        result = adapter.run(self.fx.request(items))
        rows = {row["id"]: row for row in result["items"]}
        self.assertIsNone(rows["ami-ES2002"]["error"])
        self.assertIsNone(rows["ami-IS1000"]["error"])  # 3 sessions is fine
        self.assertIn("not downloaded", rows["ami-ES2005"]["error"])
        self.assertIn("no audio for TS3003b", rows["ami-TS3003"]["error"])
        self.assertIn("only 1 session", rows["ami-TS3004"]["error"])
        for bad in ("ami-ES2005", "ami-TS3003", "ami-TS3004"):
            self.assertEqual(rows[bad]["metrics"], {})
            self.assertEqual(rows[bad]["gates"], {})
        self.assertEqual(flag(self.fx.last_argv(), "--series"), "ES2002 IS1000")
        self.assertEqual(rows["ami-IS1000"]["metrics"]["returning_appearances"], 8)
        self.assertEqual(validate_result(result, list(rows)), [])

    def test_no_runnable_series_never_calls_the_driver(self) -> None:
        result = adapter.run(self.fx.request([item("ES2005")]))
        self.assertEqual(self.fx.calls(), [])
        self.assertIn("not downloaded", result["items"][0]["error"])
        self.assertIsNone(result["environment"]["lab_seconds"])

    def test_series_without_returning_speakers_is_an_item_error(self) -> None:
        os.environ["FAKE_LAB_NO_RETURNING"] = "ES2003"
        rows = {r["id"]: r for r in adapter.run(self.fx.request([item("ES2002"), item("ES2003")]))["items"]}
        self.assertIsNone(rows["ami-ES2002"]["error"])
        self.assertIn("no returning speaker", rows["ami-ES2003"]["error"])
        self.assertEqual(rows["ami-ES2003"]["metrics"], {})

    def test_bad_items_and_split_leaks(self) -> None:
        items = [item("ES2002"), item("ES2003", split="holdout"), {"id": "x", "corpus": "icsi", "series": "ES2002"},
                 {"id": "y", "corpus": "ami", "series": "es2002"}, {"id": "dup", "corpus": "ami", "series": "ES2002"}]
        rows = {r["id"]: r for r in adapter.run(self.fx.request(items))["items"]}
        self.assertIsNone(rows["ami-ES2002"]["error"])
        self.assertIn("may not be measured", rows["ami-ES2003"]["error"])
        self.assertIn("corpus must be 'ami'", rows["x"]["error"])
        self.assertIn("AMI series id", rows["y"]["error"])
        self.assertIn("requested twice", rows["dup"]["error"])
        self.assertEqual(flag(self.fx.last_argv(), "--series"), "ES2002")

    def test_lab_failure_errors_every_runnable_item(self) -> None:
        os.environ["FAKE_LAB_FAIL"] = "1"
        result = adapter.run(self.fx.request([item("ES2002"), item("ES2003"), item("ES2005")]))
        rows = {r["id"]: r for r in result["items"]}
        for series in ("ES2002", "ES2003"):
            self.assertIn("speaker lab exited 1", rows[f"ami-{series}"]["error"])
            self.assertIn("dump failures", rows[f"ami-{series}"]["error"])
        self.assertIn("not downloaded", rows["ami-ES2005"]["error"])
        self.assertTrue((self.fx.work / "speaker-lab.stderr.log").exists())

    def test_knob_echo_and_schema_are_checked(self) -> None:
        os.environ["FAKE_LAB_MANGLE"] = "1"
        row = adapter.run(self.fx.request([item("ES2002")], knobs={
            "speaker.profile.duplicate_merge_similarity_replay": 0.7}))["items"][0]
        self.assertIn("did not use the requested knobs", row["error"])
        self.assertIn("dedup", row["error"])
        del os.environ["FAKE_LAB_MANGLE"]
        os.environ["FAKE_LAB_SCHEMA_VERSION"] = "2"
        row = adapter.run(self.fx.request([item("ES2002")]))["items"][0]
        self.assertIn("schema", row["error"])

    def test_shell_exports_never_leak_into_the_trial(self) -> None:
        for key, value in {"MATCH": "0.9", "SERIES": "TS3003", "VARIANTS": "nemotron:eres2net",
                           "DEDUP": "0.9", "OUT_DIR": "/tmp/elsewhere", "ALLOW_PARTIAL_CORPUS": "1",
                           "TRANSCRIPTED_NEMOTRON_PRESET": "offline", "TRANSCRIPTED_SPEAKER_EMBEDDER": "eres2net",
                           "TRANSCRIPTED_DIARIZATION_BACKEND": "nemotron", "HARNESS_BIN": "/nope",
                           "EMBEDDING_PARITY": "1"}.items():
            os.environ[key] = value
        row = adapter.run(self.fx.request([item("ES2002")]))["items"][0]
        self.assertIsNone(row["error"])
        env = self.fx.calls()[-1]["env"]
        for key in ("MATCH", "SERIES", "VARIANTS", "DEDUP", "OUT_DIR", "TRANSCRIPTED_NEMOTRON_PRESET",
                    "TRANSCRIPTED_SPEAKER_EMBEDDER", "TRANSCRIPTED_DIARIZATION_BACKEND", "EMBEDDING_PARITY"):
            self.assertIsNone(env[key], key)
        self.assertNotIn("--embedding-parity", self.fx.last_argv())
        self.assertEqual(env["HARNESS_BIN"], str(self.fx.harness))
        self.assertEqual(env["LAB_DATA_DIR"], str(self.fx.data))
        self.assertEqual(env["ALLOW_PARTIAL_CORPUS"], "0")
        self.assertEqual(env["TRANSCRIPTED_DISABLE_FILE_LOGGER"], "1")

    def test_scoring_options_are_forwarded(self) -> None:
        row = adapter.run(self.fx.request([item("ES2002")], knobs={"speaker.writeback.confident_blend_alpha": 0.35},
                                          collar=0.5, min_appearance_sec=3, wrong_penalty=4))["items"][0]
        argv = self.fx.last_argv()
        self.assertEqual((flag(argv, "--collar"), flag(argv, "--min-appearance-sec"), flag(argv, "--wrong-penalty")),
                         ("0.5", "3", "4"))
        self.assertAlmostEqual(row["metrics"]["objective"], 8 / 12 - 4 * (3 / 12))

    def test_app_revision_binds_harness_corpus_and_lab_scripts(self) -> None:
        request = self.fx.request([item("ES2002")])
        first = adapter.run(request)["environment"]["app_revision"]
        self.assertRegex(first, r"^sha256:[0-9a-f]{16}\+[0-9a-f]{12}\+[0-9a-f]{8}$")
        self.assertEqual(adapter.run(request)["environment"]["app_revision"], first)
        self.fx.harness.write_text("#!/bin/sh\n# rebuilt\nexit 0\n")
        second = adapter.run(request)["environment"]["app_revision"]
        self.assertNotEqual(first, second)
        write_session(self.fx.data, "ES2002b", rttm_text="SPEAKER ES2002b 1 0.0 31.0 <NA> <NA> A <NA> <NA>\n")
        third = adapter.run(request)["environment"]["app_revision"]
        self.assertNotEqual(second, third)
        self.assertEqual(third.split("+")[0], second.split("+")[0])
        self.fx.driver.write_text(self.fx.driver.read_text() + "# edited\n")
        fourth = adapter.run(request)["environment"]["app_revision"]
        self.assertNotEqual(third, fourth)

    def test_missing_harness_or_driver_is_a_request_error(self) -> None:
        with self.assertRaisesRegex(adapter.AdapterError, "harness binary missing"):
            adapter.run(self.fx.request([item("ES2002")], harness_binary=str(self.fx.root / "nope")))
        with self.assertRaisesRegex(adapter.AdapterError, "driver missing"):
            adapter.run(self.fx.request([item("ES2002")], driver=str(self.fx.root / "nope.sh")))

    def test_default_preset_spellings_are_one_variant(self) -> None:
        # the scorer treats unset / "default" / fast128 as the same Nemotron preset
        knobs = {"diarization.backend": "nemotron", "diarization.nemotron.preset": "fast128"}
        for reported in ("", "default", "fast128"):
            with self.subTest(reported=reported):
                os.environ["FAKE_LAB_REPORT_PRESET"] = reported
                row = adapter.run(self.fx.request([item("ES2002")], knobs=knobs))["items"][0]
                self.assertIsNone(row["error"])
                self.assertNotIn("--preset", self.fx.last_argv())
        os.environ["FAKE_LAB_REPORT_PRESET"] = "fast32"
        row = adapter.run(self.fx.request([item("ES2002")], knobs=knobs))["items"][0]
        self.assertIn("nemotronPreset", row["error"])
        self.assertEqual(adapter.normalized_preset(None), "fast128")
        self.assertEqual(adapter.normalized_preset(" default "), "fast128")

    def test_ignored_knobs_are_reported(self) -> None:
        env = adapter.run(self.fx.request([item("ES2002")], knobs={"diarization.nemotron.preset": "fast32"}))
        self.assertEqual(env["environment"]["ignored_knobs"], ["diarization.nemotron.preset"])
        self.assertNotIn("--preset", self.fx.last_argv())

    def test_command_line_writes_a_valid_result(self) -> None:
        items = [item("ES2002"), item("ES2005")]
        request = self.fx.request(items, knobs={"diarization.backend": "nemotron"})
        request_path = self.fx.work / "request.json"
        request_path.write_text(json.dumps(request))
        completed = subprocess.run([sys.executable, str(HERE / "speaker_lab.py"), "--request", str(request_path)],
                                   capture_output=True, text=True, env=dict(os.environ))
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(Path(request["result_path"]).read_text())
        self.assertEqual(validate_result(result, [i["id"] for i in items]), [])
        self.assertEqual(result["environment"]["variant"], "nemotron-wespeaker")

    def test_command_line_rejects_unknown_knob(self) -> None:
        request = self.fx.request([item("ES2002")], knobs={"speaker.naming.bogus": 1})
        request_path = self.fx.work / "request.json"
        request_path.write_text(json.dumps(request))
        completed = subprocess.run([sys.executable, str(HERE / "speaker_lab.py"), "--request", str(request_path)],
                                   capture_output=True, text=True, env=dict(os.environ))
        self.assertEqual(completed.returncode, 2)
        self.assertIn("unknown knob", completed.stderr)
        self.assertFalse(Path(request["result_path"]).exists())


class ProtocolTests(unittest.TestCase):
    def test_validator_flags_bad_gates_and_metrics(self) -> None:
        good = {"schema": RESULT_SCHEMA, "items": [{"id": "a", "metrics": {"m": 1.0}, "gates": {"g": 0}}]}
        self.assertEqual(validate_result(good, ["a"]), [])
        for bad_item in ({"id": "a", "gates": {"g": 1.0}}, {"id": "a", "gates": {"g": -1}},
                         {"id": "a", "gates": {"g": True}}, {"id": "a", "metrics": {"m": math.inf}}):
            with self.subTest(item=bad_item):
                self.assertTrue(validate_result({"schema": RESULT_SCHEMA, "items": [bad_item]}, ["a"]))
        self.assertTrue(validate_result(good, ["b"]))


# ---------------------------------------------------------------- real driver + fake harness


@unittest.skipUnless(shutil.which("bash") and REAL_DRIVER.is_file(), "needs bash and run_speaker_lab.sh")
class RealDriverTests(unittest.TestCase):
    """The adapter against the real run_speaker_lab.sh + score_speaker_lab.py."""

    def setUp(self) -> None:
        import test_score_speaker_lab  # scripts/, carries the fake harness the lab's own tests use
        self._env = dict(os.environ)
        self._tmp = tempfile.TemporaryDirectory()
        root = Path(self._tmp.name)
        self.data = root / "data"
        for series in ("ES2002", "ES2003"):
            for session in "abc":
                meeting = series + session
                rttm = "".join(
                    f"SPEAKER {meeting} 1 {start:.3f} 30.000 <NA> <NA> {series}_{label} <NA> <NA>\n"
                    for start, label in ((0, "A"), (30, "B"), (60, "C")))
                write_session(self.data, meeting, rttm_text=rttm)
        self.harness = root / "fake-harness"
        self.harness.write_text(test_score_speaker_lab.FAKE_HARNESS)
        self.harness.chmod(0o755)
        for key in adapter.SCRUBBED_ENV:
            os.environ.pop(key, None)
        os.environ.update(FAKE_LOG=str(root / "calls.log"), FAKE_RTTM_DIR=str(self.data / "ami" / "rttm"),
                          HOME=str(root))
        self.work = root / "work"
        self.work.mkdir()

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self._env)
        self._tmp.cleanup()

    def test_end_to_end_with_real_scorer(self) -> None:
        items = [item("ES2002"), item("ES2003")]
        request = {
            "schema": "transcripted.hillclimb.request.v1", "trial_id": "t0001", "split": "dev", "repetition": 0,
            "knobs": {"speaker.writeback.confident_blend_alpha": 0.2,
                      "speaker.profile.duplicate_merge_similarity_replay": 0.65},
            "items": items,
            "bench_options": {"harness_binary": str(self.harness), "data_dir": str(self.data)},
            "result_path": str(self.work / "result.json"),
        }
        result = adapter.run(request)
        self.assertEqual(validate_result(result, [i["id"] for i in items]), [])
        rows = {r["id"]: r for r in result["items"]}
        for row in rows.values():
            self.assertIsNone(row["error"], row["error"])
        # the fake harness keeps profile ids p0..p2 for every meeting, so ES2002's people are
        # recognized and ES2003's are glued onto ES2002's profiles
        self.assertEqual(rows["ami-ES2002"]["metrics"]["recognition_rate"], 1.0)
        self.assertEqual(rows["ami-ES2002"]["metrics"]["returning_appearances"], 6)
        self.assertEqual(rows["ami-ES2002"]["gates"], {"wrong_person": 0, "new_person_false_match": 0})
        self.assertEqual(rows["ami-ES2003"]["metrics"]["recognition_rate"], 0.0)
        self.assertEqual(rows["ami-ES2003"]["gates"], {"wrong_person": 6, "new_person_false_match": 3})
        self.assertEqual(rows["ami-ES2002"]["metrics"]["pipeline_der"], 0.0)
        self.assertEqual(result["environment"]["variant"], "pyannote-wespeaker")
        calls = Path(os.environ["FAKE_LOG"]).read_text()
        self.assertIn("--blend-confident 0.2", calls)
        self.assertIn("--dedup 0.65", calls)
        self.assertIn("--match adaptive", calls)
        self.assertTrue(Path(result["environment"]["scores_path"]).is_file())


# ---------------------------------------------------------------- suite + registry snippets


def readme_blocks() -> dict[str, Any]:
    """The JSON snippets in speaker_lab.README.md, keyed by what they are."""
    blocks: dict[str, Any] = {}
    for raw in re.findall(r"```json\n(.*?)\n```", README_PATH.read_text(), flags=re.S):
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            blocks["new_knobs"] = parsed
        elif "kind" in parsed:
            blocks["bench"] = parsed
        elif "primary" in parsed:
            blocks["objective"] = parsed
        elif all(isinstance(v, dict) and "affects_add" in v for v in parsed.values()):
            blocks["knob_patches"] = parsed
        else:
            raise AssertionError(f"unrecognized README JSON block: {raw[:80]}")
    return blocks


def merged_registry_files(tmp: Path, blocks: dict[str, Any]) -> tuple[Path, Path] | None:
    """Apply the README snippets to the hill-climb lab's registry files, if they exist here."""
    knobs_path = REPO_ROOT / "config" / "hillclimb" / "knobs.json"
    objectives_path = REPO_ROOT / "config" / "hillclimb" / "objectives.json"
    if not (knobs_path.is_file() and objectives_path.is_file()):
        return None
    knobs = json.loads(knobs_path.read_text())
    objectives = json.loads(objectives_path.read_text())
    by_id = {k["id"]: k for k in knobs["knobs"]}
    for knob_id, patch in blocks["knob_patches"].items():
        entry = by_id[knob_id]
        if patch["affects_add"] not in entry["affects"]:
            entry["affects"].append(patch["affects_add"])
        if patch["apply_add"] not in entry["apply"]:
            entry["apply"].append(patch["apply_add"])
    knobs["knobs"] = [k for k in knobs["knobs"] if k["id"] not in {n["id"] for n in blocks["new_knobs"]}]
    knobs["knobs"].extend(blocks["new_knobs"])
    objectives["objectives"] = [o for o in objectives["objectives"] if o["id"] != blocks["objective"]["id"]]
    objectives["objectives"].append(blocks["objective"])
    out_knobs, out_objectives = tmp / "knobs.json", tmp / "objectives.json"
    out_knobs.write_text(json.dumps(knobs))
    out_objectives.write_text(json.dumps(objectives))
    return out_knobs, out_objectives


KNOB_KEYS = {"id", "area", "title", "type", "default", "choices", "min", "max", "step", "status", "apply",
             "affects", "source", "risk", "notes"}


class RegistrySnippetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.blocks = readme_blocks()

    def test_readme_has_every_snippet(self) -> None:
        self.assertEqual(sorted(self.blocks), ["bench", "knob_patches", "new_knobs", "objective"])

    def test_objective_knobs_are_exactly_what_the_adapter_maps(self) -> None:
        objective = self.blocks["objective"]
        new_ids = {k["id"] for k in self.blocks["new_knobs"]}
        patched = set(self.blocks["knob_patches"])
        self.assertEqual(new_ids | patched, set(adapter.KNOB_IDS))
        self.assertEqual(set(objective["knobs"]), set(adapter.KNOB_IDS) - {adapter.K_PATH_FIXES})
        self.assertEqual(sorted(objective["hard_gates"]), ["new_person_false_match", "wrong_person"])
        self.assertEqual(objective["bench"], self.blocks["bench"]["id"])
        self.assertEqual(self.blocks["bench"]["id"], adapter.BENCH_ID)
        self.assertEqual(objective["suite"], json.loads(SUITE_PATH.read_text())["id"])
        self.assertIn("speaker_lab.py", " ".join(self.blocks["bench"]["command"]))

    def test_new_knobs_match_the_registry_schema(self) -> None:
        for raw in self.blocks["new_knobs"]:
            with self.subTest(knob=raw["id"]):
                self.assertLessEqual(set(raw), KNOB_KEYS)
                self.assertIn("speaker-lab-recognition", raw["affects"])
                self.assertTrue(all(entry["via"] in ("env", "defaults", "bench-flag", "request")
                                    for entry in raw["apply"]))
                if raw["type"] == "enum":
                    self.assertIn(raw["default"], raw["choices"])
                if raw["id"] == adapter.K_PRESET:
                    self.assertEqual(tuple(raw["choices"]), adapter.NEMOTRON_PRESETS)
                if raw["id"] == adapter.K_BACKEND:
                    self.assertEqual(tuple(raw["choices"]), adapter.BACKENDS)
                if hc_registry is not None:
                    hc_registry.Knob.from_dict(raw)
                # every default maps cleanly
                adapter.build_invocation({raw["id"]: raw["default"]} if raw["id"] != adapter.K_MATCH_FLOOR
                                         else {adapter.K_MATCH_MODE: "fixed", raw["id"]: raw["default"]})

    def test_objective_matches_the_registry_schema(self) -> None:
        objective = self.blocks["objective"]
        self.assertGreater(objective["primary"]["min_effect"], 0)
        self.assertEqual(objective["primary"]["id"], "recognition_rate")
        if hc_registry is not None:
            hc_registry.Objective.from_dict(objective)

    def test_snippets_merge_into_the_real_registry(self) -> None:
        if hc_registry is None:
            self.skipTest("hc_registry not on this branch yet")
        with tempfile.TemporaryDirectory() as tmp:
            paths = merged_registry_files(Path(tmp), self.blocks)
            if paths is None:
                self.skipTest("config/hillclimb/knobs.json not on this branch yet")
            registry = hc_registry.load_registry(*paths)
            objective = registry.objectives["speaker-lab-recognition"]
            searchable = {k.id for k in registry.searchable_knobs(objective)}
            self.assertEqual(searchable, set(objective.knobs))
            defaults = registry.defaults(objective.knobs)
            flags, _, _ = adapter.build_invocation(defaults)
            self.assertEqual(flag(flags, "--backend"), "pyannote")
            self.assertEqual(flag(flags, "--match"), "adaptive")


class SuiteFileTests(unittest.TestCase):
    def test_suite_is_the_download_lab_set_with_a_site_stratified_holdout(self) -> None:
        raw = json.loads(SUITE_PATH.read_text())
        block = re.search(r"\n\s*lab\)(.*?);;", DOWNLOADER.read_text(), flags=re.S)
        self.assertIsNotNone(block, "download_ami.sh has no lab preset")
        lab_series = re.findall(r"\b[A-Z]{2}[0-9]{4}\b", block.group(1))
        self.assertEqual(sorted(i["series"] for i in raw["items"]), sorted(lab_series))
        splits = {i["series"]: i["split"] for i in raw["items"]}
        self.assertEqual(sum(1 for s in splits.values() if s == "holdout"), 4)
        for site in ("ES", "IS", "TS"):
            self.assertIn("holdout", {v for k, v in splits.items() if k.startswith(site)}, site)
            self.assertIn("dev", {v for k, v in splits.items() if k.startswith(site)}, site)
        for entry in raw["items"]:
            with self.subTest(item=entry["id"]):
                self.assertEqual(entry["id"], f"ami-{entry['series']}")
                self.assertIsNone(adapter.item_problem(entry, entry["split"]))
                other = "dev" if entry["split"] == "holdout" else "holdout"
                self.assertIsNotNone(adapter.item_problem(entry, other))
        self.assertTrue(0.0 < raw["holdout_fraction"] < 1.0)
        if Suite is not None:
            suite = Suite.from_dict(raw)
            self.assertEqual(check_split_health(suite), [])
            self.assertEqual(suite.counts(), {"dev": 12, "holdout": 4})


if __name__ == "__main__":
    unittest.main()
