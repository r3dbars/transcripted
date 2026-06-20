#!/usr/bin/env python3
"""Measure write-time voiceprint contamination drift (roadmap fix #6).

The app blends every accepted match into the persisted voiceprint with a fixed
exponential moving average and no write-time quality/margin gate:

    SpeakerDatabase.addOrUpdateSpeaker  (Sources/TranscriptedCore/Speaker/SpeakerDatabase.swift:250-262)
        alpha = 0.15
        blended    = old * (1 - alpha) + new * alpha
        normalized = l2(blended)

This script replays that exact write-back on REAL dumped WeSpeaker embeddings
(the harness `dump` output) and quantifies how far a profile's stored voiceprint
drifts when it absorbs:

  * a CLEAN match            — another high-purity cluster of the same true person
  * a CONTAMINATED match     — an under-segmented cluster that is dominated by the
                               profile's person but carries >=20% of someone else
                               (exactly roadmap #6's "0.70 match from an
                               under-segmented cluster" case)

Drift is reported in cosine distance (1 - cos), per-write and cumulative, and is
anchored against the inter-person baseline (distance between two different real
speakers' clean centroids) so the magnitude is interpretable: a contaminated
write that moves the voiceprint X% of that baseline per blend is X% of the way to
a *different identity*.

Usage:
  contamination_drift.py --dumps data/eval/ami/dumps --rttm-dir data/ami/rttm \
      [--out-json out.json] [--purity-clean 0.9] [--purity-contam-max 0.8] \
      [--purity-contam-min 0.55]
"""
import argparse, glob, json, math, os, sys
from collections import defaultdict


# ---- vector helpers (mirror the app's float32 math) ----

def l2(v):
    n = math.sqrt(sum(x * x for x in v))
    if n == 0:
        return list(v)
    return [x / n for x in v]


def cos(a, b):
    # a, b assumed L2-normalized
    return sum(x * y for x, y in zip(a, b))


def cos_dist(a, b):
    return 1.0 - cos(a, b)


def ema_blend(old, new, alpha=0.15):
    """Exactly SpeakerDatabase.addOrUpdateSpeakerImpl: blend then L2-normalize.

    `old` and `new` are L2-normalized embeddings; result is L2-normalized."""
    blended = [o * (1 - alpha) + n * alpha for o, n in zip(old, new)]
    return l2(blended)


def mean_vec(vecs):
    if not vecs:
        return None
    dim = len(vecs[0])
    s = [0.0] * dim
    for v in vecs:
        if len(v) == dim:
            for i in range(dim):
                s[i] += v[i]
    n = float(len(vecs))
    return [x / n for x in s]


def cluster_mean_embedding(segs):
    """Quality/duration-filtered, L2-normalized mean — mirrors
    main.swift clusterMeanEmbedding (qual>=0.3, dur>=1.0, fallback to all)."""
    filt = [s["embedding"] for s in segs
            if s.get("embedding") and s["quality"] >= 0.3 and (s["end"] - s["start"]) >= 1.0]
    if not filt:
        filt = [s["embedding"] for s in segs if s.get("embedding")]
    if not filt:
        return None
    return l2(mean_vec(filt))


# ---- ground truth ----

def parse_rttm(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "SPEAKER":
                continue
            start, dur, spk = float(p[3]), float(p[4]), p[7]
            out.append((start, start + dur, spk))
    return out


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def truth_for_segment(seg, ref):
    """Dominant ground-truth speaker for a hypothesis segment (max time overlap)."""
    s, e = seg["start"], seg["end"]
    best, best_ov = None, 0.0
    for (rs, re, tid) in ref:
        if rs >= e:
            break
        ov = overlap(s, e, rs, re)
        if ov > best_ov:
            best_ov, best = ov, tid
    return best, best_ov


def analyze_clusters(dump, ref):
    """Return per-cluster records: dominant true speaker, purity (dominant time /
    total attributed time), mean embedding, and total duration."""
    by_cluster = defaultdict(list)
    for seg in dump["segments"]:
        by_cluster[seg["speakerId"]].append(seg)

    ref_sorted = sorted(ref, key=lambda x: x[0])
    clusters = []
    for cid, segs in by_cluster.items():
        time_by_truth = defaultdict(float)
        for seg in segs:
            tid, ov = truth_for_segment(seg, ref_sorted)
            if tid is not None and ov > 0:
                time_by_truth[tid] += ov
        attributed = sum(time_by_truth.values())
        if attributed <= 0:
            continue
        dom_tid, dom_t = max(time_by_truth.items(), key=lambda kv: kv[1])
        purity = dom_t / attributed
        emb = cluster_mean_embedding(segs)
        if emb is None:
            continue
        dur = sum(s["end"] - s["start"] for s in segs)
        # contaminant mass = fraction belonging to non-dominant speakers
        clusters.append({
            "meeting": dump["meeting"],
            "cid": cid,
            "dominant": dom_tid,
            "purity": purity,
            "contam_frac": 1.0 - purity,
            "time_by_truth": dict(time_by_truth),
            "emb": emb,
            "dur": dur,
            "n_truth": len(time_by_truth),
        })
    return clusters


def person_clean_centroid(clusters, tid, purity_clean):
    """L2-normalized centroid of all high-purity clusters dominated by tid —
    the 'uncontaminated' voiceprint reference for that person."""
    embs = [c["emb"] for c in clusters
            if c["dominant"] == tid and c["purity"] >= purity_clean]
    if not embs:
        return None
    return l2(mean_vec(embs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dumps", required=True, help="dir of harness dump JSONs")
    ap.add_argument("--rttm-dir", required=True)
    ap.add_argument("--alpha", type=float, default=0.15)
    ap.add_argument("--purity-clean", type=float, default=0.9,
                    help="min purity for a cluster to count as a clean match / centroid source")
    ap.add_argument("--purity-contam-max", type=float, default=0.8,
                    help="max purity for a cluster to count as under-segmented/contaminated")
    ap.add_argument("--purity-contam-min", type=float, default=0.5,
                    help="min purity so the cluster is still DOMINATED by the profile's person "
                         "(the realistic accept case, not a wholesale wrong cluster)")
    ap.add_argument("--out-json")
    args = ap.parse_args()

    dump_paths = sorted(glob.glob(os.path.join(args.dumps, "*.json")))
    if not dump_paths:
        print(f"error: no dumps in {args.dumps}", file=sys.stderr); sys.exit(2)

    all_clusters = []
    for dp in dump_paths:
        dump = json.load(open(dp))
        rttm = os.path.join(args.rttm_dir, f"{dump['meeting']}.rttm")
        if not os.path.exists(rttm):
            print(f"  skip {dump['meeting']}: no rttm", file=sys.stderr)
            continue
        ref = parse_rttm(rttm)
        all_clusters.extend(analyze_clusters(dump, ref))

    if not all_clusters:
        print("error: no usable clusters", file=sys.stderr); sys.exit(2)

    # ---- inter-person baseline: distance between distinct people's clean centroids ----
    people = sorted(set(c["dominant"] for c in all_clusters))
    centroids = {}
    for tid in people:
        cen = person_clean_centroid(all_clusters, tid, args.purity_clean)
        if cen is not None:
            centroids[tid] = cen
    inter = []
    cids = sorted(centroids.keys())
    for i in range(len(cids)):
        for j in range(i + 1, len(cids)):
            inter.append(cos_dist(centroids[cids[i]], centroids[cids[j]]))
    inter_mean = sum(inter) / len(inter) if inter else None
    inter_min = min(inter) if inter else None

    # ---- per-write drift: clean vs contaminated absorption ----
    # For each person with a clean centroid, simulate ONE EMA write-back of each
    # eligible cluster and record the resulting drift from the centroid.
    clean_writes = []     # (drift, meeting, cid, purity)
    contam_writes = []    # (drift, meeting, cid, purity, contam_frac, toward_contaminant)

    # cumulative streams: feed a profile a sequence of same-person clusters in
    # meeting order and track cumulative drift after each blend.
    clean_cumulative = defaultdict(list)    # tid -> [cum_drift after each clean write]
    contam_cumulative = defaultdict(list)   # tid -> [cum_drift after each contaminated write]

    for tid in centroids:
        cen = centroids[tid]

        # clean candidates: high-purity, same person (exclude the trivial identical-set
        # bias by still measuring the realistic per-cluster blend)
        clean_clusters = sorted(
            [c for c in all_clusters if c["dominant"] == tid and c["purity"] >= args.purity_clean],
            key=lambda c: (c["meeting"], c["cid"]))
        # contaminated candidates: dominated by tid but under-segmented (carries others)
        contam_clusters = sorted(
            [c for c in all_clusters if c["dominant"] == tid
             and args.purity_contam_min <= c["purity"] <= args.purity_contam_max],
            key=lambda c: (c["meeting"], c["cid"]))

        for c in clean_clusters:
            after = ema_blend(cen, c["emb"], args.alpha)
            clean_writes.append((cos_dist(cen, after), c["meeting"], c["cid"], c["purity"]))

        for c in contam_clusters:
            after = ema_blend(cen, c["emb"], args.alpha)
            drift = cos_dist(cen, after)
            # did the blend move the voiceprint TOWARD the contaminant identity?
            toward = None
            others = [t for t in c["time_by_truth"] if t != tid and t in centroids]
            if others:
                # nearest other identity present in the cluster
                near = min(others, key=lambda t: cos_dist(c["emb"], centroids[t]))
                before_d = cos_dist(cen, centroids[near])
                after_d = cos_dist(after, centroids[near])
                toward = before_d - after_d  # >0 means moved closer to the other person
            contam_writes.append((drift, c["meeting"], c["cid"], c["purity"],
                                  c["contam_frac"], toward))

        # cumulative streams
        cur = list(cen)
        for c in clean_clusters:
            cur = ema_blend(cur, c["emb"], args.alpha)
            clean_cumulative[tid].append(cos_dist(cen, cur))
        cur = list(cen)
        for c in contam_clusters:
            cur = ema_blend(cur, c["emb"], args.alpha)
            contam_cumulative[tid].append(cos_dist(cen, cur))

    def stats(xs):
        if not xs:
            return None
        xs = sorted(xs)
        n = len(xs)
        mean = sum(xs) / n
        med = xs[n // 2]
        return {"n": n, "mean": round(mean, 5), "median": round(med, 5),
                "min": round(xs[0], 5), "max": round(xs[-1], 5)}

    clean_drifts = [w[0] for w in clean_writes]
    contam_drifts = [w[0] for w in contam_writes]
    toward_vals = [w[5] for w in contam_writes if w[5] is not None]

    # final cumulative drift per person (after absorbing all eligible clusters)
    clean_final = [v[-1] for v in clean_cumulative.values() if v]
    contam_final = [v[-1] for v in contam_cumulative.values() if v]

    summary = {
        "config": {"alpha": args.alpha, "purity_clean": args.purity_clean,
                   "purity_contam_min": args.purity_contam_min,
                   "purity_contam_max": args.purity_contam_max},
        "corpus": {"clusters": len(all_clusters), "people": len(people),
                   "people_with_clean_centroid": len(centroids)},
        "inter_person_baseline_cosdist": {
            "mean": round(inter_mean, 5) if inter_mean is not None else None,
            "min": round(inter_min, 5) if inter_min is not None else None,
            "pairs": len(inter)},
        "per_write_drift": {
            "clean": stats(clean_drifts),
            "contaminated": stats(contam_drifts),
        },
        "per_write_drift_pct_of_inter_baseline": {
            "clean_mean_pct": round(100 * (sum(clean_drifts)/len(clean_drifts)) / inter_mean, 2)
            if clean_drifts and inter_mean else None,
            "contaminated_mean_pct": round(100 * (sum(contam_drifts)/len(contam_drifts)) / inter_mean, 2)
            if contam_drifts and inter_mean else None,
        },
        "moved_toward_contaminant_cosdist": stats(toward_vals),
        "cumulative_final_drift": {
            "clean": stats(clean_final),
            "contaminated": stats(contam_final),
        },
        "n_contaminated_clusters_available": len(contam_writes),
        "n_clean_clusters_available": len(clean_writes),
    }

    if args.out_json:
        json.dump(summary, open(args.out_json, "w"), indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
