#!/usr/bin/env python3
"""Unit tests for the dictation-stop bench adapter.

Run: python3 scripts/hillclimb/benches/dictation_stop.py --self-test

Everything runs on Linux with fakes: a fake `say` stores the phrase text as the
WAV's sample bytes, a fake `afconvert` copies it, and a fake app binary reads
those bytes back as its "transcript", so a wrong case_id -> item mapping shows
up as wrong text. The fake app writes JSONL and Dictations_*.md in the same
shapes as DictationStopBenchmarkRunner / DictationTranscriptWriter.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
import wave
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import dictation_stop as ds  # noqa: E402
from hc_benches import validate_result  # noqa: E402

FAKE_SAY = """\
import sys, wave
args = sys.argv[1:]
text = open(args[args.index("-f") + 1], encoding="utf-8").read().strip()
if "FAILSAY" in text:
    sys.exit(3)
data = text.encode("utf-8")
if len(data) % 2:
    data += b"\\x00"
with wave.open(args[args.index("-o") + 1], "wb") as out:
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(48000)
    out.writeframes(data)
"""

FAKE_AFCONVERT = """\
import shutil, sys
shutil.copyfile(sys.argv[-2], sys.argv[-1])
"""

# Mirrors DictationStopBenchmarkRunner: case_id = file stem, sorted by name,
# run_start then one case_result per case; saved text goes to SAVE_DIR as
# DictationTranscriptWriter day-file sections. FAKE_APP_CONFIG (JSON) steers it:
#   {"replace": {ref text: hyp}, "silence_text": str, "drop": [case suffix], "env_dump": path}
FAKE_APP = """\
#!/usr/bin/env python3
import json, os, sys, wave
from pathlib import Path

def fnv(text):
    h = 14695981039346656037
    for b in text.encode("utf-8"):
        h ^= b
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h

env = os.environ
cfg = json.loads(Path(env["FAKE_APP_CONFIG"]).read_text()) if env.get("FAKE_APP_CONFIG") else {}
if cfg.get("env_dump"):
    Path(cfg["env_dump"]).write_text(json.dumps(dict(env)))
audio = Path(env["TRANSCRIPTED_DICTATION_STOP_BENCH_AUDIO_DIR"])
out = Path(env["TRANSCRIPTED_DICTATION_STOP_BENCH_OUTPUT"])
save = Path(env["TRANSCRIPTED_DICTATION_STOP_BENCH_SAVE_DIR"])
save.mkdir(parents=True, exist_ok=True)
wavs = sorted(p for p in audio.iterdir() if p.suffix.lower() == ".wav" and not p.name.startswith("."))
if not wavs:
    print("Dictation stop benchmark failed: No .wav fixtures", file=sys.stderr)
    sys.exit(1)
lines = [{"record_type": "run_start", "variant": env.get("TRANSCRIPTED_DICTATION_STOP_BENCH_VARIANT", "native"),
          "iterations": int(env.get("TRANSCRIPTED_DICTATION_STOP_BENCH_ITERATIONS", "3")), "case_count": len(wavs),
          "model_init_s": 1.25, "encoder_compute_units": env.get("TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS", "default"),
          "finalization_order": env.get("TRANSCRIPTED_DICTATION_STOP_BENCH_FINALIZATION_ORDER"),
          "simulate_auto_enter": env.get("TRANSCRIPTED_DICTATION_STOP_BENCH_AUTO_ENTER") != "0",
          "chunk_seconds": float(env.get("TRANSCRIPTED_DICTATION_STOP_BENCH_CHUNK_SECONDS", "30"))}]
md = save / "Dictations_2026-09-23.md"
sections = []
for n, wav in enumerate(wavs):
    case_id = wav.stem
    if any(case_id.endswith(s) for s in cfg.get("drop", [])):
        continue
    with wave.open(str(wav)) as h:
        frames = h.readframes(h.getnframes())
        duration = h.getnframes() / h.getframerate()
    ref = frames.rstrip(b"\\x00").decode("utf-8", "replace").strip()
    text = cfg.get("replace", {}).get(ref, ref) if ref else cfg.get("silence_text", "")
    text = text.strip()
    row = {"record_type": "case_result", "case_id": case_id, "iteration": 1,
           "variant": lines[0]["variant"], "audio_duration_s": round(duration, 3),
           "preprocess_s": 0.01, "stop_to_text_s": round(0.2 + 0.01 * n, 3)}
    if lines[0]["variant"] == "production":
        row.update({"snapshot_resample_s": 0.01, "recovery_checkpoint_s": 0.002, "decode_s": round(0.15 + 0.01 * n, 3)})
    if not text:
        row.update({"no_speech": True, "saved": False, "delivery": "no_speech", "chars": 0, "words": 0,
                    "text_hash": "", "stop_to_delivery_s": row["stop_to_text_s"]})
    else:
        row.update({"no_speech": False, "saved": True, "delivery": "pasted", "chars": len(text),
                    "words": len(text.split()), "text_hash": fnv(text), "cleanup_removed": 0,
                    "stop_to_pasted_s": row["stop_to_text_s"], "stop_to_saved_s": round(row["stop_to_text_s"] + 0.005, 3),
                    "stop_to_delivery_s": round(row["stop_to_text_s"] + 0.3, 3)})
        title = " ".join(text.split()[:7])
        sections.append(
            f"## 9:0{n % 10} AM - {title}\\n\\n"
            f"Entry ID: `dictation-20260923-0900{n:02d}-000-abc`\\n"
            f"Captured: 2026-09-23T09:00:{n:02d}.000Z\\n"
            f"Source app: Unknown\\n"
            f"Delivery: pasted\\n"
            f"Words: {len(text.split())}\\n"
            f"Characters: {len(text)}\\n\\n"
            f"{text}")
    lines.append(row)
if sections:
    header = ("---\\ntitle: \\"Dictations for September 23, 2026\\"\\ndate: 2026-09-23\\n"
              "capture_type: dictation_day\\nformat_version: 1\\n---\\n\\n# Dictations for September 23, 2026")
    md.write_text(header + "\\n\\n" + "\\n\\n".join(sections))
out.parent.mkdir(parents=True, exist_ok=True)
with open(out, "w") as h:
    for line in lines:
        h.write(json.dumps(line, sort_keys=True) + "\\n")
"""

ITEMS = [
    {"id": "p001", "kind": "speech", "text": "Ship it."},
    {"id": "p002", "kind": "speech", "text": "The meeting is on March 14th at 3:30 PM."},
    {"id": "odd/id.v2", "kind": "speech", "text": "Send the draft to jordan.lee@example.com today."},
    {"id": "silence-01", "kind": "silence", "seconds": 0.5},
]


def write_exec(path: Path, body: str) -> Path:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


class WerTests(unittest.TestCase):
    def test_identical_is_zero(self):
        self.assertEqual(ds.word_error_rate("the cat sat", "the cat sat"), 0.0)

    def test_substitution_and_deletion(self):
        # ref 6 words; "sat"->"sit" (1 sub), "the" before mat deleted (1 del) = 2/6
        self.assertAlmostEqual(ds.word_error_rate("the cat sat on the mat", "the cat sit on mat"), 2 / 6)

    def test_insertions_can_exceed_one(self):
        self.assertAlmostEqual(ds.word_error_rate("a b", "a x b y z"), 3 / 2)

    def test_empty_hypothesis_is_all_deletions(self):
        self.assertEqual(ds.word_error_rate("one two three four", ""), 1.0)

    def test_normalization(self):
        self.assertEqual(ds.normalize_words("Hello,  World! Don't follow-up 1,200"), ["hello", "world", "dont", "follow", "up", "1200"])
        self.assertEqual(ds.word_error_rate("Hello, World!", "hello world"), 0.0)
        self.assertEqual(ds.word_error_rate("It’s 3:30 PM.", "its 3 30 pm"), 0.0)

    def test_fnv_matches_swift_constants(self):
        self.assertEqual(ds.fnv1a64(""), "cbf29ce484222325")
        self.assertEqual(ds.fnv1a64("a"), "af63dc4c8601ec8c")


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        tools = self.root / "tools"
        tools.mkdir()
        self.say = write_exec(tools / "say.py", FAKE_SAY)
        self.afconvert = write_exec(tools / "afconvert.py", FAKE_AFCONVERT)
        self.app = write_exec(tools / "Transcripted", FAKE_APP)
        self.config_path = self.root / "fake-app.json"
        self.work_root = self.root / "work"
        self.counter = 0
        patcher = mock.patch.dict(os.environ, {"FAKE_APP_CONFIG": str(self.config_path)})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)
        self.set_app_config({})

    def set_app_config(self, config: dict) -> None:
        self.config_path.write_text(json.dumps(config))

    def request(self, *, items=None, knobs=None, repetition=0, trial_id="t0001", **options) -> Path:
        self.counter += 1
        work = self.work_root / f"{trial_id}-r{repetition}-{self.counter}"
        work.mkdir(parents=True)
        bench_options = {
            "app_binary": str(self.app),
            "voice": "Samantha",
            "fixture_cache": str(self.root / "cache"),
            "say_command": [sys.executable, str(self.say)],
            "afconvert_command": [sys.executable, str(self.afconvert)],
            "timeout_seconds": 60,
        }
        bench_options.update(options)
        payload = {
            "schema": "transcripted.hillclimb.request.v1",
            "trial_id": trial_id,
            "objective": "dictation-stop-latency",
            "suite": "test",
            "split": "dev",
            "repetition": repetition,
            "knobs": knobs or {},
            "items": items if items is not None else ITEMS,
            "bench_options": bench_options,
            "result_path": str(work / "result.json"),
        }
        path = work / "request.json"
        path.write_text(json.dumps(payload))
        return path

    def run_main(self, request_path: Path) -> tuple[int, dict | None]:
        code = ds.main(["--request", str(request_path)])
        result_path = request_path.parent / "result.json"
        result = json.loads(result_path.read_text()) if result_path.exists() else None
        return code, result

    def by_id(self, result: dict) -> dict:
        return {item["id"]: item for item in result["items"]}

    def test_clean_run_validates_and_maps_cases(self):
        code, result = self.run_main(self.request())
        self.assertEqual(code, 0)
        self.assertEqual(validate_result(result, [i["id"] for i in ITEMS]), [])
        items = self.by_id(result)
        self.assertEqual(len(result["items"]), len(ITEMS))
        for item_id in ("p001", "p002", "odd/id.v2"):
            self.assertIsNone(items[item_id]["error"])
            # fake app echoes the fixture's own text, so WER 0 proves case_id -> item mapping
            self.assertEqual(items[item_id]["metrics"]["word_error_rate"], 0.0, item_id)
            self.assertEqual(items[item_id]["gates"], {"missing_text": 0, "silence_text": 0, "unstable_output": 0})
            for name in ("stop_to_text_s", "stop_to_delivery_s", "decode_s", "stop_to_saved_s"):
                self.assertIn(name, items[item_id]["metrics"])
        silence = items["silence-01"]
        self.assertNotIn("word_error_rate", silence["metrics"])
        self.assertIn("stop_to_text_s", silence["metrics"])
        self.assertEqual(silence["gates"]["silence_text"], 0)
        env = result["environment"]
        self.assertTrue(env["app_revision"].startswith("sha256:") and len(env["app_revision"]) == 23)
        self.assertEqual(env["model_init_s"], 1.25)
        self.assertTrue(env["host"] and env["os"])
        blob = json.dumps(result)
        self.assertNotIn("jordan", blob)  # no transcript text in the result

    def test_case_id_stems_are_unique_and_ordered(self):
        stems = [ds.case_stem(i, x) for i, x in enumerate(["b", "a/b", "a_b", "a.b"])]
        self.assertEqual(len(set(stems)), 4)
        self.assertEqual(stems, sorted(stems))
        self.assertEqual(stems[1], "0001-a_b")

    def test_wer_uses_saved_text(self):
        self.set_app_config({"replace": {"The meeting is on March 14th at 3:30 PM.": "The meeting is on March 14 at 3:30 PM."}})
        _, result = self.run_main(self.request())
        # ref normalized: the meeting is on march 14th at 3 30 pm (10 words); 1 substitution
        self.assertAlmostEqual(self.by_id(result)["p002"]["metrics"]["word_error_rate"], 0.1)

    def test_missing_text_gate(self):
        self.set_app_config({"replace": {"Ship it.": ""}})
        _, result = self.run_main(self.request())
        item = self.by_id(result)["p001"]
        self.assertEqual(item["gates"]["missing_text"], 1)
        self.assertEqual(item["metrics"]["word_error_rate"], 1.0)
        self.assertNotIn("stop_to_saved_s", item["metrics"])

    def test_silence_text_gate(self):
        self.set_app_config({"silence_text": "thank you"})
        _, result = self.run_main(self.request())
        item = self.by_id(result)["silence-01"]
        self.assertEqual(item["gates"]["silence_text"], 1)
        self.assertNotIn("word_error_rate", item["metrics"])

    def test_unstable_output_fires_on_second_repetition(self):
        _, first = self.run_main(self.request(repetition=0))
        self.assertEqual(self.by_id(first)["p001"]["gates"]["unstable_output"], 0)
        _, same = self.run_main(self.request(repetition=1))
        self.assertEqual(self.by_id(same)["p001"]["gates"]["unstable_output"], 0)
        self.set_app_config({"replace": {"Ship it.": "Ship it now."}})
        _, changed = self.run_main(self.request(repetition=2))
        self.assertEqual(self.by_id(changed)["p001"]["gates"]["unstable_output"], 1)
        self.assertEqual(self.by_id(changed)["p002"]["gates"]["unstable_output"], 0)
        # a different trial id starts fresh
        _, other = self.run_main(self.request(repetition=0, trial_id="t0002"))
        self.assertEqual(self.by_id(other)["p001"]["gates"]["unstable_output"], 0)
        self.assertTrue((self.work_root / "dictation-hashes.json").exists())

    def test_env_knobs_reach_binary(self):
        dump = self.root / "env.json"
        self.set_app_config({"env_dump": str(dump)})
        knobs = {"dictation.stop.path": "chunked", "dictation.stop.finalization_order": "saveAfterAutoEnter",
                 "dictation.stop.chunk_seconds": 12.5, "speech.parakeet.encoder_compute_units": "all"}
        with mock.patch.dict(os.environ, {"TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS": "all",
                                          "TRANSCRIPTED_DICTATION_STOP_BENCH_ITERATIONS": "9"}):
            request_path = self.request(knobs=knobs)
            code, result = self.run_main(request_path)
        self.assertEqual(code, 0)
        env = json.loads(dump.read_text())
        prefix = "TRANSCRIPTED_DICTATION_STOP_BENCH_"
        self.assertEqual(env[prefix + "VARIANT"], "chunked")
        self.assertEqual(env[prefix + "FINALIZATION_ORDER"], "saveAfterAutoEnter")
        self.assertEqual(env[prefix + "CHUNK_SECONDS"], "12.5")
        self.assertEqual(env[prefix + "ITERATIONS"], "1")
        self.assertEqual(env[prefix + "AUTO_ENTER"], "1")
        self.assertEqual(env["TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS"], "all")
        for flag in ("TRANSCRIPTED_DISABLE_FILE_LOGGER", "TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS",
                     "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"):
            self.assertEqual(env[flag], "1")
        self.assertEqual(env["HOME"], env["CFFIXED_USER_HOME"])
        self.assertTrue(env["HOME"].startswith(str(request_path.parent)))
        self.assertEqual(result["environment"]["encoder_compute_units"], "all")
        # chunked variant has no decode_s in the runner's output
        self.assertNotIn("decode_s", self.by_id(result)["p001"]["metrics"])

    def test_defaults_when_knobs_absent(self):
        self.assertEqual(ds.stop_settings({}), {"VARIANT": "production", "FINALIZATION_ORDER": "saveBeforeAutoEnter", "CHUNK_SECONDS": "30"})
        with self.assertRaises(ValueError):
            ds.stop_settings({"dictation.stop.path": "warp"})

    def test_missing_binary_is_clean_error(self):
        request_path = self.request(app_binary=str(self.root / "nope" / "Transcripted"))
        with mock.patch("sys.stderr") as stderr:
            code, result = self.run_main(request_path)
        self.assertEqual(code, 2)
        self.assertIn("app binary missing", "".join(str(c.args[0]) for c in stderr.write.call_args_list))
        self.assertEqual(result["environment"]["app_revision"], "missing")
        self.assertTrue(all(i["error"] for i in result["items"]))

    def test_say_failure_for_one_item_is_per_item(self):
        items = ITEMS + [{"id": "p009", "kind": "speech", "text": "FAILSAY please"}]
        code, result = self.run_main(self.request(items=items))
        self.assertEqual(code, 0)
        items_by_id = self.by_id(result)
        self.assertIn("fixture", items_by_id["p009"]["error"])
        self.assertIsNone(items_by_id["p001"]["error"])

    def test_say_failure_everywhere_exits_nonzero(self):
        items = [{"id": "p1", "kind": "speech", "text": "FAILSAY one"}, {"id": "s", "kind": "silence", "seconds": 1}]
        with mock.patch("sys.stderr"):
            code, _ = self.run_main(self.request(items=items))
        self.assertEqual(code, 2)

    def test_dropped_case_becomes_item_error(self):
        self.set_app_config({"drop": ["-p002"]})
        _, result = self.run_main(self.request())
        self.assertEqual(validate_result(result, [i["id"] for i in ITEMS]), [])
        self.assertEqual(self.by_id(result)["p002"]["error"], "no case_result")

    def test_fixture_cache_is_reused(self):
        self.run_main(self.request())
        cached = sorted((self.root / "cache").glob("*.wav"))
        self.assertEqual(len(cached), 3)
        expected = ds.fixture_key("Samantha", 170, "Ship it.") + ".wav"
        self.assertIn(expected, [p.name for p in cached])
        mtimes = [p.stat().st_mtime_ns for p in cached]
        self.run_main(self.request(repetition=1))
        self.assertEqual(mtimes, [p.stat().st_mtime_ns for p in sorted((self.root / "cache").glob("*.wav"))])

    def test_silence_fixture_shape(self):
        path = self.root / "s.wav"
        ds.write_silence(path, 0.25)
        with wave.open(str(path)) as h:
            self.assertEqual((h.getnchannels(), h.getsampwidth(), h.getframerate(), h.getnframes()), (1, 2, 48000, 12000))

    def test_real_suite_shape(self):
        suite_path = HERE.parents[2] / "config" / "hillclimb" / "suites" / "dictation-phrases-v1.json"
        suite = json.loads(suite_path.read_text())
        speech = [i for i in suite["items"] if i["kind"] == "speech"]
        silence = [i for i in suite["items"] if i["kind"] == "silence"]
        self.assertEqual(suite["salt"], "dictation-phrases-v1")
        self.assertGreaterEqual(len(speech), 55)
        self.assertEqual(sorted(i["split"] for i in silence), ["dev", "dev", "dev", "holdout"])
        self.assertTrue(all(ds.normalize_words(i["text"]) for i in speech))


if __name__ == "__main__":
    unittest.main()
