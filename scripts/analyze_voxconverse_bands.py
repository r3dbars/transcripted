#!/usr/bin/env python3
"""Report-supporting analysis for the VoxConverse speaker-eval (measurement only).

Two decision-relevant measurements the SWEEP.md doesn't compute:

  1. DIARIZER SEGMENTATION — raw diarizer cluster count (from the cached dumps) vs the
     ground-truth speaker count (from the RTTMs), per file. Answers: does the diarizer
     OVER-segment (clusters > true, the user's "1 person -> 9" bug) or UNDER-segment
     (clusters < true, AMI's signature) in the wild?

  2. EMBEDDING SIMILARITY BANDS — cosine between quality-filtered mean embeddings:
       * same-speaker  (within file, split-half of one true speaker's segments)
       * different-speaker, within file
       * different-speaker, ACROSS files  <-- the cross-meeting FALSE-MERGE surface
     For each candidate match threshold, the fraction of different-speaker pairs that
     exceed it = the false-merge pressure if you set the matcher there. This is what
     decides whether lowering toward 0.50 is safe on in-the-wild audio.

Reads the cached dumps in data/eval/<corpus>/dumps and the RTTMs in data/<corpus>/rttm.
Pure measurement: prints numbers, writes an optional JSON. No app code touched.
"""
import argparse, glob, json, os, random, statistics as st
from collections import defaultdict

Q_MIN, DUR_MIN = 0.3, 1.0  # mirror the harness' clusterMeanEmbedding quality filter


def parse_rttm(path):
    out = []
    with open(path) as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 8 and p[0] == "SPEAKER":
                s, d = float(p[3]), float(p[4])
                out.append((s, s + d, p[7]))
    return out


def true_speaker_for(seg_s, seg_e, ref):
    """Assign a hyp segment to the true speaker with the most temporal overlap."""
    best, best_ov = None, 0.0
    for (rs, re, tid) in ref:
        ov = max(0.0, min(seg_e, re) - max(seg_s, rs))
        if ov > best_ov:
            best, best_ov = tid, ov
    return best


def l2(v):
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v] if n > 0 else v


def mean_emb(embs):
    if not embs:
        return None
    dim = len(embs[0])
    m = [sum(e[i] for e in embs) / len(embs) for i in range(dim)]
    return l2(m)


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))  # both already L2-normalized


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dumps", default="data/eval/voxconverse/dumps")
    ap.add_argument("--rttm-dir", default="data/voxconverse/rttm")
    ap.add_argument("--out-json")
    ap.add_argument("--cross-file-pairs", type=int, default=200000,
                    help="cap on sampled cross-file different-speaker pairs")
    ap.add_argument("--seed", type=int, default=1234)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    dumps = sorted(glob.glob(os.path.join(args.dumps, "*.json")))
    # per-file: true_speaker -> list of quality-filtered segment embeddings
    file_true_embs = {}          # meeting -> {tid: [emb,...]}
    seg_counts = []              # diarizer raw clusters vs true count
    THRS = [0.45, 0.50, 0.55, 0.60, 0.65]

    for dp in dumps:
        meeting = os.path.basename(dp)[:-5]
        rp = os.path.join(args.rttm_dir, meeting + ".rttm")
        if not os.path.exists(rp):
            continue
        d = json.load(open(dp))
        ref = parse_rttm(rp)
        true_n = len(set(t for _, _, t in ref))
        raw_clusters = d.get("diarizerSpeakerCount", len(set(s["speakerId"] for s in d["segments"])))
        seg_counts.append({"meeting": meeting, "true": true_n, "raw_clusters": raw_clusters})

        by_tid = defaultdict(list)
        for s in d["segments"]:
            emb = s.get("embedding")
            if not emb:
                continue
            dur = s["end"] - s["start"]
            if s.get("quality", 1.0) < Q_MIN or dur < DUR_MIN:
                continue
            tid = true_speaker_for(s["start"], s["end"], ref)
            if tid is not None:
                by_tid[tid].append(l2(emb))
        file_true_embs[meeting] = dict(by_tid)

    # ---- 1. diarizer segmentation profile ----
    under = sum(1 for c in seg_counts if c["raw_clusters"] < c["true"])
    exact = sum(1 for c in seg_counts if c["raw_clusters"] == c["true"])
    over = sum(1 for c in seg_counts if c["raw_clusters"] > c["true"])
    ratios = [c["raw_clusters"] / c["true"] for c in seg_counts if c["true"] > 0]
    diffs = [c["raw_clusters"] - c["true"] for c in seg_counts]

    # ---- 2a. same-speaker (within-file split-half) ----
    same_cos = []
    for meeting, tids in file_true_embs.items():
        for tid, embs in tids.items():
            if len(embs) < 2:
                continue
            idx = list(range(len(embs)))
            rng.shuffle(idx)
            half = len(idx) // 2
            a = mean_emb([embs[i] for i in idx[:half]])
            b = mean_emb([embs[i] for i in idx[half:]])
            if a and b:
                same_cos.append(cos(a, b))

    # per-(file,true) mean embedding for different-speaker comparisons
    file_means = {}  # meeting -> {tid: mean_emb}
    for meeting, tids in file_true_embs.items():
        file_means[meeting] = {tid: mean_emb(embs) for tid, embs in tids.items()
                               if mean_emb(embs) is not None}

    # ---- 2b. different-speaker within file ----
    diff_in = []
    for meeting, means in file_means.items():
        ids = list(means)
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                diff_in.append(cos(means[ids[i]], means[ids[j]]))

    # ---- 2c. different-speaker ACROSS files (the false-merge surface; sampled) ----
    flat = [(m, tid, e) for m, means in file_means.items() for tid, e in means.items()]
    diff_cross = []
    n = len(flat)
    target = min(args.cross_file_pairs, n * (n - 1) // 2)
    seen = 0
    while len(diff_cross) < target and seen < target * 6:
        i, j = rng.randrange(n), rng.randrange(n)
        seen += 1
        if i == j or flat[i][0] == flat[j][0]:
            continue  # need different files
        diff_cross.append(cos(flat[i][2], flat[j][2]))

    def pct(xs, ps=(5, 25, 50, 75, 90, 95, 99)):
        if not xs:
            return {}
        xs = sorted(xs)
        return {p: round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 4) for p in ps}

    def frac_above(xs, t):
        return round(sum(1 for x in xs if x >= t) / len(xs), 4) if xs else None

    summary = {
        "n_files": len(seg_counts),
        "diarizer_segmentation": {
            "under": under, "exact": exact, "over": over,
            "mean_clusters_per_true": round(st.mean(ratios), 3) if ratios else None,
            "median_clusters_per_true": round(st.median(ratios), 3) if ratios else None,
            "mean_diff_clusters_minus_true": round(st.mean(diffs), 3) if diffs else None,
        },
        "bands": {
            "same_speaker": {"n": len(same_cos), "mean": round(st.mean(same_cos), 4) if same_cos else None,
                             "pct": pct(same_cos)},
            "diff_within_file": {"n": len(diff_in), "mean": round(st.mean(diff_in), 4) if diff_in else None,
                                 "pct": pct(diff_in)},
            "diff_cross_file": {"n": len(diff_cross), "mean": round(st.mean(diff_cross), 4) if diff_cross else None,
                                "pct": pct(diff_cross)},
        },
        "false_merge_pressure": {
            # fraction of DIFFERENT-speaker pairs that would exceed each match threshold
            f"{t}": {"cross_file": frac_above(diff_cross, t), "within_file": frac_above(diff_in, t)}
            for t in THRS
        },
        "same_speaker_recall": {
            # fraction of SAME-speaker pairs that clear each threshold (re-merge benefit)
            f"{t}": frac_above(same_cos, t) for t in THRS
        },
    }

    print(json.dumps(summary, indent=2))
    if args.out_json:
        json.dump(summary, open(args.out_json, "w"), indent=2)


if __name__ == "__main__":
    main()
