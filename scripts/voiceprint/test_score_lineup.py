#!/usr/bin/env python3
"""Tests for score_lineup.py on synthetic embeddings (no real data, no app state).

Promises checked:
  1. A perfectly separable voiceprint puts the right person on top every time and, at the
     zero-wrong-names bar, names 100% of known people with 0 misidentifications and 0 strangers named.
  2. A random voiceprint (no speaker information) does not: low rank-1 and low DIR at zero wrong names.
  3. At the zero-wrong bar nothing wrong is named, on a hand-built example; the 1% FA bar lets through
     at most 1% of strangers.
  4. Strangers are never enrolled: every stranger_only person, plus 20% of each set's multi-session
     people; audit drop-list clips are left out.

Run: data/eval/voiceprint/venv/bin/python scripts/voiceprint/test_score_lineup.py
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
import score_lineup as sl  # noqa: E402

N_MULTI, N_SO, N_SESS, N_CLIPS, DIM = 10, 2, 3, 3, 128


def build_root(root: Path) -> dict[str, list[dict]]:
    """Four human sets and a yodas set: N_MULTI people x N_SESS sessions, plus N_SO one-session strangers."""
    sets: dict[str, list[dict]] = {}
    for name in sl.HUMAN_SETS + (sl.XDIST_SET,):
        rows = []
        people = [(f"p{i}", False, N_SESS) for i in range(N_MULTI if name != sl.XDIST_SET else 0)]
        people += [(f"s{i}", True, 1) for i in range(N_SO if name != sl.XDIST_SET else 5)]
        for pi, (spk, so, n_sess) in enumerate(people):
            for j in range(n_sess):
                for n in range(N_CLIPS):
                    rows.append({"seg_id": f"{name}:{spk}:{j}:{n}", "set": name, "speaker": f"{name}:{spk}",
                                 "session": f"{name}:{spk}-{j}", "bucket": 4, "dur": 4.0,
                                 "clip": f"clips/{name}/clean/{name}:{spk}:{j}:{n}.wav",
                                 "gender": "MF"[pi % 2], "stranger_only": so, "session_order": j})
        d = root / "sets" / name
        d.mkdir(parents=True)
        (d / "segments.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        sets[name] = rows
    audit = root / "results" / "audit"
    audit.mkdir(parents=True)
    (audit / "drop_vox1o.txt").write_text("vox1o:p0:0:0\n")
    return sets


def write_model(root: Path, model: str, sets: dict[str, list[dict]], perfect: bool) -> None:
    rng = np.random.default_rng(7)
    speakers = sorted({r["speaker"] for rows in sets.values() for r in rows})
    basis, _ = np.linalg.qr(rng.standard_normal((DIM, DIM)))
    voice = {s: basis[i] for i, s in enumerate(speakers)}
    d = root / "emb" / model
    d.mkdir(parents=True)
    for name, rows in sets.items():
        for ci, cond in enumerate(sl.PROBE_CONDS):
            if perfect:
                X = np.stack([voice[r["speaker"]] + 0.01 * rng.standard_normal(DIM) for r in rows])
            else:
                X = rng.standard_normal((len(rows), DIM))
            np.savez(d / f"{name}__{cond}.npz", seg_id=np.array([r["seg_id"] for r in rows]),
                     emb=X.astype(np.float32))


class LineupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name)
        cls.sets = build_root(cls.root)
        write_model(cls.root, "perfect", cls.sets, perfect=True)
        write_model(cls.root, "random", cls.sets, perfect=False)
        old = os.environ.get("VP_ROOT")
        os.environ["VP_ROOT"] = str(cls.root)
        try:
            sl.main(["--seeds", "2", "--force", "--baseline", "random"])
        finally:
            if old is None:
                os.environ.pop("VP_ROOT")
            else:
                os.environ["VP_ROOT"] = old
        out = cls.root / "results" / "lineup"
        cls.res = {m: json.loads((out / f"{m}.json").read_text()) for m in ("perfect", "random")}

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_perfect_model_names_everyone_with_no_wrong_names(self):
        r = self.res["perfect"]
        self.assertTrue(r["coverage"]["full"])
        for mode in sl.MODES:
            for pc in sl.PROBE_CONDS:
                for lineup in ("pooled", "within", "xdist"):
                    c = sl.cell(r, mode, probe=pc, lineup=lineup)
                    self.assertEqual(c["rank1"]["mean"], 1.0)
                    self.assertEqual(c["zero"]["dir"]["mean"], 1.0, (mode, pc, lineup))
                    for op in sl.OPS:
                        self.assertEqual(c[op]["mir"]["mean"], 0.0)
                        self.assertEqual(c[op]["n_mis"]["mean"], 0.0)
                    self.assertEqual(c["zero"]["far"]["mean"], 0.0)

    def test_random_model_does_not(self):
        r = self.res["random"]
        c = sl.cell(r, "cos")
        self.assertLess(c["rank1"]["mean"], 0.3)
        self.assertLess(c["zero"]["dir"]["mean"], 0.3)
        self.assertLess(c["far1"]["dir"]["mean"], 0.5)

    def test_zero_bar_names_nothing_wrong(self):
        strangers = np.array([0.1, 0.2, 0.3])
        tops = np.array([0.9, 0.5, 0.25])
        ok = np.array([True, False, True])
        bars = sl.calibrate(tops, ok, strangers)
        self.assertEqual(bars["zero"], 0.5)
        r = sl.evaluate(bars["zero"], tops, ok, strangers)
        self.assertEqual((r["n_mis"], r["n_fa"]), (0, 0))
        self.assertAlmostEqual(r["dir"], 1 / 3)
        s = np.linspace(0, 1, 300)
        r1 = sl.evaluate(sl.calibrate(tops, ok, s)["far1"], tops, ok, s)
        self.assertLessEqual(r1["n_fa"], 3)

    def test_strangers_never_enrolled_and_drops_applied(self):
        c = sl.load_corpus(self.root)
        self.assertNotIn("vox1o:p0:0:0", c.seg_index["vox1o"])
        for seed in range(3):
            plan = sl.seed_plan(c, seed)
            self.assertFalse((plan.enrolled & c.p_so).any())
            self.assertFalse((plan.enrolled & c.p_xdist).any())
            for name in sl.HUMAN_SETS:
                in_set = np.array([s == name for s in c.p_set])
                self.assertEqual(int((plan.enrolled & in_set).sum()), N_MULTI - round(sl.HOLDOUT * N_MULTI))
        n_known = self.res["perfect"]["counts"]["known_probes_k1"]["seeds"][0]
        self.assertEqual(n_known, len(sl.HUMAN_SETS) * (N_MULTI - 2) * (N_SESS - 1))


if __name__ == "__main__":
    unittest.main(verbosity=2)
