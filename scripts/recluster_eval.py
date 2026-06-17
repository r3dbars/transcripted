#!/usr/bin/env python3
"""Diarizer-arm experiment: re-cluster the dump's per-segment WeSpeaker embeddings with
alternative methods and measure whether better clustering reduces within-meeting speaker
merging (the floor that the matcher-side levers could not move). Measurement only — reads
the cached dumps + RTTMs; never touches app code or re-runs diarization.

The sharp diagnostic is the ORACLE-K ceiling: if we hand the clusterer the true number of
speakers and it still cannot separate them, the limit is the EMBEDDINGS/segmentation, not
the clustering threshold — so tuning the clusterer cannot help and the lever is a better
segmenter / codec-robust embeddings.

All methods are evaluated on the SAME quality-filtered segment set (quality>=0.3, dur>=1s)
so the comparison is apples-to-apples (the 'app' method = the dump's own speakerId on that
set). DER uses pyannote optimal label mapping (isolates clustering quality).

Methods: app | agglo_thresh | agglo_oraclek | ward_oraclek | spectral_oraclek | kmeans_oraclek
Centering of segment embeddings before clustering: none | global | per_meeting
"""
import argparse, glob, json, os, statistics as st
from collections import defaultdict, Counter
import numpy as np

from pyannote.core import Annotation, Segment
from pyannote.metrics.diarization import DiarizationErrorRate


def parse_rttm(p):
    o = []
    for ln in open(p):
        x = ln.split()
        if len(x) >= 8 and x[0] == "SPEAKER":
            s, d = float(x[3]), float(x[4]); o.append((s, s + d, x[7]))
    return o


def unit(M):
    M = np.nan_to_num(np.asarray(M, dtype=np.float64))
    n = np.linalg.norm(M, axis=1, keepdims=True); n[n == 0] = 1.0
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


def cluster(embs, method, k, threshold):
    from sklearn.cluster import AgglomerativeClustering, SpectralClustering, KMeans
    n = len(embs)
    if n <= 1:
        return np.zeros(n, dtype=int)
    sim = np.clip(embs @ embs.T, -1.0, 1.0)
    D = 1.0 - sim
    np.fill_diagonal(D, 0.0)
    if method == "agglo_thresh":
        return AgglomerativeClustering(n_clusters=None, distance_threshold=1.0 - threshold,
                                       metric="precomputed", linkage="average").fit(D).labels_
    k = max(1, min(k, n))
    if method == "agglo_oraclek":
        return AgglomerativeClustering(n_clusters=k, metric="precomputed", linkage="average").fit(D).labels_
    if method == "ward_oraclek":
        return AgglomerativeClustering(n_clusters=k, linkage="ward").fit(embs).labels_
    if method == "spectral_oraclek":
        A = np.clip((sim + 1) / 2, 0, 1)
        return SpectralClustering(n_clusters=k, affinity="precomputed",
                                  assign_labels="discretize", random_state=0).fit(A).labels_
    if method == "kmeans_oraclek":
        return KMeans(n_clusters=k, n_init=10, random_state=0).fit(embs).labels_
    raise SystemExit(f"bad method {method}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--method", required=True)
    ap.add_argument("--center", default="none", choices=["none", "global", "per_meeting"])
    ap.add_argument("--threshold", type=float, default=0.7)
    ap.add_argument("--dumps")
    ap.add_argument("--rttm-dir", default="data/ami/rttm")
    ap.add_argument("--out-json")
    args = ap.parse_args()
    dumps = args.dumps or f"data/eval/ami_{args.arm}/dumps"
    der_metric = DiarizationErrorRate(collar=0.25, skip_overlap=False)

    # global centroid across the arm if requested
    gcent = None
    if args.center == "global":
        allv = []
        for f in glob.glob(os.path.join(dumps, "*.json")):
            for s in json.load(open(f))["segments"]:
                if s.get("embedding") and s["quality"] >= 0.3 and s["end"] - s["start"] >= 1.0:
                    allv.append(s["embedding"])
        U = unit(allv); gcent = U.mean(axis=0)

    per = []
    for f in sorted(glob.glob(os.path.join(dumps, "*.json"))):
        m = os.path.basename(f)[:-5]
        rp = os.path.join(args.rttm_dir, m + ".rttm")
        if not os.path.exists(rp):
            continue
        d = json.load(open(f)); ref = parse_rttm(rp)
        segs = [s for s in d["segments"] if s.get("embedding") and s["quality"] >= 0.3 and s["end"] - s["start"] >= 1.0]
        if len(segs) < 2:
            continue
        E = unit([s["embedding"] for s in segs])
        if args.center == "global" and gcent is not None:
            E = unit(E - gcent)
        elif args.center == "per_meeting":
            E = unit(E - E.mean(axis=0))
        spans = [(s["start"], s["end"]) for s in segs]
        tids = [true_for(s["start"], s["end"], ref) for s in segs]
        ktrue = len(set(t for t in tids if t is not None))
        if args.method == "app":
            labels = [s["speakerId"] for s in segs]
        else:
            labels = list(cluster(E, args.method, ktrue, args.threshold))
        # metrics
        der = der_metric(ann(spans, tids), ann(spans, labels), detailed=True)
        tot = der["total"] or 1.0
        # coverage: distinct true ids that are the dominant (time-weighted) true id of some cluster
        byc = defaultdict(lambda: defaultdict(float))
        for (s0, s1), lab, t in zip(spans, labels, tids):
            if t is not None:
                byc[lab][t] += (s1 - s0)
        dom = {c: max(v.items(), key=lambda kv: kv[1])[0] for c, v in byc.items()}
        covered = len(set(dom.values()))
        # within-meeting trapped: true ids that never get a cluster they dominate (folded into another's)
        trapped = ktrue - covered
        # cluster purity: time-weighted fraction of each cluster that is its dominant speaker
        pur = []
        for c, v in byc.items():
            tt = sum(v.values()); pur.append(max(v.values()) / tt if tt else 0)
        per.append({"m": m, "ktrue": ktrue, "nclusters": len(set(labels)),
                    "der": der["diarization error rate"], "conf": der["confusion"] / tot,
                    "miss": der["missed detection"] / tot, "fa": der["false alarm"] / tot,
                    "covered": covered, "trapped": trapped,
                    "purity": round(st.mean(pur), 4) if pur else None})

    agg = {
        "arm": args.arm, "method": args.method, "center": args.center,
        "threshold": args.threshold if args.method == "agglo_thresh" else None,
        "n_meetings": len(per),
        "mean_der": round(st.mean(p["der"] for p in per), 4) if per else None,
        "mean_conf": round(st.mean(p["conf"] for p in per), 4) if per else None,
        "mean_clusters_per_true": round(st.mean(p["nclusters"] / p["ktrue"] for p in per if p["ktrue"]), 3) if per else None,
        "mean_purity": round(st.mean(p["purity"] for p in per if p["purity"] is not None), 4) if per else None,
        "total_true": sum(p["ktrue"] for p in per),
        "total_covered": sum(p["covered"] for p in per),
        "total_trapped": sum(p["trapped"] for p in per),
        "coverage_frac": round(sum(p["covered"] for p in per) / max(1, sum(p["ktrue"] for p in per)), 4),
        "per_meeting": per,
    }
    print(json.dumps({k: v for k, v in agg.items() if k != "per_meeting"}, indent=2))
    if args.out_json:
        json.dump(agg, open(args.out_json, "w"), indent=2)


if __name__ == "__main__":
    main()
