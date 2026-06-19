#!/usr/bin/env python3
"""Per-embedding-model scorecard on an AMI codec arm (measurement only). Compares a
candidate speaker-embedding model against the shipping WeSpeaker on the metrics that
decide on-device speaker accuracy, evaluated FAIRLY (threshold-free where it matters so
an anisotropic model like WavLM isn't unfairly penalized):

  WITHIN-MEETING (the diarizer floor):
    - oracle-k coverage  : distinct true speakers recovered as some cluster's dominant id
    - purity, DER        : pyannote optimal-mapping confusion on the same filtered segments
  CROSS-MEETING (the matcher fitness — can it tell if two appearances are the same person):
    - AUC                : ROC-AUC of same-vs-different cross-meeting pairs by cosine.
                           THRESHOLD-FREE -> immune to anisotropy/scale; the fair "how well
                           does this model separate speakers" number. 0.5=chance, 1.0=perfect.
    - sep_raw            : same_mean - diff_mean on raw cosine
    - sep_centered       : same - diff after subtracting the per-arm global mean (whitening
                           the shared/anisotropy direction) -> the deployable-with-whitening view
    - eer                : equal error rate of the same/different verification task

Reads data/eval/ami_<arm>/dumps (WeSpeaker) or data/eval/ami_<arm>__<model>/dumps.
"""
import argparse, glob, json, os, statistics as st
from collections import defaultdict
import numpy as np
from sklearn.metrics import roc_auc_score
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from recluster_eval import parse_rttm, unit, true_for, ann, cluster  # reuse
from pyannote.metrics.diarization import DiarizationErrorRate

Q, D = 0.3, 1.0


def eer_from(scores, labels):
    order = np.argsort(-scores)
    labels = np.asarray(labels)[order]
    P = labels.sum(); N = len(labels) - P
    if P == 0 or N == 0:
        return None
    tp = np.cumsum(labels); fp = np.cumsum(1 - labels)
    fnr = 1 - tp / P; fpr = fp / N
    i = np.argmin(np.abs(fnr - fpr))
    return float((fnr[i] + fpr[i]) / 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", required=True)
    ap.add_argument("--model", default="", help="'' = WeSpeaker baseline; else ecapa/wavlm/unisat/redimnet_b6/...")
    ap.add_argument("--rttm-dir", default="data/ami/rttm")
    ap.add_argument("--dumps", default=None, help="explicit dumps dir (overrides the ami_<arm> path; for Zoom/generic)")
    ap.add_argument("--max-pairs", type=int, default=400000)
    ap.add_argument("--out-json")
    args = ap.parse_args()
    dumps = args.dumps or (f"data/eval/ami_{args.arm}/dumps" if not args.model else f"data/eval/ami_{args.arm}__{args.model}/dumps")
    der_metric = DiarizationErrorRate(collar=0.25, skip_overlap=False)

    per = []
    mean_by = {}   # (meeting, spk) -> mean emb
    for f in sorted(glob.glob(os.path.join(dumps, "*.json"))):
        m = os.path.basename(f)[:-5]
        rp = os.path.join(args.rttm_dir, m + ".rttm")
        if not os.path.exists(rp):
            continue
        d = json.load(open(f)); ref = parse_rttm(rp)
        segs = [s for s in d["segments"] if s.get("embedding") and s["quality"] >= Q and s["end"] - s["start"] >= D]
        if len(segs) < 2:
            continue
        E = unit([s["embedding"] for s in segs])
        spans = [(s["start"], s["end"]) for s in segs]
        tids = [true_for(s["start"], s["end"], ref) for s in segs]
        ktrue = len(set(t for t in tids if t))
        labels = list(cluster(E, "agglo_oraclek", ktrue, 0.7))
        der = der_metric(ann(spans, tids), ann(spans, labels), detailed=True); tot = der["total"] or 1.0
        byc = defaultdict(lambda: defaultdict(float))
        for (s0, s1), lab, t in zip(spans, labels, tids):
            if t is not None:
                byc[lab][t] += s1 - s0
        dom = {c: max(v, key=v.get) for c, v in byc.items()}
        cov = len(set(dom.values()))
        pur = [max(v.values()) / sum(v.values()) for v in byc.values() if sum(v.values())]
        per.append({"ktrue": ktrue, "cov": cov, "der": der["diarization error rate"],
                    "conf": der["confusion"] / tot, "purity": st.mean(pur) if pur else 0})
        # per (meeting,speaker) mean for cross-meeting
        bt = defaultdict(list)
        for e, t in zip(E, tids):
            if t is not None:
                bt[t].append(e)
        for t, es in bt.items():
            mean_by[(m, t)] = unit([np.mean(es, axis=0)])[0]

    # cross-meeting pairs (different meetings)
    keys = list(mean_by); V = np.array([mean_by[k] for k in keys])
    gmean = V.mean(axis=0)
    Vc = unit(V - gmean)
    rng = np.random.RandomState(0)
    n = len(keys)
    allpairs = [(i, j) for i in range(n) for j in range(i + 1, n) if keys[i][0] != keys[j][0]]
    rng.shuffle(allpairs)
    allpairs = allpairs[:args.max_pairs]
    sc_raw, sc_ctr, lab = [], [], []
    for i, j in allpairs:
        sc_raw.append(float(V[i] @ V[j])); sc_ctr.append(float(Vc[i] @ Vc[j]))
        lab.append(1 if keys[i][1] == keys[j][1] else 0)
    sc_raw = np.array(sc_raw); sc_ctr = np.array(sc_ctr); lab = np.array(lab)
    # cross-call metrics need pairs from >=2 recordings with both same- and different-speaker pairs.
    # A single recording (e.g. one Zoom call) has none -> report cross_meeting as N/A; within-meeting stands.
    cross_ok = len(lab) > 0 and 0 < int(lab.sum()) < len(lab)

    def m_(x):
        return round(float(x.mean()), 4) if len(x) else None

    if cross_ok:
        same_r = sc_raw[lab == 1]; diff_r = sc_raw[lab == 0]
        same_c = sc_ctr[lab == 1]; diff_c = sc_ctr[lab == 0]
        cross = {
            "n_pairs": int(len(lab)), "n_same": int(lab.sum()),
            "auc_raw": round(float(roc_auc_score(lab, sc_raw)), 4),
            "auc_centered": round(float(roc_auc_score(lab, sc_ctr)), 4),
            "eer_raw": round(eer_from(sc_raw, lab), 4) if eer_from(sc_raw, lab) is not None else None,
            "eer_centered": round(eer_from(sc_ctr, lab), 4) if eer_from(sc_ctr, lab) is not None else None,
            "same_mean_raw": m_(same_r), "diff_mean_raw": m_(diff_r),
            "sep_raw": round(m_(same_r) - m_(diff_r), 4),
            "sep_centered": round(m_(same_c) - m_(diff_c), 4),
        }
    else:
        cross = {"n_pairs": int(len(lab)), "n_same": int(lab.sum()), "auc_raw": None,
                 "auc_centered": None, "eer_raw": None, "eer_centered": None,
                 "same_mean_raw": None, "diff_mean_raw": None, "sep_raw": None, "sep_centered": None,
                 "note": "single recording — cross-call metrics need >=2 recordings with recurring speakers"}

    out = {
        "arm": args.arm, "model": args.model or "wespeaker", "n_meetings": len(per),
        "dim": int(V.shape[1]),
        "within": {
            "coverage_frac": round(sum(p["cov"] for p in per) / max(1, sum(p["ktrue"] for p in per)), 4),
            "mean_purity": round(st.mean(p["purity"] for p in per), 4),
            "mean_der": round(st.mean(p["der"] for p in per), 4),
            "mean_conf": round(st.mean(p["conf"] for p in per), 4),
        },
        "cross_meeting": {**cross,
        },
    }
    print(json.dumps(out, indent=2))
    if args.out_json:
        json.dump(out, open(args.out_json, "w"), indent=2)


if __name__ == "__main__":
    main()
