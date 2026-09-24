#!/usr/bin/env python3
"""Unit + fake-CLI end-to-end tests for the FluidAudio A/B (scripts/stt_fluidaudio_ab.py
and scripts/stt_fluidaudio_ab.sh). Plain unittest, no Swift, no models, runs on Linux:

    python3 scripts/test_stt_fluidaudio_ab.py

The end-to-end tests need the STT shootout module (this checkout or a git ref, see
resolve_shootout) and skip when it can't be found.
"""
from __future__ import annotations

import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import stt_fluidaudio_ab as ab  # noqa: E402

TH = dict(ab.DEFAULT_THRESHOLDS)

_SHOOTOUT = None


def shootout_path() -> Path | None:
    """The real shootout module, cached once per test run; None when unavailable."""
    global _SHOOTOUT
    if _SHOOTOUT is None:
        cache = Path(tempfile.mkdtemp(prefix="stt-ab-shootout-"))
        try:
            with redirect_stderr(io.StringIO()):
                _SHOOTOUT, _ = ab.resolve_shootout(None, ab.REPO, cache)
        except SystemExit:
            _SHOOTOUT = False
    return _SHOOTOUT or None


def fake_scorer(reference: str, hypothesis: str) -> dict:
    """Position-wise word diff; enough to check the pooling math."""
    ref, hyp = reference.split(), hypothesis.split()
    subs = sum(1 for r, h in zip(ref, hyp) if r != h)
    dels = max(0, len(ref) - len(hyp))
    ins = max(0, len(hyp) - len(ref))
    return {"substitutions": subs, "deletions": dels, "insertions": ins, "reference_words": len(ref),
            "hypothesis_words": len(hyp), "wer": (subs + dels + ins) / max(1, len(ref))}


def blank_case(cid: str, **extra) -> dict:
    return {"id": cid, "kind": "silence", "class": "blank", "audio_seconds": 1.0, **extra}


class FixtureTests(unittest.TestCase):
    def test_silence_is_digital_zero_with_exact_length(self):
        samples = ab.synth_samples({"kind": "silence", "seconds": 3.0})
        self.assertEqual(len(samples), 48_000)
        self.assertTrue(all(s == 0 for s in samples))

    def test_noise_hits_its_level_and_is_deterministic(self):
        for color in ("white", "brown"):
            case = {"kind": "noise", "seconds": 1.0, "dbfs": -40.0, "color": color, "seed": 5}
            first, second = ab.synth_samples(case), ab.synth_samples(case)
            self.assertEqual(first, second)
            self.assertAlmostEqual(ab.rms_dbfs(first), -40.0, delta=0.3, msg=color)
        quiet = ab.synth_samples({"kind": "noise", "seconds": 1.0, "dbfs": -84.0, "color": "white", "seed": 1})
        self.assertLessEqual(max(abs(s) for s in quiet), 12)
        self.assertGreater(sum(1 for s in quiet if s != 0), 8000)

    def test_wav_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.wav"
            ab.write_wav(path, [0, 1, -1, 32767, -32768] * 3200)
            self.assertEqual(ab.read_wav_samples(path)[:5], [0, 1, -1, 32767, -32768])
            self.assertAlmostEqual(ab.wav_duration(path), 1.0)

    def test_stop_fixtures_without_speech(self):
        with tempfile.TemporaryDirectory() as tmp:
            cases, notes = ab.prepare_stop_fixtures(Path(tmp), speech=False)
            self.assertEqual(notes, [])
            self.assertEqual([c["class"] for c in cases], ["blank"] * 7)
            burst = next(c for c in cases if c["id"] == "noise-burst-0.5s")
            self.assertAlmostEqual(burst["audio_seconds"], 0.5)
            self.assertAlmostEqual(burst["level_dbfs"], -35.0, delta=0.3)
            self.assertTrue(all(Path(c["path"]).exists() for c in cases))

    def test_stop_fixtures_with_a_speech_maker(self):
        made = []

        def fake_say(text, target, trailing):
            made.append((text, trailing))
            ab.write_wav(target, [1000] * int(16_000 * (0.5 + trailing)))

        with tempfile.TemporaryDirectory() as tmp:
            cases, notes = ab.prepare_stop_fixtures(Path(tmp), speech=True, say=fake_say)
        speech = [c for c in cases if c["class"] == "speech"]
        self.assertEqual(len(speech), 4)
        self.assertEqual(notes, [])
        padded = next(c for c in speech if c["id"] == "say-okay-then-3s-silence")
        self.assertAlmostEqual(padded["audio_seconds"], 3.5)
        self.assertEqual(padded["reference"], "Okay.")
        self.assertIn(("Okay.", 3.0), made)

    def test_missing_say_is_a_note_not_a_failure(self):
        if shutil.which("say") and shutil.which("afconvert"):
            self.skipTest("say is installed here")
        with tempfile.TemporaryDirectory() as tmp:
            cases, notes = ab.prepare_stop_fixtures(Path(tmp), speech=True)
        self.assertEqual(len(cases), 7)
        self.assertTrue(any("say" in n for n in notes))


class WindowTests(unittest.TestCase):
    CUES = [(float(i * 5), float(i * 5 + 4.5), f"cue{i}") for i in range(120)]  # 10 minutes of 5 s cues

    def test_windows_are_whole_cues_within_bounds(self):
        windows = ab.cue_windows(self.CUES, 60.0, 4, 45.0, min_seconds=20.0)
        self.assertEqual(len(windows), 4)
        for start, end, text in windows:
            self.assertGreaterEqual(start, 60.0)
            self.assertLessEqual(end - start, 45.0)
            self.assertGreaterEqual(end - start, 20.0)
            self.assertTrue(text.startswith("cue") and " " in text)
        starts = [w[0] for w in windows]
        self.assertEqual(starts, sorted(starts))
        self.assertGreater(starts[-1] - starts[0], 300)  # spread across the audio

    def test_count_and_limits(self):
        self.assertEqual(ab.cue_windows(self.CUES, 0.0, 0, 45.0), [])
        self.assertEqual(len(ab.cue_windows(self.CUES, 0.0, 1, 45.0)), 1)
        self.assertEqual(ab.cue_windows(self.CUES, 0.0, 3, 45.0, audio_seconds=10.0), [])
        long_cue = [(0.0, 100.0, "long")] + [(100.0 + i * 5, 104.5 + i * 5, f"c{i}") for i in range(12)]
        windows = ab.cue_windows(long_cue, 0.0, 5, 45.0)
        self.assertTrue(all(w[0] >= 100.0 for w in windows))


class PlanTests(unittest.TestCase):
    def test_abba_order(self):
        self.assertEqual(ab.round_order(0), ("baseline", "candidate"))
        self.assertEqual(ab.round_order(1), ("candidate", "baseline"))
        self.assertEqual(ab.round_order(2), ("baseline", "candidate"))

    def test_timing_plan_warms_up_then_interleaves(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            cases = []
            for cid, cls in (("a", "blank"), ("b", "speech"), ("c", "blank")):
                path = src / f"{cid}.wav"
                ab.write_wav(path, [0] * 1600)
                cases.append({"id": cid, "class": cls, "path": str(path)})
            plan = ab.timing_plan(cases, 3, Path(tmp) / "stage", "baseline0")
            self.assertEqual([cid for cid, _ in plan[:2]], [None, None])
            self.assertEqual([cid for cid, _ in plan[2:5]], ["a", "b", "c"])
            self.assertEqual(len(plan), 2 + 9)
            self.assertEqual(len({p.stem for _, p in plan}), len(plan))
            self.assertTrue(all(p.exists() for _, p in plan))

    def test_read_cli_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            (out / "one.json").write_text(json.dumps([{"text": "hi", "processingSeconds": 0.1}]))
            (out / "two.json").write_text("not json")
            got = ab.read_cli_outputs(out, [Path("/x/one.wav"), Path("/x/two.wav"), Path("/x/three.wav")])
            self.assertEqual(list(got), ["one"])
            self.assertEqual(got["one"]["text"], "hi")


class ScoringTests(unittest.TestCase):
    def timing(self, a, b, texts_a=None, texts_b=None, cls="blank", reference=None):
        case = blank_case("x") if cls == "blank" else {"id": "x", "kind": "speech", "class": "speech",
                                                       "audio_seconds": 1.0, "reference": reference}
        samples = {"baseline": {"x": a}, "candidate": {"x": b}}
        texts = {"baseline": {"x": texts_a if texts_a is not None else [""] * len(a)},
                 "candidate": {"x": texts_b if texts_b is not None else [""] * len(b)}}
        return ab.summarize_timing([case], samples, texts, TH, scorer=fake_scorer)[0]

    def test_time_gate_pass(self):
        row = self.timing([0.10, 0.11, 0.12], [0.11, 0.12, 0.13])
        self.assertTrue(row["pass"])
        self.assertAlmostEqual(row["delta_ms"], 10.0)
        self.assertEqual(row["baseline"]["blank_runs"], 3)

    def test_time_gate_fails_on_ratio_even_when_small(self):
        row = self.timing([0.02] * 3, [0.10] * 3)  # 5x, +80 ms
        self.assertFalse(row["pass"])
        self.assertEqual(row["ratio"], 5.0)

    def test_time_gate_fails_on_absolute_delta(self):
        row = self.timing([2.0] * 3, [2.4] * 3)  # 1.2x, +400 ms
        self.assertFalse(row["pass"])

    def test_time_gate_fails_when_a_side_is_missing(self):
        row = self.timing([0.1], [])
        self.assertFalse(row["pass"])
        self.assertNotIn("delta_ms", row)

    def test_speech_rows_are_scored_not_gated(self):
        row = self.timing([0.1] * 2, [0.5] * 2, ["send it", "send it"], ["send it", "sent it"],
                          cls="speech", reference="send it")
        self.assertNotIn("pass", row)
        self.assertEqual(row["baseline"]["wer"], 0.0)
        self.assertEqual(row["candidate"]["distinct_texts"], 2)

    def test_wer_pooling_and_subsets(self):
        items = [
            {"id": "long", "subset": "long", "reference": "a b c d e f g h i j"},
            {"id": "s0", "subset": "dictation-length", "reference": "k l m n o"},
        ]
        texts = {"baseline": {"long": "a b c d e f g h i j", "s0": "k l m n x"},
                 "candidate": {"long": "a b c d e f g h i", "s0": "k l m n x"}}
        wer = ab.summarize_wer(items, texts, fake_scorer)
        self.assertTrue(wer["complete"])
        self.assertAlmostEqual(wer["pooled"]["baseline"]["wer"], 1 / 15, places=4)
        self.assertAlmostEqual(wer["pooled"]["candidate"]["wer"], 2 / 15, places=4)
        self.assertAlmostEqual(wer["pooled"]["delta_pp"], 6.667, places=2)
        self.assertEqual(wer["subsets"]["long"]["candidate"]["errors"], 1)
        self.assertEqual(wer["items"][1]["delta_pp"], 0.0)

    def test_wer_incomplete_when_a_side_is_missing(self):
        items = [{"id": "long", "subset": "long", "reference": "a b"}]
        wer = ab.summarize_wer(items, {"baseline": {"long": "a b"}, "candidate": {}}, fake_scorer)
        self.assertFalse(wer["complete"])
        self.assertNotIn("delta_pp", wer["pooled"])

    def gate(self, wer_delta_texts, timing_rows, problems=()):
        items = [{"id": "long", "subset": "long", "reference": " ".join(f"w{i}" for i in range(1000))}]
        base = items[0]["reference"]
        cand = " ".join(f"w{i}" for i in range(1000 - wer_delta_texts))
        wer = ab.summarize_wer(items, {"baseline": {"long": base}, "candidate": {"long": cand}}, fake_scorer)
        return ab.evaluate_gate(wer, timing_rows, TH, list(problems))

    def test_gate_all_checks(self):
        good = self.timing([0.1] * 3, [0.1] * 3)
        bad = self.timing([0.1] * 3, [0.6] * 3)
        self.assertTrue(self.gate(5, [good])["pass"])          # +0.5 points is allowed
        wer_fail = self.gate(6, [good])                           # +0.6 points is not
        self.assertFalse(wer_fail["pass"])
        self.assertEqual([c["pass"] for c in wer_fail["checks"]], [True, False, True])
        time_fail = self.gate(0, [good, bad])
        self.assertFalse(time_fail["pass"])
        self.assertIn("1/2 clips", time_fail["checks"][2]["detail"])
        self.assertFalse(self.gate(0, [good], problems=["candidate crashed"])["pass"])
        self.assertFalse(self.gate(0, [])["pass"])
        self.assertFalse(ab.evaluate_gate(None, [good], TH, [])["pass"])

    def test_warnings(self):
        halluc = self.timing([0.1] * 2, [0.1] * 2, ["", ""], ["thank you", ""])
        changed = self.timing([0.1], [0.1], ["send it"], ["sent it"], cls="speech", reference="send it")
        models = {"candidate": {"before": {"digest": "a"}, "after": {"digest": "b"}},
                  "baseline": {"before": {"digest": "a"}, "after": {"digest": "a"}}}
        warnings = ab.collect_warnings([halluc, changed], None, models)
        self.assertTrue(any("returned text on 1/2" in w for w in warnings))
        self.assertTrue(any("text changed" in w for w in warnings))
        self.assertTrue(any(w.startswith("candidate: FluidAudio changed") for w in warnings))
        self.assertFalse(any(w.startswith("baseline:") for w in warnings))

    def test_report_renders(self):
        row = self.timing([0.1] * 3, [0.6] * 3)
        items = [{"id": "long", "subset": "long", "reference": "a b c", "audio_seconds": 60.0}]
        wer = ab.summarize_wer(items, {"baseline": {"long": "a b c"}, "candidate": {"long": "a b c"}}, fake_scorer)
        result = {
            "created_at": "2026-09-24T00:00:00+00:00", "machine": {"summary": "test"}, "conditions": {"on_battery": True},
            "gate": ab.evaluate_gate(wer, [row], TH, []), "thresholds": TH, "quick": True,
            "sides": {"baseline": {"label": "FluidAudio 0.15.4", "fluidaudio_version": "0.15.4", "ref": "origin/main",
                                   "commit": "abc"},
                      "candidate": {"label": "FluidAudio 0.17.0", "fluidaudio_version": "0.17.0", "ref": "HEAD",
                                    "commit": "def"}},
            "wer": wer, "wer_audio": {"title": "lecture"}, "normalizer": "basic", "timing": [row],
            "settings": {"repeats": 5, "rounds": 2}, "warnings": ["w1"], "notes": ["n1"],
        }
        text = ab.render_report(result)
        self.assertIn("**FAIL**", text)
        self.assertIn("quick run", text)
        self.assertIn("on battery", text)
        self.assertIn("| x | 1.0 s | 100 ms | 600 ms | 6.00x |", text)
        self.assertIn("| all | 1.0 min | 3 | 0.00% | 0.00% | +0.00 pts |", text)
        json.dumps(result)  # everything in a result must serialize


class ShootoutTests(unittest.TestCase):
    def test_explicit_path_must_exist(self):
        with self.assertRaises(SystemExit):
            ab.resolve_shootout("/nonexistent/shootout.py", ab.REPO, Path(tempfile.gettempdir()))

    def test_real_scorer(self):
        path = shootout_path()
        if not path:
            self.skipTest("STT shootout not reachable (no checkout copy, no git ref)")
        sh = ab.load_shootout(path)
        counts = sh.score("Hello world, this is a test.", "hello word this is a test")
        self.assertEqual(counts["reference_words"], 6)
        self.assertAlmostEqual(counts["wer"], 1 / 6)

    def test_wer_set_from_captions(self):
        """Long piece = first N minutes; dictation pieces cut on cue edges after it."""
        path = shootout_path()
        if not path:
            self.skipTest("STT shootout not reachable (no checkout copy, no git ref)")
        sh = ab.load_shootout(path)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            audio = tmp / "talk.wav"
            ab.write_wav(audio, [0] * (16_000 * 300))
            cues = []
            for i in range(60):
                start = i * 5
                cues.append(f"00:{start // 60:02d}:{start % 60:02d}.000 --> "
                            f"00:{(start + 4) // 60:02d}:{(start + 4) % 60:02d}.500\nline {i} here")
            vtt = tmp / "talk.vtt"
            vtt.write_text("WEBVTT\n\n" + "\n\n".join(cues) + "\n")
            args = ab.parse_args(["--baseline-cli", "x", "--candidate-cli", "y", "--audio", str(audio),
                                  "--reference", str(vtt), "--minutes", "1", "--segments", "3"])
            items, meta = ab.prepare_wer_set(sh, args, tmp / "media", tmp / "run")
        self.assertEqual([i["subset"] for i in items], ["long", "dictation-length", "dictation-length",
                                                        "dictation-length"])
        self.assertAlmostEqual(items[0]["audio_seconds"], 60.0)
        self.assertTrue(items[0]["reference"].startswith("line 0 here"))
        self.assertTrue(items[0]["reference"].rstrip().endswith("line 11 here"))
        for seg in items[1:]:
            self.assertGreaterEqual(seg["start_seconds"], 60.0)
            first = int(seg["start_seconds"] // 5)
            self.assertTrue(seg["reference"].startswith(f"line {first} here"))
            self.assertLessEqual(seg["audio_seconds"], 45.5)
            self.assertGreaterEqual(seg["audio_seconds"], 20.0)
        self.assertEqual(meta["notes"], [])


# ---------------------------------------------------------------- end to end with a fake CLI

FAKE_CLI = r'''#!/usr/bin/env python3
"""Stands in for transcripted-cli. MODE: baseline | slow-blank | worse."""
import json, math, os, sys, wave
MODE = "@MODE@"
args = sys.argv[1:]
if args[:1] == ["build-info"]:
    print(json.dumps({"mode": "audio", "transcription": True, "diarization": True, "meetingImport": False}))
    sys.exit(0)
assert args[0] == "transcribe", args
out_dir, files, i = None, [], 1
while i < len(args):
    if args[i] in ("--models-dir", "--output-dir", "--output", "-o"):
        if args[i] == "--output-dir":
            out_dir = args[i + 1]
        i += 2
    elif args[i].startswith("--"):
        i += 1
    else:
        files.append(args[i]); i += 1
assert out_dir, "the A/B must always pass --output-dir"
text = open(os.environ["FAKE_CLI_TEXT"]).read().split()
for f in files:
    with wave.open(f, "rb") as w:
        raw = w.readframes(w.getnframes()); seconds = w.getnframes() / w.getframerate()
    vals = [int.from_bytes(raw[k:k + 2], "little", signed=True) for k in range(0, len(raw), 2)]
    rms = math.sqrt(sum(v * v for v in vals) / max(1, len(vals)))
    blank = rms < 1000
    out = "" if blank else " ".join(text[:-3] if MODE == "worse" else text)
    took = 0.02 + 0.001 * seconds
    if MODE == "slow-blank" and blank:
        took = took * 6 + 0.4
    name = os.path.splitext(os.path.basename(f))[0]
    with open(os.path.join(out_dir, name + ".json"), "w") as fh:
        json.dump([{"file": f, "text": out, "durationSeconds": seconds, "processingSeconds": took,
                    "speedFactor": 1.0, "confidence": 0.9, "segments": []}], fh)
    print(f"Done {name}", file=sys.stderr)
'''


def write_fake_cli(path: Path, mode: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(FAKE_CLI.replace("@MODE@", mode))
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def make_wer_inputs(tmp: Path) -> tuple[Path, Path]:
    words = " ".join(f"word{i}" for i in range(400))
    audio = tmp / "speech.wav"
    ab.write_wav(audio, ab.synth_samples({"kind": "noise", "seconds": 4.0, "dbfs": -20.0, "color": "white", "seed": 3}))
    reference = tmp / "speech.txt"
    reference.write_text(words)
    return audio, reference


class EndToEndTests(unittest.TestCase):
    def setUp(self):
        self.shootout = shootout_path()
        if not self.shootout:
            self.skipTest("STT shootout not reachable (no checkout copy, no git ref)")
        self.tmp = Path(tempfile.mkdtemp(prefix="stt-ab-e2e-"))
        self.audio, self.reference = make_wer_inputs(self.tmp)
        self.models = self.tmp / "models-src"
        self.models.mkdir()
        (self.models / "Encoder.mlmodelc").mkdir()
        (self.models / "Encoder.mlmodelc" / "weights.bin").write_bytes(b"x" * 10)
        os.environ["FAKE_CLI_TEXT"] = str(self.reference)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        os.environ.pop("FAKE_CLI_TEXT", None)

    def run_main(self, candidate_mode: str) -> tuple[int, dict, str]:
        base = self.tmp / f"base-{candidate_mode}"
        argv = [
            "--base", str(base), "--shootout", str(self.shootout),
            "--baseline-cli", str(write_fake_cli(self.tmp / "bin" / "baseline-cli", "baseline")),
            "--candidate-cli", str(write_fake_cli(self.tmp / "bin" / f"{candidate_mode}-cli", candidate_mode)),
            "--audio", str(self.audio), "--reference", str(self.reference), "--models-source", str(self.models),
            "--media-dir", str(self.tmp / "media"), "--no-speech-clips", "--repeats", "2", "--rounds", "2",
        ]
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = ab.main(argv)
        last = out.getvalue().strip().splitlines()[-1]
        return code, json.loads(Path(last).read_text()), last

    def test_same_behavior_passes(self):
        code, result, path = self.run_main("baseline")
        self.assertEqual(code, 0, result["gate"])
        self.assertTrue(result["gate"]["pass"])
        self.assertEqual(result["schema"], ab.SCHEMA)
        self.assertEqual(result["wer"]["pooled"]["delta_pp"], 0.0)
        self.assertEqual(len(result["timing"]), 7)
        self.assertTrue(all(r["baseline"]["runs"] == 4 and r["candidate"]["runs"] == 4 for r in result["timing"]))
        self.assertEqual([p["side"] for p in result["processes"] if p["phase"] == "stop"],
                         ["baseline", "candidate", "candidate", "baseline"])
        self.assertTrue(Path(path).with_name("report.md").exists())
        self.assertTrue((Path(path).parent / "transcripts" / "wer-long.candidate.txt").exists())
        # The model copies are private per side and untouched by the fake.
        self.assertEqual(result["models"]["baseline"]["before"], result["models"]["baseline"]["after"])

    def test_slow_blank_decode_fails_the_time_gate(self):
        code, result, _ = self.run_main("slow-blank")
        self.assertEqual(code, 3)
        checks = {c["name"]: c["pass"] for c in result["gate"]["checks"]}
        self.assertEqual(checks, {"both sides ran": True, "word error rate": True, "blank-audio stop time": False})

    def test_worse_wer_fails_the_wer_gate(self):
        code, result, _ = self.run_main("worse")
        self.assertEqual(code, 3)
        self.assertAlmostEqual(result["wer"]["pooled"]["delta_pp"], 0.75, places=3)
        checks = {c["name"]: c["pass"] for c in result["gate"]["checks"]}
        self.assertFalse(checks["word error rate"])
        self.assertTrue(checks["blank-audio stop time"])


class WrapperTests(unittest.TestCase):
    """Runs the real bash wrapper against a throwaway git repo with stubbed Mac tools
    (uname, swift, shasum, uv) and a fake build-deps.sh, then checks the builds,
    records, version guard and the handoff to the Python side."""

    def setUp(self):
        self.shootout = shootout_path()
        if not self.shootout or not shutil.which("git") or not shutil.which("bash"):
            self.skipTest("needs git, bash and the STT shootout")
        self.tmp = Path(tempfile.mkdtemp(prefix="stt-ab-wrap-"))
        self.repo = self.tmp / "repo"
        self.stubs = self.tmp / "stubs"
        self.make_repo()
        self.make_stubs()
        self.audio, self.reference = make_wer_inputs(self.tmp)
        self.models = self.tmp / "models-src"
        (self.models / "Decoder.mlmodelc").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True)

    def make_repo(self):
        cli_src = self.repo / "Tools/TranscriptedCLI/Sources/TranscriptedCLI"
        cli_src.mkdir(parents=True)
        (self.repo / "scripts").mkdir()
        for name in ("stt_fluidaudio_ab.sh", "stt_fluidaudio_ab.py"):
            shutil.copy(HERE / name, self.repo / "scripts" / name)
        (self.repo / "build-deps.sh").write_text(textwrap.dedent("""\
            #!/bin/bash
            set -e
            echo "Computed https://github.com/FluidInference/FluidAudio.git at ${FAKE_RESOLVED:-$FLUID_AUDIO_VERSION}"
            mkdir -p deps-libs && echo "$FLUID_AUDIO_VERSION" > deps-libs/version
            echo built >> "$FAKE_BUILD_LOG"
            """))
        (self.repo / ".gitignore").write_text("deps-libs/\n.build/\n")
        (cli_src / "TranscribeCommand.swift").write_text("let manager = AsrManager(config: .default)\n")
        self.git("init", "-q")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        self.git("tag", "pre-bump")
        (cli_src / "TranscribeCommand.swift").write_text(
            "let manager = AsrManager(config: ASRConfig(melChunkContext: true, seamGapRepair: false))\n")
        self.git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "bump")

    def make_stubs(self):
        self.stubs.mkdir()
        fake_cli = FAKE_CLI.replace("@MODE@", "baseline")
        stubs = {
            "uname": 'case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) /bin/uname "$@" ;; esac\n',
            "shasum": 'shift 2; exec sha256sum "$@"\n',
            # swift build [...] --package-path P ... [--show-bin-path]
            "swift": textwrap.dedent('''\
                pkg=""; show=0; prev=""
                for a in "$@"; do
                  [ "$prev" = "--package-path" ] && pkg="$a"
                  [ "$a" = "--show-bin-path" ] && show=1
                  prev="$a"
                done
                [ "$TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION" = 1 ] || { echo "transcription not enabled" >&2; exit 1; }
                if [ "$show" = 1 ]; then echo "$pkg/.build/release"; exit 0; fi
                mkdir -p "$pkg/.build/release"
                cat > "$pkg/.build/release/transcripted-cli" <<'CLI'
                @FAKE_CLI@
                CLI
                chmod +x "$pkg/.build/release/transcripted-cli"
                '''),
            # uv run [flags...] python SCRIPT ARGS -> python3 SCRIPT ARGS
            "uv": 'while [ "$#" -gt 0 ] && [ "$1" != python ]; do shift; done; shift; exec python3 "$@"\n',
        }
        for name, body in stubs.items():
            body = body.replace("@FAKE_CLI@", fake_cli)
            path = self.stubs / name
            path.write_text("#!/bin/bash\n" + body)
            path.chmod(0o755)

    def run_wrapper(self, *extra, resolved=None):
        env = {**os.environ, "PATH": f"{self.stubs}:{os.environ['PATH']}", "FAKE_CLI_TEXT": str(self.reference),
               "FAKE_BUILD_LOG": str(self.tmp / "builds.log"), "HOME": str(self.tmp / "home")}
        if resolved:
            env["FAKE_RESOLVED"] = resolved
        cmd = ["bash", str(self.repo / "scripts/stt_fluidaudio_ab.sh"), "--base-dir", str(self.tmp / "ab"),
               "--baseline-ref", "pre-bump", "--no-fetch", *extra,
               "--shootout", str(self.shootout), "--audio", str(self.audio), "--reference", str(self.reference),
               "--models-source", str(self.models), "--media-dir", str(self.tmp / "media"),
               "--no-speech-clips", "--repeats", "1", "--rounds", "1"]
        return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=600)

    def builds(self) -> int:
        log = self.tmp / "builds.log"
        return len(log.read_text().splitlines()) if log.exists() else 0

    def test_builds_both_sides_runs_and_reuses_builds(self):
        done = self.run_wrapper()
        self.assertEqual(done.returncode, 0, done.stderr[-3000:])
        result_path = Path(done.stdout.strip().splitlines()[-1])
        result = json.loads(result_path.read_text())
        self.assertTrue(result["gate"]["pass"])
        self.assertEqual(result["sides"]["baseline"]["fluidaudio_version"], "0.15.4")
        self.assertEqual(result["sides"]["candidate"]["fluidaudio_version"], "0.17.0")
        self.assertEqual(result["sides"]["baseline"]["fluidaudio_resolved"], "0.15.4")
        self.assertTrue(result["sides"]["candidate"]["ref"].startswith("HEAD ("))
        base_ver = (self.tmp / "ab/src/baseline/deps-libs/version").read_text().strip()
        cand_ver = (self.tmp / "ab/src/candidate/deps-libs/version").read_text().strip()
        self.assertEqual((base_ver, cand_ver), ("0.15.4", "0.17.0"))
        self.assertEqual(self.builds(), 2)
        # Unchanged inputs: the second run reuses both builds.
        again = self.run_wrapper("--quick")
        self.assertEqual(again.returncode, 0, again.stderr[-3000:])
        self.assertEqual(self.builds(), 2)
        self.assertIn("build is current", again.stderr)
        skip = self.run_wrapper("--skip-build")
        self.assertEqual(skip.returncode, 0, skip.stderr[-3000:])

    def test_skip_build_needs_an_existing_build(self):
        done = self.run_wrapper("--skip-build")
        self.assertEqual(done.returncode, 1)
        self.assertIn("no baseline build yet", done.stderr)
        self.assertEqual(self.builds(), 0)

    def test_refuses_a_baseline_that_already_uses_the_new_api(self):
        done = self.run_wrapper("--baseline-ref", "HEAD")
        self.assertEqual(done.returncode, 1)
        self.assertIn("0.17 ASRConfig API", done.stderr)

    def test_catches_a_version_override_that_did_not_take(self):
        done = self.run_wrapper(resolved="0.16.0")
        self.assertEqual(done.returncode, 1)
        self.assertIn("resolved FluidAudio 0.16.0", done.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
