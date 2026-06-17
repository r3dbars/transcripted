#!/usr/bin/env python3
"""TASK C — pure-segment embedding separability (sharpest diagnosis of the diarizer floor).

Question: is the within-meeting under-segmentation a CLUSTERING problem, an EMBEDDING
problem, or a SEGMENTATION (mixed/overlap) problem?

Method: restrict to PURE segments only — a segment whose time span overlaps ONE true
RTTM speaker for >= PURITY_THRESH (default 0.90) of the segment's duration (so it carries
essentially one speaker's voice, not a mix/overlap). Then cluster THOSE embeddings with
oracle-k (true # speakers among the pure segments) using agglo + spectral, +/- global
centering, and measure coverage_frac and time-weighted purity per arm.

Logic:
- If PURE segments STILL fail to separate at oracle-k on compressed audio (coverage << 1.0),
  the embedding MODEL is the floor: the codec has destroyed within-meeting speaker info, and
  no clustering/segmentation change can help — you need codec-robust embeddings.
- If PURE segments DO separate cleanly (coverage ~ 1.0) while ALL segments do not, the ceiling
  is the mixed/overlap segments: finer segmentation is the lever.

Reuses helpers from recluster_eval.py (parse_rttm, unit, ann, cluster). Adds per-segment
true-id overlap-fraction to identify pure segments. Same quality filter (quality>=0.3,
dur>=1s) as the all-segment baseline so the comparison is apples-to-apples.

Measurement only: reads cached dumps + RTTMs; no app code, no re-diarization.
"""
import argparse, glob, json, os, statistics as st
from collections import defaultdict
import numpy as np

import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from recluster_eval import parse_rttm, unit, ann, cluster

from pyannote.metrics.diarization import DiarizationErrorRate


def true_overlap_fracs(s, e, ref):
    """Return {true_id: fraction of [s,e] covered by that true id}. Fractions are over the
    segment duration; they need not sum to 1 (gaps with no speaker), and overlapped true
    speech can push a single id's frac high while others are nonzero too."""
    dur = e - s
    if dur <= 0:
        return {}
    acc = defaultdict(float)
    for rs, re, t in ref:
        ov = max(0.0, min(e, re) - max(s, rs))
        if ov > 0:
            acc[t] += ov
    return {t: v / dur for t, v in acc.items()}


def dominant_frac(s, e, ref):
    fr = true_overlap_fracs(s, e, ref)
    if not fr:
        return None, 0.0
    t, v = max(fr.items(), key=lambda kv: kv[1])
    return t, v


def eval_set(segs, ref, method, center, gcent, der_metric):
    """Cluster a chosen segment set at oracle-k and return per-meeting metrics, or None if
    fewer than 2 segments / fewer than 1 true speaker present."""
    if len(segs) < 2:
        return None
    E = unit([s["embedding"] for s in segs])
    if center == "global" and gcent is not None:
        E = unit(E - gcent)
    spans = [(s["start"], s["end"]) for s in segs]
    # dominant true id per segment (for coverage/purity bookkeeping + DER reference)
    tids = [dominant_frac(s0, s1, ref)[0] for (s0, s1) in spans]
    ktrue = len(set(t for t in tids if t is not None))
    if ktrue < 1:
        return None
    labels = list(cluster(E, method, ktrue, 0.7))
    der = der_metric(ann(spans, tids), ann(spans, labels), detailed=True)
    tot = der["total"] or 1.0
    byc = defaultdict(lambda: defaultdict(float))
    for (s0, s1), lab, t in zip(spans, labels, tids):
        if t is not None:
            byc[lab][t] += (s1 - s0)
    dom = {c: max(v.items(), key=lambda kv: kv[1])[0] for c, v in byc.items()}
    covered = len(set(dom.values()))
    pur = []
    for c, v in byc.items():
        tt = sum(v.values())
        pur.append(max(v.values()) / tt if tt else 0)
    return {
        "ktrue": ktrue, "nseg": len(segs), "nclusters": len(set(labels)),
        "covered": covered, "trapped": ktrue - covered,
        "der": der["diarization error rate"], "conf": der["confusion"] / tot,
        "purity": st.mean(pur) if pur else None,
    }


def aggregate(per):
    if not per:
        return {"n_meetings": 0}
    return {
        "n_meetings": len(per),
        "total_true": sum(p["ktrue"] for p in per),
        "total_covered": sum(p["covered"] for p in per),
        "total_trapped": sum(p["trapped"] for p in per),
        "coverage_frac": round(sum(p["covered"] for p in per) / max(1, sum(p["ktrue"] for p in per)), 4),
        "mean_purity": round(st.mean(p["purity"] for p in per if p["purity"] is not None), 4),
        "mean_der": round(st.mean(p["der"] for p in per), 4),
        "mean_conf": round(st.mean(p["conf"] for p in per), 4),
        "mean_clusters_per_true": round(st.mean(p["nclusters"] / p["ktrue"] for p in per if p["ktrue"]), 3),
        "mean_seg_per_meeting": round(st.mean(p["nseg"] for p in per), 1),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arms", nargs="+", default=["clean", "opus12k", "opus8k", "g711u"])
    ap.add_argument("--methods", nargs="+", default=["agglo_oraclek", "spectral_oraclek"])
    ap.add_argument("--centers", nargs="+", default=["none", "global"])
    ap.add_argument("--purity-thresh", type=float, default=0.90)
    ap.add_argument("--eval-root", default="data/eval")
    ap.add_argument("--rttm-dir", default="data/ami/rttm")
    ap.add_argument("--out-json")
    args = ap.parse_args()

    der_metric = DiarizationErrorRate(collar=0.25, skip_overlap=False)
    results = {}

    for arm in args.arms:
        dumps = os.path.join(args.eval_root, f"ami_{arm}", "dumps")

        # global centroid over the (quality-filtered) ALL-segment set for this arm,
        # matching recluster_eval's global-centering definition
        allv = []
        for f in glob.glob(os.path.join(dumps, "*.json")):
            for s in json.load(open(f))["segments"]:
                if s.get("embedding") and s["quality"] >= 0.3 and s["end"] - s["start"] >= 1.0:
                    allv.append(s["embedding"])
        gcent = unit(allv).mean(axis=0) if allv else None

        # accumulate per-meeting metrics keyed by (variant -> method,center)
        bins = defaultdict(lambda: {"all": [], "pure": []})
        # purity-of-segments diagnostics
        pure_counts, all_counts = [], []

        for f in sorted(glob.glob(os.path.join(dumps, "*.json"))):
            m = os.path.basename(f)[:-5]
            rp = os.path.join(args.rttm_dir, m + ".rttm")
            if not os.path.exists(rp):
                continue
            ref = parse_rttm(rp)
            d = json.load(open(f))
            qsegs = [s for s in d["segments"]
                     if s.get("embedding") and s["quality"] >= 0.3 and s["end"] - s["start"] >= 1.0]
            psegs = [s for s in qsegs
                     if dominant_frac(s["start"], s["end"], ref)[1] >= args.purity_thresh]
            all_counts.append(len(qsegs))
            pure_counts.append(len(psegs))

            for method in args.methods:
                for center in args.centers:
                    key = (method, center)
                    ra = eval_set(qsegs, ref, method, center, gcent, der_metric)
                    rp_ = eval_set(psegs, ref, method, center, gcent, der_metric)
                    if ra:
                        bins[key]["all"].append(ra)
                    if rp_:
                        bins[key]["pure"].append(rp_)

        arm_out = {
            "n_meetings": len([f for f in glob.glob(os.path.join(dumps, "*.json"))
                               if os.path.exists(os.path.join(args.rttm_dir, os.path.basename(f)[:-5] + ".rttm"))]),
            "purity_thresh": args.purity_thresh,
            "mean_all_seg_per_meeting": round(st.mean(all_counts), 1) if all_counts else None,
            "mean_pure_seg_per_meeting": round(st.mean(pure_counts), 1) if pure_counts else None,
            "pure_seg_retained_frac": round(sum(pure_counts) / max(1, sum(all_counts)), 4),
            "variants": {},
        }
        for (method, center), v in bins.items():
            arm_out["variants"][f"{method}|center={center}"] = {
                "all_segments": aggregate(v["all"]),
                "pure_segments": aggregate(v["pure"]),
            }
        results[arm] = arm_out

    # ---- pretty report ----
    print("=" * 96)
    print(f"TASK C: pure-segment embedding separability at oracle-k (pure = dominant true id covers >= {args.purity_thresh:.0%} of segment span)")
    print("=" * 96)
    for arm in args.arms:
        if arm not in results:
            continue
        a = results[arm]
        print(f"\n### ARM: {arm}   ({a['n_meetings']} meetings)   "
              f"pure segs retained: {a['pure_seg_retained_frac']:.0%} "
              f"({a['mean_pure_seg_per_meeting']}/{a['mean_all_seg_per_meeting']} per meeting)")
        hdr = f"  {'method|center':<28} {'set':<5} {'cov':>6} {'purity':>7} {'DER':>6} {'conf':>6} {'cl/true':>8}"
        print(hdr)
        print("  " + "-" * (len(hdr) - 2))
        for vk in sorted(a["variants"].keys()):
            v = a["variants"][vk]
            for setname in ("all_segments", "pure_segments"):
                g = v[setname]
                if not g.get("n_meetings"):
                    print(f"  {vk:<28} {setname[:4]:<5} {'--':>6}")
                    continue
                tag = "all" if setname == "all_segments" else "pure"
                print(f"  {vk:<28} {tag:<5} {g['coverage_frac']:>6.3f} {g['mean_purity']:>7.3f} "
                      f"{g['mean_der']:>6.3f} {g['mean_conf']:>6.3f} {g['mean_clusters_per_true']:>8.3f}")

    if args.out_json:
        json.dump(results, open(args.out_json, "w"), indent=2)
        print(f"\nwrote {args.out_json}")


if __name__ == "__main__":
    main()
