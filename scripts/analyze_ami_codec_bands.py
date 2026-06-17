#!/usr/bin/env python3
"""Embedding-band analysis for an AMI codec arm (measurement only).

AMI participant ids (FEE005...) recur across a meeting series, so unlike VoxConverse
we can measure the two bands that actually decide the cross-meeting MATCH threshold:

  * SAME-SPEAKER, cross-meeting  — cosine between one participant's mean embedding in
    meeting A vs the same participant in meeting B. This is the RE-ID surface: the
    matcher must clear the threshold to re-identify a returning speaker. Compression
    pushes this DOWN (BASELINE saw clean ~0.5+ -> VoIP ~0.39).
  * DIFFERENT-SPEAKER, cross-meeting — cosine between two distinct participants. This
    is the FALSE-MERGE surface: anything above threshold fuses strangers.

The match threshold X that maximizes (same-speaker recall) while minimizing (different-
speaker pressure) is read straight off these two distributions. We also report the
diarizer's per-meeting over/under-segmentation so we can see if the codec flips it from
under-segmenting (AMI-clean) to over-segmenting.
"""
import argparse, glob, json, os, random, statistics as st
from collections import defaultdict

Q_MIN, DUR_MIN = 0.3, 1.0


def parse_rttm(path):
    out = []
    for ln in open(path):
        p = ln.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            s, d = float(p[3]), float(p[4]); out.append((s, s + d, p[7]))
    return out


def true_for(s, e, ref):
    best, bov = None, 0.0
    for (rs, re, t) in ref:
        ov = max(0.0, min(e, re) - max(s, rs))
        if ov > bov: best, bov = t, ov
    return best


def l2(v):
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v] if n else v


def mean_emb(es):
    if not es: return None
    d = len(es[0]); return l2([sum(e[i] for e in es) / len(es) for i in range(d)])


def cos(a, b): return sum(x * y for x, y in zip(a, b))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dumps", required=True)
    ap.add_argument("--rttm-dir", required=True)
    ap.add_argument("--tag", default="")
    ap.add_argument("--out-json")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    THRS = [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]

    # (meeting, global_speaker) -> mean embedding
    mean_by = {}
    seg_counts = []
    for dp in sorted(glob.glob(os.path.join(args.dumps, "*.json"))):
        m = os.path.basename(dp)[:-5]
        rp = os.path.join(args.rttm_dir, m + ".rttm")
        if not os.path.exists(rp): continue
        d = json.load(open(dp)); ref = parse_rttm(rp)
        seg_counts.append({"m": m, "true": len(set(t for _, _, t in ref)),
                           "raw": d.get("diarizerSpeakerCount",
                                        len(set(s["speakerId"] for s in d["segments"])))})
        by = defaultdict(list)
        for s in d["segments"]:
            emb = s.get("embedding")
            if not emb or s.get("quality", 1.0) < Q_MIN or (s["end"] - s["start"]) < DUR_MIN:
                continue
            t = true_for(s["start"], s["end"], ref)
            if t is not None: by[t].append(l2(emb))
        for t, es in by.items():
            me = mean_emb(es)
            if me: mean_by[(m, t)] = me

    # group means by global speaker id
    by_spk = defaultdict(dict)            # spk -> {meeting: mean}
    for (m, t), me in mean_by.items(): by_spk[t][m] = me

    same = []   # same speaker, cross-meeting
    for spk, mm in by_spk.items():
        ms = sorted(mm)
        for i in range(len(ms)):
            for j in range(i + 1, len(ms)):
                same.append(cos(mm[ms[i]], mm[ms[j]]))

    diff = []   # different speakers, cross-meeting (different series => true strangers)
    flat = [(m, t, me) for (m, t), me in mean_by.items()]
    n = len(flat)
    pairs = [(i, j) for i in range(n) for j in range(i + 1, n)
             if flat[i][1] != flat[j][1] and flat[i][0] != flat[j][0]]
    rng.shuffle(pairs)
    for i, j in pairs[:300000]:
        diff.append(cos(flat[i][2], flat[j][2]))

    def pct(xs, ps=(1, 5, 25, 50, 75, 90, 95, 99)):
        if not xs: return {}
        xs = sorted(xs); return {p: round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 4) for p in ps}

    def fa(xs, t): return round(sum(1 for x in xs if x >= t) / len(xs), 4) if xs else None

    under = sum(1 for c in seg_counts if c["raw"] < c["true"])
    exact = sum(1 for c in seg_counts if c["raw"] == c["true"])
    over = sum(1 for c in seg_counts if c["raw"] > c["true"])
    ratios = [c["raw"] / c["true"] for c in seg_counts if c["true"]]

    out = {
        "tag": args.tag, "n_meetings": len(seg_counts),
        "diarizer_segmentation": {"under": under, "exact": exact, "over": over,
                                  "mean_clusters_per_true": round(st.mean(ratios), 3) if ratios else None},
        "same_speaker_cross_meeting": {"n": len(same), "mean": round(st.mean(same), 4) if same else None,
                                       "pct": pct(same)},
        "different_speaker_cross_meeting": {"n": len(diff), "mean": round(st.mean(diff), 4) if diff else None,
                                            "pct": pct(diff)},
        # the X read-off: for each threshold, re-ID recall (same-speaker pairs cleared)
        # vs false-merge pressure (different-speaker pairs cleared). separation = recall - pressure.
        "threshold_tradeoff": {
            f"{t}": {"reid_recall": fa(same, t), "false_merge_pressure": fa(diff, t),
                     "separation": round((fa(same, t) or 0) - (fa(diff, t) or 0), 4)}
            for t in THRS
        },
    }
    # best-separation threshold = argmax(recall - pressure) over the grid
    best = max(THRS, key=lambda t: (fa(same, t) or 0) - (fa(diff, t) or 0))
    out["X_best_separation"] = best
    print(json.dumps(out, indent=2))
    if args.out_json: json.dump(out, open(args.out_json, "w"), indent=2)


if __name__ == "__main__":
    main()
