#!/usr/bin/env python3
"""Task D dump rewriter: replace each segment's speakerId with an ORACLE-K agglomerative
re-clustering label, so the better (finer) clustering can be replayed through the REAL
matcher (EmbeddingClusterer.postProcess + cross-meeting match). Measurement only — every
other dump field (embedding, start, end, quality) is preserved verbatim.

The re-clustering mirrors recluster_eval.py's `agglo_oraclek`:
  * per meeting, average-linkage agglomerative on cosine distance (1 - cos) of the
    L2-normalized embeddings, n_clusters = the TRUE number of AMI speakers (from the RTTM).
  * clustering is FIT on the quality-filtered segments (quality>=0.3, dur>=1s) — identical
    to the recluster_eval ceiling — so the labels we hand the matcher are exactly the
    oracle-k clusters that experiment scored.
  * segments that fail the quality filter still need a label (the harness replays every
    segment), so they are assigned to the nearest oracle-cluster mean embedding. They are a
    small minority and do not participate in the ceiling metric; nearest-centroid keeps the
    dump complete without inventing new clusters.

speakerId is rewritten to a small contiguous int per meeting (0..k-1), matching the dump's
int speakerId type. Output dumps are byte-compatible with the harness RawDump decoder.
"""
import argparse, glob, json, os
import numpy as np
from sklearn.cluster import AgglomerativeClustering


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dumps", required=True)
    ap.add_argument("--out-dumps", required=True)
    ap.add_argument("--rttm-dir", default="data/ami/rttm")
    args = ap.parse_args()
    os.makedirs(args.out_dumps, exist_ok=True)

    files = sorted(glob.glob(os.path.join(args.in_dumps, "*.json")))
    n_written = 0
    for f in files:
        d = json.load(open(f))
        m = os.path.basename(f)[:-5]
        rp = os.path.join(args.rttm_dir, m + ".rttm")
        segs = d["segments"]
        # which segments have a usable embedding at all
        has_emb = [bool(s.get("embedding")) for s in segs]

        if not os.path.exists(rp):
            # no ground truth -> cannot pick oracle k; passthrough unchanged
            json.dump(d, open(os.path.join(args.out_dumps, os.path.basename(f)), "w"))
            n_written += 1
            continue
        ref = parse_rttm(rp)

        # ceiling segment set: identical filter to recluster_eval.py
        idx_fit = [i for i, s in enumerate(segs)
                   if s.get("embedding") and s["quality"] >= 0.3 and s["end"] - s["start"] >= 1.0]
        # oracle k from the true number of distinct AMI speakers among the fit segments
        tids = [true_for(segs[i]["start"], segs[i]["end"], ref) for i in idx_fit]
        ktrue = len(set(t for t in tids if t is not None))

        if len(idx_fit) < 2 or ktrue < 1:
            # not enough to cluster -> leave speakerId as-is
            json.dump(d, open(os.path.join(args.out_dumps, os.path.basename(f)), "w"))
            n_written += 1
            continue

        Efit = unit([segs[i]["embedding"] for i in idx_fit])
        k = max(1, min(ktrue, len(idx_fit)))
        sim = np.clip(Efit @ Efit.T, -1.0, 1.0)
        D = 1.0 - sim
        np.fill_diagonal(D, 0.0)
        labels = AgglomerativeClustering(n_clusters=k, metric="precomputed",
                                         linkage="average").fit(D).labels_
        # cluster mean embeddings (unit) for nearest-centroid assignment of off-set segments
        cents = []
        for c in range(k):
            members = Efit[labels == c]
            cents.append(members.mean(axis=0) if len(members) else np.zeros(Efit.shape[1]))
        cents = unit(cents)

        new_id = {}
        for j, i in enumerate(idx_fit):
            new_id[i] = int(labels[j])
        # assign every other embedded segment to nearest oracle centroid
        for i, s in enumerate(segs):
            if i in new_id:
                continue
            if s.get("embedding"):
                e = unit([s["embedding"]])[0]
                new_id[i] = int(np.argmax(cents @ e))
            else:
                new_id[i] = 0  # no embedding: drop into cluster 0 (matcher skips empty embs)

        out_segs = []
        for i, s in enumerate(segs):
            ns = dict(s)
            ns["speakerId"] = new_id[i]
            out_segs.append(ns)
        d["segments"] = out_segs
        d["diarizerSpeakerCount"] = len(set(new_id.values()))
        json.dump(d, open(os.path.join(args.out_dumps, os.path.basename(f)), "w"))
        n_written += 1
    print(f"[oraclek] wrote {n_written} dumps -> {args.out_dumps}")


if __name__ == "__main__":
    main()
