#!/usr/bin/env python3
"""Tests for naming_sim.py on synthetic embeddings (no real data, no app state).

Promises checked:
  1. A perfectly separable voiceprint: zero wrong names, and once a regular has been named and
     confirmed (meetings 1 and 2), every later meeting names them silently: zero naming work
     from meeting 3 on.
  2. A random voiceprint (no speaker information): the calibrated bars never let it name anyone
     silently on the held-out speakers, so it can't produce a wrong name.
  3. The simulated user and the app ladder behave as documented on a hand-built sequence
     (type, confirm, then silent), and two people with the same voice produce a counted wrong name
     when the bars are forced low.
  4. Missing embeddings are skipped, not fatal.
  5. Clips on the answer-key audit's drop list are excluded (and can be kept with drops=False).

Run: data/eval/voiceprint/venv/bin/python scripts/voiceprint/test_naming_sim.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import naming_sim as ns  # noqa: E402


def write_set(root: Path, name: str, rows: list[dict]) -> None:
    d = root / "sets" / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "segments.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
    (d / "READY").write_text("ok\n")


def seg_rows(set_name: str, speaker: str, session: str, stranger: bool, clips: int = 3) -> list[dict]:
    rows = []
    for n, bucket in enumerate((2, 4, 8)[:clips] if clips <= 3 else [2, 4, 8] * (clips // 3)):
        seg = f"{set_name}:{speaker}:{session}:{n}".replace(" ", "_")
        r = {"seg_id": seg, "set": set_name, "speaker": f"{set_name}:{speaker}", "session": f"{set_name}:{session}",
             "bucket": bucket, "dur": bucket, "clip": f"clips/{set_name}/clean/{seg}.wav"}
        if stranger:
            r["stranger_only"] = True
        rows.append(r)
    return rows


def build_synthetic_vp(root: Path, dim: int = 192, seed: int = 7) -> dict[str, list[dict]]:
    """Two sets: `syn` (synthetic groups: 40 regulars x 6 sessions, 12 one-session strangers) and
    `ami` (natural series: 14 series of 4 people x 4 meetings, ES20xxa-d, plus 6 walk-ins)."""
    sets: dict[str, list[dict]] = {"syn": [], "ami": []}
    for i in range(40):
        for s in range(6):
            sets["syn"] += seg_rows("syn", f"spk{i:02d}", f"v{i:02d}_{s}", False)
    for i in range(12):
        sets["syn"] += seg_rows("syn", f"one{i:02d}", f"w{i:02d}", True)
    for series in range(14):
        sid = f"ES20{series:02d}"
        for letter in "abcd":
            for p in range(4):
                sets["ami"] += seg_rows("ami", f"{sid}_p{p}", f"{sid}{letter}", False)
        if series < 6:
            sets["ami"] += seg_rows("ami", f"{sid}_guest", f"{sid}c", True)
    for name, rows in sets.items():
        write_set(root, name, rows)
    # a set with segments but no embeddings at all: must be skipped
    write_set(root, "libri", seg_rows("libri", "r1", "c1", True))
    return sets


def write_model(root: Path, model: str, sets: dict[str, list[dict]], fn, drop_every: int = 0) -> None:
    out = root / "emb" / model
    out.mkdir(parents=True, exist_ok=True)
    for name, rows in sets.items():
        ids, embs = [], []
        for k, r in enumerate(rows):
            if drop_every and k % drop_every == 0:
                continue  # some clips failed to embed
            ids.append(r["seg_id"])
            embs.append(fn(r))
        np.savez(out / f"{name}__clean.npz", seg_id=np.array(ids), emb=np.stack(embs).astype(np.float32))


def perfect_fn(dim: int, seed: int):
    rng = np.random.default_rng(seed)
    centroids: dict[str, np.ndarray] = {}

    def fn(r: dict) -> np.ndarray:
        spk = r["speaker"]
        if spk not in centroids:
            centroids[spk] = rng.standard_normal(dim)
            centroids[spk] /= np.linalg.norm(centroids[spk])
        noise = np.random.default_rng(ns.hnum("noise", r["seg_id"]) % 2**32).standard_normal(dim)
        return 3.0 * (centroids[spk] + 0.01 * noise)  # raw scale: the sim must normalize

    return fn


def random_fn(dim: int):
    def fn(r: dict) -> np.ndarray:
        return np.random.default_rng(ns.hnum("rand", r["seg_id"]) % 2**32).standard_normal(dim)

    return fn


class SyntheticEndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory(prefix="naming_sim_test_")
        cls.root = Path(cls.tmp.name)
        cls.old_root = os.environ.get("VP_ROOT")
        os.environ["VP_ROOT"] = str(cls.root)
        sets = build_synthetic_vp(cls.root)
        write_model(cls.root, "perfect", sets, perfect_fn(192, 1))
        write_model(cls.root, "random", sets, random_fn(192), drop_every=17)
        opts = ns.Options(reps=2)
        cls.docs = {}
        for model in ("perfect", "random"):
            name, status = ns.run_one((model, opts, True))
            cls.docs[model] = json.loads((cls.root / "results" / "naming" / f"{model}.json").read_text())
        ns.write_summary(cls.root / "results" / "naming", cls.root / "results" / "naming_summary.md")

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.old_root is None:
            os.environ.pop("VP_ROOT", None)
        else:
            os.environ["VP_ROOT"] = cls.old_root
        cls.tmp.cleanup()

    def test_perfect_model_names_regulars_silently_from_meeting_3_with_no_wrong_names(self) -> None:
        doc = self.docs["perfect"]
        for view in ("test", "calib"):
            self.assertEqual(doc["pooled"][view]["all"]["wrong_silent_names"], 0, view)
            self.assertEqual(doc["pooled"][view]["all"]["strangers_wrongly_named"], 0, view)
        invite = [r for r in doc["rows"] if r["split"] == "test" and r["mode"] == "invite"]
        self.assertTrue(invite)
        for r in invite:
            self.assertEqual(r["regular_work_from_meeting3"], 0, (r["set"], r["talk"], r["fold"]))
            self.assertEqual(r["auto_share_from_meeting3"], 1.0, (r["set"], r["talk"], r["fold"]))
            self.assertEqual(r["first_auto_median"], 3)
        # With no invite the lineup is the 12 people heard most recently. Three active groups of up
        # to 6 plus named strangers overflow it, and off-lineup people need 5 confirmations. That's the
        # app's policy, not the voiceprint: a perfect model must never miss for any other reason.
        recent = doc["pooled"]["test"]["by_mode"]["recent"]
        self.assertEqual(recent["wrong_silent_names"], 0)
        self.assertEqual(set(recent["why_not_auto_from_meeting3"]), {"off_lineup_confirmations"})

    def test_random_model_never_names_anyone_silently_on_held_out_speakers(self) -> None:
        doc = self.docs["random"]
        test_rows = [r for r in doc["rows"] if r["split"] == "test"]
        self.assertTrue(test_rows)
        for r in test_rows:
            self.assertEqual(r["decisions"]["auto_ok"] + r["decisions"]["auto_wrong"], 0,
                             (r["set"], r["talk"], r["mode"], r["fold"]))
        self.assertEqual(doc["pooled"]["calib"]["all"]["wrong_silent_names"], 0)

    def test_both_folds_calibrate_disjoint_halves(self) -> None:
        for doc in self.docs.values():
            self.assertEqual([(f["calib_split"], f["test_split"]) for f in doc["folds"]], [(0, 1), (1, 0)])
            for f in doc["folds"]:
                b = f["bars"]
                self.assertGreaterEqual(b["auto_global"], b["auto_lineup"])
                self.assertEqual(b["confirms_lineup"], 2)
                self.assertEqual(b["confirms_global"], 5)
                self.assertEqual(b["margin_global"], 0.12)
            self.assertEqual(set(doc["sets"]), {"syn", "ami"})  # libri has no embeddings: skipped
            self.assertEqual(doc["splits"]["ami"]["method"], "component")

    def test_summary_lists_both_models_with_perfect_first(self) -> None:
        text = (self.root / "results" / "naming_summary.md").read_text()
        self.assertLess(text.index("| perfect |"), text.index("| random |"))


def voice(person: str, vec: np.ndarray, stranger: bool = False, nseg: int = 9) -> ns.Voice:
    return ns.Voice(person, stranger, ns.unit(vec).astype(np.float32), nseg, 10.0)


class LadderOnHandBuiltMeetings(unittest.TestCase):
    def setUp(self) -> None:
        rng = np.random.default_rng(3)
        self.a = rng.standard_normal(64)
        self.b = rng.standard_normal(64)

    def test_type_then_confirm_then_silent(self) -> None:
        bars = ns.make_bars(0.5, 0.6, 0.9)
        meetings = [ns.SimMeeting([voice("ann", self.a), voice("bob", self.b)], frozenset({"ann", "bob"})) for _ in range(4)]
        r = ns.simulate(meetings, bars, "invite")
        self.assertEqual(r.counts["ask_new"], 2)
        self.assertEqual(r.counts["suggest_ok"], 2)
        self.assertEqual(r.counts["auto_ok"], 4)
        self.assertEqual(r.counts["work"], 2 * 3 + 2 * 1)
        self.assertEqual(r.counts["reg_work_3plus"], 0)
        self.assertEqual(dict(r.first_auto), {"3": 2})

    def test_off_lineup_needs_five_confirmations(self) -> None:
        bars = ns.make_bars(0.5, 0.6, 0.9)
        meetings = [ns.SimMeeting([voice("ann", self.a)], frozenset()) for _ in range(7)]
        r = ns.simulate(meetings, bars, "invite")  # invite that never lists ann
        self.assertEqual(r.counts["auto_ok"], 2)   # meetings 6 and 7
        self.assertEqual(dict(r.first_auto), {"6": 1})

    def test_same_voice_two_people_is_a_counted_wrong_name(self) -> None:
        bars = ns.make_bars(0.5, 0.6, 0.9)
        meetings = [ns.SimMeeting([voice("ann", self.a)], frozenset({"ann"})) for _ in range(3)]
        meetings.append(ns.SimMeeting([voice("twin", self.a, stranger=True)], frozenset({"ann"})))
        r = ns.simulate(meetings, bars, "invite")
        self.assertEqual(r.counts["auto_wrong"], 1)
        self.assertEqual(r.counts["stranger_auto_wrong"], 1)
        self.assertEqual(r.counts["new_auto_wrong"], 1)
        self.assertEqual(r.counts["work"], 3 + 1 + 0 + 10)


class Helpers(unittest.TestCase):
    def test_geometry_carries_app_constants_between_impostor_and_genuine_medians(self) -> None:
        self.assertEqual(ns.make_bars(0.7, 0.8, 0.92), ns.APP_BARS)
        same = ns.Geometry(0.1, 0.7, 0.1, 0.7)
        self.assertAlmostEqual(same.map(0.8), 0.8)
        squeezed = ns.Geometry(0.95, 0.98, 0.1, 0.7)  # un-centered x-vector: everything near 1
        bars = ns.make_bars(0.97, 0.99, 0.99, squeezed)
        self.assertAlmostEqual(bars.margin_lineup, 0.10 * 0.05)
        self.assertAlmostEqual(bars.floor_one - bars.floor, 0.15 * 0.05)
        self.assertAlmostEqual(bars.wb_confident, 0.95 + 0.7 * 0.05)
        fixed = ns.make_bars(0.97, 0.99, 0.99, squeezed, fixed_margins=True)
        self.assertEqual(fixed.margin_global, 0.12)

    def test_audit_drop_list_removes_clips_and_can_turn_a_speaker_into_a_stranger(self) -> None:
        with tempfile.TemporaryDirectory(prefix="naming_sim_drops_") as tmp:
            root = Path(tmp)
            rows = seg_rows("dd", "ann", "s1", False) + seg_rows("dd", "ann", "s2", False) + seg_rows("dd", "bob", "s3", False)
            write_set(root, "dd", rows)
            (root / "results" / "audit").mkdir(parents=True)
            dropped = [r["seg_id"] for r in rows if r["session"] == "dd:s2"] + [rows[-1]["seg_id"]]
            (root / "results" / "audit" / "drop_dd.txt").write_text("\n".join(dropped) + "\n")
            old = os.environ.get("VP_ROOT")
            os.environ["VP_ROOT"] = str(root)
            try:
                si = ns.load_set("dd")
                kept = ns.load_set("dd", drops=False)
            finally:
                if old is None:
                    os.environ.pop("VP_ROOT", None)
                else:
                    os.environ["VP_ROOT"] = old
            self.assertEqual(si.dropped, 4)
            self.assertEqual(si.sessions_of["dd:ann"], ["dd:s1"])
            self.assertIn("dd:ann", si.stranger_only)      # one session left: only useful as a stranger
            self.assertEqual(len(si.clips[("dd:bob", "dd:s3")]), 2)
            self.assertEqual(kept.dropped, 0)
            self.assertNotIn("dd:ann", kept.stranger_only)

    def test_group_keys(self) -> None:
        self.assertEqual(ns.group_key("ami:ES2002a"), "ES2002")
        self.assertEqual(ns.group_key("icsi:Bmr001"), "Bmr")


if __name__ == "__main__":
    unittest.main(verbosity=2)
