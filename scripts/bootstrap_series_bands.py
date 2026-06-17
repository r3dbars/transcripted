#!/usr/bin/env python3
"""Cluster bootstrap (resample the 8 SERIES with replacement) as a robustness cross-check
on the leave-one-series-out jackknife. Because the same 8 series feed every arm, the arm
estimates are paired/correlated: we resample a set of 8 series indices ONCE per bootstrap
draw and recompute every arm's separation on that same resample, then look at the PAIRED
gaps (clean-opus12k, opus12k-opus8k). This directly answers: across resampling of series,
does clean>opus12k>opus8k ever flip?

We rebuild same/diff pairs but recompute means on the resampled multiset of series. A
same-speaker pair belongs to one series (speakers are series-pure). A different-speaker
cross-meeting pair belongs to an unordered pair of series; under a resample with counts
c[series], we weight each diff pair by c[sa]*c[sb] (or c*(c-1) coeff handled via product),
and each same pair by c[ser]. This is the natural cluster-bootstrap weighting of the U-stat.
"""
import glob, json, os, random, statistics as st
from collections import defaultdict

Q_MIN, DUR_MIN = 0.3, 1.0
ROOT = "/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2/data"
RTTM_DIR = os.path.join(ROOT, "ami", "rttm")
SERIES = ["ES2002", "ES2003", "ES2005", "ES2006", "ES2007", "ES2008", "ES2009", "ES2010"]
ARMS = ["clean", "opus12k", "opus8k"]


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


def load_pairs(arm):
    dumps = os.path.join(ROOT, "eval", f"ami_{arm}", "dumps")
    mean_by = {}
    for dp in sorted(glob.glob(os.path.join(dumps, "*.json"))):
        m = os.path.basename(dp)[:-5]
        rp = os.path.join(RTTM_DIR, m + ".rttm")
        if not os.path.exists(rp): continue
        d = json.load(open(dp)); ref = parse_rttm(rp)
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
    by_spk = defaultdict(dict)
    for (m, t), me in mean_by.items():
        by_spk[t][m] = me
    same = []  # (series, cos)
    for spk, mm in by_spk.items():
        ms = sorted(mm)
        for i in range(len(ms)):
            si = ms[i][:6]
            for j in range(i + 1, len(ms)):
                same.append((si, cos(mm[ms[i]], mm[ms[j]])))
    flat = [(m, t, me) for (m, t), me in mean_by.items()]
    n = len(flat); diff = []
    for i in range(n):
        for j in range(i + 1, n):
            if flat[i][1] != flat[j][1] and flat[i][0] != flat[j][0]:
                diff.append((flat[i][0][:6], flat[j][0][:6], cos(flat[i][2], flat[j][2])))
    return same, diff


def sep_weighted(same, diff, counts):
    """Separation under series multiplicities `counts` (dict series->int)."""
    sw = sd = 0.0; swn = sdn = 0.0
    for (ser, c) in same:
        w = counts[ser]
        if w: sw += w * c; swn += w
    for (sa, sb, c) in diff:
        w = counts[sa] * counts[sb]
        if w: sd += w * c; sdn += w
    if swn == 0 or sdn == 0: return None
    return (sw / swn) - (sd / sdn)


def main():
    pairs = {a: load_pairs(a) for a in ARMS}
    rng = random.Random(20260617)
    B = 5000
    sep_draws = {a: [] for a in ARMS}
    flip_order = 0
    flip_c12 = 0
    flip_128 = 0
    for _ in range(B):
        idx = [rng.randrange(len(SERIES)) for _ in range(len(SERIES))]
        counts = defaultdict(int)
        for k in idx: counts[SERIES[k]] += 1
        s = {}
        for a in ARMS:
            v = sep_weighted(pairs[a][0], pairs[a][1], counts)
            s[a] = v; sep_draws[a].append(v)
        if not (s["clean"] > s["opus12k"]): flip_c12 += 1
        if not (s["opus12k"] > s["opus8k"]): flip_128 += 1
        if not (s["clean"] > s["opus12k"] > s["opus8k"]): flip_order += 1

    def ci(xs):
        xs = sorted(xs)
        return st.mean(xs), xs[int(0.025 * len(xs))], xs[int(0.975 * len(xs))], st.pstdev(xs)

    print("CLUSTER BOOTSTRAP over 8 series, B=%d (paired across arms)" % B)
    print(f"{'arm':9} {'mean':>8} {'2.5%':>8} {'97.5%':>8} {'sd':>8}")
    for a in ARMS:
        m, lo, hi, sd = ci(sep_draws[a])
        print(f"{a:9} {m:8.4f} {lo:8.4f} {hi:8.4f} {sd:8.4f}")
    print()
    print(f"P(NOT clean>opus12k)          = {flip_c12/B:.4f}")
    print(f"P(NOT opus12k>opus8k)         = {flip_128/B:.4f}")
    print(f"P(ordering clean>opus12k>opus8k FAILS) = {flip_order/B:.4f}")
    # paired gap CIs
    c12 = sorted(sep_draws['clean'][i]-sep_draws['opus12k'][i] for i in range(B))
    g128 = sorted(sep_draws['opus12k'][i]-sep_draws['opus8k'][i] for i in range(B))
    print()
    print(f"paired gap clean-opus12k : mean={st.mean(c12):.4f} 95%CI=[{c12[int(.025*B)]:.4f},{c12[int(.975*B)]:.4f}]")
    print(f"paired gap opus12k-opus8k: mean={st.mean(g128):.4f} 95%CI=[{g128[int(.025*B)]:.4f},{g128[int(.975*B)]:.4f}]")


if __name__ == "__main__":
    main()
