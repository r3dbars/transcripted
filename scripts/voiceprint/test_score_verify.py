#!/usr/bin/env python3
"""Tests for score_verify.py. Run: VP/venv/bin/python scripts/voiceprint/test_score_verify.py

Everything runs on a synthetic VP tree in a temp directory; nothing touches real data.
"""
from __future__ import annotations

import io
import json
import math
import shutil
import sys
import tempfile
import unittest
import wave
from contextlib import redirect_stderr
from pathlib import Path

import numpy as np
from scipy.stats import norm

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_verify as sv  # noqa: E402

CONDS = ("clean", "opus12", "phone", "noisy")


# ------------------------------------------------------------------------------------------------
# Synthetic VP tree


def write_wav(path: Path, samples: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(samples.astype("<i2").tobytes())


def unit_rows(x: np.ndarray) -> np.ndarray:
    return x / np.linalg.norm(x, axis=1, keepdims=True)


def build_fixture(root: Path, sets: dict, models: dict, seed: int = 0) -> dict:
    """sets: name -> {n_spk, n_sess, clips, buckets, strangers}
    models: id -> {rho, dim, baseline, eps, skip: {(set, cond)}, offset, part_scale, scale}

    Embedding model: x = sqrt(rho) u_speaker + sqrt(1 - rho) z, z a random unit vector orthogonal to
    u. Same-speaker cosine ~ N(rho, (1 - rho)^2 / (D - 1)); different speakers ~ N(0, 1 / D).
    Degraded conditions mix in sqrt(eps) of fresh noise. Raw vectors get a random scale so the
    scorer has to normalize them. `offset` adds a shared direction to every raw vector and
    `part_scale` varies the speaker part's length per clip: raw cosines get squashed toward 1 and
    turn into a length-sensitive distance, like the x-vector heads.
    """
    rng = np.random.default_rng(seed)
    info = {}
    for name, spec in sets.items():
        rows = []
        n_spk, n_sess, clips = spec["n_spk"], spec["n_sess"], spec["clips"]
        buckets = spec.get("buckets", (2, 4, 8))
        strangers = spec.get("strangers", 0)
        for k in range(n_spk + strangers):
            spk = f"{name}:s{k:04d}"
            is_str = k >= n_spk
            for j in range(1 if is_str else n_sess):
                sess = f"{name}:v{k:04d}_{j}"
                n = 0
                for b in buckets:
                    for _ in range(clips):
                        seg = f"{name}:s{k:04d}:v{k:04d}_{j}:{n}"
                        n += 1
                        row = {"seg_id": seg, "set": name, "speaker": spk, "session": sess, "bucket": b, "dur": b,
                               "clip": f"clips/{name}/clean/{seg}.wav",
                               "src": {"file": f"{sess}.wav", "start": 10.0 * n, "end": 10.0 * n + b}}
                        if is_str:
                            row["stranger_only"] = True
                        rows.append(row)
        for r in rows:
            write_wav(root / r["clip"], rng.integers(-3000, 3000, 64))
        sd = root / "sets" / name
        sd.mkdir(parents=True, exist_ok=True)
        (sd / "segments.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
        (sd / "READY").write_text("ok\n")
        for c in CONDS[1:]:
            (root / "clips" / name / c).mkdir(parents=True, exist_ok=True)
            (root / "clips" / name / c / "READY").write_text("ok\n")
        info[name] = rows
    shared_dir = {d: unit_rows(rng.standard_normal((1, d)))[0] for d in {m["dim"] for m in models.values()}}
    for mid, m in models.items():
        md = root / "models" / mid
        md.mkdir(parents=True, exist_ok=True)
        (md / "model.json").write_text(json.dumps({"model_id": mid, "runtime": "fake", "dim": m["dim"],
                                                   "baseline": m.get("baseline", False), "status": "ready"}))
        for name, rows in info.items():
            spk_names = sorted({r["speaker"] for r in rows})
            spk_idx = np.array([spk_names.index(r["speaker"]) for r in rows])
            d = m["dim"]
            U = unit_rows(rng.standard_normal((len(spk_names), d)))[spk_idx]
            Z = rng.standard_normal((len(rows), d))
            Z -= np.sum(Z * U, axis=1, keepdims=True) * U
            Z = unit_rows(Z)
            X = math.sqrt(m["rho"]) * U + math.sqrt(1 - m["rho"]) * Z
            for c in CONDS:
                if (name, c) in m.get("skip", set()):
                    continue
                Xc = X if c == "clean" else unit_rows(
                    math.sqrt(1 - m.get("eps", 0.1)) * X + math.sqrt(m.get("eps", 0.1)) * unit_rows(rng.standard_normal(X.shape)))
                Xc = Xc * rng.uniform(*m.get("part_scale", (1.0, 1.0)), (len(rows), 1))
                Xc = Xc + m.get("offset", 0.0) * shared_dir[d]
                Xc = Xc * rng.uniform(*m.get("scale", (0.5, 3.0)), (len(rows), 1))
                out = root / "emb" / mid / f"{name}__{c}.npz"
                out.parent.mkdir(parents=True, exist_ok=True)
                np.savez(out, seg_id=np.array([r["seg_id"] for r in rows]), emb=Xc.astype(np.float32))
    return info


def run(root: Path, *args: str) -> tuple[int, str]:
    err = io.StringIO()
    with redirect_stderr(err):
        code = sv.main(["--vp", str(root), *args])
    return code, err.getvalue()


# ------------------------------------------------------------------------------------------------
# Brute-force references


def brute_metrics(scores, labels, p=sv.P_TARGET):
    scores = np.asarray(scores, float)
    labels = np.asarray(labels, bool)
    tg, nt = scores[labels], scores[~labels]
    thr = np.r_[np.inf, np.unique(scores)[::-1]]
    tar = np.array([(tg >= t).mean() for t in thr])
    far = np.array([(nt >= t).mean() for t in thr])
    fa = np.array([(nt >= t).sum() for t in thr])
    out = {"mindcf": min(1.0, float(np.min((p * (1 - tar) + (1 - p) * far) / min(p, 1 - p))))}
    for name, f in sv.FARS.items():
        out[name] = float(tar[fa <= math.floor(f * len(nt) + 1e-9)].max())
    i = np.argmin(np.abs(far - (1 - tar)))
    out["eer_approx"] = float((far[i] + 1 - tar[i]) / 2)
    return out


class MetricTests(unittest.TestCase):
    def test_gaussian_scores_match_analytic_values(self):
        rng = np.random.default_rng(1)
        n = 200_000
        for mu1, s1 in ((2.0, 1.0), (3.29, 1.0), (2.5, 0.6)):
            tg = rng.normal(mu1, s1, n)
            nt = rng.normal(0.0, 1.0, n)
            pt, _ = sv.cell_metrics(np.r_[tg, nt], np.r_[np.ones(n, bool), np.zeros(n, bool)])
            eer = norm.cdf(-mu1 / (1.0 + s1))  # crossing where (mu1 - t)/s1 = t
            auc = norm.cdf(mu1 / math.sqrt(1.0 + s1 ** 2))
            grid = np.linspace(-3, 8, 200_001)
            dcf = np.min((0.01 * norm.cdf((grid - mu1) / s1) + 0.99 * norm.sf(grid)) / 0.01)
            with self.subTest(mu1=mu1, s1=s1):
                self.assertAlmostEqual(pt["eer"], eer, delta=0.003)
                self.assertAlmostEqual(pt["auc"], auc, delta=0.002)
                self.assertAlmostEqual(pt["mindcf"], min(dcf, 1.0), delta=0.03)
                for name, far in sv.FARS.items():
                    t = norm.isf(far)
                    tar = norm.sf((t - mu1) / s1)
                    tol = 0.02 if far >= 1e-3 else 0.05
                    self.assertAlmostEqual(pt[name], tar, delta=tol)

    def test_matches_brute_force_with_ties(self):
        rng = np.random.default_rng(2)
        for trial in range(20):
            n_t, n_n = rng.integers(5, 300), rng.integers(1000, 12000)
            s = np.r_[np.round(rng.normal(1.5, 1, n_t), 1), np.round(rng.normal(0, 1, n_n), 1)]
            y = np.r_[np.ones(n_t, bool), np.zeros(n_n, bool)]
            pt, _ = sv.cell_metrics(s, y)
            ref = brute_metrics(s, y)
            with self.subTest(trial=trial):
                self.assertAlmostEqual(pt["mindcf"], ref["mindcf"], places=10)
                for name in sv.FARS:
                    self.assertAlmostEqual(pt[name], ref[name], places=10)
                from sklearn.metrics import roc_auc_score
                self.assertAlmostEqual(pt["auc"], roc_auc_score(y, s), places=10)
                self.assertLess(abs(pt["eer"] - ref["eer_approx"]), 0.5 / min(n_t, n_n) + 0.02)

    def test_edge_cases(self):
        y = np.r_[np.ones(50, bool), np.zeros(50, bool)]
        pt, _ = sv.cell_metrics(np.zeros(100), y)  # all tied
        self.assertAlmostEqual(pt["eer"], 0.5)
        self.assertAlmostEqual(pt["auc"], 0.5)
        pt, _ = sv.cell_metrics(np.r_[np.ones(50), np.zeros(50)], y)  # perfect
        self.assertEqual(pt["eer"], 0.0)
        self.assertEqual(pt["tar@1e-4"], 1.0)
        self.assertEqual(pt["auc"], 1.0)
        pt, _ = sv.cell_metrics(np.r_[np.zeros(50), np.ones(50)], y)  # inverted
        self.assertEqual(pt["eer"], 1.0)
        self.assertEqual(pt["tar@1e-3"], 0.0)

    def test_far_budget_is_floor_of_far_times_nontargets(self):
        # 3000 non-targets -> 3 false accepts allowed at 1e-3, 0 at 1e-4.
        nt = np.linspace(0, 1, 3000)
        tg = np.array([nt[-1] + 1, nt[-3] + 1e-9, nt[-4] + 1e-9, nt[-5] + 1e-9])  # above 1st, 3rd, 4th, 5th highest
        pt, _ = sv.cell_metrics(np.r_[tg, nt], np.r_[np.ones(4, bool), np.zeros(3000, bool)])
        self.assertAlmostEqual(pt["tar@1e-4"], 0.25)  # threshold above every non-target
        self.assertAlmostEqual(pt["tar@1e-3"], 0.75)  # 3 FAs allowed: targets above the 4th-highest count

    def test_bootstrap_weights_equal_repeating_trials(self):
        rng = np.random.default_rng(3)
        n_spk = 30
        spk_a = rng.integers(0, n_spk, 4000)
        same = rng.random(4000) < 0.3
        spk_b = np.where(same, spk_a, (spk_a + rng.integers(1, n_spk, 4000)) % n_spk)
        s = np.round(np.where(same, rng.normal(1.2, 1, 4000), rng.normal(0, 1, 4000)), 2)
        mult = sv.boot_multiplicities(n_spk, 7, seed=9)
        _, reps = sv.cell_metrics(s, same, spk_a, spk_b, mult, chunk=3)
        for r in range(7):
            w = np.where(same, mult[r, spk_a], mult[r, spk_a] * mult[r, spk_b])
            pt, _ = sv.cell_metrics(np.repeat(s, w), np.repeat(same, w))
            for i, m in enumerate(sv.METRICS):
                self.assertAlmostEqual(float(reps[i, r]), pt[m], places=5, msg=f"replicate {r} {m}")
        ones = np.ones((2, n_spk), np.int32)
        pt, reps = sv.cell_metrics(s, same, spk_a, spk_b, ones)
        for i, m in enumerate(sv.METRICS):
            self.assertAlmostEqual(float(reps[i, 0]), pt[m], places=5)

    def test_bootstrap_grid_is_close_to_full_resolution(self):
        rng = np.random.default_rng(4)
        n_spk, n_t, n_n = 120, 8000, 30000
        a_t = rng.integers(0, n_spk, n_t)
        a_n = rng.integers(0, n_spk, n_n)
        b_n = (a_n + rng.integers(1, n_spk, n_n)) % n_spk
        s = np.r_[rng.normal(2.5, 1, n_t), rng.normal(0, 1, n_n)]
        y = np.r_[np.ones(n_t, bool), np.zeros(n_n, bool)]
        mult = sv.boot_multiplicities(n_spk, 40, 1)
        _, grid = sv.cell_metrics(s, y, np.r_[a_t, a_n], np.r_[a_t, b_n], mult)
        _, full = sv.cell_metrics(s, y, np.r_[a_t, a_n], np.r_[a_t, b_n], mult, grid_max=10 ** 9)
        err = {m: float(np.max(np.abs(grid[i] - full[i]))) for i, m in enumerate(sv.METRICS)}
        self.assertLess(err["eer"], 0.001, err)
        self.assertLess(err["auc"], 0.0005, err)
        for m in ("mindcf", "tar@1e-3", "tar@1e-4"):
            self.assertEqual(err[m], 0.0, err)

    def test_one_threshold_tar(self):
        tg = [np.array([5.0, 0.5]), np.array([3.0])]
        top = [np.array([2.0, 1.0, 0.0]), np.array([1.5])]
        out = sv.one_threshold_tar(tg, top, [3, 1])
        self.assertEqual(out["n_nontarget"], 4)
        self.assertAlmostEqual(out["tar@1e-3"], 2 / 3)  # 0 FA allowed: threshold 2.0


# ------------------------------------------------------------------------------------------------
# Trials, leakage, end to end


class FixtureCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="score_verify_test_")
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()


class TrialTests(FixtureCase):
    def prepare(self, **kw):
        notes, errors = [], []
        states = sv.prepare_sets(self.root, kw.get("max_per_class", 500), False, notes, errors)
        return states, notes, errors

    def test_trial_rules_and_determinism(self):
        build_fixture(self.root, {"vox1o": {"n_spk": 25, "n_sess": 3, "clips": 3, "strangers": 6}}, {})
        states, _, errors = self.prepare()
        self.assertEqual(errors, [])
        st = states["vox1o"]
        seen_stranger_nontarget = False
        for b, tr in st.trials.items():
            y = tr.y
            self.assertTrue(np.all(st.spk[tr.e[y]] == st.spk[tr.t[y]]))
            self.assertTrue(np.all(st.sess[tr.e[y]] != st.sess[tr.t[y]]))
            self.assertTrue(np.all(st.spk[tr.e[~y]] != st.spk[tr.t[~y]]))
            self.assertFalse(st.spk_stranger[st.spk[tr.e[y]]].any())
            seen_stranger_nontarget |= bool(st.spk_stranger[st.spk[np.r_[tr.e[~y], tr.t[~y]]]].any())
            self.assertLessEqual(y.sum(), 500)
            self.assertLessEqual((~y).sum(), 500)
            self.assertEqual(tr.meta["n_target_possible"], 25 * (9 * 8 // 2 - 3 * 3))
        self.assertTrue(seen_stranger_nontarget)
        first = {b: (st.seg_ids[tr.e], st.seg_ids[tr.t], tr.y) for b, tr in st.trials.items()}
        shutil.rmtree(self.root / "results")  # rebuild from scratch: same seed, same pairs
        states2, _, _ = self.prepare()
        for b, tr in states2["vox1o"].trials.items():
            e, t, y = first[b]
            np.testing.assert_array_equal(states2["vox1o"].seg_ids[tr.e], e)
            np.testing.assert_array_equal(states2["vox1o"].seg_ids[tr.t], t)
            np.testing.assert_array_equal(tr.y, y)

    def test_rejection_sampling_path(self):
        build_fixture(self.root, {"libri": {"n_spk": 40, "n_sess": 2, "clips": 3, "buckets": (2,)}}, {})
        old = sv.ENUMERATE_PAIRS_MAX
        sv.ENUMERATE_PAIRS_MAX = 10
        try:
            states, _, errors = self.prepare(max_per_class=2000)
        finally:
            sv.ENUMERATE_PAIRS_MAX = old
        self.assertEqual(errors, [])
        tr = states["libri"].trials[2]
        self.assertEqual(int((~tr.y).sum()), 2000)
        sv.verify_trials(states["libri"], tr)  # no duplicates, no same-speaker non-targets

    def test_duplicate_audio_fails_loudly(self):
        info = build_fixture(self.root, {"ami": {"n_spk": 10, "n_sess": 2, "clips": 2}}, {})
        a, b = info["ami"][0]["clip"], info["ami"][7]["clip"]
        shutil.copy(self.root / a, self.root / b)
        states, _, errors = self.prepare()
        self.assertTrue(states["ami"].leak)
        self.assertTrue(any("identical audio" in e for e in errors), errors)

    def test_same_session_target_fails_loudly(self):
        build_fixture(self.root, {"icsi": {"n_spk": 10, "n_sess": 2, "clips": 3}}, {})
        states, _, errors = self.prepare()
        self.assertEqual(errors, [])
        st = states["icsi"]
        # tamper with the cached trial list: point one target at a clip from the same session
        path = sv.trials_path(self.root, "icsi", 2)
        z = dict(np.load(path, allow_pickle=False))
        i = int(np.flatnonzero(z["label"] == 1)[0])
        e = st.index[str(z["seg_ids"][z["enroll"][i]])]
        same = [k for k in range(st.n) if st.sess[k] == st.sess[e] and k != e and st.bucket[k] == 2]
        z["seg_ids"] = np.append(z["seg_ids"], st.seg_ids[same[0]])
        z["test"] = z["test"].copy()
        z["test"][i] = len(z["seg_ids"]) - 1
        sv.save_npz(path, **z)
        states, _, errors = self.prepare()
        self.assertTrue(states["icsi"].leak)
        self.assertTrue(any("same session" in e for e in errors), errors)

    def test_same_source_file_across_sessions_fails(self):
        build_fixture(self.root, {"libri": {"n_spk": 6, "n_sess": 2, "clips": 2}}, {})
        seg = self.root / "sets" / "libri" / "segments.jsonl"
        rows = [json.loads(l) for l in seg.read_text().splitlines()]
        for r in rows:
            r["src"]["file"] = r["speaker"] + ".wav"  # every session of a speaker "comes from" one file
        seg.write_text("".join(json.dumps(r) + "\n" for r in rows))
        _, _, errors = self.prepare()
        self.assertTrue(any("same source file" in e for e in errors), errors)

    def test_duplicate_seg_id_fails(self):
        build_fixture(self.root, {"vox1o": {"n_spk": 4, "n_sess": 2, "clips": 1}}, {})
        seg = self.root / "sets" / "vox1o" / "segments.jsonl"
        lines = seg.read_text().splitlines()
        seg.write_text("\n".join(lines + [lines[0]]) + "\n")
        _, _, errors = self.prepare()
        self.assertTrue(any("duplicate seg_id" in e for e in errors), errors)


class EndToEndTests(FixtureCase):
    def test_full_run(self):
        D = 256
        rho = 0.19
        sets = {
            "vox1o": {"n_spk": 300, "n_sess": 4, "clips": 3, "buckets": (4,)},
            "ami": {"n_spk": 40, "n_sess": 3, "clips": 2, "strangers": 5},
            "yodas": {"n_spk": 60, "n_sess": 2, "clips": 2},
            "libri": {"n_spk": 30, "n_sess": 3, "clips": 2},
        }
        models = {
            "good": {"rho": 0.45, "dim": D},
            "base": {"rho": rho, "dim": D, "baseline": True},
            "partial": {"rho": 0.3, "dim": 192, "skip": {("ami", "noisy"), ("ami", "phone")}},
            "squashed": {"rho": 0.3, "dim": 128, "offset": 2.5, "part_scale": (0.3, 1.5), "scale": (0.95, 1.05)},
        }
        build_fixture(self.root, sets, models, seed=5)
        (self.root / "sets" / "icsi").mkdir(parents=True)  # not READY: must be skipped quietly
        code, err = run(self.root, "--boot", "60")
        self.assertEqual(code, 0, err)
        res = self.root / "results"
        md = (res / "verify_summary.md").read_text()
        table = [l for l in md.splitlines() if l.startswith("| ") and "`" in l]
        for f in ("verify_summary.md", "verify_summary.csv", "verify/good.json", "verify/base.json", "verify/partial.json"):
            self.assertTrue((res / f).exists(), f)

        base = json.loads((res / "verify" / "base.json").read_text())
        # clean EER through the whole embedding path vs the analytic value for this generator
        cell = [c for c in base["cells"] if c["set"] == "vox1o" and c["cond"] == "clean" and c["mode"] == "cos"][0]
        s0, s1 = 1 / math.sqrt(D), (1 - rho) / math.sqrt(D - 1)
        analytic = norm.cdf(-rho / (s0 + s1))
        self.assertGreater(cell["n_target"], 10_000)
        self.assertAlmostEqual(cell["metrics"]["eer"], analytic, delta=0.008,
                               msg=f"EER {cell['metrics']['eer']:.4f} vs analytic {analytic:.4f}")
        # AS-norm ran with the yodas cohort (vox1o) and libri cohort (yodas)
        asn = [c for c in base["cells"] if c["mode"] == "asnorm"]
        self.assertTrue(asn)
        self.assertEqual({c["cohort"]["enroll"]["set"] for c in asn if c["set"] == "vox1o"}, {"yodas"})
        self.assertEqual({c["cohort"]["enroll"]["set"] for c in asn if c["set"] == "yodas"}, {"libri"})
        for c in asn:
            self.assertTrue(all(np.isfinite(v) for v in c["metrics"].values()))

        # identical trial lists across models
        def counts(doc):
            return {(c["set"], c["bucket"], c["cond"]): (c["n_target"], c["n_nontarget"])
                    for c in doc["cells"] if c["mode"] == "cos"}
        good = json.loads((res / "verify" / "good.json").read_text())
        partial = json.loads((res / "verify" / "partial.json").read_text())
        cg, cb, cp = counts(good), counts(base), counts(partial)
        self.assertEqual(cg, cb)
        self.assertTrue(set(cp) < set(cb))
        for k in cp:
            self.assertEqual(cp[k], cb[k])

        # ranking, baseline marker, paired delta
        self.assertIn("`good`", table[0])
        self.assertIn("(baseline)", [l for l in table if "`base`" in l][0])
        head = good["pooled"]["human"]["cross"]["cos"]["metrics"]["tar@1e-3"]
        self.assertGreater(head["delta"]["value"], 0)
        self.assertGreater(head["delta"]["ci"][0], 0)  # clearly better, CI excludes 0
        self.assertLessEqual(head["ci"][0], head["value"])
        self.assertLessEqual(head["value"], head["ci"][1])
        self.assertIn("partial", [l for l in table if "`partial`" in l][0])
        # yodas is not in the human pool
        self.assertEqual(set(good["pooled"]["human"]["overall"]["cos"]["sets"]), {"vox1o", "ami", "libri"})
        self.assertIn("yodas", good["pooled"])

        csv_text = (res / "verify_summary.csv").read_text().splitlines()
        self.assertTrue(all(len(l.split(",")) == 17 for l in csv_text))

        # centered cosine: squashed raw cosines sit near 1; centering restores the spread
        sq = json.loads((res / "verify" / "squashed.json").read_text())
        raw_clean = [c for c in sq["cells"] if c["set"] == "vox1o" and c["cond"] == "clean"]
        by_mode = {c["mode"]: c for c in raw_clean}
        self.assertEqual(set(by_mode), set(sv.MODES))
        self.assertGreater(by_mode["cos"]["metrics"]["eer"], by_mode["centered"]["metrics"]["eer"] + 0.02)
        self.assertIn(sq["headline"]["mode"], ("centered", "asnorm"))
        self.assertIn(f"| {sq['headline']['mode']} |", [l for l in table if "`squashed`" in l][0])
        self.assertIn("Variant wins:", md)
        # headline delta is paired between the two headline variants
        hd = good["headline"]["delta_vs_baseline"]["cross"]
        self.assertEqual(hd["model_mode"], good["headline"]["mode"])
        self.assertEqual(hd["baseline_mode"], base["headline"]["mode"])
        self.assertGreater(hd["metrics"]["tar@1e-3"]["ci"][0], 0)

        # second run: everything comes from cache
        stamp = (res / "verify" / "_cells" / "good" / "vox1o.json").stat().st_mtime_ns
        code, err = run(self.root, "--boot", "60")
        self.assertEqual(code, 0, err)
        self.assertIn("recomputed 0", err)
        self.assertEqual((res / "verify" / "_cells" / "good" / "vox1o.json").stat().st_mtime_ns, stamp)

        # --models limits recompute; summary still covers every model
        code, err = run(self.root, "--boot", "60", "--models", "good", "--force")
        self.assertEqual(code, 0, err)
        md = (res / "verify_summary.md").read_text()
        self.assertIn("`partial`", md)

    def test_leaky_set_is_excluded_and_exit_code_is_2(self):
        info = build_fixture(self.root, {"vox1o": {"n_spk": 12, "n_sess": 2, "clips": 2},
                                         "libri": {"n_spk": 12, "n_sess": 2, "clips": 2}},
                             {"m": {"rho": 0.4, "dim": 64, "baseline": True}})
        shutil.copy(self.root / info["libri"][0]["clip"], self.root / info["libri"][5]["clip"])
        code, err = run(self.root, "--boot", "20", "--no-asnorm")
        self.assertEqual(code, 2)
        self.assertIn("LEAKAGE", err)
        doc = json.loads((self.root / "results" / "verify" / "m.json").read_text())
        self.assertEqual({c["set"] for c in doc["cells"]}, {"vox1o"})
        self.assertIn("LEAKAGE", (self.root / "results" / "verify_summary.md").read_text())

    def test_stale_embeddings_are_skipped(self):
        build_fixture(self.root, {"vox1o": {"n_spk": 12, "n_sess": 2, "clips": 2}},
                      {"m": {"rho": 0.4, "dim": 64}})
        path = self.root / "emb" / "m" / "vox1o__opus12.npz"
        z = dict(np.load(path))
        z["seg_id"] = z["seg_id"].copy()
        z["seg_id"][0] = "vox1o:ghost:ghost:0"
        np.savez(path, **z)
        code, err = run(self.root, "--boot", "0", "--no-asnorm")
        self.assertEqual(code, 0, err)
        doc = json.loads((self.root / "results" / "verify" / "m.json").read_text())
        self.assertNotIn("opus12", {c["cond"] for c in doc["cells"]})
        self.assertNotIn("clean>opus12", {c["cond"] for c in doc["cells"]})
        self.assertTrue(any("stale" in n for n in doc["notes"]))

    def test_clean_only_models_still_rank(self):
        # the daemon embeds clean first: before any degraded file exists, rank on clean trials
        build_fixture(self.root, {"vox1o": {"n_spk": 20, "n_sess": 3, "clips": 2},
                                  "yodas": {"n_spk": 40, "n_sess": 2, "clips": 1}},
                      {"hi": {"rho": 0.5, "dim": 64, "skip": {(s, c) for s in ("vox1o", "yodas") for c in CONDS[1:]}},
                       "lo": {"rho": 0.2, "dim": 64, "baseline": True,
                              "skip": {(s, c) for s in ("vox1o", "yodas") for c in CONDS[1:]}}})
        code, err = run(self.root, "--boot", "30")
        self.assertEqual(code, 0, err)
        md = (self.root / "results" / "verify_summary.md").read_text()
        rows = [l for l in md.splitlines() if l.startswith("| 1 |") or l.startswith("| 2 |")]
        self.assertIn("`hi`", rows[0])
        self.assertIn("on clean", rows[0])
        doc = json.loads((self.root / "results" / "verify" / "hi.json").read_text())
        self.assertEqual(doc["headline"]["group"], "clean")
        self.assertIsNotNone(doc["headline"]["delta_vs_baseline"]["clean"])

    def test_nothing_ready(self):
        code, err = run(self.root)
        self.assertEqual(code, 0, err)
        self.assertIn("No model", (self.root / "results" / "verify_summary.md").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
