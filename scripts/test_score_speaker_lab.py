#!/usr/bin/env python3
"""Unit tests for the speaker lab scorer (scripts/score_speaker_lab.py) and the shared
math in scripts/speaker_eval_common.py. Plain unittest, synthetic fixtures, no audio,
no Swift, runs on Linux:

    python3 scripts/test_score_speaker_lab.py
"""
import io
import json
import os
import random
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_speaker_lab as lab  # noqa: E402
from speaker_eval_common import (  # noqa: E402
    ASKED_AGAIN, FALSE_MATCH, NEW_OK, RECOGNIZED, UNDETECTED, WRONG_PERSON,
    diarization_error, hungarian_max, identity_metrics, recognition_metrics, union_seconds,
)

try:  # optional cross-check against the reference implementation
    import warnings
    warnings.filterwarnings("ignore")
    from pyannote.core import Annotation, Segment
    from pyannote.metrics.diarization import DiarizationErrorRate
    HAVE_PYANNOTE = True
except Exception:  # pragma: no cover
    HAVE_PYANNOTE = False


def turns(spec):
    """'A:0-10 B:10-20' -> [(0,10,'A'), (10,20,'B')]"""
    out = []
    for tok in spec.split():
        lbl, rng = tok.split(":")
        s, e = rng.split("-")
        out.append((float(s), float(e), lbl))
    return out


class DERTests(unittest.TestCase):
    def test_perfect_hypothesis_is_zero_even_with_other_labels(self):
        ref = turns("A:0-10 B:10-25 A:25-30 C:30-40")
        hyp = [(s, e, {"A": "p9", "B": "p1", "C": "p4"}[l]) for s, e, l in ref]
        for collar in (0.0, 0.25):
            d = diarization_error(ref, hyp, collar=collar)
            self.assertAlmostEqual(d["der"], 0.0)
            self.assertAlmostEqual(d["jer"], 0.0)
        self.assertEqual(d["mapping"], {"p9": "A", "p1": "B", "p4": "C"})

    def test_empty_hypothesis_is_all_miss(self):
        d = diarization_error(turns("A:0-10 B:10-20"), [], collar=0.0)
        self.assertAlmostEqual(d["der"], 1.0)
        self.assertAlmostEqual(d["miss_rate"], 1.0)
        self.assertAlmostEqual(d["jer"], 1.0)

    def test_merged_speakers_are_confusion(self):
        # one hyp speaker covers two ref speakers -> half the speech is confused
        d = diarization_error(turns("A:0-10 B:10-20"), [(0, 20, "x")], collar=0.0)
        self.assertAlmostEqual(d["confusion_rate"], 0.5)
        self.assertAlmostEqual(d["miss_rate"], 0.0)
        self.assertAlmostEqual(d["false_alarm_rate"], 0.0)

    def test_false_alarm_outside_reference(self):
        d = diarization_error(turns("A:0-10"), [(0, 10, "x"), (10, 15, "x")], collar=0.0)
        self.assertAlmostEqual(d["false_alarm_rate"], 0.5)

    def test_collar_forgives_boundary_jitter(self):
        ref = turns("A:0-10 B:10-20")
        hyp = [(0, 10.1, "a"), (10.1, 20, "b")]
        self.assertGreater(diarization_error(ref, hyp, collar=0.0)["der"], 0)
        self.assertAlmostEqual(diarization_error(ref, hyp, collar=0.25)["der"], 0.0)

    def test_hungarian_rectangular(self):
        pairs = hungarian_max([[1, 9, 0], [8, 1, 0]])
        self.assertEqual(sorted(pairs), [(0, 1), (1, 0)])
        self.assertEqual(hungarian_max([]), [])

    @unittest.skipUnless(HAVE_PYANNOTE, "pyannote.metrics not installed")
    def test_matches_pyannote_on_random_fixtures(self):
        def ann(segs):
            a = Annotation()
            for i, (s, e, l) in enumerate(segs):
                a[Segment(s, e), i] = l
            return a
        rng = random.Random(11)
        for _ in range(60):
            def gen(labels, k):
                out = []
                for _ in range(k):
                    s = round(rng.uniform(0, 120), 3)
                    out.append((s, s + round(rng.uniform(0.2, 12), 3), rng.choice(labels)))
                return out
            ref = gen(["A", "B", "C", "D"], rng.randint(1, 25))
            hyp = gen([0, 1, 2, 3, 4], rng.randint(1, 25))
            for collar in (0.0, 0.25):
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore")   # "uem was approximated" — same default we use
                    want = DiarizationErrorRate(collar=collar, skip_overlap=False)(ann(ref), ann(hyp))
                self.assertAlmostEqual(diarization_error(ref, hyp, collar=collar)["der"], want, places=9)

    def test_fast_enough_for_meeting_sized_inputs(self):
        rng = random.Random(5)
        ref, t = [], 0.0
        for _ in range(2000):
            d = rng.uniform(0.2, 3)
            ref.append((t, t + d, f"S{rng.randint(0, 3)}"))
            t += d * rng.uniform(0.6, 1.4)
        hyp, t = [], 0.0
        for _ in range(300):
            d = rng.uniform(1, 20)
            hyp.append((t, t + d, rng.randint(0, 4)))
            t += d
        t0 = time.time()
        diarization_error(ref, hyp, collar=0.25)
        self.assertLess(time.time() - t0, 2.0)

    def test_union_seconds(self):
        self.assertAlmostEqual(union_seconds([(0, 5), (3, 8), (10, 11)]), 9.0)


def whole(meeting_spec):
    return turns(meeting_spec)


class RecognitionTests(unittest.TestCase):
    def series(self):
        # meeting 1: A->pA, B->pB, C->pC, D->pD (all new)
        m1_ref = whole("A:0-20 B:20-40 C:40-60 D:60-80")
        m1_hyp = [(0, 20, "pA"), (20, 40, "pB"), (40, 60, "pC"), (60, 80, "pD")]
        # meeting 2: A recognized, B lands on A's profile (wrong person), C gets a brand-new
        # profile (asked again), D is not detected, E is new but matched to pA (false match)
        m2_ref = whole("A:0-20 B:20-40 C:40-60 D:60-80 E:80-100")
        m2_hyp = [(0, 20, "pA"), (20, 40, "pA"), (40, 60, "pC2"), (80, 100, "pA")]
        # meeting 3: F is new and correctly new; A recognized; tiny speaker G ignored
        m3_ref = whole("A:0-20 F:20-40 G:40-42")
        m3_hyp = [(0, 20, "pA"), (20, 40, "pF"), (40, 42, "pA")]
        return [("m1", m1_ref, m1_hyp), ("m2", m2_ref, m2_hyp), ("m3", m3_ref, m3_hyp)]

    def test_outcomes(self):
        r = recognition_metrics(self.series(), min_appearance_sec=5.0)
        got = {(e["meeting"], e["speaker"]): e["outcome"] for e in r["events"]}
        self.assertEqual(got[("m1", "A")], NEW_OK)
        self.assertEqual(got[("m2", "A")], RECOGNIZED)
        self.assertEqual(got[("m2", "B")], WRONG_PERSON)
        self.assertEqual(got[("m2", "C")], ASKED_AGAIN)
        self.assertEqual(got[("m2", "D")], UNDETECTED)
        self.assertEqual(got[("m2", "E")], FALSE_MATCH)
        self.assertEqual(got[("m3", "A")], RECOGNIZED)
        self.assertEqual(got[("m3", "F")], NEW_OK)
        self.assertNotIn(("m3", "G"), got)  # under min_appearance_sec
        self.assertEqual(r["returningAppearances"], 5)
        self.assertEqual((r["recognized"], r["wrongPerson"], r["askedAgain"], r["undetected"]), (2, 1, 1, 1))
        self.assertAlmostEqual(r["recognizedRate"], 0.4)
        self.assertEqual(r["firstAppearances"], 6)
        self.assertEqual(r["firstAppearanceFalseMatches"], 1)

    def test_profile_owner_is_majority_of_earlier_speech(self):
        # pX holds 15 s of A and 5 s of B in meeting 1 -> owned by A; B landing on it later is wrong.
        m1 = ("m1", whole("A:0-15 B:15-40"), [(0, 20, "pX"), (20, 40, "pB")])
        m2 = ("m2", whole("A:0-10 B:10-20"), [(0, 10, "pX"), (10, 20, "pX")])
        r = recognition_metrics([m1, m2])
        got = {(e["meeting"], e["speaker"]): e["outcome"] for e in r["events"]}
        self.assertEqual(got[("m2", "A")], RECOGNIZED)
        self.assertEqual(got[("m2", "B")], WRONG_PERSON)

    def test_identity_metrics_reid_curve(self):
        ident = identity_metrics(self.series())
        self.assertEqual(ident["reid_curve"]["1"], 1.0)
        self.assertIn("pA", ident["false_merge"])


class GridAndDumpTests(unittest.TestCase):
    def test_grid_is_cartesian_and_skips_empty(self):
        rows = lab.grid_settings({"match": "adaptive 0.6", "write_path_fixes": "on off", "dedup": ""})
        self.assertEqual(len(rows), 4)
        self.assertIn(("m-adaptive_fx-on", ["--match", "adaptive", "--write-path-fixes", "on"]), rows)
        self.assertEqual(lab.grid_settings({}), [("defaults", [])])

    def test_grid_cli_prints_tab_separated(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            lab.main(["grid", "--match", "0.55 0.6", "--same-voice", "profile"])
        lines = buf.getvalue().strip().split("\n")
        self.assertEqual(lines[0], "m-0.55_sv-profile\t--match 0.55 --same-voice profile")

    def test_dump_matches_variant(self):
        d = {"backend": "nemotron", "embedder": "wespeaker", "nemotronPreset": "fast32", "segments": []}
        self.assertTrue(lab.dump_matches(d, "nemotron", "native", "fast32"))
        self.assertFalse(lab.dump_matches(d, "nemotron", "native", ""))
        self.assertFalse(lab.dump_matches(d, "pyannote", "native", ""))
        self.assertFalse(lab.dump_matches(d, "nemotron", "eres2net", "fast32"))
        legacy = {"meeting": "x", "segments": []}   # pre-lab dump: never reused by the lab
        self.assertFalse(lab.dump_matches(legacy, "pyannote", "native", ""))


def write_text(path, text):
    with open(path, "w") as f:
        f.write(text)


def read_text(path):
    with open(path) as f:
        return f.read()


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f)


def make_dump(meeting, segs, backend="pyannote", embedder="wespeaker", audio=100.0, dia=1.0):
    return {"meeting": meeting, "audioPath": "/nowhere.wav", "durationSeconds": max(e for _, e, _ in segs),
            "diarizerSpeakerCount": len({l for _, _, l in segs}),
            "segments": [{"speakerId": l, "start": s, "end": e, "quality": 0.9, "embedding": None}
                         for s, e, l in segs],
            "backend": backend, "embedder": embedder, "embeddingDimension": 256,
            "diarizeSeconds": dia, "audioSeconds": audio, "initSeconds": 0.5, "nemotronPreset": None}


def make_replay(meetings, match=0.6, mode="fixed", profiles_at_end=4):
    return {"consolidationThreshold": "none", "matchThreshold": match, "writePathFixes": True,
            "profilesAtEnd": profiles_at_end, "matchMode": mode, "sameVoiceThreshold": 0.88,
            "thresholdProfile": "weSpeaker", "dedupThreshold": 0.6, "backend": "pyannote",
            "embedder": "wespeaker",
            "writeBack": {"confidentAlpha": 0.15, "cautiousAlpha": 0.05, "confidentSimilarity": 0.8,
                          "cautiousSimilarity": 0.72, "marginMin": 0.12},
            "meetings": [{"meeting": m, "diarizerClustersAfterConsolidation": len({p for _, _, p in a}),
                          "clusterToProfile": {}, "rawDiarizerClusters": 3,
                          "clusterStatus": st, "profilesAfterMeeting": 4,
                          "assignments": [{"start": s, "end": e, "diarizerCluster": 0, "dbProfile": p}
                                          for s, e, p in a]} for m, a, st in meetings]}


class EndToEndScoreTests(unittest.TestCase):
    def build_corpus_run(self, tmp):
        rttm = os.path.join(tmp, "rttm")
        os.makedirs(rttm)
        refs = {"ES1a": "A:0-30 B:30-60 C:60-90", "ES1b": "A:0-30 B:30-60 C:60-90"}
        for m, spec in refs.items():
            with open(os.path.join(rttm, f"{m}.rttm"), "w") as f:
                for s, e, l in turns(spec):
                    f.write(f"SPEAKER {m} 1 {s:.3f} {e - s:.3f} <NA> <NA> {l} <NA> <NA>\n")
        run = os.path.join(tmp, "run")
        os.makedirs(run)
        variants = [("good", os.path.join(tmp, "dumps", "good")), ("bad", os.path.join(tmp, "dumps", "bad"))]
        # good: perfect raw diarization; bad: merges B+C
        for m, spec in refs.items():
            segs = [(s, e, {"A": 0, "B": 1, "C": 2}[l]) for s, e, l in turns(spec)]
            write_json(os.path.join(variants[0][1], f"{m}.json"), make_dump(m, segs))
            segs_bad = [(s, e, {"A": 0, "B": 1, "C": 1}[l]) for s, e, l in turns(spec)]
            write_json(os.path.join(variants[1][1], f"{m}.json"), make_dump(m, segs_bad, backend="nemotron", dia=0.5))
        good_all = [(0, 30, "pA"), (30, 60, "pB"), (60, 90, "pC")]
        # good @0.6 recognizes everyone; good @0.7 asks again for C
        r_good_06 = make_replay([("ES1a", good_all, {"0": "new", "1": "new", "2": "new"}),
                                 ("ES1b", good_all, {"0": "matched", "1": "matched", "2": "matched"})], 0.6)
        r_good_07 = make_replay([("ES1a", good_all, {}),
                                 ("ES1b", [(0, 30, "pA"), (30, 60, "pB"), (60, 90, "pC2")], {})], 0.7)
        bad_pipe = [(0, 30, "pA"), (30, 90, "pB")]
        r_bad = make_replay([("ES1a", bad_pipe, {}), ("ES1b", bad_pipe, {})], mode="adaptive")
        paths = {}
        for name, rp in (("good_06", r_good_06), ("good_07", r_good_07), ("bad_ad", r_bad)):
            paths[name] = os.path.join(run, "replays", f"{name}.json")
            write_json(paths[name], rp)
        with open(os.path.join(run, "run.env"), "w") as f:
            f.write(f"MODE=corpus\nCORPUS=ami\nRTTM_DIR={rttm}\nCOLLAR=0.25\nMIN_APPEARANCE_SEC=5\n"
                    "WRONG_PENALTY=2\nGIT_REVISION=abc123\nGIT_DIRTY=0\nCOMMAND=test\nKNOB_MATCH=0.6 0.7\n")
        with open(os.path.join(run, "meetings.tsv"), "w") as f:
            f.write("ES1a\t\tES1a\nES1b\t\tES1b\n")
        with open(os.path.join(run, "variants.tsv"), "w") as f:
            f.write(f"good\tpyannote\twespeaker\t\t{variants[0][1]}\n")
            f.write(f"bad\tnemotron\twespeaker\tfast32\t{variants[1][1]}\n")
        with open(os.path.join(run, "replays.tsv"), "w") as f:
            f.write(f"good\tm-0.6\t{paths['good_06']}\ngood\tm-0.7\t{paths['good_07']}\n"
                    f"bad\tm-adaptive\t{paths['bad_ad']}\n")
        return run

    def test_corpus_scores_json_schema_and_values(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = self.build_corpus_run(tmp)
            self.assertEqual(lab.main(["score", "--run-dir", run, "--quiet"]), 0)
            with open(os.path.join(run, "scores.json")) as f:
                s = json.load(f)
            self.assertEqual(s["schema"], lab.SCHEMA)
            self.assertEqual(s["schemaVersion"], 1)
            self.assertEqual(s["gitRevision"], "abc123")
            self.assertEqual(s["meetings"], ["ES1a", "ES1b"])
            self.assertEqual(s["requestedKnobs"], {"match": "0.6 0.7"})
            good, bad = s["variants"]
            self.assertEqual(good["raw"]["meanDER"], 0.0)
            self.assertEqual(good["raw"]["meanSpeakerCountError"], 0.0)
            self.assertEqual(good["raw"]["exactSpeakerCountRate"], 1.0)
            self.assertEqual(bad["raw"]["meanSpeakerCountError"], -1.0)
            self.assertGreater(bad["raw"]["meanDER"], 0.3)
            self.assertEqual(good["speed"]["xRealtime"], 100.0)
            self.assertEqual(bad["speed"]["xRealtime"], 200.0)
            self.assertEqual(bad["nemotronPreset"], "fast32")
            # best setting for "good" is match 0.6 (everyone recognized)
            self.assertEqual(good["best"]["tag"], "m-0.6")
            self.assertEqual(good["best"]["knobs"]["match"], 0.6)
            self.assertEqual(good["best"]["recognition"]["recognizedRate"], 1.0)
            self.assertEqual(good["best"]["objective"], 1.0)
            self.assertEqual(good["best"]["pipeline"]["meanDER"], 0.0)
            by_tag = {x["tag"]: x for x in good["settings"]}
            self.assertEqual(by_tag["m-0.7"]["recognition"]["askedAgain"], 1)
            self.assertEqual(by_tag["m-0.6"]["perMeeting"][1]["clustersMatched"], 3)
            # bad: C lands on B's profile in meeting 2 -> wrong person
            self.assertEqual(bad["best"]["knobs"]["match"], "adaptive")
            self.assertEqual(bad["best"]["recognition"]["wrongPerson"], 1)
            self.assertEqual(bad["best"]["pipeline"]["meanSpeakerCountError"], -1.0)
            for f in ("REPORT.md", "recognition-events.json"):
                self.assertTrue(os.path.exists(os.path.join(run, f)))
            with open(os.path.join(run, "REPORT.md")) as f:
                md = f.read()
            self.assertIn("| **good** |", md)
            self.assertIn("What moved recognition", md)

    def test_score_fails_when_a_variant_has_no_dumps(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = self.build_corpus_run(tmp)
            with open(os.path.join(run, "variants.tsv"), "a") as f:
                f.write(f"empty\tpyannote\teres2net\t\t{os.path.join(tmp, 'nope')}\n")
            self.assertEqual(lab.main(["score", "--run-dir", run, "--quiet"]), 1)

    def test_own_calls_listing_and_score(self):
        with tempfile.TemporaryDirectory() as tmp:
            lib = os.path.join(tmp, "meetings")
            for i, stem in enumerate(["Call_2026-09-02", "Call_2026-09-01", "Imported thing"]):
                d = os.path.join(lib, "audio", f"{stem}_audio")
                os.makedirs(d)
                track = "recording.m4a" if stem.startswith("Imported") else "system_audio.m4a"
                for name in (track, "microphone.m4a"):
                    p = os.path.join(d, name)
                    write_text(p, "")
                    os.utime(p, (1000 + i * 10, {0: 2000, 1: 1000, 2: 3000}[i]))
            os.makedirs(os.path.join(lib, "audio", "Empty_audio"))
            rows = lab.find_call_tracks(lib)
            self.assertEqual([r[2] for r in rows], ["Call_2026-09-01", "Call_2026-09-02", "Imported thing"])
            self.assertTrue(rows[0][1].endswith("system_audio.m4a"))
            self.assertTrue(rows[2][1].endswith("recording.m4a"))
            self.assertTrue(all(r[0].startswith("call-") for r in rows))
            self.assertEqual(lab.find_call_tracks(lib), rows)  # stable ids

            run = os.path.join(tmp, "run")
            os.makedirs(run)
            vdirs = {v: os.path.join(tmp, "dumps", v) for v in ("a", "b")}
            replays = {}
            for v in vdirs:
                meets = []
                for cid, path, _ in rows:
                    segs = [(0, 10, 0), (10, 20, 1)] if v == "a" else [(0, 20, 0)]
                    write_json(os.path.join(vdirs[v], f"{cid}.json"), make_dump(cid, segs, audio=30.0))
                    meets.append((cid, [(0, 10, "p1"), (10, 20, "p2")], {"0": "matched", "1": "new"}))
                replays[v] = os.path.join(run, "replays", v, "prod.json")
                write_json(replays[v], make_replay(meets, mode="adaptive"))
            with open(os.path.join(run, "run.env"), "w") as f:
                f.write("MODE=own-calls\nGIT_REVISION=abc\n")
            with open(os.path.join(run, "meetings.tsv"), "w") as f:
                f.write("".join(f"{cid}\t{path}\t{stem}\n" for cid, path, stem in rows))
            with open(os.path.join(run, "variants.tsv"), "w") as f:
                f.write(f"a\tpyannote\twespeaker\t\t{vdirs['a']}\nb\tnemotron\twespeaker\t\t{vdirs['b']}\n")
            with open(os.path.join(run, "replays.tsv"), "w") as f:
                f.write(f"a\tprod\t{replays['a']}\nb\tprod\t{replays['b']}\n")
            self.assertEqual(lab.main(["score", "--run-dir", run, "--quiet"]), 0)
            with open(os.path.join(run, "scores.json")) as f:
                s = json.load(f)
            self.assertEqual(s["mode"], "own-calls")
            a, b = s["variants"]
            self.assertEqual(a["summary"]["meanRawSpeakers"], 2.0)
            self.assertEqual(b["summary"]["meanRawSpeakers"], 1.0)
            self.assertEqual(a["summary"]["clustersMatched"], 3)
            self.assertEqual(a["summary"]["clustersNew"], 3)
            self.assertAlmostEqual(a["perMeeting"][0]["speechCoverage"], 20 / 30, places=3)
            self.assertEqual(b["agreement"]["baseline"], "a")
            self.assertGreater(b["agreement"]["meanDerVsBaseline"], 0.0)
            raw_json = json.dumps(s)
            self.assertNotIn(tmp, raw_json)            # no local paths in scores.json
            self.assertNotIn("Call_2026", raw_json)    # no meeting names in scores.json
            with open(os.path.join(run, "timeline.html")) as f:
                page = f.read()
            self.assertIn("<!doctype html>", page)
            self.assertNotIn("<script src", page)       # self-contained
            self.assertNotIn("<link", page)
            self.assertNotIn(".m4a", page)              # never references audio
            self.assertIn("Call_2026-09-01", page)      # local-only page may show names


FAKE_HARNESS = r'''#!/usr/bin/env python3
# Stand-in for speaker-eval-harness so run_speaker_lab.sh can be exercised without Swift.
import json, os, sys
args = sys.argv[1:]
def val(name, default=None):
    return args[args.index(name) + 1] if name in args else default
cmd = args[0]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(" ".join(args) + " preset=" + os.environ.get("TRANSCRIPTED_NEMOTRON_PRESET", "-") + "\n")
if cmd == "dump":
    meeting = val("--meeting")
    if meeting == os.environ.get("FAKE_FAIL_MEETING"):
        print("error: diarization failed", file=sys.stderr); sys.exit(1)
    rttm = os.path.join(os.environ["FAKE_RTTM_DIR"], meeting + ".rttm")
    rows = [l.split() for l in open(rttm) if l.startswith("SPEAKER")]
    labels = sorted({r[7] for r in rows})
    backend = val("--backend", "pyannote")
    segs = []
    for r in rows:
        sid = labels.index(r[7])
        if backend == "nemotron" and sid == 2:
            sid = 1   # this fake "nemotron" merges two people
        s = float(r[3]); segs.append({"speakerId": sid, "start": s, "end": s + float(r[4]),
                                      "quality": 0.9, "embedding": None})
    emb = "eres2net" if val("--embedder") == "eres2net" else "wespeaker"
    dump = {"meeting": meeting, "audioPath": val("--audio"), "durationSeconds": 90.0,
            "diarizerSpeakerCount": len({s["speakerId"] for s in segs}), "segments": segs,
            "backend": backend, "embedder": emb, "embeddingDimension": 192 if emb == "eres2net" else 256,
            "diarizeSeconds": 1.0, "audioSeconds": 90.0, "initSeconds": 0.1,
            "nemotronPreset": (os.environ.get("TRANSCRIPTED_NEMOTRON_PRESET") or "default") if backend == "nemotron" else None}
    json.dump(dump, open(val("--out"), "w"))
    print("[dump] %s: ok -> %s" % (meeting, val("--out")), file=sys.stderr)
elif cmd == "replay":
    dumps = [json.load(open(p)) for p in val("--inputs").split(",")]
    match = val("--match", "0.6")
    meetings = []
    for i, d in enumerate(dumps):
        # at a strict fixed floor the fake "asks again" for everyone after the first meeting
        suffix = "-%d" % i if (match not in ("adaptive",) and float(match) >= 0.7 and i > 0) else ""
        a = [{"start": s["start"], "end": s["end"], "diarizerCluster": s["speakerId"],
              "dbProfile": "p%d%s" % (s["speakerId"], suffix)} for s in d["segments"]]
        st = {str(s["speakerId"]): ("new" if (i == 0 or suffix) else "matched") for s in d["segments"]}
        meetings.append({"meeting": d["meeting"], "diarizerClustersAfterConsolidation": len(st),
                         "clusterToProfile": {}, "assignments": a, "rawDiarizerClusters": len(st),
                         "clusterStatus": st, "profilesAfterMeeting": 3})
    out = {"consolidationThreshold": val("--consolidation", "none"),
           "matchThreshold": 0.7 if match == "adaptive" else float(match),
           "writePathFixes": val("--write-path-fixes", "off") == "on", "profilesAtEnd": 3,
           "matchMode": "adaptive" if match == "adaptive" else "fixed", "sameVoiceThreshold": 0.88,
           "thresholdProfile": "weSpeaker", "dedupThreshold": float(val("--dedup", "0.6")),
           "writeBack": {"confidentAlpha": float(val("--blend-confident", "0.15")), "cautiousAlpha": 0.05,
                         "confidentSimilarity": 0.8, "cautiousSimilarity": 0.72, "marginMin": 0.12},
           "backend": dumps[0]["backend"], "embedder": dumps[0]["embedder"], "meetings": meetings}
    json.dump(out, open(val("--out"), "w"))
else:
    sys.exit(2)
'''


class RunSpeakerLabShellTests(unittest.TestCase):
    """Drive scripts/run_speaker_lab.sh end to end against a fake harness."""
    SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run_speaker_lab.sh")

    def setUp(self):
        import subprocess
        self.subprocess = subprocess
        self.tmp = tempfile.mkdtemp()
        self.data = os.path.join(self.tmp, "data")
        rttm = os.path.join(self.data, "ami", "rttm")
        audio = os.path.join(self.data, "ami", "audio")
        os.makedirs(rttm)
        os.makedirs(audio)
        for m in ("ES9001a", "ES9001b", "ES9001c"):
            with open(os.path.join(rttm, m + ".rttm"), "w") as f:
                for s, e, l in turns("A:0-30 B:30-60 C:60-90"):
                    f.write(f"SPEAKER {m} 1 {s:.3f} {e - s:.3f} <NA> <NA> {l} <NA> <NA>\n")
            write_text(os.path.join(audio, m + ".Mix-Headset.wav"), "x")
        self.harness = os.path.join(self.tmp, "fake-harness")
        with open(self.harness, "w") as f:
            f.write(FAKE_HARNESS)
        os.chmod(self.harness, 0o755)
        self.log = os.path.join(self.tmp, "calls.log")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_lab(self, *args, extra_env=None):
        env = dict(os.environ, HARNESS_BIN=self.harness, LAB_DATA_DIR=self.data, FAKE_LOG=self.log,
                   FAKE_RTTM_DIR=os.path.join(self.data, "ami", "rttm"), HOME=self.tmp)
        for k in ("VARIANTS", "MATCH", "SERIES", "OUT_DIR", "NEMOTRON_PRESET", "TRANSCRIPTED_NEMOTRON_PRESET"):
            env.pop(k, None)
        env.update(extra_env or {})
        return self.subprocess.run(["bash", self.SCRIPT, *args], env=env, capture_output=True, text=True)

    def test_sweep_two_variants(self):
        out = os.path.join(self.tmp, "run")
        p = self.run_lab("--variants", "pyannote:native nemotron:native:fast32", "--match", "0.6 0.7",
                         "--out-dir", out)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip().split("\n")[-1], os.path.join(out, "scores.json"))
        with open(os.path.join(out, "scores.json")) as f:
            s = json.load(f)
        names = [v["name"] for v in s["variants"]]
        self.assertEqual(names, ["pyannote-wespeaker", "nemotron-wespeaker-fast32"])
        py, ne = s["variants"]
        self.assertEqual(len(py["settings"]), 2)
        self.assertEqual(py["best"]["knobs"]["match"], 0.6)
        self.assertEqual(py["best"]["recognition"]["recognizedRate"], 1.0)
        self.assertEqual(py["raw"]["meanDER"], 0.0)
        self.assertEqual(ne["raw"]["meanSpeakerCountError"], -1.0)
        self.assertEqual(s["requestedKnobs"]["match"], "0.6 0.7")
        self.assertEqual(s["requestedKnobs"]["write_path_fixes"], "on")
        calls = read_text(self.log)
        self.assertIn("--backend nemotron", calls)
        self.assertIn("preset=fast32", calls)
        self.assertIn("--dedup 0.6", calls)
        self.assertTrue(os.path.exists(os.path.join(self.data, "eval", "ami", "dumps",
                                                    "nemotron-wespeaker-fast32", "ES9001a.json")))
        # second run reuses the per-variant cache: no new dump calls
        n_dumps = calls.count("dump ")
        p = self.run_lab("--variants", "pyannote:native nemotron:native:fast32", "--match", "0.6",
                         "--out-dir", os.path.join(self.tmp, "run2"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(read_text(self.log).count("dump "), n_dumps)
        # a different preset is a different variant -> fresh dumps, never the fast32 cache
        p = self.run_lab("--variants", "nemotron:native", "--match", "0.6", "--out-dir", os.path.join(self.tmp, "run3"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(read_text(self.log).count("dump "), n_dumps + 3)
        self.assertIn("preset=-", read_text(self.log).splitlines()[-4])

    def test_single_mode_prints_scores_path_last(self):
        p = self.run_lab("--single", "--backend", "pyannote", "--series", "ES9001",
                         "--blend-confident", "0.3", extra_env={"OUT_DIR": os.path.join(self.tmp, "single")})
        self.assertEqual(p.returncode, 0, p.stderr)
        path = p.stdout.strip().split("\n")[-1]
        with open(path) as f:
            s = json.load(f)
        self.assertTrue(s["single"])
        self.assertEqual(len(s["variants"]), 1)
        self.assertEqual(len(s["variants"][0]["settings"]), 1)
        knobs = s["variants"][0]["best"]["knobs"]
        self.assertEqual(knobs["match"], "adaptive")
        self.assertEqual(knobs["blendConfident"], 0.3)
        self.assertEqual(s["meetings"], ["ES9001a", "ES9001b", "ES9001c"])

    def test_single_rejects_grids_and_bad_flags(self):
        p = self.run_lab("--single", "--match", "0.6 0.7")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("single value", p.stderr)
        p = self.run_lab("--variants", "whisper:native")
        self.assertNotEqual(p.returncode, 0)
        p = self.run_lab("--bogus", "1")
        self.assertNotEqual(p.returncode, 0)

    def test_dump_failure_fails_the_run(self):
        p = self.run_lab("--single", extra_env={"FAKE_FAIL_MEETING": "ES9001b",
                                                "OUT_DIR": os.path.join(self.tmp, "f")})
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("dump failures", p.stderr)
        p = self.run_lab("--single", extra_env={"FAKE_FAIL_MEETING": "ES9001b", "ALLOW_PARTIAL_CORPUS": "1",
                                                "OUT_DIR": os.path.join(self.tmp, "g")})
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_own_calls_mode(self):
        lib = os.path.join(self.tmp, "meetings")
        for i, stem in enumerate(["Call_1", "Call_2"]):
            d = os.path.join(lib, "audio", f"{stem}_audio")
            os.makedirs(d)
            p = os.path.join(d, "system_audio.m4a")
            write_text(p, "x")
            os.utime(p, (1000 + i, 1000 + i))
        # the fake harness reads an RTTM named after the call id
        for cid, _, _ in lab.find_call_tracks(lib):
            with open(os.path.join(self.data, "ami", "rttm", cid + ".rttm"), "w") as f:
                for s, e, l in turns("X:0-40 Y:40-80"):
                    f.write(f"SPEAKER {cid} 1 {s:.3f} {e - s:.3f} <NA> <NA> {l} <NA> <NA>\n")
        out = os.path.join(self.tmp, "own")
        p = self.run_lab("--own-calls", lib, "--variants", "pyannote:native nemotron:native", "--out-dir", out)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip().split("\n")[-1], os.path.join(out, "scores.json"))
        for f in ("REPORT.md", "scores.json", "timeline.html"):
            self.assertTrue(os.path.exists(os.path.join(out, f)), f)
        self.assertTrue(os.path.isdir(os.path.join(self.data, "eval", "own-calls", "dumps", "pyannote-wespeaker")))
        # audio is read in place, never copied into the run dir
        copied = [f for _, _, fs in os.walk(out) for f in fs if f.endswith((".m4a", ".wav"))]
        self.assertEqual(copied, [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
