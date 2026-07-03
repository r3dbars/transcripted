#!/usr/bin/env python3
"""
Calibrate ERes2Net matcher thresholds from the AMI eval dumps.

The app's speaker matcher (tuned for WeSpeaker) uses cosine thresholds:
  adaptive DB match {1 seg:0.85, 2-3:0.78, 4+:0.70}, consolidation 0.88,
  small-cluster absorb 0.72 / micro 0.62, ghost floor 0.72, per-seg split 0.62.
ERes2Net has different cosine geometry, so these need re-deriving.

We approximate same-speaker vs different-speaker cosine distributions using the
diarizer's own cluster labels (speakerId) as a proxy for ground-truth identity:
  - SAME pair  = two segments with the same speakerId in the same meeting
  - DIFF pair  = two segments with different speakerId in the same meeting
We also compute per-speaker MEAN embeddings (what the matcher actually compares)
and report same/diff mean-vs-segment cosines, since DB matching uses means.

Prints percentiles so we can place thresholds with margin between the bands.
"""
import os, json, glob, numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARMS = {
    "clean": "data/eval/ami_clean__eres2net/dumps",
    "opus8k": "data/eval/ami_opus8k__eres2net/dumps",
    "g711u": "data/eval/ami_g711u__eres2net/dumps",
}


def norm(v):
    v = np.asarray(v, dtype=np.float64)
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def load_meeting(path):
    with open(path) as f:
        d = json.load(f)
    by_spk = {}
    for s in d.get("segments", []):
        emb = s.get("embedding")
        if not emb:
            continue
        dur = float(s.get("endTime", s.get("end", 0)) - s.get("startTime", s.get("start", 0))) \
            if ("endTime" in s or "end" in s) else 0.0
        by_spk.setdefault(int(s["speakerId"]), []).append(norm(emb))
    return by_spk


def pct(a, ps):
    a = np.asarray(a)
    return {p: round(float(np.percentile(a, p)), 3) for p in ps} if len(a) else {}


def analyze(arm, dump_dir):
    files = sorted(glob.glob(os.path.join(ROOT, dump_dir, "*.json")))
    same_seg, diff_seg = [], []          # segment-vs-segment
    same_mean, diff_mean = [], []        # segment-vs-other-speaker-mean (DB-match proxy)
    for fp in files:
        by_spk = load_meeting(fp)
        spks = [s for s, e in by_spk.items() if len(e) >= 2]
        means = {s: norm(np.mean(by_spk[s], axis=0)) for s in by_spk}
        # same-speaker segment pairs (subsample to keep it bounded)
        for s in spks:
            embs = by_spk[s]
            for i in range(min(len(embs), 40)):
                for j in range(i + 1, min(len(embs), 40)):
                    same_seg.append(float(np.dot(embs[i], embs[j])))
        # diff-speaker segment pairs
        ids = list(by_spk.keys())
        for a in range(len(ids)):
            for b in range(a + 1, len(ids)):
                ea, eb = by_spk[ids[a]][:15], by_spk[ids[b]][:15]
                for x in ea:
                    for y in eb:
                        diff_seg.append(float(np.dot(x, y)))
        # mean-match proxy: each speaker's mean vs same-mean(self) and other means
        for s in by_spk:
            for t in by_spk:
                c = float(np.dot(means[s], means[t]))
                (same_mean if s == t else diff_mean).append(c)
    print(f"\n=== {arm}  ({len(files)} meetings) ===")
    print(f"  SAME seg-pairs n={len(same_seg):>6}  pct = {pct(same_seg,[5,10,25,50])}")
    print(f"  DIFF seg-pairs n={len(diff_seg):>6}  pct = {pct(diff_seg,[50,75,90,95,99])}")
    print(f"  DIFF mean-pairs (cross-speaker means) pct = {pct(diff_mean,[50,90,95,99])}")
    return dict(same_seg=same_seg, diff_seg=diff_seg, diff_mean=diff_mean)


def main():
    agg = {"same_seg": [], "diff_seg": [], "diff_mean": []}
    for arm, d in ARMS.items():
        if not os.path.isdir(os.path.join(ROOT, d)):
            print(f"[skip] {arm}: {d} missing")
            continue
        r = analyze(arm, d)
        for k in agg:
            agg[k] += r[k]
    print("\n===== POOLED (clean+opus8k+g711u) =====")
    print(f"  SAME seg-pairs  pct = {pct(agg['same_seg'],[1,5,10,25,50])}")
    print(f"  DIFF seg-pairs  pct = {pct(agg['diff_seg'],[50,90,95,99,99.9])}")
    print(f"  DIFF mean-pairs pct = {pct(agg['diff_mean'],[50,90,95,99])}")
    same10 = np.percentile(agg["same_seg"], 10) if agg["same_seg"] else float("nan")
    diff99 = np.percentile(agg["diff_seg"], 99) if agg["diff_seg"] else float("nan")
    diff95 = np.percentile(agg["diff_seg"], 95) if agg["diff_seg"] else float("nan")
    print(f"\n[guide] same-speaker 10th pct = {same10:.3f} (matches should clear ~this)")
    print(f"[guide] diff-speaker 95th/99th pct = {diff95:.3f}/{diff99:.3f} "
          f"(merges must stay above this)")
    print(f"[guide] a safe DB-match floor sits between {diff99:.2f} and {same10:.2f}")


if __name__ == "__main__":
    main()
