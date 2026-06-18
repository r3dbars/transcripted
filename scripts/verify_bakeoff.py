#!/usr/bin/env python3
"""TASK A independent adversarial verification of the embedding bake-off.
Recomputes everything FROM THE DUMPS, does not read any scorecard JSON.
Keeps PER-MEETING results for a paired sign test. Reimplements coverage/purity
directly; uses pyannote DER (standard lib) and sklearn agglomerative (standard lib).
"""
import glob, json, os, sys, math
from collections import defaultdict
import numpy as np
from sklearn.cluster import AgglomerativeClustering
from sklearn.metrics import roc_auc_score
from pyannote.core import Annotation, Segment
from pyannote.metrics.diarization import DiarizationErrorRate

Q, DUR = 0.3, 1.0
RTTM = "data/ami/rttm"


def parse_rttm(p):
    o = []
    for ln in open(p):
        x = ln.split()
        if len(x) >= 8 and x[0] == "SPEAKER":
            s, d = float(x[3]), float(x[4])
            o.append((s, s + d, x[7]))
    return o


def unit(M):
    M = np.nan_to_num(np.asarray(M, dtype=np.float64))
    n = np.linalg.norm(M, axis=1, keepdims=True)
    n[n == 0] = 1.0
    return M / n


def true_for(s, e, ref):
    best, bo = None, 0.0
    for rs, re, t in ref:
        ov = max(0.0, min(e, re) - max(s, rs))
        if ov > bo:
            best, bo = t, ov
    return best


def ann(spans, labels):
    a = Annotation()
    for i, ((s, e), lab) in enumerate(zip(spans, labels)):
        if e > s:
            a[Segment(s, e), i] = str(lab)
    return a


def oracle_k_labels(E, k):
    n = len(E)
    if n <= 1:
        return np.zeros(n, dtype=int)
    sim = np.clip(E @ E.T, -1.0, 1.0)
    D = 1.0 - sim
    np.fill_diagonal(D, 0.0)
    k = max(1, min(k, n))
    return AgglomerativeClustering(n_clusters=k, metric="precomputed",
                                   linkage="average").fit(D).labels_


def eval_arm_model(arm, model):
    d = f"data/eval/ami_{arm}" + (f"__{model}" if model else "") + "/dumps"
    der_metric = DiarizationErrorRate(collar=0.25, skip_overlap=False)
    per = []
    mean_by = {}  # (meeting, spk) -> mean unit emb
    dim = None
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        m = os.path.basename(f)[:-5]
        rp = os.path.join(RTTM, m + ".rttm")
        if not os.path.exists(rp):
            continue
        data = json.load(open(f))
        ref = parse_rttm(rp)
        segs = [s for s in data["segments"]
                if s.get("embedding") and s["quality"] >= Q and s["end"] - s["start"] >= DUR]
        if len(segs) < 2:
            continue
        E = unit([s["embedding"] for s in segs])
        dim = E.shape[1]
        spans = [(s["start"], s["end"]) for s in segs]
        tids = [true_for(s["start"], s["end"], ref) for s in segs]
        ktrue = len(set(t for t in tids if t is not None))
        labels = list(oracle_k_labels(E, ktrue))
        der = der_metric(ann(spans, tids), ann(spans, labels), detailed=True)
        tot = der["total"] or 1.0
        # coverage + purity, time-weighted, computed independently
        byc = defaultdict(lambda: defaultdict(float))
        for (s0, s1), lab, t in zip(spans, labels, tids):
            if t is not None:
                byc[lab][t] += (s1 - s0)
        dom = {c: max(v, key=v.get) for c, v in byc.items()}
        covered = len(set(dom.values()))
        purs = [max(v.values()) / sum(v.values()) for v in byc.values() if sum(v.values())]
        per.append({
            "m": m, "ktrue": ktrue, "covered": covered,
            "cov_frac": covered / ktrue if ktrue else 0.0,
            "der": der["diarization error rate"],
            "conf": der["confusion"] / tot,
            "purity": float(np.mean(purs)) if purs else 0.0,
        })
        # cross-meeting per-(meeting,speaker) means
        bt = defaultdict(list)
        for e, t in zip(E, tids):
            if t is not None:
                bt[t].append(e)
        for t, es in bt.items():
            mean_by[(m, t)] = unit([np.mean(es, axis=0)])[0]
    # cross-meeting verification
    keys = list(mean_by)
    V = np.array([mean_by[k] for k in keys])
    n = len(keys)
    pairs = [(i, j) for i in range(n) for j in range(i + 1, n) if keys[i][0] != keys[j][0]]
    same_s, diff_s = [], []
    sc, lab = [], []
    for i, j in pairs:
        c = float(V[i] @ V[j])
        sc.append(c)
        same = 1 if keys[i][1] == keys[j][1] else 0
        lab.append(same)
        (same_s if same else diff_s).append(c)
    sc = np.array(sc); lab = np.array(lab)
    auc = float(roc_auc_score(lab, sc)) if lab.sum() and (len(lab) - lab.sum()) else None
    return {
        "arm": arm, "model": model or "wespeaker", "dim": dim,
        "n_meetings": len(per),
        "agg_cov_frac": sum(p["covered"] for p in per) / max(1, sum(p["ktrue"] for p in per)),
        "mean_der": float(np.mean([p["der"] for p in per])),
        "mean_conf": float(np.mean([p["conf"] for p in per])),
        "mean_purity": float(np.mean([p["purity"] for p in per])),
        "per": per,
        "xm_auc": auc,
        "xm_n_same": int(lab.sum()), "xm_n_diff": int(len(lab) - lab.sum()),
        "xm_same_mean": float(np.mean(same_s)) if same_s else None,
        "xm_diff_mean": float(np.mean(diff_s)) if diff_s else None,
        "xm_sep": float(np.mean(same_s) - np.mean(diff_s)) if same_s and diff_s else None,
    }


def sign_test_p(wins, losses):
    """two-sided exact binomial p under H0=0.5 on decisive (non-tie) meetings."""
    n = wins + losses
    if n == 0:
        return 1.0
    k = min(wins, losses)
    from math import comb
    tail = sum(comb(n, i) for i in range(0, k + 1))
    p = 2 * tail / (2 ** n)
    return min(1.0, p)


def paired(base, cand, key, lower_better=True):
    """Return (wins, losses, ties, mean_delta) for cand vs base on per-meeting `key`."""
    bm = {p["m"]: p for p in base["per"]}
    wins = losses = ties = 0
    deltas = []
    for p in cand["per"]:
        if p["m"] not in bm:
            continue
        b = bm[p["m"]][key]
        c = p[key]
        deltas.append(c - b)
        if abs(c - b) < 1e-9:
            ties += 1
        elif (c < b) == lower_better:
            wins += 1
        else:
            losses += 1
    return wins, losses, ties, float(np.mean(deltas)) if deltas else 0.0


if __name__ == "__main__":
    arms = ["clean", "opus8k", "g711u", "opus12k"]
    models = ["", "ecapa", "redimnet_b6"]
    results = {}
    for arm in arms:
        for model in models:
            d = f"data/eval/ami_{arm}" + (f"__{model}" if model else "") + "/dumps"
            ndump = len(glob.glob(os.path.join(d, "*.json")))
            if ndump < 32:
                print(f"SKIP {arm}__{model or 'wespeaker'}: only {ndump} dumps", file=sys.stderr)
                continue
            r = eval_arm_model(arm, model)
            results[(arm, model or "wespeaker")] = r
            print(f"DONE {arm:8s} {model or 'wespeaker':12s} "
                  f"cov={r['agg_cov_frac']:.3f} der={r['mean_der']:.3f} "
                  f"pur={r['mean_purity']:.3f} auc={r['xm_auc']:.4f} "
                  f"sep={r['xm_sep']:.3f} nm={r['n_meetings']}", file=sys.stderr)
    json.dump({f"{a}__{m}": v for (a, m), v in results.items()},
              open("/tmp/bakeoff_verify.json", "w"))
    # paired comparisons
    print("\n=== PAIRED (cand vs wespeaker), DER lower better ===", file=sys.stderr)
    for arm in arms:
        base = results.get((arm, "wespeaker"))
        if not base:
            continue
        for model in ["ecapa", "redimnet_b6"]:
            cand = results.get((arm, model))
            if not cand:
                continue
            w, l, t, md = paired(base, cand, "der", lower_better=True)
            wc, lc, tc, mc = paired(base, cand, "cov_frac", lower_better=False)
            p = sign_test_p(w, l)
            print(f"{arm:8s} {model:12s} DER wins={w:2d} losses={l:2d} ties={t} "
                  f"meanΔ={md:+.3f} signtest_p={p:.4g} | COV wins={wc:2d} losses={lc:2d} meanΔ={mc:+.3f}",
                  file=sys.stderr)
