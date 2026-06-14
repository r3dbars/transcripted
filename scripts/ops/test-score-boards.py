#!/usr/bin/env python3
"""Tests for the board scorecard engine and scorers.

Run: python3 scripts/ops/test-score-boards.py
These are pure-logic / CLI tests — no app, no Mac, no network.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

OPS_DIR = Path(__file__).resolve().parent
REPO_ROOT = OPS_DIR.parent.parent
FIXTURES = OPS_DIR / "fixtures" / "board-scorecard"

sys.path.insert(0, str(OPS_DIR))
import score_boards_lib as lib  # noqa: E402


def run(script: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(OPS_DIR / script), *args],
        capture_output=True, text=True,
    )


class ScoringMathTests(unittest.TestCase):
    def test_checks_to_dimension_score(self):
        self.assertEqual(lib.checks_to_dimension_score("ui", ["PASS", "PASS"]).score, 100.0)
        self.assertEqual(lib.checks_to_dimension_score("ui", ["PASS", "FAIL"]).score, 50.0)
        self.assertEqual(lib.checks_to_dimension_score("ui", ["WARN"]).score, 50.0)
        self.assertFalse(lib.checks_to_dimension_score("ui", []).present)

    def test_blend_renormalizes_over_present(self):
        dims = [
            lib.DimensionScore.scored("ui", 100.0),
            lib.DimensionScore.scored("functional", 0.0),
            lib.DimensionScore.missing("accuracy"),
        ]
        # equal weights over the two present dims -> 50, accuracy dropped
        score, _ = lib.blend_dimensions(dims, {"ui": 0.5, "functional": 0.5, "accuracy": 0.5})
        self.assertAlmostEqual(score, 50.0, places=1)
        # unequal weights renormalize over present dims only (accuracy excluded)
        score2, _ = lib.blend_dimensions(dims, {"ui": 0.34, "functional": 0.33, "accuracy": 0.33})
        self.assertAlmostEqual(score2, 34.0 / 0.67, places=1)

    def test_blend_none_when_no_evidence(self):
        score, _ = lib.blend_dimensions([lib.DimensionScore.missing("ui")], {})
        self.assertIsNone(score)

    def test_status_thresholds(self):
        self.assertEqual(lib.status_for_score(90, 85, 65), lib.STATUS_GREEN)
        self.assertEqual(lib.status_for_score(70, 85, 65), lib.STATUS_YELLOW)
        self.assertEqual(lib.status_for_score(50, 85, 65), lib.STATUS_RED)
        self.assertEqual(lib.status_for_score(None, 85, 65), lib.STATUS_INCOMPLETE)

    def test_overall_status_worst_auto_board_wins(self):
        boards = [
            lib.BoardScore("a", "A", "ui", "auto", 1.0, score=95, status=lib.STATUS_GREEN),
            lib.BoardScore("b", "B", "ui", "auto", 1.0, score=40, status=lib.STATUS_RED),
            lib.BoardScore("c", "C", "cap", "hardware", 1.0, score=None, status=lib.STATUS_INCOMPLETE),
        ]
        self.assertEqual(lib.overall_status(boards), lib.STATUS_RED)

    def test_overall_score_weighted(self):
        boards = [
            lib.BoardScore("a", "A", "ui", "auto", 1.0, score=100.0),
            lib.BoardScore("b", "B", "ui", "auto", 3.0, score=0.0),
        ]
        self.assertAlmostEqual(lib.overall_score(boards), 25.0, places=1)


class DiarizationScorerTests(unittest.TestCase):
    def test_perfect_diarization_scores_100(self):
        with tempfile.TemporaryDirectory() as tmp:
            seg = Path(tmp) / "seg.json"
            out = Path(tmp) / "score-diarization.json"
            seg.write_text(json.dumps({
                "reference": [{"speaker": "A", "start": 0, "end": 2}, {"speaker": "B", "start": 2, "end": 4}],
                "hypothesis": [{"speaker": "X", "start": 0, "end": 2}, {"speaker": "Y", "start": 2, "end": 4}],
            }))
            proc = run("score-diarization.py", "--segments", str(seg), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(out.read_text())
            self.assertEqual(data["score"], 100.0)

    def test_sample_fixture_penalizes_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "score-diarization.json"
            proc = run("score-diarization.py", "--segments", str(FIXTURES / "diarization-sample.json"), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(out.read_text())
            # one swapped label + boundary slips -> not perfect, but recognizable
            self.assertLess(data["score"], 100.0)
            self.assertGreater(data["score"], 40.0)


class DictationScorerTests(unittest.TestCase):
    def test_exact_candidate_scores_100(self):
        fixture = json.loads((FIXTURES / "dictation-corrections.json").read_text())
        candidate = {item["id"]: item["expected"] for item in fixture["items"]}
        with tempfile.TemporaryDirectory() as tmp:
            cand = Path(tmp) / "candidate.json"
            out = Path(tmp) / "score-dictation.json"
            cand.write_text(json.dumps(candidate))
            proc = run("score-dictation.py", "--fixture", str(FIXTURES / "dictation-corrections.json"),
                       "--candidate", str(cand), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(out.read_text())
            self.assertEqual(data["score"], 100.0)

    def test_missing_candidate_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "score-dictation.json"
            proc = run("score-dictation.py", "--fixture", str(FIXTURES / "dictation-corrections.json"), "--out", str(out))
            self.assertEqual(proc.returncode, 3)
            self.assertFalse(json.loads(out.read_text())["present"])


class DetectionScorerTests(unittest.TestCase):
    def test_perfect_detector_scores_100(self):
        fixture = json.loads((FIXTURES / "meeting-detection.json").read_text())
        candidate = {item["id"]: bool(item["should_prompt"]) for item in fixture["items"]}
        with tempfile.TemporaryDirectory() as tmp:
            cand = Path(tmp) / "candidate.json"
            out = Path(tmp) / "score-detection.json"
            cand.write_text(json.dumps(candidate))
            proc = run("score-detection.py", "--fixture", str(FIXTURES / "meeting-detection.json"),
                       "--candidate", str(cand), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(out.read_text())["score"], 100.0)

    def test_false_negative_drops_recall(self):
        fixture = json.loads((FIXTURES / "meeting-detection.json").read_text())
        candidate = {item["id"]: False for item in fixture["items"]}  # never fires
        with tempfile.TemporaryDirectory() as tmp:
            cand = Path(tmp) / "candidate.json"
            out = Path(tmp) / "score-detection.json"
            cand.write_text(json.dumps(candidate))
            run("score-detection.py", "--fixture", str(FIXTURES / "meeting-detection.json"),
                "--candidate", str(cand), "--out", str(out))
            data = json.loads(out.read_text())
            self.assertEqual(data["subscores"]["recall"], 0.0)


class SummaryJudgeTests(unittest.TestCase):
    def test_rubric_scores(self):
        with tempfile.TemporaryDirectory() as tmp:
            judge = Path(tmp) / "judge.json"
            out = Path(tmp) / "score-summary.json"
            judge.write_text(json.dumps({"meetings": [
                {"id": "m1", "rubric": {"coverage": 5, "faithfulness": 5, "actionItems": 5, "conciseness": 5}},
                {"id": "m2", "rubric": {"coverage": 3, "faithfulness": 4, "actionItems": 2, "conciseness": 5}},
            ]}))
            proc = run("score-summary-judge.py", "--mode", "score", "--judge-result", str(judge), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(out.read_text())
            self.assertTrue(data["present"])
            self.assertGreater(data["score"], 60.0)
            self.assertLess(data["score"], 100.0)

    def test_single_prompt_result_scores(self):
        with tempfile.TemporaryDirectory() as tmp:
            judge = Path(tmp) / "judge.json"
            out = Path(tmp) / "score-summary.json"
            judge.write_text(json.dumps(
                {"id": "m1", "rubric": {"coverage": 5, "faithfulness": 5, "actionItems": 5, "conciseness": 5}}
            ))
            proc = run("score-summary-judge.py", "--mode", "score", "--judge-result", str(judge), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(out.read_text())
            self.assertTrue(data["present"])
            self.assertEqual(data["score"], 100.0)

    def test_invalid_judge_json_is_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            judge = Path(tmp) / "judge.json"
            out = Path(tmp) / "score-summary.json"
            judge.write_text("{")
            proc = run("score-summary-judge.py", "--mode", "score", "--judge-result", str(judge), "--out", str(out))
            self.assertEqual(proc.returncode, 3, proc.stderr)
            data = json.loads(out.read_text())
            self.assertFalse(data["present"])

    def test_non_numeric_rubric_value_does_not_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            judge = Path(tmp) / "judge.json"
            out = Path(tmp) / "score-summary.json"
            judge.write_text(json.dumps(
                {"id": "m1", "rubric": {"coverage": "good", "faithfulness": 5, "actionItems": 5, "conciseness": 5}}
            ))
            proc = run("score-summary-judge.py", "--mode", "score", "--judge-result", str(judge), "--out", str(out))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(out.read_text())
            self.assertTrue(data["present"])


class AggregatorTests(unittest.TestCase):
    def _registry(self) -> str:
        return str(REPO_ROOT / ".agents" / "board-scorecard.yml")

    def test_end_to_end_scorecard(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            # functional report: a couple of transcript checks pass
            (tmp / "functional.json").write_text(json.dumps({"results": [
                {"check": "transcript/dictation-format", "status": "PASS", "target": "x"},
                {"check": "transcript/speaker-attribution", "status": "PASS", "target": "x"},
                {"check": "transcript/timestamps", "status": "WARN", "target": "x"},
            ]}))
            # ui report: general controls visible
            (tmp / "ui.json").write_text(json.dumps({"results": [
                {"check": "ui/general.dictationMode", "status": "PASS", "target": "x"},
            ]}))
            # accuracy inputs
            (tmp / "score-transcription.json").write_text(json.dumps(
                {"board": "transcription", "present": True, "score": 88.0, "detail": "recall 88%"}))
            (tmp / "score-diarization.json").write_text(json.dumps(
                {"board": "diarization", "present": True, "score": 70.0, "detail": "DER 30%"}))

            out_json = tmp / "scorecard.json"
            out_md = tmp / "scorecard.md"
            proc = run("score-boards.py",
                       "--registry", self._registry(),
                       "--ui-json", str(tmp / "ui.json"),
                       "--functional-json", str(tmp / "functional.json"),
                       "--accuracy-dir", str(tmp),
                       "--json-out", str(out_json),
                       "--markdown-out", str(out_md))
            # incomplete/yellow expected (many boards lack evidence) -> exit 3 or 1
            self.assertIn(proc.returncode, (0, 1, 3), proc.stderr)
            payload = json.loads(out_json.read_text())
            boards = {b["id"]: b for b in payload["boards"]}

            # transcription board: functional + accuracy present -> scored
            self.assertIsNotNone(boards["transcription"]["score"])
            # hardware board stays unscored / incomplete, not red
            self.assertEqual(boards["meeting-capture"]["automatable"], "hardware")
            self.assertIsNone(boards["meeting-capture"]["score"])
            # markdown report exists and is non-empty
            self.assertTrue(out_md.read_text().startswith("# Transcripted Board Scorecard"))

    def test_ui_smoke_checks_shape_maps_id_to_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            registry = tmp / "registry.yml"
            registry.write_text("""
version: 1
defaults:
  weights:
    ui: 1.0
  thresholds:
    green: 85
    yellow: 65
boards:
  - id: home
    name: Home
    category: ui
    automatable: auto
    weight: 1.0
    ui:
      check_globs: ['settings-home']
""")
            (tmp / "ui.json").write_text(json.dumps({"checks": [
                {"id": "settings-home", "title": "Home", "status": "PASS", "target": "transcripted.home"}
            ]}))

            out_json = tmp / "scorecard.json"
            out_md = tmp / "scorecard.md"
            proc = run("score-boards.py",
                       "--registry", str(registry),
                       "--ui-json", str(tmp / "ui.json"),
                       "--json-out", str(out_json),
                       "--markdown-out", str(out_md))
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            payload = json.loads(out_json.read_text())
            self.assertEqual(payload["boards"][0]["score"], 100.0)

    def test_invalid_report_json_is_incomplete_not_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            registry = tmp / "registry.yml"
            registry.write_text("""
version: 1
defaults:
  weights:
    functional: 1.0
  thresholds:
    green: 85
    yellow: 65
boards:
  - id: home
    name: Home
    category: ui
    automatable: auto
    weight: 1.0
    functional:
      check_globs: ["index/*"]
""")
            (tmp / "functional.json").write_text("{")

            out_json = tmp / "scorecard.json"
            out_md = tmp / "scorecard.md"
            proc = run("score-boards.py",
                       "--registry", str(registry),
                       "--functional-json", str(tmp / "functional.json"),
                       "--json-out", str(out_json),
                       "--markdown-out", str(out_md))
            self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
            payload = json.loads(out_json.read_text())
            self.assertEqual(payload["overallStatus"], lib.STATUS_INCOMPLETE)

    def test_no_evidence_is_incomplete_not_green(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            out_json = tmp / "scorecard.json"
            out_md = tmp / "scorecard.md"
            proc = run("score-boards.py",
                       "--registry", self._registry(),
                       "--json-out", str(out_json),
                       "--markdown-out", str(out_md))
            self.assertEqual(proc.returncode, 3, proc.stdout + proc.stderr)
            payload = json.loads(out_json.read_text())
            self.assertEqual(payload["overallStatus"], lib.STATUS_INCOMPLETE)


if __name__ == "__main__":
    unittest.main(verbosity=2)
