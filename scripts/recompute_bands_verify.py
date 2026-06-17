#!/usr/bin/env python3
"""INDEPENDENT recomputation of embedding similarity bands from raw dumps + RTTMs.

Does NOT read bands.json. Builds per-(meeting,true-speaker) mean embeddings by assigning
each dump segment to its true AMI speaker via RTTM time overlap, then computes:
  (a) SAME speaker, different meetings  cosine band
  (b) DIFFERENT speakers, different meetings cosine band
  separation = same_mean - diff_mean

Then tests the shared-coloration MECHANISM: subtract per-arm global mean embedding from
every per-(meeting,speaker) mean, re-normalize, recompute the different-speaker band.
"""
import glob, json, os, math, statistics as st
from collections import defaultdict

Q_MIN, DUR_MIN = 0.3, 1.0
ROOT = "/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2"
RTTM_DIR = f"{ROOT}/data/ami/rttm"
ARMS = ["clean", "opus24k", "opus16k", "opus12k", "opus8k", "g711u"]


def parse_rttm(path):
    out = []
    for ln in open(path):
        p = ln.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            s, d = float(p[3]), float(p[4])
            out.append((s, s + d, p[7]))
    return out


def true_for(s, e, ref):
    best, bov = None, 0.0
    for (rs, re, t) in ref:
        ov = max(0.0, min(e, re) - max(s, rs))
        if ov > bov:
            best, bov = t, ov
    return best


def l2(v):
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v] if n else v


def mean_emb(es):
    if not es:
        return None
    d = len(es[0])
    return [sum(e[i] for e in es) / len(es) for i in range(d)]  # NOT renormalized here


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def series_of(meeting):
    # ES2002a -> ES2002 ; series shares the 4 recurring speakers
    return meeting[:-1]


def pct(xs, ps=(5, 25, 50, 75, 95)):
    if not xs:
        return {}
    xs = sorted(xs)
    return {p: round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))], 4) for p in ps}


def frac_ge(xs, t):
    return round(sum(1 for x in xs if x >= t) / len(xs), 4) if xs else None


def build_means(arm):
    """Return dict (meeting, true_speaker) -> L2-normalized mean embedding."""
    dumps = f"{ROOT}/data/eval/ami_{arm}/dumps"
    mean_by = {}
    for dp in sorted(glob.glob(os.path.join(dumps, "*.json"))):
        m = os.path.basename(dp)[:-5]
        rp = os.path.join(RTTM_DIR, m + ".rttm")
        if not os.path.exists(rp):
            continue
        d = json.load(open(dp))
        ref = parse_rttm(rp)
        by = defaultdict(list)
        for s in d["segments"]:
            emb = s.get("embedding")
            if not emb or s.get("quality", 1.0) < Q_MIN or (s["end"] - s["start"]) < DUR_MIN:
                continue
            t = true_for(s["start"], s["end"], ref)
            if t is not None:
                by[t].append(l2(emb))  # L2-normalize each segment embedding first
        for t, es in by.items():
            me = mean_emb(es)
            if me:
                mean_by[(m, t)] = l2(me)  # L2-normalize the per-(meeting,speaker) mean
    return mean_by


def bands(mean_by):
    """Compute same-speaker (cross-meeting) and different-speaker (cross-meeting) cosine lists.
    different-speaker = different true speaker AND different meeting (true strangers across
    series, plus within-series different participants in different meetings)."""
    by_spk = defaultdict(dict)
    for (m, t), me in mean_by.items():
        by_spk[t][m] = me

    same = []
    for spk, mm in by_spk.items():
        ms = sorted(mm)
        for i in range(len(ms)):
            for j in range(i + 1, len(ms)):
                same.append(cos(mm[ms[i]], mm[ms[j]]))

    flat = [(m, t, me) for (m, t), me in mean_by.items()]
    n = len(flat)
    diff = []
    diff_crossseries = []  # strict strangers: also different series
    for i in range(n):
        for j in range(i + 1, n):
            if flat[i][1] != flat[j][1] and flat[i][0] != flat[j][0]:
                c = cos(flat[i][2], flat[j][2])
                diff.append(c)
                if series_of(flat[i][0]) != series_of(flat[j][0]):
                    diff_crossseries.append(c)
    return same, diff, diff_crossseries


def center(mean_by):
    """Subtract per-arm global mean embedding (centroid of all per-(meeting,speaker) means),
    then re-normalize."""
    vals = list(mean_by.values())
    d = len(vals[0])
    g = [sum(v[i] for v in vals) / len(vals) for i in range(d)]
    out = {}
    for k, v in mean_by.items():
        c = [v[i] - g[i] for i in range(d)]
        out[k] = l2(c)
    gnorm = math.sqrt(sum(x * x for x in g))
    return out, gnorm


def summarize(same, diff):
    sm = st.mean(same) if same else None
    dm = st.mean(diff) if diff else None
    return {
        "same_mean": round(sm, 4) if sm is not None else None,
        "same_pct": pct(same),
        "same_n": len(same),
        "diff_mean": round(dm, 4) if dm is not None else None,
        "diff_pct": pct(diff),
        "diff_n": len(diff),
        "separation": round(sm - dm, 4) if (sm is not None and dm is not None) else None,
        "false_merge_0.60": frac_ge(diff, 0.60),
        "reid_recall_0.60": frac_ge(same, 0.60),
    }


def main():
    results = {}
    for arm in ARMS:
        mb = build_means(arm)
        same, diff, diff_cs = bands(mb)
        raw = summarize(same, diff)
        raw["diff_crossseries_mean"] = round(st.mean(diff_cs), 4) if diff_cs else None
        raw["n_means"] = len(mb)

        # Mechanism test: mean-center
        mbc, gnorm = center(mb)
        same_c, diff_c, diff_cs_c = bands(mbc)
        cen = summarize(same_c, diff_c)
        cen["global_mean_norm"] = round(gnorm, 4)

        results[arm] = {"raw": raw, "centered": cen}

    print(json.dumps(results, indent=2))

    # Compact tables
    print("\n=== RAW BANDS (uncentered) ===")
    print(f"{'arm':<9} {'same':>7} {'diff':>7} {'sep':>7} {'diff_xS':>8} {'fm@.60':>7} {'reid@.60':>8} {'nmeans':>6}")
    for arm in ARMS:
        r = results[arm]["raw"]
        print(f"{arm:<9} {r['same_mean']:>7} {r['diff_mean']:>7} {r['separation']:>7} "
              f"{r['diff_crossseries_mean']:>8} {r['false_merge_0.60']:>7} {r['reid_recall_0.60']:>8} {r['n_means']:>6}")

    print("\n=== CENTERED (per-arm global mean subtracted, renormalized) ===")
    print(f"{'arm':<9} {'same_c':>7} {'diff_c':>7} {'sep_c':>7} {'gmean_norm':>10} {'sep_raw':>8} {'sep_gain':>8}")
    for arm in ARMS:
        r = results[arm]["raw"]
        c = results[arm]["centered"]
        gain = round(c["separation"] - r["separation"], 4)
        print(f"{arm:<9} {c['same_mean']:>7} {c['diff_mean']:>7} {c['separation']:>7} "
              f"{c['global_mean_norm']:>10} {r['separation']:>8} {gain:>+8}")


if __name__ == "__main__":
    main()
