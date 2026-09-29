#!/usr/bin/env python3
"""Pooled open-set lineup for the voiceprint bake-off: every labeled person in one database.

The owner's question: with hundreds of people saved, how often does a new session get matched to
the WRONG person, especially someone who sounds alike? One wrong name destroys trust, so the
headline is how many known people still get named when the bar is set so nobody gets a wrong name.

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md. VP = data/eval/voiceprint (or $VP_ROOT).
Reads VP/sets/<set>/segments.jsonl, VP/results/audit/drop_<set>.txt and
VP/emb/<model>/<set>__<cond>.npz. Writes VP/results/lineup/<model_id>.json and
VP/results/lineup_summary.md. Never touches the app's real speaker database.

People and roles (per seed, seeds 0..4)
  * Everyone in the four human-labeled sets (vox1o, libri, ami, icsi), after the audit drop lists.
  * Strangers (never enrolled): every `stranger_only` person, anyone left with one session, plus
    20% of each set's multi-session people (chosen by a seeded hash, per set, so the dataset mix
    stays the same across seeds). Everyone else is enrolled.
  * Sessions are ordered by `date`, then `session_order`, then session id.
  * Profile = L2-normalized mean of the per-session means of the person's earliest k sessions
    (k = 1, also 2), all clips, enrollment audio clean (also opus12, like a profile learned from
    calls). Clip embeddings are L2-normalized before any mean.
  * Probes: every later session of an enrolled person (known probes) and every session of a
    stranger. Probe = L2-normalized mean of that session's clips: 1 clip, 3 clips (seeded picks) or
    all clips. Probe audio: clean, opus12, noisy.

Scoring
  * cos = raw cosine; centered = subtract the model's mean raw embedding (yodas clean; until yodas
    is embedded for a model, the mean over the four human sets' clean clips, flagged in the output),
    then L2-normalize.
  * Lineups: `pooled` = every enrolled person (about 233) is a candidate for every probe;
    `within` = only enrolled people from the probe's own dataset (cross-dataset matches are easier
    because recording conditions differ, so this is the honest version); `xdist` = pooled, plus the
    ~236 yodas `stranger_only` people as extra strangers (side check: yodas labels came from two of
    the candidate models).
  * Closed-set rank-1: the right person is the top match among all enrolled people.
  * Open set, one threshold per model: a name is shown when the top match's cosine > bar.
      DIR   known person, top match correct and above the bar
      misID known person, top match WRONG and above the bar (a wrong name)
      FA    stranger whose top match is above the bar (also a wrong name)
    Operating points: `far1` / `far01` = the bar that lets at most floor(1% / 0.1% x strangers)
    strangers through; `zero` = the lowest bar with zero wrong names at all (no misID, no FA).
  * Bar scope: `one` (headline) = one bar per model per talk time, set on clean + opus12 + noisy
    probes pooled, because the app can't tell a clean room from a weak Zoom link but does know how
    long someone talked; metrics are then reported per condition. `cond` = a bar tuned on that
    condition's probes alone (optimistic; used for the clean-only table so partial models compare
    on equal footing).
  * Everything is computed per seed and averaged over 5 seeds (sd reported).
  * Most-confused pairs: every top-1 wrong match (known person matched to someone else, or a
    stranger's top match) at the headline setting (clean enrollment, 1 session, all clips; all probe
    conditions and seeds pooled), grouped by unordered person pair, ranked by the highest cosine.

Models: every model with clean embeddings on all four human sets. Probe / enrollment conditions
are used only where all four sets have them; a model with clean only is labeled `partial`.

Run (cheap to rerun: a model is recomputed only when one of its inputs changed):
  VP/venv/bin/python scripts/voiceprint/score_lineup.py
  VP/venv/bin/python scripts/voiceprint/score_lineup.py --models app-wespeaker-coreml --force
  VP/venv/bin/python scripts/voiceprint/score_lineup.py --summary-only
"""
from __future__ import annotations

import os

for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_var, "3")

import argparse
import hashlib
import json
import math
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
VERSION = 2

HUMAN_SETS = ("vox1o", "libri", "ami", "icsi")
XDIST_SET = "yodas"
PROBE_CONDS = ("clean", "opus12", "noisy")
ENROLL_CONDS = ("clean", "opus12")
ENROLL_KS = (1, 2)
TALKS = ("1", "3", "all")
TALK_N = {"1": 1, "3": 3, "all": None}
MODES = ("cos", "centered")
MODE_LABEL = {"cos": "raw", "centered": "centered"}
LINEUPS = ("pooled", "within", "xdist")
SCOPES = ("one", "cond")
OPS = ("far1", "far01", "zero")
OP_FAR = {"far1": 0.01, "far01": 0.001}
HOLDOUT = 0.2
N_SEEDS = 5
BASELINE = "app-wespeaker-coreml"
HEAD = {"enroll": "clean", "k": 1, "talk": "all", "probe": "opus12", "lineup": "pooled", "scope": "one"}
TOP_PAIRS = 20


def vp_root() -> Path:
    return Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))


def log(msg: str) -> None:
    print(f"[lineup {time.strftime('%H:%M:%S')}] {msg}", flush=True)


def hnum(*parts) -> int:
    return int.from_bytes(hashlib.sha1("|".join(str(p) for p in parts).encode()).digest()[:8], "big")


def cell_key(mode: str, enroll: str, k: int, talk: str, probe: str, lineup: str, scope: str) -> str:
    return f"{mode}|{enroll}|k{k}|{talk}|{probe}|{lineup}|{scope}"


# ----------------------------------------------------------------------------------------------
# Corpus: people, sessions, clips (model-independent)
# ----------------------------------------------------------------------------------------------

@dataclass
class Corpus:
    sets: list[str]
    seg_index: dict[str, dict[str, int]]   # set -> seg_id -> global row (kept rows only)
    known_ids: dict[str, frozenset]        # set -> every seg_id in segments.jsonl (dropped included)
    row_seg: list[str]
    persons: list[str]
    p_set: list[str]
    p_gender: list[str]
    p_so: np.ndarray        # stranger_only flag
    p_xdist: np.ndarray     # yodas stranger_only person (extra distractor)
    person_ps: list[list[int]]   # ordered person-session indices per person
    ps_person: np.ndarray
    ps_session: list[str]
    ps_rows: list[np.ndarray]
    fp: str
    drop_info: dict
    set_rows: dict[str, np.ndarray] = field(default_factory=dict)
    _orders: dict = field(default_factory=dict)

    @property
    def n_rows(self) -> int:
        return len(self.row_seg)

    def human_mask(self) -> np.ndarray:
        return ~self.p_xdist

    def clip_order(self, seed: int) -> list[np.ndarray]:
        """Rows of every person-session in a seeded order (the first n are the 'n clips' probe)."""
        if seed not in self._orders:
            out = []
            for rows in self.ps_rows:
                keys = [hnum(seed, "clip", self.row_seg[r]) for r in rows]
                out.append(rows[np.argsort(np.array(keys, dtype=np.uint64), kind="stable")])
            self._orders[seed] = out
        return self._orders[seed]


def load_drops(vp: Path, name: str, use: bool) -> tuple[frozenset, str]:
    p = vp / "results" / "audit" / f"drop_{name}.txt"
    if not use or not p.exists():
        return frozenset(), "none"
    text = p.read_text()
    ids = frozenset(l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#"))
    return ids, hashlib.sha1(text.encode()).hexdigest()[:12]


def norm_gender(g) -> str:
    g = str(g or "").strip().upper()[:1]
    return g if g in ("M", "F") else "?"


def session_key(meta: dict, session: str) -> tuple:
    order = meta.get("session_order")
    try:
        order = float(order) if order is not None else math.inf
    except (TypeError, ValueError):
        order = math.inf
    return (str(meta.get("date") or ""), order, session)


def load_corpus(vp: Path, drops: bool = True, with_xdist: bool = True) -> Corpus:
    sets = [s for s in HUMAN_SETS]
    missing = [s for s in HUMAN_SETS if not (vp / "sets" / s / "segments.jsonl").exists()]
    if missing:
        raise SystemExit(f"missing human sets: {missing}")
    if with_xdist and (vp / "sets" / XDIST_SET / "segments.jsonl").exists():
        sets.append(XDIST_SET)
    row_seg: list[str] = []
    seg_index: dict[str, dict[str, int]] = {}
    known_ids: dict[str, frozenset] = {}
    set_rows: dict[str, list[int]] = defaultdict(list)
    fp = hashlib.sha1(f"v{VERSION}".encode())
    drop_info = {}
    person_meta: dict[str, dict] = {}
    ps_rows: dict[tuple[str, str], list[int]] = defaultdict(list)
    ps_meta: dict[tuple[str, str], dict] = {}
    for name in sets:
        path = vp / "sets" / name / "segments.jsonl"
        text = path.read_text()
        fp.update(hashlib.sha1(text.encode()).digest())
        dropset, dsig = load_drops(vp, name, drops)
        fp.update(dsig.encode())
        rows = [json.loads(l) for l in text.splitlines() if l.strip()]
        known_ids[name] = frozenset(str(r["seg_id"]) for r in rows)
        kept = [r for r in rows if str(r["seg_id"]) not in dropset]
        drop_info[name] = {"listed": len(dropset), "removed": len(rows) - len(kept)}
        seg_index[name] = {}
        for r in kept:
            sid = str(r["seg_id"])
            row = len(row_seg)
            row_seg.append(sid)
            seg_index[name][sid] = row
            set_rows[name].append(row)
            spk, ses = str(r["speaker"]), str(r["session"])
            if name == XDIST_SET and not r.get("stranger_only"):
                continue  # yodas multi-session people: rows count for the centering mean only
            pm = person_meta.setdefault(spk, {"set": name, "gender": norm_gender(r.get("gender")), "so": False})
            if pm["gender"] == "?" and r.get("gender"):
                pm["gender"] = norm_gender(r.get("gender"))
            pm["so"] = pm["so"] or bool(r.get("stranger_only"))
            ps_rows[(spk, ses)].append(row)
            m = ps_meta.setdefault((spk, ses), {})
            for f in ("date", "session_order"):
                if r.get(f) is not None and f not in m:
                    m[f] = r[f]
    set_order = {s: i for i, s in enumerate(sets)}
    persons = sorted(person_meta, key=lambda p: (set_order[person_meta[p]["set"]], p))
    pidx = {p: i for i, p in enumerate(persons)}
    by_person: dict[str, list[str]] = defaultdict(list)
    for (spk, ses) in ps_rows:
        by_person[spk].append(ses)
    ps_person, ps_session, ps_list = [], [], []
    person_ps: list[list[int]] = [[] for _ in persons]
    for p in persons:
        for ses in sorted(by_person[p], key=lambda s: session_key(ps_meta[(p, s)], s)):
            i = len(ps_session)
            ps_person.append(pidx[p])
            ps_session.append(ses)
            ps_list.append(np.array(ps_rows[(p, ses)], dtype=np.int64))
            person_ps[pidx[p]].append(i)
    return Corpus(
        sets=sets, seg_index=seg_index, known_ids=known_ids, row_seg=row_seg, persons=persons,
        p_set=[person_meta[p]["set"] for p in persons], p_gender=[person_meta[p]["gender"] for p in persons],
        p_so=np.array([person_meta[p]["so"] for p in persons]),
        p_xdist=np.array([person_meta[p]["set"] == XDIST_SET for p in persons]),
        person_ps=person_ps, ps_person=np.array(ps_person, dtype=np.int64), ps_session=ps_session,
        ps_rows=ps_list, fp=fp.hexdigest(), drop_info=drop_info,
        set_rows={k: np.array(v, dtype=np.int64) for k, v in set_rows.items()},
    )


@dataclass
class SeedPlan:
    seed: int
    enrolled: np.ndarray    # person bool
    stranger: np.ndarray    # human person bool (never enrolled)


def seed_plan(c: Corpus, seed: int) -> SeedPlan:
    enrolled = np.zeros(len(c.persons), dtype=bool)
    for name in HUMAN_SETS:
        multi = [p for p in range(len(c.persons))
                 if c.p_set[p] == name and not c.p_so[p] and len(c.person_ps[p]) >= 2]
        n_hold = int(round(HOLDOUT * len(multi)))
        multi.sort(key=lambda p: hnum(seed, "hold", c.persons[p]))
        enrolled[multi[n_hold:]] = True
    stranger = ~enrolled & ~c.p_xdist
    return SeedPlan(seed, enrolled, stranger)


# ----------------------------------------------------------------------------------------------
# Embeddings
# ----------------------------------------------------------------------------------------------

def emb_path(vp: Path, model: str, set_name: str, cond: str) -> Path:
    return vp / "emb" / model / f"{set_name}__{cond}.npz"


def ready_path(vp: Path, set_name: str, cond: str) -> Path:
    return vp / "sets" / set_name / "READY" if cond == "clean" else vp / "clips" / set_name / cond / "READY"


def load_set_emb(vp: Path, model: str, c: Corpus, set_name: str, cond: str):
    """(rows, X) for the kept clips of one set, or (None, reason)."""
    path = emb_path(vp, model, set_name, cond)
    if not path.exists():
        return None, "missing"
    ready = ready_path(vp, set_name, cond)
    if ready.exists() and path.stat().st_mtime < ready.stat().st_mtime:
        return None, f"stale ({path.name} older than its READY)"
    try:
        with np.load(path, allow_pickle=False) as z:
            ids = z["seg_id"].astype(str)
            X = np.asarray(z["emb"], dtype=np.float32)
    except Exception as exc:  # noqa: BLE001
        return None, f"unreadable ({type(exc).__name__})"
    if X.ndim != 2 or len(ids) != len(X):
        return None, f"bad shape {X.shape}"
    unknown = [s for s in ids if s not in c.known_ids[set_name]]
    if unknown:
        return None, f"stale ({len(unknown)} seg_ids not in segments.jsonl)"
    idx = c.seg_index[set_name]
    rows = np.array([idx.get(s, -1) for s in ids], dtype=np.int64)
    keep = rows >= 0  # the rest are on the drop list
    rows, X = rows[keep], X[keep]
    if len(np.unique(rows)) != len(rows):
        return None, "duplicate seg_ids"
    ok = np.isfinite(X).all(axis=1) & (np.linalg.norm(X, axis=1) > 0)
    return (rows[ok], X[ok]), None


def input_files(vp: Path, model: str) -> list[Path]:
    return [emb_path(vp, model, s, cond) for s in HUMAN_SETS + (XDIST_SET,) for cond in PROBE_CONDS]


def input_sig(vp: Path, model: str, c: Corpus) -> str:
    h = hashlib.sha1(f"v{VERSION}|{c.fp}".encode())
    for p in input_files(vp, model):
        if p.exists():
            st = p.stat()
            h.update(f"{p.name}:{st.st_size}:{st.st_mtime_ns}".encode())
    return h.hexdigest()


def l2n(X: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(X, axis=1, keepdims=True)
    return np.divide(X, n, out=np.zeros_like(X), where=n > 0)


def session_means(X: np.ndarray, sel: list[np.ndarray]) -> tuple[np.ndarray, np.ndarray]:
    """L2-normalized mean of the selected (already normalized) clip rows, per person-session."""
    lens = np.array([len(s) for s in sel])
    valid = lens > 0
    M = np.zeros((len(sel), X.shape[1]), dtype=np.float32)
    if valid.any():
        rows = np.concatenate([s for s in sel if len(s)])
        offs = np.concatenate([[0], np.cumsum(lens[valid])[:-1]]).astype(np.int64)
        M[valid] = np.add.reduceat(X[rows], offs, axis=0)
    return l2n(M), valid


# ----------------------------------------------------------------------------------------------
# Open-set metrics
# ----------------------------------------------------------------------------------------------

def calibrate(known_tops: np.ndarray, known_ok: np.ndarray, str_tops: np.ndarray) -> dict[str, float]:
    """Bars (a name is shown when top > bar) at stranger FA 1% / 0.1% and at zero wrong names."""
    s = np.sort(np.asarray(str_tops, dtype=np.float64))[::-1]
    out = {}
    for op, far in OP_FAR.items():
        k = int(math.floor(far * len(s) + 1e-9))
        out[op] = float(s[k]) if k < len(s) else -math.inf
    wrong = np.asarray(known_tops)[~np.asarray(known_ok, dtype=bool)]
    out["zero"] = float(max(s[0] if len(s) else -math.inf, wrong.max() if len(wrong) else -math.inf))
    return out


def evaluate(bar: float, known_tops: np.ndarray, known_ok: np.ndarray, str_tops: np.ndarray) -> dict:
    named = np.asarray(known_tops) > bar
    ok = np.asarray(known_ok, dtype=bool)
    nk, ns = len(named), len(str_tops)
    n_hit, n_mis = int((named & ok).sum()), int((named & ~ok).sum())
    n_fa = int((np.asarray(str_tops) > bar).sum())
    return {"dir": n_hit / nk if nk else None, "mir": n_mis / nk if nk else None,
            "far": n_fa / ns if ns else None, "n_mis": n_mis, "n_fa": n_fa}


def top_match(P: np.ndarray, G: np.ndarray, allowed: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Top gallery index and cosine per probe; `allowed` (n_probe, n_gallery) masks candidates."""
    if len(P) == 0 or len(G) == 0:
        return np.zeros(len(P), dtype=np.int64), np.full(len(P), -math.inf)
    S = P @ G.T
    if allowed is not None:
        S = np.where(allowed, S, -np.inf)
    top = S.argmax(axis=1)
    return top, S[np.arange(len(S)), top]


# ----------------------------------------------------------------------------------------------
# One model
# ----------------------------------------------------------------------------------------------

class Acc:
    """Per-seed values for every cell, averaged at the end."""

    def __init__(self):
        self.d: dict[str, dict] = {}

    def put(self, key: str, path: tuple, value) -> None:
        node = self.d.setdefault(key, {})
        for p in path[:-1]:
            node = node.setdefault(p, {})
        node.setdefault(path[-1], []).append(value)

    def finish(self) -> dict:
        def fold(node):
            if isinstance(node, list):
                vals = [v for v in node if v is not None and not (isinstance(v, float) and math.isinf(v))]
                if not vals:
                    return {"mean": None, "sd": None, "seeds": node}
                arr = np.array(vals, dtype=np.float64)
                return {"mean": round(float(arr.mean()), 6), "sd": round(float(arr.std()), 6),
                        "seeds": [round(float(v), 6) if v is not None and not math.isinf(v) else None for v in node]}
            return {k: fold(v) for k, v in node.items()}
        return {k: fold(v) for k, v in self.d.items()}


def run_model(vp: Path, model: str, c: Corpus, n_seeds: int = N_SEEDS) -> dict:
    t0 = time.time()
    notes: list[str] = []
    raw: dict[str, tuple[np.ndarray, np.ndarray]] = {}
    xdist_conds: list[str] = []
    dim = None
    for cond in PROBE_CONDS:
        parts, bad = {}, None
        for s in HUMAN_SETS:
            got, why = load_set_emb(vp, model, c, s, cond)
            if got is None:
                bad = f"{s}__{cond}: {why}"
                break
            parts[s] = got
        if bad:
            if not bad.endswith("missing"):
                notes.append(bad)
            continue
        dims = {x.shape[1] for _, x in parts.values()}
        if len(dims) != 1 or (dim is not None and dims != {dim}):
            notes.append(f"{cond}: embedding dims differ across sets {sorted(dims)}")
            continue
        dim = dims.pop()
        R = np.zeros((c.n_rows, dim), dtype=np.float32)
        present = np.zeros(c.n_rows, dtype=bool)
        for rows, X in parts.values():
            R[rows] = X
            present[rows] = True
        if XDIST_SET in c.sets:
            got, why = load_set_emb(vp, model, c, XDIST_SET, cond)
            if got is not None and got[1].shape[1] == dim:
                R[got[0]] = got[1]
                present[got[0]] = True
                xdist_conds.append(cond)
            elif why != "missing":
                notes.append(f"{XDIST_SET}__{cond}: {why}")
        raw[cond] = (R, present)
    if "clean" not in raw:
        return {"model_id": model, "skipped": "no valid clean embeddings on all four human sets", "notes": notes}
    probe_conds = [cd for cd in PROBE_CONDS if cd in raw]
    enroll_conds = [cd for cd in ENROLL_CONDS if cd in raw]
    full = set(probe_conds) == set(PROBE_CONDS)

    # centering mean: yodas clean if embedded, else the human sets' clean clips (flagged)
    Rc, pc_ = raw["clean"]
    if "clean" in xdist_conds:
        yrows = c.set_rows[XDIST_SET]
        yrows = yrows[pc_[yrows]]
        mean = Rc[yrows].astype(np.float64).mean(axis=0)
        center = {"source": "yodas clean", "clips": int(len(yrows))}
    else:
        hrows = np.concatenate([c.set_rows[s] for s in HUMAN_SETS])
        hrows = hrows[pc_[hrows]]
        mean = Rc[hrows].astype(np.float64).mean(axis=0)
        center = {"source": "human sets clean (yodas not embedded yet)", "clips": int(len(hrows))}
    center["mean_norm_over_avg_norm"] = round(float(np.linalg.norm(mean) / np.linalg.norm(Rc[pc_], axis=1).mean()), 4)

    # normalized clip embeddings per (mode, cond)
    Xn: dict[tuple[str, str], np.ndarray] = {}
    for cond, (R, present) in raw.items():
        Xn[("cos", cond)] = l2n(R) * present[:, None]
        Xn[("centered", cond)] = l2n(R - mean.astype(np.float32)[None, :]) * present[:, None]
    del raw

    # session means: all clips (seed-independent) and seeded 1 / 3 clips
    def selection(cond: str, seed: int, talk: str) -> list[np.ndarray]:
        present = Xn[("cos", cond)].any(axis=1)
        if TALK_N[talk] is None:
            return [r[present[r]] for r in c.ps_rows]
        n = TALK_N[talk]
        return [o[present[o]][:n] for o in c.clip_order(seed)]

    sm_cache: dict[tuple, tuple[np.ndarray, np.ndarray]] = {}

    def sm(mode: str, cond: str, seed: int, talk: str):
        key = (mode, cond, seed if talk != "all" else -1, talk)
        if key not in sm_cache:
            sm_cache[key] = session_means(Xn[(mode, cond)], selection(cond, seed, talk))
        return sm_cache[key]

    set_id = {s: i for i, s in enumerate(c.sets)}
    p_setid = np.array([set_id[s] for s in c.p_set])
    acc = Acc()
    counts: dict[str, list] = defaultdict(list)
    pair_events: dict[str, list] = {m: [] for m in MODES}
    pair_bars: dict[str, dict] = {m: {} for m in MODES}
    base_rates = None

    xd_persons = np.flatnonzero(c.p_xdist)
    xd_ps = np.array([ps for p in xd_persons for ps in c.person_ps[p]], dtype=np.int64)

    for seed in range(n_seeds):
        plan = seed_plan(c, seed)
        gal_persons = np.flatnonzero(plan.enrolled)
        str_persons = np.flatnonzero(plan.stranger)
        str_ps = np.array([ps for p in str_persons for ps in c.person_ps[p]], dtype=np.int64)
        counts["enrolled"].append(int(len(gal_persons)))
        counts["strangers"].append(int(len(str_persons)))
        counts["stranger_probes"].append(int(len(str_ps)))
        for k in ENROLL_KS:
            kn_ps = np.array([ps for p in gal_persons for ps in c.person_ps[p][k:]], dtype=np.int64)
            counts[f"known_probes_k{k}"].append(int(len(kn_ps)))
            for mode in MODES:
                for ec in enroll_conds:
                    Mall, vall = sm(mode, ec, seed, "all")
                    G = np.zeros((len(gal_persons), Mall.shape[1]), dtype=np.float32)
                    for gi, p in enumerate(gal_persons):
                        ids = [ps for ps in c.person_ps[p][:k] if vall[ps]]
                        if ids:
                            G[gi] = Mall[ids].sum(axis=0)
                    G = l2n(G)
                    g_ok = np.linalg.norm(G, axis=1) > 0
                    g_setid = p_setid[gal_persons]
                    gpos = {int(p): gi for gi, p in enumerate(gal_persons)}
                    for talk in TALKS:
                        blocks = {}
                        for pc in probe_conds:
                            M, v = sm(mode, pc, seed, talk)
                            kp = kn_ps[v[kn_ps]]
                            k_true = np.array([gpos[int(c.ps_person[ps])] for ps in kp], dtype=np.int64)
                            keep = g_ok[k_true] if len(k_true) else np.zeros(0, dtype=bool)
                            kp, k_true = kp[keep], k_true[keep]
                            sp = str_ps[v[str_ps]]
                            Gm = np.where(g_ok[:, None], G, 0.0)
                            k_top, k_s = top_match(M[kp], Gm)
                            s_top, s_s = top_match(M[sp], Gm)
                            k_set, s_set = p_setid[c.ps_person[kp]], p_setid[c.ps_person[sp]]
                            kw_top, kw_s = top_match(M[kp], Gm, k_set[:, None] == g_setid[None, :])
                            sw_top, sw_s = top_match(M[sp], Gm, s_set[:, None] == g_setid[None, :])
                            b = {"k_s": k_s, "k_ok": k_top == k_true, "kw_s": kw_s, "kw_ok": kw_top == k_true,
                                 "s_s": s_s, "sw_s": sw_s, "k_set": k_set, "s_set": s_set,
                                 "k_person": c.ps_person[kp], "k_top": gal_persons[k_top] if len(kp) else k_top,
                                 "s_person": c.ps_person[sp], "s_top": gal_persons[s_top] if len(sp) else s_top}
                            if pc in xdist_conds and len(xd_ps):
                                xp = xd_ps[v[xd_ps]]
                                x_top, x_s = top_match(M[xp], Gm)
                                b["x_s"] = x_s
                                b["x_person"] = c.ps_person[xp]
                                b["x_top"] = gal_persons[x_top] if len(xp) else x_top
                            blocks[pc] = b
                            if ec == HEAD["enroll"] and k == HEAD["k"] and talk == HEAD["talk"] and seed == 0 \
                                    and mode == "cos" and pc == probe_conds[0]:
                                base_rates = pair_base_rates(c, b, gal_persons)
                        # one bar per model: pooled over every probe condition this model has
                        lineup_arrays = {}
                        for lineup in LINEUPS:
                            per = {}
                            for pc, b in blocks.items():
                                if lineup == "within":
                                    per[pc] = (b["kw_s"], b["kw_ok"], b["sw_s"])
                                elif lineup == "pooled":
                                    per[pc] = (b["k_s"], b["k_ok"], b["s_s"])
                                elif "x_s" in b:
                                    per[pc] = (b["k_s"], b["k_ok"], np.concatenate([b["s_s"], b["x_s"]]))
                            lineup_arrays[lineup] = per
                        for lineup, per in lineup_arrays.items():
                            if not per:
                                continue
                            one_bars = None
                            if len(per) == len(probe_conds):
                                one_bars = calibrate(np.concatenate([a[0] for a in per.values()]),
                                                     np.concatenate([a[1] for a in per.values()]),
                                                     np.concatenate([a[2] for a in per.values()]))
                            for pc, (ks, kok, ss) in per.items():
                                for scope in SCOPES:
                                    bars = one_bars if scope == "one" else calibrate(ks, kok, ss)
                                    if bars is None:
                                        continue
                                    key = cell_key(mode, ec, k, talk, pc, lineup, scope)
                                    acc.put(key, ("rank1",), float(kok.mean()) if len(kok) else None)
                                    acc.put(key, ("n_known",), len(ks))
                                    acc.put(key, ("n_strangers",), len(ss))
                                    for op in OPS:
                                        r = evaluate(bars[op], ks, kok, ss)
                                        acc.put(key, ("bar", op), bars[op])
                                        for m_, val in r.items():
                                            acc.put(key, (op, m_), val)
                                        if lineup == "pooled" and scope == "one" and talk == "all":
                                            b = blocks[pc]
                                            for si, sname in enumerate(c.sets[:len(HUMAN_SETS)]):
                                                km, sm_ = b["k_set"] == si, b["s_set"] == si
                                                rs = evaluate(bars[op], ks[km], kok[km], ss[sm_])
                                                for m_ in ("dir", "mir", "far"):
                                                    acc.put(key, ("by_set", sname, op, m_), rs[m_])
                            if lineup == "pooled" and ec == HEAD["enroll"] and k == HEAD["k"] and talk == HEAD["talk"] \
                                    and one_bars is not None:
                                pair_bars[mode][seed] = one_bars
                                for pc, b in blocks.items():
                                    wrong = ~b["k_ok"]
                                    for a, t, s in zip(b["k_person"][wrong], b["k_top"][wrong], b["k_s"][wrong]):
                                        pair_events[mode].append((seed, pc, int(a), int(t), float(s), "known"))
                                    for a, t, s in zip(b["s_person"], b["s_top"], b["s_s"]):
                                        pair_events[mode].append((seed, pc, int(a), int(t), float(s), "stranger"))
    cells = acc.finish()
    out = {
        "model_id": model, "version": VERSION, "dim": dim,
        "coverage": {"probe_conds": probe_conds, "enroll_conds": enroll_conds, "xdist_conds": xdist_conds,
                     "full": full},
        "centering": center, "seeds": n_seeds,
        "counts": {k_: {"mean": float(np.mean(v)), "seeds": v} for k_, v in counts.items()},
        "cells": cells, "notes": notes,
    }
    heads = {m: headline(out, m) for m in MODES}
    best = pick_mode(heads)
    out["headline"] = {"mode": best, "by_mode": heads}
    out["pairs"] = {m: confused_pairs(c, pair_events[m], pair_bars[m], base_rates) for m in MODES}
    out["seconds"] = round(time.time() - t0, 1)
    return out


def pair_base_rates(c: Corpus, b: dict, gal_persons: np.ndarray) -> dict:
    """Share of (probe, other enrolled person) combos that are same-dataset / same-gender."""
    gset = Counter(c.p_set[p] for p in gal_persons)
    ggen = Counter(c.p_gender[p] for p in gal_persons)
    ng = len(gal_persons)
    enrolled = set(int(p) for p in gal_persons)
    tot = same_set = same_gen = gen_known = 0
    for p in list(b["k_person"]) + list(b["s_person"]):
        p = int(p)
        self_ = 1 if p in enrolled else 0
        others = ng - self_
        tot += others
        same_set += gset[c.p_set[p]] - self_
        g = c.p_gender[p]
        if g != "?":
            known_g = ng - ggen["?"] - self_
            gen_known += known_g
            same_gen += ggen[g] - self_
    return {"same_set": same_set / tot if tot else None, "same_gender": same_gen / gen_known if gen_known else None}


def confused_pairs(c: Corpus, events: list, bars: dict, base: dict | None) -> dict:
    agg: dict[tuple, dict] = {}
    above = {"n": 0, "same_set": 0, "same_gender": 0, "gender_known": 0, "stranger": 0}
    all_ev = {"n": 0, "same_set": 0, "same_gender": 0, "gender_known": 0, "stranger": 0}
    for seed, pc, a, t, s, kind in events:
        b = bars.get(seed)
        if b is None:
            continue
        ss = c.p_set[a] == c.p_set[t]
        ga, gt = c.p_gender[a], c.p_gender[t]
        gk = ga != "?" and gt != "?"
        for bucket, cond_ in ((all_ev, True), (above, s > b["far1"])):
            if cond_:
                bucket["n"] += 1
                bucket["stranger"] += int(kind == "stranger")
                bucket["same_set"] += int(ss)
                if gk:
                    bucket["gender_known"] += 1
                    bucket["same_gender"] += int(ga == gt)
        key = (min(a, t), max(a, t))
        d = agg.setdefault(key, {"n": 0, "n_above_far1": 0, "n_above_far01": 0, "max": -math.inf, "sum": 0.0,
                                 "gap_zero": -math.inf, "kinds": Counter(), "conds": Counter()})
        d["n"] += 1
        d["n_above_far1"] += int(s > b["far1"])
        d["n_above_far01"] += int(s > b["far01"])
        d["max"] = max(d["max"], s)
        d["sum"] += s
        d["gap_zero"] = max(d["gap_zero"], s - b["zero"])
        d["kinds"][kind] += 1
        d["conds"][pc] += 1
    ranked = sorted(agg.items(), key=lambda kv: (-kv[1]["max"], -kv[1]["n"]))
    rows = []
    for (a, t), d in ranked[:TOP_PAIRS]:
        ga, gt = c.p_gender[a], c.p_gender[t]
        rows.append({
            "a": c.persons[a], "b": c.persons[t], "set_a": c.p_set[a], "set_b": c.p_set[t],
            "gender_a": ga, "gender_b": gt, "same_set": c.p_set[a] == c.p_set[t],
            "same_gender": (ga == gt) if ga != "?" and gt != "?" else None,
            "events": d["n"], "above_far1": d["n_above_far1"], "above_far01": d["n_above_far01"],
            "max_cos": round(d["max"], 4), "mean_cos": round(d["sum"] / d["n"], 4),
            "gap_to_zero_bar": round(d["gap_zero"], 4), "kinds": dict(d["kinds"]), "conds": dict(d["conds"]),
        })

    def share(x):
        return {"n": x["n"], "from_strangers": x["stranger"], "same_set": x["same_set"] / x["n"] if x["n"] else None,
                "same_gender": x["same_gender"] / x["gender_known"] if x["gender_known"] else None}

    top = rows
    return {
        "setting": "clean enrollment, 1 session, all clips, pooled lineup, probe conditions and seeds pooled",
        "top": top,
        "top_same_set": sum(r["same_set"] for r in top), "top_same_gender": sum(bool(r["same_gender"]) for r in top),
        "wrong_tops": share(all_ev), "wrong_tops_above_far1": share(above), "base_rate": base,
        "bars_mean": {op: float(np.mean([b[op] for b in bars.values()])) for op in OPS} if bars else None,
    }


# ----------------------------------------------------------------------------------------------
# Headline and summary
# ----------------------------------------------------------------------------------------------

def cell(res: dict, mode: str, enroll: str = HEAD["enroll"], k: int = HEAD["k"], talk: str = HEAD["talk"],
         probe: str = HEAD["probe"], lineup: str = HEAD["lineup"], scope: str = HEAD["scope"]) -> dict | None:
    return res.get("cells", {}).get(cell_key(mode, enroll, k, talk, probe, lineup, scope))


def val(res: dict, mode: str, path: tuple, stat: str = "mean", **kw):
    node = cell(res, mode, **kw)
    for p in path:
        if node is None:
            return None
        node = node.get(p)
    return node.get(stat) if isinstance(node, dict) else None


def headline(res: dict, mode: str) -> dict:
    """Headline numbers for one scoring mode."""
    full = res["coverage"]["full"]
    h = {"dir0_opus12": val(res, mode, ("zero", "dir")) if full else None,
         "dir0_opus12_sd": val(res, mode, ("zero", "dir"), "sd") if full else None,
         "dir0_clean_cond": val(res, mode, ("zero", "dir"), probe="clean", scope="cond")}
    return h


def pick_mode(heads: dict) -> str:
    def score(m):
        h = heads[m]
        return (h["dir0_opus12"] if h["dir0_opus12"] is not None else -1, h["dir0_clean_cond"] or -1)
    return max(MODES, key=lambda m: (score(m), m == "cos"))


def clean_mode(res: dict) -> str:
    return max(MODES, key=lambda m: (res["headline"]["by_mode"][m]["dir0_clean_cond"] or -1, m == "cos"))


def pct(v, d=1) -> str:
    return "–" if v is None else f"{100 * v:.{d}f}%"


def pct_sd(m, s, d=1) -> str:
    if m is None:
        return "–"
    return f"{100 * m:.{d}f}% ± {100 * (s or 0):.{d}f}"


def mis(res, mode, op, **kw) -> str:
    r, n = val(res, mode, (op, "mir"), **kw), val(res, mode, (op, "n_mis"), **kw)
    if r is None:
        return "–"
    return f"{100 * r:.2f}% ({n:.1f})"


def list_models(vp: Path) -> list[str]:
    d = vp / "emb"
    if not d.exists():
        return []
    return sorted(p.name for p in d.iterdir()
                  if p.is_dir() and not p.name.startswith((".", "_")) and any(p.glob("*.npz")))


def write_summary(vp: Path, out_dir: Path, baseline: str, corpus: Corpus | None) -> Path:
    results, skipped = {}, {}
    for p in sorted(out_dir.glob("*.json")):
        try:
            r = json.loads(p.read_text())
        except Exception:  # noqa: BLE001
            continue
        if r.get("skipped"):
            skipped[r["model_id"]] = r["skipped"]
        elif r.get("cells"):
            results[r["model_id"]] = r
    L: list[str] = []
    now = time.strftime("%Y-%m-%d %H:%M")
    any_r = next(iter(results.values()), None)
    cnt = (any_r or {}).get("counts", {})
    n_str1 = cnt.get("stranger_probes", {}).get("mean", 0.0)
    n_str3 = 3 * n_str1
    n_k1 = cnt.get("known_probes_k1", {}).get("mean", 0.0)
    n_k2 = cnt.get("known_probes_k2", {}).get("mean", 0.0)
    L.append("# Voiceprint lineup: every labeled person in one database")
    L.append("")
    L.append(f"Generated {now} by `scripts/voiceprint/score_lineup.py`. All 334 people of vox1o, libri, ami and icsi "
             "(after the audit drop lists) share one database. Per seed, about 233 are enrolled (their earliest "
             "session, all clips) and about 101 are strangers who are never enrolled: every `stranger_only` person "
             "plus 20% of each set's multi-session people. Probes are every later session of an enrolled person and "
             "every session of a stranger. Numbers are means over 5 seeds (which people are strangers, which clips "
             "make the 1- and 3-clip probes).")
    L.append("")
    L.append("How to read it. A name is shown when the top match's cosine clears the model's bar. **DIR** = known "
             "person, right name shown. **misID** = known person, wrong name shown. **stranger FA** = stranger given "
             "someone's name. **DIR @ 0 wrong** = DIR at the lowest bar where nobody (known or stranger) gets a wrong "
             "name. **One bar per model** (per talk time): set on clean + opus12 + noisy probes pooled, because the "
             "app can't tell a clean room from a weak call; the columns then show each condition at that one bar. "
             "`0.1% FA bar` = the bar letting through at most 0.1% of stranger probes; with "
             f"{n_str3:,.0f} stranger probes per seed over 3 conditions that allows "
             f"{int(math.floor(0.001 * n_str3 + 1e-9))} stranger false alarm(s) in the pooled set.")
    L.append("")
    if corpus is not None:
        so = int(corpus.p_so[~corpus.p_xdist].sum())
        L.append(f"People: {int((~corpus.p_xdist).sum())} human-labeled ({so} `stranger_only`), plus "
                 f"{int(corpus.p_xdist.sum())} yodas `stranger_only` people for the extra-distractor check. "
                 "Drops applied: " + ", ".join(f"{k} {v['removed']}" for k, v in corpus.drop_info.items()) + ".")
        L.append("")
    full = [m for m, r in results.items() if r["coverage"]["full"]]
    partial = [m for m, r in results.items() if not r["coverage"]["full"]]

    def mark(m):
        return f"**{m}** (baseline)" if m == baseline else m

    def hv(m):
        r = results[m]
        return r["headline"]["by_mode"][r["headline"]["mode"]]["dir0_opus12"] or -1

    full.sort(key=lambda m: -hv(m))
    L.append("## Call audio: full-coverage models")
    L.append("")
    L.append("Ranked by the headline: **DIR at zero wrong names on opus12 probes**, clean enrollment (1 session), "
             "all clips, pooled lineup, one bar per model. `score` = the scoring that wins the headline for that "
             "model (raw cosine or centered cosine).")
    L.append("")
    if full:
        L.append("| # | model | score | rank-1 opus12 | **DIR @ 0 wrong, opus12** | DIR @ 0 wrong clean / noisy | "
                 "misID @ 0.1% FA bar, opus12 (mean count per seed) | stranger FA @ 0.1% FA bar, clean / opus12 / noisy | "
                 "misID @ 1% FA bar, opus12 | bar @ 0 wrong |")
        L.append("|---|---|---|---|---|---|---|---|---|---|")
        for i, m in enumerate(full, 1):
            r = results[m]
            md = r["headline"]["mode"]
            L.append("| " + " | ".join([
                str(i), mark(m), MODE_LABEL[md],
                pct(val(r, md, ("rank1",))),
                "**" + pct_sd(val(r, md, ("zero", "dir")), val(r, md, ("zero", "dir"), "sd")) + "**",
                f"{pct(val(r, md, ('zero', 'dir'), probe='clean'))} / {pct(val(r, md, ('zero', 'dir'), probe='noisy'))}",
                mis(r, md, "far01"),
                " / ".join(pct(val(r, md, ("far01", "far"), probe=pc), 2) for pc in PROBE_CONDS),
                mis(r, md, "far1"),
                f"{val(r, md, ('bar', 'zero')):.3f}" if val(r, md, ("bar", "zero")) is not None else "–",
            ]) + " |")
        L.append("")
        L.append("Variants, same headline cell (DIR @ 0 wrong names, opus12 probes) unless the column says otherwise:")
        L.append("")
        L.append("| model | within-dataset lineup | + 236 yodas strangers | opus12 enrollment | 2-session enrollment | "
                 "1 clip / 3 clips | bar tuned on opus12 only | other scoring |")
        L.append("|---|---|---|---|---|---|---|---|")
        for m in full:
            r = results[m]
            md = r["headline"]["mode"]
            other = "centered" if md == "cos" else "cos"
            xd = val(r, md, ("zero", "dir"), lineup="xdist")
            L.append("| " + " | ".join([
                mark(m),
                pct(val(r, md, ("zero", "dir"), lineup="within")),
                pct(xd) if xd is not None else "pending (yodas not embedded)",
                pct(val(r, md, ("zero", "dir"), enroll="opus12")),
                pct(val(r, md, ("zero", "dir"), k=2)),
                f"{pct(val(r, md, ('zero', 'dir'), talk='1'))} / {pct(val(r, md, ('zero', 'dir'), talk='3'))}",
                pct(val(r, md, ("zero", "dir"), scope="cond")),
                f"{MODE_LABEL[other]} {pct(val(r, other, ('zero', 'dir')))}",
            ]) + " |")
        L.append("")
        L.append("Per dataset at the one bar (DIR @ 0 wrong names, opus12 · misID rate at the 1% FA bar):")
        L.append("")
        L.append("| model | " + " | ".join(HUMAN_SETS) + " |")
        L.append("|---|" + "---|" * len(HUMAN_SETS))
        for m in full:
            r = results[m]
            md = r["headline"]["mode"]
            node = cell(r, md) or {}
            cols = []
            for s in HUMAN_SETS:
                d0 = node.get("by_set", {}).get(s, {}).get("zero", {}).get("dir", {}).get("mean")
                m1 = node.get("by_set", {}).get(s, {}).get("far1", {}).get("mir", {}).get("mean")
                cols.append(f"{pct(d0)} · misID {pct(m1, 2)}")
            L.append(f"| {mark(m)} | " + " | ".join(cols) + " |")
        L.append("")
    else:
        L.append("_No model has clean + opus12 + noisy on all four human sets yet._")
        L.append("")

    everyone = sorted(results, key=lambda m: -(results[m]["headline"]["by_mode"][clean_mode(results[m])]["dir0_clean_cond"] or -1))
    L.append("## Clean audio: every model, equal footing")
    L.append("")
    L.append("Clean enrollment and clean probes, bar tuned on clean probes alone (so clean-only models compare "
             "fairly with full ones). `partial` = clean embeddings only so far.")
    L.append("")
    L.append("| # | model | coverage | score | rank-1 | **DIR @ 0 wrong** | misID @ 0.1% FA bar | misID @ 1% FA bar | "
             "within-dataset DIR @ 0 | 1 clip / 3 clips DIR @ 0 | 2-session enrollment | raw / centered DIR @ 0 |")
    L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for i, m in enumerate(everyone, 1):
        r = results[m]
        md = clean_mode(r)
        kw = {"probe": "clean", "scope": "cond"}
        cov = "full" if r["coverage"]["full"] else "partial (" + "+".join(r["coverage"]["probe_conds"]) + ")"
        L.append("| " + " | ".join([
            str(i), mark(m), cov, MODE_LABEL[md],
            pct(val(r, md, ("rank1",), **kw)),
            "**" + pct_sd(val(r, md, ("zero", "dir"), **kw), val(r, md, ("zero", "dir"), "sd", **kw)) + "**",
            mis(r, md, "far01", **kw), mis(r, md, "far1", **kw),
            pct(val(r, md, ("zero", "dir"), lineup="within", **kw)),
            f"{pct(val(r, md, ('zero', 'dir'), talk='1', **kw))} / {pct(val(r, md, ('zero', 'dir'), talk='3', **kw))}",
            pct(val(r, md, ("zero", "dir"), k=2, **kw)),
            " / ".join(pct(val(r, mm, ("zero", "dir"), **kw)) for mm in MODES),
        ]) + " |")
    L.append("")

    # confused pairs
    best = full[0] if full else (everyone[0] if everyone else None)
    if best == baseline and len(full) > 1:
        best_other = full[1]
    else:
        best_other = best
    L.append("## Who gets confused with whom")
    L.append("")
    L.append("Every top-1 wrong match (a known person matched to someone else, or a stranger's top match) at "
             "clean enrollment, 1 session, all clips, pooled lineup; probe conditions and seeds pooled. Pairs are "
             "ranked by their highest cosine. About 1% of stranger probes clear the 1%-FA bar by construction, so the "
             "telling number is the known people misnamed above it. `above 1% bar` = how many of a pair's matches clear the model's "
             "1%-FA bar (a wrong name at that bar). `gap` = highest cosine minus the zero-wrong bar of that seed "
             "(0 = this pair sets the bar).")
    L.append("")
    L.append("| model | wrong top matches | above 1% FA bar: strangers (set by the bar) / known people misnamed | same dataset: above bar "
             "(all wrong tops; chance) | same gender: above bar (all wrong tops; chance) | top-20 pairs same dataset / same gender |")
    L.append("|---|---|---|---|---|---|")
    for m in ([baseline] if baseline in results else []) + [x for x in full if x != baseline] + \
            [x for x in partial if x != baseline]:
        r = results[m]
        md = r["headline"]["mode"] if r["coverage"]["full"] else clean_mode(r)
        pr = r["pairs"][md]
        a, w, b = pr["wrong_tops_above_far1"], pr["wrong_tops"], pr["base_rate"] or {}
        L.append("| " + " | ".join([
            mark(m), str(w["n"]),
            f"{a.get('from_strangers', 0)} / {a['n'] - a.get('from_strangers', 0)}",
            f"{pct(a['same_set'], 0)} ({pct(w['same_set'], 0)}; {pct(b.get('same_set'), 0)})",
            f"{pct(a['same_gender'], 0)} ({pct(w['same_gender'], 0)}; {pct(b.get('same_gender'), 0)})",
            f"{pr['top_same_set']} / {pr['top_same_gender']} of {len(pr['top'])}",
        ]) + " |")
    L.append("")
    for m in [x for x in (baseline, best_other) if x in results]:
        r = results[m]
        md = r["headline"]["mode"] if r["coverage"]["full"] else clean_mode(r)
        pr = r["pairs"][md]
        L.append(f"### {m}{' (baseline)' if m == baseline else ''}: 20 most-confused pairs ({MODE_LABEL[md]} cosine, "
                 f"probe conditions: {', '.join(r['coverage']['probe_conds'])})")
        L.append("")
        bm = pr.get("bars_mean") or {}
        if bm:
            L.append(f"Mean bars over seeds: 1% FA {bm['far1']:.3f}, 0.1% FA {bm['far01']:.3f}, zero wrong {bm['zero']:.3f}.")
            L.append("")
        L.append("| # | person A | person B | datasets | genders | wrong top matches (known / stranger) | "
                 "above 1% bar | max cos | gap to 0-wrong bar |")
        L.append("|---|---|---|---|---|---|---|---|---|")
        for i, row in enumerate(pr["top"], 1):
            same_set = "same" if row["same_set"] else "different"
            sg = {True: "same", False: "different", None: "?"}[row["same_gender"]]
            L.append("| " + " | ".join([
                str(i), row["a"], row["b"], f"{row['set_a']}/{row['set_b']} ({same_set})",
                f"{row['gender_a']}/{row['gender_b']} ({sg})",
                f"{row['events']} ({row['kinds'].get('known', 0)} / {row['kinds'].get('stranger', 0)})",
                str(row["above_far1"]), f"{row['max_cos']:.3f}", f"{row['gap_to_zero_bar']:+.3f}",
            ]) + " |")
        L.append("")

    L.append("## Notes")
    L.append("")
    cen = Counter(r["centering"]["source"] for r in results.values())
    L.append("- Centering mean: " + "; ".join(f"{k} ({v} models)" for k, v in cen.items()) +
             ". The contract says yodas clean; models without yodas embeddings use the four human sets' clean mean "
             "until yodas lands (one global vector over about 11k clips, so it barely depends on any one person), "
             "and rerunning picks yodas up automatically.")
    xd = [m for m, r in results.items() if r["coverage"]["xdist_conds"]]
    L.append(f"- Extra distractors (yodas): {'available for ' + ', '.join(xd) if xd else 'pending for every model: no yodas embeddings in VP/emb yet'}."
             " yodas labels came from TitaNet and CAM++, so treat it as a side check.")
    if corpus is not None:
        plan = seed_plan(corpus, 0)
        per_set = Counter(corpus.p_set[p] for p in np.flatnonzero(plan.enrolled) for _ in corpus.person_ps[p][1:])
        share_txt = ", ".join(f"{s_} {per_set[s_]}" for s_ in HUMAN_SETS)
    else:
        share_txt = "?"
    L.append(f"- Probes per seed and condition: {n_k1:,.0f} known with 1-session enrollment ({n_k2:,.0f} with 2 "
             f"sessions), {n_str1:,.0f} stranger. Known probes by set (seed 0): {share_txt}; vox1o people have "
             "up to 24 sessions, so vox1o weighs heavily in DIR and is also the hardest set.")
    L.append("- Within-dataset vs pooled: the within-dataset lineup only offers candidates from the probe's own "
             "dataset (about a quarter of the database), so its bars sit lower and its DIR is usually a bit higher. "
             "The pooled lineup is not flattered by cross-dataset ease: roughly half of all wrong top matches cross "
             "datasets (ami and icsi are both meeting rooms), though same-dataset look-alikes are 2 to 3 times as "
             "common as chance (see the table above).")
    L.append("- 2-session enrollment: people with exactly 2 sessions stay in the database but have no probes, so "
             "its probe set is smaller and skews to people with many sessions (vox1o, ami).")
    L.append("- `-coreml` conversions of redimnet2 give the same embeddings as the torch originals (cosine about 1.0), "
             "so their rows match.")
    if skipped:
        L.append("- Skipped: " + "; ".join(f"{m} ({why})" for m, why in sorted(skipped.items())) + ".")
    notes = sorted({f"{m}: {n}" for m, r in results.items() for n in r.get("notes", [])})
    for n in notes:
        L.append(f"- {n}")
    L.append("")
    path = vp / "results" / "lineup_summary.md"
    path.write_text("\n".join(L) + "\n")
    return path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--models", nargs="*", help="model ids (default: every model with embeddings)")
    ap.add_argument("--force", action="store_true", help="recompute even if inputs are unchanged")
    ap.add_argument("--summary-only", action="store_true")
    ap.add_argument("--seeds", type=int, default=N_SEEDS)
    ap.add_argument("--baseline", default=BASELINE)
    ap.add_argument("--no-drops", action="store_true", help="ignore the audit drop lists (writes to lineup_nodrops/)")
    args = ap.parse_args(argv)
    vp = vp_root()
    out_dir = vp / "results" / ("lineup_nodrops" if args.no_drops else "lineup")
    out_dir.mkdir(parents=True, exist_ok=True)
    corpus = load_corpus(vp, drops=not args.no_drops)
    if not args.summary_only:
        models = args.models or list_models(vp)
        for m in models:
            sig = input_sig(vp, m, corpus) + f"|seeds{args.seeds}"
            path = out_dir / f"{m}.json"
            if not args.force and path.exists():
                try:
                    if json.loads(path.read_text()).get("inputs_sig") == sig:
                        log(f"{m}: unchanged, skipped")
                        continue
                except Exception:  # noqa: BLE001
                    pass
            log(f"{m}: scoring")
            res = run_model(vp, m, corpus, args.seeds)
            res["inputs_sig"] = sig
            res["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            meta_p = vp / "models" / m / "model.json"
            try:
                meta = json.loads(meta_p.read_text())
                res["meta"] = {k: meta.get(k) for k in ("family", "runtime", "dim", "params_m", "train_data", "baseline")}
            except Exception:  # noqa: BLE001
                res["meta"] = {}
            tmp = path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(res, separators=(",", ":"), default=float))
            tmp.replace(path)
            if res.get("skipped"):
                log(f"{m}: skipped ({res['skipped']})")
            else:
                h = res["headline"]
                hb = h["by_mode"][h["mode"]]
                log(f"{m}: done in {res['seconds']}s; {h['mode']} DIR@0 opus12 {pct(hb['dir0_opus12'])}, "
                    f"clean {pct(hb['dir0_clean_cond'])}")
    if args.no_drops:
        return 0
    path = write_summary(vp, out_dir, args.baseline, corpus)
    log(f"summary: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
