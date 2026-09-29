#!/usr/bin/env python3
"""Fusion scorer for the voiceprint bake-off: does combining two models beat the best one alone?

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md. VP = data/eval/voiceprint (or $VP_ROOT).

Reuses score_verify.py for everything that defines "the same test": segment loading and drop lists
(load_segments / load_drops), the cached trial lists (load_or_build_trials, read-only here: a stale
cache skips the set instead of rebuilding it), embedding loading (load_emb, which also refuses stale
files), and the metric code (cell_metrics: EER, minDCF, TAR at FAR 1e-3 / 1e-4, AUC, speaker-level
bootstrap; pooled_value: mean over sets of mean over cells). The bootstrap speaker weights come from
SetState.mult, so replicates are paired across every method here and with score_verify's own.

Human-labeled sets only (vox1o, libri, ami, icsi). Trial conditions: clean, opus12, noisy (both sides
degraded) and clean>opus12, clean>noisy (enroll clean, test degraded; "cross", the headline).

Cross-fitting. Every fitted number (z-norm mean and std, the fusion weight) is estimated on a
calibration half of the speakers of each set and reported on the other half. A seeded 50/50 split of
each set's speakers (repeat r), and both directions (fold f = calibrate on half f, evaluate on the
other one). Evaluation trials of a fold: target trials of speakers in the evaluation half, and
non-target trials whose two speakers are both in it (so 1/4 of the shared non-target list per fold,
1/2 in total across the two directions). Calibration uses the same rule on the calibration half.
Metrics are averaged over folds (per cell, points and bootstrap replicates alike), so the bootstrap
CI covers the speaker sampling and, through the shared replicate weights, is paired across methods.
The single models are scored on exactly the same folds and trials, with nothing fitted.

Methods, for a pair (A, B):
  single:A, single:B   raw cosine of one model
  concat               L2-normalize each embedding, concatenate, re-normalize; cosine. Literal.
                       Its cosine is exactly (cos_A + cos_B) / 2, checked in the report.
  zavg                 z-norm each model's cosine with its non-target mean and std (calibration half,
                       one pair of numbers per model, pooled over sets and conditions), then average
  ztuned               same z-norm, weighted average w*zA + (1-w)*zB, w tuned on the calibration half
                       (grid 0..1 step 0.1, objective pooled TAR@1e-3 of the headline group, grid
                       smoothed with a [1 2 1]/4 kernel), reported on the other half
  zavg-percond         zavg with one mean/std per model per trial condition (a sensitivity check;
                       the app would have to know the call condition)
A z-norm weighted average is a weighted average of raw cosines up to an additive constant, so the app
can ship it as one vector per person: concatenate sqrt(a_A) * embA and sqrt(a_B) * embB with
a = weight / std (checked in the report).

Pair search: the top --top-n single models in VP/results/verify_summary.csv (Core ML clones of a model
already in the list are dropped; models the license gate marks ineligible or unclear are dropped and
listed). Every pair among them is scored with ztuned on the calibration half. The best pair is chosen
in-fold, on the calibration half only, and evaluated on the other half ("nested"), and it is compared
with the best single model of the whole candidate list. A second table shows the pair that ranks
first over all folds (which used every speaker for selection, so read it as optimistic).

A second search runs the same way over the top models that already have every condition embedded, so the
cross-condition trials can drive the choice while the main list is still waiting for degraded embeddings.
Both reuse the same code; when every candidate is complete they coincide and only one is shown.

Outputs (VP/results/):
  fusion_summary.md    the report
  fusion_summary.json  the numbers behind it (--out changes the stem)
  fusion_cache/        pickled per-pair and per-model results, keyed on the embedding files, so a rerun only
                       recomputes what changed (--no-cache ignores it)
Cost: bootstrap evaluation dominates (about 70 ms per cell per method at 1000 replicates); --workers splits
pairs and searches over processes, each single-threaded.

Usage:
  score_fusion.py [--boot 500] [--repeats 1] [--top-n 8] [--no-search] [--pairs a+b,c+d] [--workers 3]
"""
from __future__ import annotations

import os

for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_var, "1")  # the work is single-threaded; parallelism comes from --workers (max 3 threads total)

import argparse  # noqa: E402
import csv  # noqa: E402
import hashlib  # noqa: E402
import itertools  # noqa: E402
import json  # noqa: E402
import pickle  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from dataclasses import dataclass, field  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import score_verify as sv  # noqa: E402

FUSION_VERSION = "1.0"
METRICS = sv.METRICS
I_EER, I_TAR3 = METRICS.index("eer"), METRICS.index("tar@1e-3")
HUMAN = sv.HUMAN_SETS
DEFAULT_CONDS = ("clean", "opus12", "noisy")
W_GRID = np.round(np.arange(0.0, 1.0001, 0.1), 2)
N_BOOT = 500

NAMED_PAIRS = [
    ("redimnet2-b6-vox2-lm", "wespeaker-resnet293-lm-coreml"),
    ("redimnet2-b4-vox2-lm", "wespeaker-resnet293-lm-coreml"),
    ("redimnet2-b6-vox2-lm", "app-wespeaker-coreml"),
    ("redimnet2-b4-vox2-lm", "app-wespeaker-coreml"),
    ("titanet-large", "redimnet2-b6-vox2-lm"),
]
# not in the brief: same family and recipe as resnet293 (23.8M vs 28.6M params) but its degraded embeddings exist,
# so it stands in while resnet293-lm-coreml's opus12 / noisy embeddings are still being made
EXTRA_PAIRS = [
    ("redimnet2-b6-vox2-lm", "wespeaker-resnet221-lm-coreml"),
    ("redimnet2-b4-vox2-lm", "wespeaker-resnet221-lm-coreml"),
]
FUSION_METHODS = ("concat", "zavg", "ztuned", "zavg-percond")
METHOD_LABEL = {
    "concat": "concat (L2 each, concat, re-norm)",
    "zavg": "z-norm average (w = 0.5)",
    "ztuned": "z-norm weighted (w tuned on calibration half)",
    "zavg-percond": "z-norm average, per-condition constants",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def tc_lists(conds: tuple[str, ...]):
    tcs = tuple(conds) + tuple(f"clean>{c}" for c in conds if c != "clean")
    groups = {"clean": ("clean",)}
    for c in conds:
        if c != "clean":
            groups[c] = (c,)
    groups["cross"] = tuple(t for t in tcs if ">" in t)
    return tcs, groups


# ----------------------------------------------------------------------------------------------
# Data: sets, trials, embeddings, cosines


class Data:
    def __init__(self, vp: Path, tcs: tuple[str, ...], n_boot: int, sets: tuple[str, ...] = HUMAN):
        self.vp, self.tcs, self.n_boot = vp, tcs, n_boot
        self.notes: list[str] = []
        self.states: dict[str, sv.SetState] = {}
        self.trials: dict[str, dict[int, sv.Trials]] = {}
        self._emb: dict = {}
        self._cos: dict = {}
        self._halves: dict = {}
        self._fold: dict = {}
        for name in sets:
            self._load_set(name)

    def _load_set(self, name: str) -> None:
        sd = self.vp / "sets" / name
        if not (sd / "READY").exists() or not (sd / "segments.jsonl").exists():
            self.notes.append(f"set {name}: not READY, skipped")
            return
        try:
            st = sv.load_segments(self.vp, name, sv.load_drops(self.vp, name))
        except sv.DataError as exc:
            self.notes.append(f"set {name}: {exc}")
            return
        trials = {}
        for b in sorted(np.unique(st.bucket).tolist()):
            path = sv.trials_path(self.vp, name, int(b))
            try:
                with np.load(path, allow_pickle=False) as z:
                    meta = json.loads(str(z["meta"]))
                fresh = meta.get("fingerprint") == st.fp and meta.get("version") == sv.TRIALS_VERSION \
                    and meta.get("max_per_class") == sv.MAX_PER_CLASS
            except Exception:
                fresh = False
            if not fresh:
                self.notes.append(f"set {name} b{b}: trial cache missing or stale, run score_verify.py first; set skipped")
                trials = None
                break
            tr = sv.load_or_build_trials(self.vp, st, int(b), sv.MAX_PER_CLASS)  # cache hit: read-only
            try:
                sv.verify_trials(st, tr)
            except sv.LeakageError as exc:
                self.notes.append(f"set {name}: LEAKAGE {exc}")
                trials = None
                break
            trials[int(b)] = tr
        if trials:
            self.states[name] = st
            self.trials[name] = trials

    # -- embeddings and cosines

    def emb(self, model: str, sname: str, cond: str):
        key = (model, sname, cond)
        if key not in self._emb:
            e, why = sv.load_emb(self.vp, model, self.states[sname], cond)
            if e is not None:
                e.raw = e.raw[:0]  # not needed here; frees memory
            self._emb[key] = (e, why)
        return self._emb[key]

    def cos(self, model: str, sname: str, b: int, tc: str):
        """Cosine of every trial of (set, bucket) for one model (float32, NaN where a side has no
        embedding), or None when the model lacks the condition."""
        key = (model, sname, b, tc)
        if key not in self._cos:
            tr = self.trials[sname][b]
            ec, xc = sv.split_cond(tc)
            (Ee, w1), (Et, w2) = self.emb(model, sname, ec), self.emb(model, sname, xc)
            out = None
            if Ee is not None and Et is not None and Ee.dim == Et.dim:
                out = np.einsum("ij,ij->i", Ee.E[tr.e], Et.E[tr.t])
                out[~(Ee.present[tr.e] & Et.present[tr.t])] = np.nan
            else:
                for why in (w1, w2):
                    if why and why != "missing":
                        self.notes.append(f"{model} {sname}: {why}")
            self._cos[key] = out
        return self._cos[key]

    def concat_cos(self, m1: str, m2: str, sname: str, b: int, tc: str, scale=(1.0, 1.0)):
        """Cosine of the concatenation [scale0 * E1, scale1 * E2] (each E L2-normalized), re-normalized."""
        tr = self.trials[sname][b]
        ec, xc = sv.split_cond(tc)
        parts = []
        for cond in (ec, xc):
            e1, _ = self.emb(m1, sname, cond)
            e2, _ = self.emb(m2, sname, cond)
            if e1 is None or e2 is None:
                return None
            X = np.concatenate([scale[0] * e1.E, scale[1] * e2.E], axis=1).astype(np.float64)
            n = np.linalg.norm(X, axis=1, keepdims=True)
            parts.append(X / np.where(n > 0, n, 1.0))
        out = np.einsum("ij,ij->i", parts[0][tr.e], parts[1][tr.t])
        return out

    # -- speaker halves and fold masks

    def halves(self, sname: str, rep: int) -> np.ndarray:
        key = (sname, rep)
        if key not in self._halves:
            st = self.states[sname]
            rng = np.random.default_rng(sv.stable_seed(sname, "fusion-split", rep, "1"))
            order = np.concatenate([rng.permutation(np.flatnonzero(~st.spk_stranger)),
                                    rng.permutation(np.flatnonzero(st.spk_stranger))])
            half = np.zeros(len(st.spk_names), dtype=np.int8)
            half[order] = np.arange(len(order)) % 2
            self._halves[key] = half
        return self._halves[key]

    def fold_masks(self, sname: str, b: int, fold: tuple[int, int]):
        """(evaluation mask, calibration mask) over the trials of (set, bucket)."""
        key = (sname, b, fold)
        if key not in self._fold:
            st, tr = self.states[sname], self.trials[sname][b]
            rep, f = fold
            half = self.halves(sname, rep)
            he, ht = half[st.spk[tr.e]], half[st.spk[tr.t]]

            def mask(h):
                return np.where(tr.y, he == h, (he == h) & (ht == h))
            self._fold[key] = (mask(1 - f), mask(f))
        return self._fold[key]


# ----------------------------------------------------------------------------------------------
# Pairs, calibration, scoring


@dataclass
class Cell:
    sname: str
    bucket: int
    tc: str
    cos: list  # one float32 array per model
    valid: np.ndarray
    sig: str

    @property
    def key(self):
        return (self.sname, self.bucket, self.tc)


@dataclass
class Group:
    """One or two models and the cells (set, bucket, trial condition) every one of them has."""
    models: tuple
    cells: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)

    @property
    def sig(self) -> str:
        return hashlib.sha1("|".join(f"{k}:{c.sig}" for k, c in sorted(self.cells.items())).encode()).hexdigest()[:12]


def build_group(data: Data, models: tuple, tcs=None) -> Group:
    g = Group(models=tuple(models))
    for sname, st in data.states.items():
        for b, tr in data.trials[sname].items():
            for tc in (tcs or data.tcs):
                cs = [data.cos(m, sname, b, tc) for m in models]
                if any(c is None for c in cs):
                    continue
                valid = np.ones(len(tr.y), dtype=bool)
                for c in cs:
                    valid &= ~np.isnan(c)
                n_drop = int((~valid).sum())
                if n_drop > sv.MAX_DROP_FRAC * len(valid):
                    g.notes.append(f"{sname} b{b} {tc}: {n_drop}/{len(valid)} trials lack an embedding, cell skipped")
                    continue
                if not tr.y[valid].any() or tr.y[valid].all():
                    continue
                sig = hashlib.sha1(valid.tobytes()).hexdigest()[:10]
                g.cells[(sname, b, tc)] = Cell(sname, b, tc, cs, valid, sig)
    return g


def pool(cells_res: dict, tcs: tuple, sets=None):
    """Pooled (point (M,), reps (M, B) or None) over the cells of a {(set, b, tc): (point, reps)} dict."""
    ids = [(s, b, tc, "x") for (s, b, tc) in sorted(cells_res) if tc in tcs and (sets is None or s in sets)]
    if not ids:
        return None, None
    points = {(s, b, tc, "x"): dict(zip(METRICS, cells_res[(s, b, tc)][0])) for (s, b, tc, _) in ids}
    reps = {(s, b, tc, "x"): cells_res[(s, b, tc)][1] for (s, b, tc, _) in ids if cells_res[(s, b, tc)][1] is not None}
    return sv.pooled_value(points, reps, ids)


def cell_eval(score: np.ndarray, cell: Cell, data: Data, mask: np.ndarray, with_reps: bool):
    st, tr = data.states[cell.sname], data.trials[cell.sname][cell.bucket]
    m = mask & cell.valid
    y = tr.y[m]
    if not y.any() or y.all():
        return None
    mult = st.mult(data.n_boot) if with_reps else None
    return sv.cell_metrics(score[m], y, st.spk[tr.e[m]], st.spk[tr.t[m]], mult)


class Engine:
    def __init__(self, data: Data, folds: list, groups: dict):
        self.data, self.folds, self.tc_groups = data, folds, groups
        self.cross = groups["cross"]
        self.cache: dict = {}      # (method key, cell key, fold, sig) -> (point vec, reps)
        self.calib_cache: dict = {}

    # -- calibration -------------------------------------------------------------------------

    def tune_tcs(self, grp: Group) -> tuple:
        have = {tc for (_, _, tc) in grp.cells}
        cross = tuple(t for t in self.cross if t in have)
        return cross if cross else ("clean",)

    def calibrate(self, grp: Group, fold):
        key = (grp.models, fold, grp.sig)
        if key in self.calib_cache:
            return self.calib_cache[key]
        d = self.data
        nt: dict = {(mi, tc): [] for mi in range(2) for tc in d.tcs}
        for (sname, b, tc), cell in grp.cells.items():
            tr = d.trials[sname][b]
            _, cal = d.fold_masks(sname, b, fold)
            sel = cal & cell.valid & ~tr.y
            for mi in range(2):
                nt[(mi, tc)].append(cell.cos[mi][sel].astype(np.float64))
        stats = {}
        for mi in range(2):
            allv = np.concatenate([np.concatenate(v) for (i, _), v in nt.items() if i == mi and v])
            stats[(mi, "all")] = (float(allv.mean()), float(allv.std()))
            for tc in d.tcs:
                v = nt[(mi, tc)]
                if v:
                    x = np.concatenate(v)
                    stats[(mi, tc)] = (float(x.mean()), float(x.std()))
        n_nt = int(sum(len(a) for (i, _), v in nt.items() if i == 0 for a in v))
        # tune the weight on the calibration half
        tcs_t = self.tune_tcs(grp)
        obj = np.full(len(W_GRID), np.nan)
        for gi, w in enumerate(W_GRID):
            pts = {}
            for (sname, b, tc), cell in grp.cells.items():
                if tc not in tcs_t:
                    continue
                _, cal = d.fold_masks(sname, b, fold)
                sc = self.z_score(cell, stats, "all", w)
                r = cell_eval(sc, cell, d, cal, with_reps=False)
                if r is not None:
                    pts[(sname, b, tc, "x")] = r[0]
            if pts:
                obj[gi] = sv.pooled_value(pts, {}, sorted(pts))[0][I_TAR3]
        padded = np.pad(obj, 1, mode="edge")
        smooth = 0.25 * padded[:-2] + 0.5 * padded[1:-1] + 0.25 * padded[2:]
        best = np.flatnonzero(smooth >= np.nanmax(smooth) - 1e-12)
        gi = int(best[np.argmin(np.abs(W_GRID[best] - 0.5))])
        out = {"stats": stats, "w": float(W_GRID[gi]), "obj": obj, "obj_smooth": smooth,
               "obj_at_w": float(obj[gi]), "obj_max_smooth": float(np.nanmax(smooth)),
               "n_nontarget": n_nt, "tune_tcs": tcs_t}
        self.calib_cache[key] = out
        return out

    @staticmethod
    def z_score(cell: Cell, stats: dict, scope: str, w: float) -> np.ndarray:
        k = "all" if scope == "all" else cell.tc
        (m1, s1), (m2, s2) = stats[(0, k)], stats[(1, k)]
        return (w * (cell.cos[0].astype(np.float64) - m1) / s1
                + (1.0 - w) * (cell.cos[1].astype(np.float64) - m2) / s2)

    # -- evaluation --------------------------------------------------------------------------

    def method_score(self, grp: Group, cell: Cell, method: str, fold, w_fixed=None) -> np.ndarray:
        """Score of every trial of a cell under one method, parameters fitted on the calibration half of `fold`."""
        if method.startswith("single:"):
            return cell.cos[grp.models.index(method.split(":", 1)[1])]
        if method == "concat":
            return self.data.concat_cos(grp.models[0], grp.models[1], cell.sname, cell.bucket, cell.tc)
        calib = self.calibrate(grp, fold)
        if method == "zavg":
            return self.z_score(cell, calib["stats"], "all", 0.5)
        if method == "ztuned":
            return self.z_score(cell, calib["stats"], "all", calib["w"])
        if method == "zavg-percond":
            return self.z_score(cell, calib["stats"], "tc", 0.5)
        if method == "zw":
            return self.z_score(cell, calib["stats"], "all", w_fixed)
        raise ValueError(method)

    def eval_method(self, grp: Group, method: str, fold, with_reps=True, w_fixed=None):
        """{cell key: (point, reps)} on the evaluation half of one fold."""
        d = self.data
        out = {}
        for ck, cell in grp.cells.items():
            mkey = (method,) if method.startswith("single:") else (method, grp.models, w_fixed)
            ck2 = (mkey, ck, fold, cell.sig, with_reps)
            if ck2 not in self.cache:
                ev, _ = d.fold_masks(cell.sname, cell.bucket, fold)
                sc = self.method_score(grp, cell, method, fold, w_fixed)
                self.cache[ck2] = cell_eval(sc, cell, d, ev, with_reps)
            if self.cache[ck2] is not None:
                out[ck] = self.cache[ck2]
        return out

    def one_threshold(self, grp: Group, method: str, tcs: tuple) -> dict:
        """TAR at FAR 1e-3 / 1e-4 under ONE threshold for all evaluation-half trials of the given conditions
        (every set, clip length and condition pooled), averaged over folds. Point values only."""
        d = self.data
        vals = {k: [] for k in sv.FARS}
        n_nt = []
        for fold in self.folds:
            tg, nt = [], []
            for ck, cell in grp.cells.items():
                if cell.tc not in tcs:
                    continue
                ev, _ = d.fold_masks(cell.sname, cell.bucket, fold)
                m = ev & cell.valid
                y = d.trials[cell.sname][cell.bucket].y[m]
                sc = self.method_score(grp, cell, method, fold)[m]
                tg.append(sc[y])
                nt.append(sc[~y])
            if not tg:
                continue
            tg, nt = np.concatenate(tg), np.sort(np.concatenate(nt))[::-1]
            n_nt.append(len(nt))
            for k, far in sv.FARS.items():
                allowed = int(np.floor(far * len(nt) + 1e-9))
                vals[k].append(float(np.mean(tg > nt[allowed])) if allowed < len(nt) else 1.0)
        return {"tar@1e-3": float(np.mean(vals["tar@1e-3"])) if vals["tar@1e-3"] else None,
                "tar@1e-4": float(np.mean(vals["tar@1e-4"])) if vals["tar@1e-4"] else None,
                "n_nontarget": int(np.mean(n_nt)) if n_nt else 0}

    def eval_avg(self, grp: Group, method: str, with_reps=True, w_fixed=None, folds=None):
        """Average over folds, per cell."""
        acc: dict = {}
        for fold in (folds or self.folds):
            for ck, (pt, rp) in self.eval_method(grp, method, fold, with_reps, w_fixed).items():
                a = acc.setdefault(ck, [[], []])
                a[0].append(np.array([pt[m] for m in METRICS]))
                if rp is not None:
                    a[1].append(rp)
        res = {}
        for ck, (pts, rps) in acc.items():
            res[ck] = (np.mean(pts, axis=0), np.mean(rps, axis=0) if rps else None)
        return res


# ----------------------------------------------------------------------------------------------
# Selecting candidates


def read_licenses(vp: Path) -> dict:
    try:
        d = json.loads((vp / "models" / "licenses.json").read_text())
        return {m["model_id"]: m.get("verdict") for m in d.get("models", [])}
    except Exception:
        return {}


def license_of(lic: dict, model: str):
    if model in lic:
        return lic[model]
    stem = model[:-len("-coreml")] if model.endswith("-coreml") else model
    return lic.get(stem)


def top_models(vp: Path, n: int, rank_group: str, have: set, lic: dict, not_have_reason="no embeddings in emb/"):
    """Top-n single models from verify_summary.csv (human, headline variant, TAR@1e-3), minus Core ML
    clones of a model already ranked and models the license gate rules out. Returns (chosen,
    raw_topn, dropped [(model, why)], ranked_on)."""
    path = vp / "results" / "verify_summary.csv"
    vals: dict = {}
    with open(path) as fh:
        for r in csv.DictReader(fh):
            if r["scope"] != "human" or r["metric"] != "tar@1e-3" or r["mode"] != r["headline_mode"]:
                continue
            if r["group"] in ("cross", "clean"):
                vals.setdefault(r["model_id"], {})[r["group"]] = float(r["value"])
    n_cross = sum(1 for v in vals.values() if "cross" in v)
    group = rank_group if rank_group != "auto" else ("cross" if n_cross >= n else "clean")
    ranked = sorted((m for m, v in vals.items() if group in v), key=lambda m: -vals[m][group])
    raw = ranked[:n]
    dropped, chosen = [], []
    for m in ranked:
        stem = m[:-len("-coreml")] if m.endswith("-coreml") else m
        if m != stem and stem in ranked:
            dropped.append((m, f"Core ML build of {stem}"))
            continue
        v = license_of(lic, m)
        if v in ("ineligible", "unclear"):
            dropped.append((m, f"license gate: {v}"))
            continue
        if m not in have:
            dropped.append((m, not_have_reason))
            continue
        chosen.append(m)
        if len(chosen) == n:
            break
    return chosen, raw, dropped, group


# ----------------------------------------------------------------------------------------------
# Report helpers


def pct(v, d=1):
    return "-" if v is None or (isinstance(v, float) and np.isnan(v)) else f"{100 * v:.{d}f}"


def cipct(v, rp, i, d=1):
    """value [lo, hi] in %."""
    s = pct(v, d)
    c = sv.ci(rp[i] if rp is not None else None)
    return s + (f" [{pct(c[0], d)}, {pct(c[1], d)}]" if c else "")


def delta_txt(pt_f, rp_f, pt_s, rp_s, i, d=1):
    """fusion minus single, in percentage points, with a paired bootstrap CI; returns (text, ci, p, dv)."""
    dv = float(pt_f[i] - pt_s[i])
    if rp_f is None or rp_s is None:
        return f"{100 * dv:+.{d}f}", None, None, dv
    dr = rp_f[i] - rp_s[i]
    c = sv.ci(dr)
    p = None
    if c:
        nb = int(np.sum(~np.isnan(dr)))
        p = min(1.0, 2 * (min(np.sum(dr <= 0), np.sum(dr >= 0)) + 1) / (nb + 1))
    sig = "*" if c and (c[0] > 0 or c[1] < 0) else ""
    txt = f"{100 * dv:+.{d}f}{sig}" + (f" [{100 * c[0]:+.{d}f}, {100 * c[1]:+.{d}f}]" if c else "")
    return txt, c, p, dv


def is_gain(c, i):
    """True when the CI of (fusion - single) shows an improvement (TAR up, EER down)."""
    if not c:
        return False
    return c[0] > 0 if i == I_TAR3 else c[1] < 0


# ----------------------------------------------------------------------------------------------
# Self-checks


def self_checks(data: Data, notes: list) -> dict:
    """Cross-checks of the pipeline against the identities the report leans on."""
    out = {}
    pair = ("redimnet2-b4-vox2-lm", "app-wespeaker-coreml")
    cell = None
    for sname in data.states:
        for b in data.trials[sname]:
            cs = [data.cos(m, sname, b, "clean") for m in pair]
            if all(c is not None for c in cs):
                cell = (sname, b, cs)
                break
        if cell:
            break
    if cell:
        sname, b, cs = cell
        lit = data.concat_cos(pair[0], pair[1], sname, b, "clean")
        avg = 0.5 * (cs[0].astype(np.float64) + cs[1].astype(np.float64))
        ok = ~np.isnan(avg)
        out["concat_vs_avg_max_abs"] = float(np.max(np.abs(lit[ok] - avg[ok])))
        # weighted concat: sqrt(a) blocks with a = w / std must rank like the z-norm weighted average
        tr = data.trials[sname][b]
        y = tr.y & ok
        nt = ~tr.y & ok
        sd = [float(c[nt].astype(np.float64).std()) for c in cs]
        w = 0.7
        a = (w / sd[0], (1 - w) / sd[1])
        wc = data.concat_cos(pair[0], pair[1], sname, b, "clean", scale=(np.sqrt(a[0]), np.sqrt(a[1])))
        zf = w * cs[0].astype(np.float64) / sd[0] + (1 - w) * cs[1].astype(np.float64) / sd[1]
        # wc = zf / (a0 + a1): compare
        out["weighted_concat_vs_z_max_abs"] = float(np.max(np.abs(wc[ok] * (a[0] + a[1]) - zf[ok])))
    # a single model here must match score_verify's own cached cell, on all trials of one cell
    m = "app-wespeaker-coreml"
    for sname in data.states:
        p = data.vp / "results" / "verify" / "_cells" / m / f"{sname}.json"
        if not p.exists():
            continue
        try:
            rec = json.loads(p.read_text())
        except Exception:
            continue
        for c in rec.get("cells", []):
            if c["mode"] == "cos" and c["cond"] == "clean" and c["bucket"] in data.trials[sname]:
                cos = data.cos(m, sname, c["bucket"], "clean")
                if cos is None:
                    continue
                st, tr = data.states[sname], data.trials[sname][c["bucket"]]
                ok = ~np.isnan(cos)
                pt, _ = sv.cell_metrics(cos[ok].astype(np.float64), tr.y[ok])
                out["scorer_match"] = {"cell": f"{m} {sname} b{c['bucket']} clean",
                                       "max_abs_diff": float(max(abs(pt[k] - c["metrics"][k]) for k in ("eer", "tar@1e-3", "auc"))),
                                       "mine_tar@1e-3": pt["tar@1e-3"], "scorer_tar@1e-3": c["metrics"]["tar@1e-3"]}
                break
        if "scorer_match" in out:
            break
    return out


# ----------------------------------------------------------------------------------------------
# Main


_CTX: dict = {}


class LiteGroup:
    """What the report needs of a Group, without the trial arrays."""

    def __init__(self, grp: Group):
        self.models, self.cells, self.notes = grp.models, {ck: None for ck in grp.cells}, grp.notes


def average_cell_results(per_fold: list) -> dict:
    """[{cell: (point vec, reps)}, ...] -> {cell: (mean point, mean reps)}."""
    acc: dict = {}
    for cells in per_fold:
        for ck, (pt, rp) in cells.items():
            a = acc.setdefault(ck, [[], []])
            a[0].append(pt)
            if rp is not None:
                a[1].append(rp)
    return {ck: (np.mean(a[0], axis=0), np.mean(a[1], axis=0) if a[1] else None) for ck, a in acc.items()}


def _pair_task(pair):
    data, eng, tc_groups, folds = _CTX["data"], _CTX["eng"], _CTX["tc_groups"], _CTX["folds"]
    grp = build_group(data, pair)
    res = {"group": LiteGroup(grp), "methods": {}}
    for m in pair:
        res["methods"][f"single:{m}"] = eng.eval_avg(grp, f"single:{m}")
    for meth in FUSION_METHODS:
        res["methods"][meth] = eng.eval_avg(grp, meth, with_reps=(meth != "zavg-percond"))  # sensitivity row: no CI
    res["calib"] = {f"{r}.{f}": eng.calibrate(grp, (r, f)) for (r, f) in folds}
    _, htcs = headline_tcs(grp, tc_groups)
    res["onethr"] = {k: eng.one_threshold(grp, k, htcs) for k in res["methods"]}
    # weight sweep (fixed w, z-norm from the calibration half), points only
    res["sweep"] = {float(w): eng.eval_avg(grp, "zw", with_reps=False, w_fixed=float(w)) for w in W_GRID}
    return pair, res


def _single_task(m):
    data, eng, tcs = _CTX["data"], _CTX["eng"], _CTX["tcs"]
    return m, eng.eval_avg(build_group(data, (m,), tcs), f"single:{m}")


def _search_calib_task(job):
    pair, search_tcs = job
    data, eng, folds = _CTX["data"], _CTX["eng"], _CTX["folds"]
    grp = build_group(data, pair, search_tcs)
    out = {}
    for f in folds:
        c = eng.calibrate(grp, f)
        out[f] = (c["obj_at_w"], c["w"])
    return pair, out


def _eval_folds_task(job):
    pair, search_tcs, method, fold_list = job
    data, eng = _CTX["data"], _CTX["eng"]
    grp = build_group(data, pair, search_tcs)
    out = {}
    for f in fold_list:
        out[f] = {ck: (np.array([pt[m] for m in METRICS]), rp) for ck, (pt, rp) in eng.eval_method(grp, method, f).items()}
    return out


def cache_key(data: Data, args, grp: Group, kind: str) -> str:
    """Key of a cached result: code version, settings, the cells and valid-trial masks, and every embedding file used."""
    parts = [FUSION_VERSION, sv.SCORER_VERSION, kind, str(args.boot), str(args.repeats), ",".join(data.tcs), grp.sig]
    for m in grp.models:
        for sname in data.states:
            for c in sv.CONDS:
                parts.append(f"{m}|{sname}|{c}|{sv.file_sig(sv.emb_path(data.vp, m, sname, c))}")
    return hashlib.sha1("\n".join(parts).encode()).hexdigest()[:20]


def cache_load(vp: Path, key: str):
    path = vp / "results" / "fusion_cache" / f"{key}.pkl"
    try:
        with open(path, "rb") as fh:
            return pickle.load(fh)
    except Exception:
        return None


def cache_save(vp: Path, key: str, obj) -> None:
    path = vp / "results" / "fusion_cache" / f"{key}.pkl"
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    with open(tmp, "wb") as fh:
        pickle.dump(obj, fh, protocol=pickle.HIGHEST_PROTOCOL)
    os.replace(tmp, path)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vp", default=str(sv.DEFAULT_VP))
    ap.add_argument("--boot", type=int, default=N_BOOT, help="bootstrap replicates")
    ap.add_argument("--repeats", type=int, default=1, help="random speaker splits (each used in both directions)")
    ap.add_argument("--conds", default=",".join(DEFAULT_CONDS), help="conditions; cross trials are clean>each degraded one")
    ap.add_argument("--top-n", type=int, default=8)
    ap.add_argument("--rank-group", choices=("auto", "clean", "cross"), default="auto")
    ap.add_argument("--no-search", action="store_true", help="skip the top-n pair search")
    ap.add_argument("--pairs", default="", help="override the named pairs: a+b,c+d ( - for none)")
    ap.add_argument("--no-cache", action="store_true", help="ignore VP/results/fusion_cache")
    ap.add_argument("--workers", type=int, default=3, help="worker processes (each single-threaded)")
    ap.add_argument("--out", default="fusion_summary", help="output stem in VP/results/")
    args = ap.parse_args(argv)

    vp = Path(args.vp).resolve()
    conds = tuple(c for c in args.conds.split(",") if c)
    tcs, tc_groups = tc_lists(conds)
    t0 = time.time()
    data = Data(vp, tcs, args.boot)
    if not data.states:
        log("no human set is ready with a fresh trial cache")
        return 2
    folds = [(r, f) for r in range(args.repeats) for f in (0, 1)]
    eng = Engine(data, folds, tc_groups)
    log(f"sets: {', '.join(data.states)}; folds {len(folds)}; boot {args.boot}; conditions {', '.join(tcs)}")

    named = [] if args.pairs == "-" else ([tuple(p.split("+")) for p in args.pairs.split(",") if p] or NAMED_PAIRS + EXTRA_PAIRS)
    lic = read_licenses(vp)
    have = {p.name for p in (vp / "emb").iterdir() if p.is_dir()}

    per_tc_expected = sum(len(data.trials[s]) for s in data.states)

    # every model that will be touched: embeddings and cosines are loaded once here, then shared with the
    # worker processes (fork) so none of them reloads anything
    searches: list = []
    if not args.no_search:
        chosen, raw, dropped, ranked_on = top_models(vp, args.top_n, args.rank_group, have, lic)
        searches.append({"title": f"Top {args.top_n} of verify_summary.csv", "chosen": chosen, "raw_top": raw,
                         "dropped": dropped, "ranked_on": ranked_on})
        # the same ranking, restricted to models that already have every condition on every set: this search
        # can use the cross-condition trials while the top list is still waiting for degraded embeddings
        full = {m for m in have if all(sv.emb_path(vp, m, s, c).exists() for s in data.states for c in conds)}
        chosen2, raw2, dropped2, ranked2 = top_models(vp, args.top_n, args.rank_group, full, lic,
                                                      "degraded embeddings not complete yet")
        if len(chosen2) >= 3 and set(chosen2) != set(chosen):
            searches.append({"title": f"Top {args.top_n} of verify_summary.csv among models with every condition already embedded",
                             "chosen": chosen2, "raw_top": raw2, "dropped": dropped2, "ranked_on": ranked2})
    all_chosen = list(dict.fromkeys(m for sr in searches for m in sr["chosen"]))
    all_models = sorted({m for p in named for m in p if m in have} | set(all_chosen))
    for m in all_models:
        build_group(data, (m,), tcs)
    n_missing = sum(int(np.isnan(data.cos(m, s, b, tc)).sum()) for m in all_models for s in data.states
                    for b in data.trials[s] for tc in tcs if data.cos(m, s, b, tc) is not None)
    if n_missing:
        data.notes.append(f"{n_missing} (trial, model) scores are missing because a clip has no embedding; a single model "
                          "and a fusion are scored on the same trials inside a pair, but the candidate-list singles use their own")
    _CTX.update(data=data, eng=eng, tc_groups=tc_groups, tcs=tcs, folds=folds)
    pool_ = None
    if args.workers > 1:
        import multiprocessing as mp
        pool_ = mp.get_context("fork").Pool(args.workers)

    def run(fn, jobs):
        return list(pool_.imap(fn, jobs)) if pool_ else [fn(j) for j in jobs]

    # ---- named pairs
    results: dict = {}
    todo, keys = [], {}
    for pair in named:
        if not all(m in have for m in pair):
            data.notes.append(f"pair {'+'.join(pair)}: a model has no embeddings yet, skipped")
            continue
        grp = build_group(data, pair)
        if not grp.cells:
            data.notes.append(f"pair {'+'.join(pair)}: no common cells yet")
            continue
        keys[pair] = cache_key(data, args, grp, "pair")
        hit = None if args.no_cache else cache_load(vp, keys[pair])
        if hit is not None:
            results[pair] = hit
            log(f"  {'+'.join(pair)}: {len(hit['group'].cells)} cells (cached)")
        else:
            todo.append(pair)
    for pair, res in run(_pair_task, todo):
        results[pair] = res
        cache_save(vp, keys[pair], res)
        log(f"  {'+'.join(pair)}: {len(res['group'].cells)} cells")
    results = {p: results[p] for p in named if p in results}

    # ---- singles of every candidate over every cell they have (the practical alternative to a pair)
    need_singles = list(dict.fromkeys(all_chosen + [m for pair in results for m in pair]))
    singles_all, todo_s, skeys = {}, [], {}
    for m in need_singles:
        skeys[m] = cache_key(data, args, build_group(data, (m,), tcs), "single")
        hit = None if args.no_cache else cache_load(vp, skeys[m])
        if hit is not None:
            singles_all[m] = hit
        else:
            todo_s.append(m)
    for m, cells in run(_single_task, todo_s):
        singles_all[m] = cells
        cache_save(vp, skeys[m], cells)

    # ---- pair search over the top-n
    for search in searches:
        chosen = search["chosen"]
        cand_cells = None
        for m in chosen:
            ks = {(s, b, tc) for s in data.states for b in data.trials[s] for tc in tcs
                  if data.cos(m, s, b, tc) is not None}
            cand_cells = ks if cand_cells is None else cand_cells & ks
        cand_cells = cand_cells or set()
        cross_cells = [c for c in cand_cells if c[2] in tc_groups["cross"]]
        full_cross = bool(tc_groups["cross"]) and len(cross_cells) == per_tc_expected * len(tc_groups["cross"])
        search_tcs = tcs if full_cross else ("clean",)
        search["search_tcs"] = search_tcs
        search["n_cells"] = len([c for c in cand_cells if c[2] in search_tcs])
        log(f"pair search over {len(chosen)} models on {', '.join(search_tcs)} ({search['n_cells']} cells)")
        pairs = list(itertools.combinations(chosen, 2))
        calib = dict(run(_search_calib_task, [(p, search_tcs) for p in pairs]))
        search["fold_obj"] = {f: {p: calib[p][f][0] for p in pairs} for f in folds}
        search["rank_w"] = {p: [calib[p][f][1] for f in folds] for p in pairs}
        sel_by_fold = {f: max(pairs, key=lambda p: search["fold_obj"][f][p]) for f in folds}
        search["rank"] = sorted(((p, float(np.mean([search["fold_obj"][f][p] for f in folds]))) for p in pairs),
                                key=lambda x: -x[1])
        search["sel_by_fold"] = {f"{r}.{f}": list(sel_by_fold[(r, f)]) for (r, f) in folds}
        # nested: the pair picked in-fold, `ztuned`, on that fold's evaluation half
        sel_pairs = sorted(set(sel_by_fold.values()))
        jobs = [(p, search_tcs, "ztuned", [f for f in folds if sel_by_fold[f] == p]) for p in sel_pairs]
        nested: dict = {}
        for per_fold in run(_eval_folds_task, jobs):
            for fold, cells in per_fold.items():
                for ck, v in cells.items():
                    nested.setdefault(ck, []).append(v)
        search["nested"] = {ck: (np.mean([v[0] for v in vs], axis=0),
                                 np.mean([v[1] for v in vs], axis=0) if all(v[1] is not None for v in vs) else None)
                            for ck, vs in nested.items()}
        search["singles"] = {m: {ck: v for ck, v in singles_all[m].items() if ck in cand_cells and ck[2] in search_tcs}
                             for m in chosen}
        # the pair that ranks first over all folds, on every evaluation half (its picking used every speaker)
        best_pair = search["rank"][0][0]
        search["best_pair"] = best_pair
        meths = ["ztuned", "concat", "zavg", f"single:{best_pair[0]}", f"single:{best_pair[1]}"]
        search["best_pair_res"] = {}
        for meth, per_fold in zip(meths, run(_eval_folds_task, [(best_pair, search_tcs, k, folds) for k in meths])):
            search["best_pair_res"][meth] = average_cell_results(list(per_fold.values()))

    # the practical alternative to a pair is the best single model on offer, not just the better of the two
    for pair, res in results.items():
        grp = res["group"]
        hname, htcs = headline_tcs(grp, tc_groups)
        need = {ck for ck in grp.cells if ck[2] in htcs}
        best = None
        for m in dict.fromkeys(all_chosen + list(pair)):
            if m not in singles_all or not need <= set(singles_all[m]):
                continue
            sub = {k: v for k, v in singles_all[m].items() if k in need}
            pt, rp = pool(sub, htcs)
            if pt is not None and (best is None or pt[I_TAR3] > best[1][I_TAR3]):
                best = (m, pt, rp)
        res["cand_best"] = best
    if pool_:
        pool_.close()
        pool_.join()
    cover = {m: {tc: sum(1 for s in data.states for b in data.trials[s] if data.cos(m, s, b, tc) is not None)
                 for tc in tcs} for m in all_models}
    checks = self_checks(data, data.notes)
    write_report(vp, args, data, eng, tc_groups, tcs, named, results, searches, cover, per_tc_expected, checks, t0, lic)
    log(f"done in {time.time() - t0:.0f}s")
    return 0


# ----------------------------------------------------------------------------------------------
# Report


def headline_tcs(grp: Group, tc_groups: dict) -> tuple[str, tuple]:
    have = {tc for (_, _, tc) in grp.cells}
    cr = tuple(t for t in tc_groups["cross"] if t in have)
    return ("cross", cr) if cr else ("clean", ("clean",))


def complete(grp: Group, data: Data, tcs: tuple) -> bool:
    return len(grp.cells) >= sum(len(data.trials[s]) for s in data.states) * len(tcs)


def write_report(vp, args, data, eng, tc_groups, tcs, named, results, searches, cover, per_tc_expected, checks, t0, lic):
    L = []
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    sets_txt = ", ".join(data.states)
    nfold = len(eng.folds)
    L.append("# Voiceprint fusion: does combining two models beat the best one?\n")
    L.append(f"Generated {now} by `scripts/voiceprint/score_fusion.py` v{FUSION_VERSION} on top of `score_verify.py` "
             f"v{sv.SCORER_VERSION} (same trial lists, drop lists, embeddings and metric code). Human-labeled sets: {sets_txt}. "
             f"TAR, EER and Δ are in % (Δ in percentage points).\n")
    verdicts = []
    body = []

    # ---- coverage
    body.append("## Data coverage\n")
    body.append("Cells = (set, clip length) trial lists per condition; a full condition is "
                f"{per_tc_expected}. A pair is scored on the cells both models have.\n")
    body.append("| model | " + " | ".join(tcs) + " |")
    body.append("|---|" + "---|" * len(tcs))
    for m, row in cover.items():
        body.append(f"| `{m}` | " + " | ".join(f"{row[tc]}/{per_tc_expected}" for tc in tcs) + " |")
    body.append("")

    # ---- named pairs
    body.append("## Pairs\n")
    body.append(f"Each row: pooled over the pair's cells (mean over sets of the mean over that set's cells), cross-fitted "
                f"({nfold} folds: {args.repeats} random speaker split(s), both directions; z-norm constants and weights "
                f"fitted on the other half of the speakers). **cross** = enroll clean, test opus12 / noisy; "
                f"**clean** = both sides clean. Δ = fusion minus the better single model of the pair (better = higher pooled "
                f"TAR@1e-3 on the same trials, picked after the fact, which is conservative), with a paired 95% "
                f"bootstrap CI over speakers ({args.boot} replicates); `*` = CI excludes 0. `p` = two-sided bootstrap p "
                f"for that Δ on TAR@1e-3, resolution 1/{args.boot + 1}.\n")
    summary_rows = []
    for pair, res in results.items():
        grp = res["group"]
        hname, htcs = headline_tcs(grp, tc_groups)
        is_full = complete(grp, data, tcs)
        pname = " + ".join(f"`{m}`" for m in pair)
        metas = [sv.model_meta(vp, m) for m in pair]
        fam = " + ".join(str(mt.get("family", "?")) for mt in metas)
        prm = " + ".join(f"{mt['params_m']:g}M" for mt in metas if mt.get("params_m"))
        body.append(f"### {pname}\n")
        body.append(f"Families: {fam}; parameters: {prm or 'n/a'}." + (
            " **Extra pair, not in the brief** (stand-in for the resnet293 pairs while their degraded embeddings are missing)."
            if pair in EXTRA_PAIRS else "") + "\n")
        cov = f"{len(grp.cells)}/{per_tc_expected * len(tcs)} cells"
        if not is_full:
            have_tc = sorted({tc for (_, _, tc) in grp.cells}, key=tcs.index)
            body.append(f"**Partial: {cov}** (conditions present: {', '.join(have_tc)}). Headline group here: **{hname}**. "
                        "Rerun when the missing embeddings land; do not read a verdict from this row.\n")
        for n in grp.notes:
            body.append(f"_{n}_\n")
        singles = [f"single:{m}" for m in pair]
        pts = {k: pool(res["methods"][k], htcs) for k in res["methods"]}
        best_single = max(singles, key=lambda k: -1 if pts[k][0] is None else pts[k][0][I_TAR3])
        bs_pt, bs_rp = pts[best_single]
        bs_clean = pool(res["methods"][best_single], ("clean",))
        bs_cross = pool(res["methods"][best_single], tc_groups["cross"]) if hname == "cross" else (None, None)
        lic_txt = ", ".join(f"`{m}`: {license_of(lic, m) or 'unknown'}" for m in pair)
        body.append(f"License gate: {lic_txt}.\n")
        show_clean = hname != "clean"
        body.append(f"| method | TAR@1e-3 {hname} | Δ vs best single | p | EER {hname} | Δ EER | "
                    f"TAR@1e-4 {hname}, one threshold |" + (" TAR@1e-3 clean | Δ clean | EER clean |" if show_clean else ""))
        body.append("|---|---|---|---|---|---|---|" + ("---|---|---|" if show_clean else ""))
        for k in singles + list(FUSION_METHODS):
            pt, rp = pts[k]
            if pt is None:
                continue
            cpt, crp = pool(res["methods"][k], ("clean",))
            name = f"`{k[7:]}` alone" if k.startswith("single:") else METHOD_LABEL[k]
            if k == best_single:
                name += " **(best single)**"
                d1 = d2 = d3 = "ref"
                p = "-"
            else:
                d1, c1, p_, _ = delta_txt(pt, rp, bs_pt, bs_rp, I_TAR3)
                d2, _, _, _ = delta_txt(pt, rp, bs_pt, bs_rp, I_EER, 2)
                d3 = "-" if cpt is None or bs_clean[0] is None else delta_txt(cpt, crp, bs_clean[0], bs_clean[1], I_TAR3)[0]
                p = "-" if p_ is None else f"{p_:.3f}"
                if k in ("concat", "zavg", "ztuned") and is_full:
                    cbx = res.get("cand_best")
                    cand_d = delta_txt(pt, rp, cbx[1], cbx[2], I_TAR3) + (cbx[0],) if cbx else None
                    summary_rows.append((pair, k, d1, c1, p_, delta_txt(pt, rp, bs_pt, bs_rp, I_EER, 2), pt, rp, cand_d))
            ot = res["onethr"][k]
            ot_txt = "-" if ot["tar@1e-4"] is None else f"{pct(ot['tar@1e-4'])} ({int(np.floor(1e-4 * ot['n_nontarget']))} FA of {ot['n_nontarget']})"
            body.append(f"| {name} | {cipct(pt[I_TAR3], rp, I_TAR3)} | {d1} | {p} | {cipct(pt[I_EER], rp, I_EER, 2)} | {d2} "
                        f"| {ot_txt} |" + (f" {'-' if cpt is None else cipct(cpt[I_TAR3], crp, I_TAR3)} | {d3} "
                        f"| {'-' if cpt is None else cipct(cpt[I_EER], crp, I_EER, 2)} |" if show_clean else ""))
        body.append("")
        cb = res.get("cand_best")
        if cb and cb[0] not in pair:
            lines = [f"Best single model among the candidates on these cells: `{cb[0]}`, TAR@1e-3 {hname} {cipct(cb[1][I_TAR3], cb[2], I_TAR3)}, "
                     f"EER {cipct(cb[1][I_EER], cb[2], I_EER, 2)}. Fusion minus that model, TAR@1e-3 {hname}: "]
            parts = []
            for k in ("concat", "ztuned"):
                fpt, frp = pts[k]
                if fpt is not None:
                    parts.append(f"{k} {delta_txt(fpt, frp, cb[1], cb[2], I_TAR3)[0]}")
            body.append(lines[0] + "; ".join(parts) + ".\n")
        # by condition
        body.append("By condition, TAR@1e-3 / EER (headline methods):\n")
        body.append("| method | " + " | ".join(tcs) + " |")
        body.append("|---|" + "---|" * len(tcs))
        for k in singles + ["concat", "ztuned"]:
            row = []
            for tc in tcs:
                pt, _ = pool(res["methods"][k], (tc,))
                row.append("-" if pt is None else f"{pct(pt[I_TAR3])} / {pct(pt[I_EER], 2)}")
            nm = f"`{k[7:]}`" if k.startswith("single:") else k
            body.append(f"| {nm} | " + " | ".join(row) + " |")
        body.append("")
        # per set and per clip length: best fusion method vs best single
        fmeth = "ztuned"
        body.append(f"Per set and clip length, `ztuned` minus best single, TAR@1e-3 {hname} (pp, paired 95% CI):\n")
        set_names = sorted({c[0] for c in grp.cells})
        buckets = sorted({c[1] for c in grp.cells})
        body.append("| | " + " | ".join(f"{s}" for s in set_names) + " | " + " | ".join(f"{b} s" for b in buckets) + " |")
        body.append("|---|" + "---|" * (len(set_names) + len(buckets)))
        row = []
        for s in set_names:
            f_ = pool(res["methods"][fmeth], htcs, {s})
            b_ = pool(res["methods"][best_single], htcs, {s})
            row.append("-" if f_[0] is None else delta_txt(f_[0], f_[1], b_[0], b_[1], I_TAR3)[0])
        for bk in buckets:
            sub_f = {k: v for k, v in res["methods"][fmeth].items() if k[1] == bk}
            sub_b = {k: v for k, v in res["methods"][best_single].items() if k[1] == bk}
            f_, b_ = pool(sub_f, htcs), pool(sub_b, htcs)
            row.append("-" if f_[0] is None else delta_txt(f_[0], f_[1], b_[0], b_[1], I_TAR3)[0])
        body.append("| Δ | " + " | ".join(row) + " |")
        body.append("")
        # calibration
        ws = [res["calib"][k]["w"] for k in res["calib"]]
        st_all = {}
        for k, c in res["calib"].items():
            for mi, m in enumerate(pair):
                st_all.setdefault(m, []).append(c["stats"][(mi, "all")])
        body.append("Fitted on the calibration halves: tuned weight on " + f"`{pair[0]}` = "
                    + ", ".join(f"{w:.1f}" for w in ws) + " (one per fold); non-target z-norm mean / std per model: "
                    + "; ".join(f"`{m}` {np.mean([a for a, _ in v]):.3f} / {np.mean([b for _, b in v]):.3f}" for m, v in st_all.items())
                    + f". Objective on the calibration half: {hname} TAR@1e-3.\n")
        # weight sweep
        body.append(f"Weight sweep (not tuned; z-norm from the calibration half, weight w on `{pair[0]}`), evaluation halves, "
                    f"TAR@1e-3 {hname}{' / clean' if hname != 'clean' else ''} / EER {hname}:\n")
        body.append("| w | " + " | ".join(f"{w:.1f}" for w in W_GRID) + " |")
        body.append("|---|" + "---|" * len(W_GRID))
        sweep_rows = [(f"TAR {hname}", htcs, I_TAR3, 1)] + ([("TAR clean", ("clean",), I_TAR3, 1)] if show_clean else []) \
            + [(f"EER {hname}", htcs, I_EER, 2)]
        for label, tset, idx, dg in sweep_rows:
            row = []
            for w in W_GRID:
                pt, _ = pool(res["sweep"][float(w)], tset)
                row.append("-" if pt is None else pct(pt[idx], dg))
            body.append(f"| {label} | " + " | ".join(row) + " |")
        body.append("")

    # ---- overall summary table of complete pairs
    verdicts.append("## Verdict\n")
    if summary_rows:
        verdicts.append("Complete pairs only (all four sets, every condition), cross-condition headline, fusion minus the better "
                        "single model of the pair:\n")
        verdicts.append("| pair | method | Δ TAR@1e-3 cross | p | Δ EER cross | significant? | Δ TAR@1e-3 vs best single of all candidates |")
        verdicts.append("|---|---|---|---|---|---|---|")
        gains = []
        for pair, k, d1, c1, p_, (d2, c2, _, _), pt, rp, cand_d in summary_rows:
            sig = is_gain(c1, I_TAR3)
            both = sig and is_gain(c2, I_EER)
            if sig:
                gains.append((pair, k, d1))
            cand_txt = "-" if not cand_d else f"{cand_d[0]} vs `{cand_d[4]}`"
            verdicts.append(f"| {' + '.join(pair)} | {k} | {d1} | {'-' if p_ is None else f'{p_:.3f}'} | {d2} "
                            f"| {'yes (TAR and EER)' if both else ('TAR only' if sig else 'no')} | {cand_txt} |")
        n_cmp = len(summary_rows)
        verdicts.append("")
        sig_rows = [r for r in summary_rows if is_gain(r[3], I_TAR3)]
        cand_sig = [r for r in summary_rows if r[8] and is_gain(r[8][1], I_TAR3)]
        if sig_rows:
            best_r = max(sig_rows, key=lambda r: r[2 + 0] and float(r[2].split()[0].rstrip("*")))
            verdicts.append(f"- Significant gains over the better single model of the pair: {len(sig_rows)} of {n_cmp} comparisons. "
                            f"Largest: {' + '.join(best_r[0])}, {best_r[1]}, {best_r[2]} TAR@1e-3 and {best_r[5][0]} EER (pp).")
        else:
            verdicts.append(f"- No comparison shows a significant TAR@1e-3 gain over the better single model of its pair.")
        verdicts.append(f"- Against the best single model on offer (the practical alternative), {len(cand_sig)} of {n_cmp} clear a 95% CI"
                        + (": " + "; ".join(f"{' + '.join(r[0])} ({r[1]}) {r[8][0]} vs `{r[8][4]}`" for r in cand_sig) if cand_sig else "") + ".")
        n_concat = sum(1 for r in sig_rows if r[1] == "concat")
        verdicts.append(f"- `concat` (no fitted numbers, one vector per person, the simplest app version) is significant in "
                        f"{n_concat} of {sum(1 for r in summary_rows if r[1] == 'concat')} pairs; `ztuned` in "
                        f"{sum(1 for r in sig_rows if r[1] == 'ztuned')} of {sum(1 for r in summary_rows if r[1] == 'ztuned')}.")
        verdicts.append("")
        verdicts.append(f"{n_cmp} fusion-versus-single comparisons are listed; with that many, expect about {0.05 * n_cmp:.1f} "
                        "to clear a 95% CI by chance, so a lone marginal star is not evidence.\n")
    else:
        verdicts.append("No pair has every set and condition yet, so there is no verdict; the tables below are partial.\n")

    # ---- pair search
    for search in searches:
        body.append(f"## Best pair search: {search['title']}\n")
        body.append(f"Candidates: the top {args.top_n} of `verify_summary.csv` ranked on human TAR@1e-3 **{search['ranked_on']}** "
                    f"({'cross data is complete enough' if search['ranked_on'] == 'cross' else 'cross-condition data is still incomplete for most models'}), "
                    "minus the exclusions below.\n")
        body.append("Raw top: " + ", ".join(f"`{m}`" for m in search["raw_top"]) + ".\n")
        if search["dropped"]:
            body.append("Not used: " + "; ".join(f"`{m}` ({why})" for m, why in search["dropped"][:14]) + ".\n")
        body.append("Candidates used: " + ", ".join(f"`{m}`" for m in search["chosen"]) + ".\n")
        body.append(f"Search objective: pooled TAR@1e-3 on **{', '.join(search['search_tcs'])}** ({search['n_cells']} cells common to "
                    "every candidate), `ztuned` fitted on the calibration half. "
                    + ("" if search["search_tcs"] != ("clean",) else
                       "Only clean is used because not every candidate has degraded embeddings yet. ") + "\n")
        body.append("Pair ranking by calibration-half objective, averaged over folds (the same speakers are used for selection "
                    "and, in the other fold, evaluation, so this is a ranking, not a score):\n")
        body.append("| # | pair | calibration TAR@1e-3 (%) | weight on first, per fold |")
        body.append("|---|---|---|---|")
        for i, (p, v) in enumerate(search["rank"][:10], 1):
            ws = search["rank_w"][p]
            body.append(f"| {i} | `{p[0]}` + `{p[1]}` | {pct(v)} | {', '.join(f'{w:.1f}' for w in ws)} |")
        body.append("")
        singles_rank = []
        for m, res in search["singles"].items():
            pt, rp = pool(res, search["search_tcs"])
            singles_rank.append((m, pt, rp))
        singles_rank.sort(key=lambda x: -x[1][I_TAR3])
        best_m, best_pt, best_rp = singles_rank[0]
        body.append(f"Best single among the candidates on the same cells (evaluation halves): `{best_m}`, "
                    f"TAR@1e-3 {cipct(best_pt[I_TAR3], best_rp, I_TAR3)}, EER {cipct(best_pt[I_EER], best_rp, I_EER, 2)}.\n")
        body.append("| what | TAR@1e-3 | Δ vs best single | p | EER | Δ EER |")
        body.append("|---|---|---|---|---|---|")
        npt, nrp = pool(search["nested"], search["search_tcs"])
        rows = [("**nested**: pair picked in-fold on the calibration half, `ztuned`", npt, nrp)]
        bp = search["best_pair"]
        for meth in ("ztuned", "concat", "zavg"):
            pt, rp = pool(search["best_pair_res"][meth], search["search_tcs"])
            rows.append((f"top-ranked pair `{bp[0]}` + `{bp[1]}`, {meth} (optimistic: picked with all speakers)", pt, rp))
        for nm, pt, rp in rows:
            d1, c1, p_, _ = delta_txt(pt, rp, best_pt, best_rp, I_TAR3)
            d2 = delta_txt(pt, rp, best_pt, best_rp, I_EER, 2)[0]
            body.append(f"| {nm} | {cipct(pt[I_TAR3], rp, I_TAR3)} | {d1} | {'-' if p_ is None else f'{p_:.3f}'} "
                        f"| {cipct(pt[I_EER], rp, I_EER, 2)} | {d2} |")
        body.append("")
        lic_bp = ", ".join(f"`{m}`: {license_of(lic, m) or 'unknown'}" for m in bp)
        body.append(f"License gate of the top-ranked pair: {lic_bp}.\n")
        body.append("In-fold picks: " + "; ".join(f"fold {k}: `{v[0]}` + `{v[1]}`" for k, v in search["sel_by_fold"].items()) + ".\n")
        body.append("Single models of the candidate list on the same cells and folds (TAR@1e-3 / EER):\n")
        body.append("| model | TAR@1e-3 | EER |")
        body.append("|---|---|---|")
        for m, pt, rp in singles_rank:
            body.append(f"| `{m}` | {cipct(pt[I_TAR3], rp, I_TAR3)} | {cipct(pt[I_EER], rp, I_EER, 2)} |")
        body.append("")
        if search["search_tcs"] == ("clean",):
            verdicts.append(f"Pair search \"{search['title']}\" ran on clean trials only for now; see its section.\n")

    # ---- notes
    body.append("## Method notes and checks\n")
    concat_note = ""
    if "concat_vs_avg_max_abs" in checks:
        concat_note = (f" Checked on real embeddings: max |literal concat cosine - (cos A + cos B) / 2| = "
                       f"{checks['concat_vs_avg_max_abs']:.2e}; max |weighted concat * (a1 + a2) - z fusion| = "
                       f"{checks['weighted_concat_vs_z_max_abs']:.2e}.")
    body.append("- **Concatenation equals a plain average of the two cosines.** For unit vectors, [a, b]·[a', b'] = cos(a, a') + "
                "cos(b, b'), and re-normalizing divides by 2. So `concat` is the unweighted raw-cosine fusion, and a z-norm weighted "
                "average is the same thing with block scales sqrt(w / std) (the additive z-norm mean only moves the threshold, "
                "not the ranking). One vector per person is therefore enough for the app; nothing is lost by choosing "
                "concatenation over score fusion, except the option to change weights per condition." + concat_note)
    if "scorer_match" in checks:
        sm = checks["scorer_match"]
        body.append(f"- Pipeline check: {sm['cell']}, all trials: TAR@1e-3 {100 * sm['mine_tar@1e-3']:.3f}% here vs "
                    f"{100 * sm['scorer_tar@1e-3']:.3f}% in score_verify's cached cell (max abs diff over EER, TAR, AUC "
                    f"{sm['max_abs_diff']:.1e}).")
    body.append(f"- Non-target trials per fold are 1/4 of the shared list (both speakers in the evaluation half), so TAR@1e-3 "
                "rests on about 7 false accepts per cell before pooling; that is why the CIs here are wider than score_verify's.")
    body.append("- Halves are seeded 50/50 splits of each set's speakers (stranger-only speakers split evenly too); "
                "vox1o has only 40 speakers.")
    body.append("- Bootstrap: speakers resampled with the same replicate weights score_verify uses per set, so Δ CIs are paired "
                "across methods and folds. The CI does not include the after-the-fact choice of the better single model "
                "(which works against fusion) or the choice among several fusion methods and pairs (which works for it).")
    for n in data.notes:
        body.append(f"- {n}")
    body.append("")

    out_md = "\n".join(L + verdicts + [""] + body)
    sv.save_text(vp / "results" / f"{args.out}.md", out_md)

    # ---- json
    js = {"version": FUSION_VERSION, "generated_at": now, "folds": len(eng.folds), "boot": args.boot,
          "conditions": list(tcs), "checks": checks, "pairs": {}}
    for pair, res in results.items():
        grp = res["group"]
        hname, htcs = headline_tcs(grp, tc_groups)
        d = {"cells": len(grp.cells), "complete": complete(grp, data, tcs), "headline": hname, "methods": {}}
        for k, cr in res["methods"].items():
            entry = {}
            for gname, gt in (("clean", ("clean",)), ("cross", tc_groups["cross"]), ("headline", htcs)):
                pt, rp = pool(cr, gt)
                if pt is None:
                    continue
                entry[gname] = {m: {"value": float(pt[i]), "ci": sv.ci(rp[i] if rp is not None else None)} for i, m in enumerate(METRICS)}
            d["methods"][k] = entry
        js["pairs"]["+".join(pair)] = d
    sv.save_text(vp / "results" / f"{args.out}.json", json.dumps(js, indent=1))
    log(f"wrote {vp / 'results' / (args.out + '.md')}")


if __name__ == "__main__":
    sys.exit(main())
