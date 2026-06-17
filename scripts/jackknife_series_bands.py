#!/usr/bin/env python3
"""Leave-one-series-out (LOSO) jackknife of the AMI cross-meeting embedding bands.

Recomputes, from raw dumps + RTTM ground truth, the SAME-speaker band, the
DIFFERENT-speaker band, and their separation (same.mean - diff.mean), exactly the
way scripts/analyze_ami_codec_bands.py does (same quality/duration filters, same
per-meeting per-true-speaker mean embedding, same cross-meeting pairing rule).

Then it jackknifes by SERIES: there are 8 AMI series (ES2002..ES2010), each with
4 meetings and 4 recurring participants that appear in NO other series. Dropping a
series removes those 4 speakers and every pair that touches them. We report, per arm:
  - full-sample point estimate of same/diff/separation
  - the 8 LOSO leave-one-out values
  - jackknife mean and jackknife SE (sqrt((n-1)/n * sum (xi - xbar)^2))
  - which single series, when DROPPED, moves the separation the most
and checks whether ordering clean > opus12k > opus8k holds across all 8 leave-outs.
"""
import glob, json, os, statistics as st
from collections import defaultdict

Q_MIN, DUR_MIN = 0.3, 1.0
ROOT = "/Users/redbars/transcripted/.claude/worktrees/objective-noyce-06bac2/data"
RTTM_DIR = os.path.join(ROOT, "ami", "rttm")


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


def load_arm(arm):
    """Return mean_by: (meeting, speaker) -> mean embedding, restricted to meetings
    that have an RTTM. Series is meeting[:6]."""
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
    return mean_by


def build_pairs(mean_by):
    """Reproduce analyze_ami_codec_bands pairing. Returns:
       same: list of (series, cosine) for same-speaker cross-meeting pairs
       diff: list of (seriesA, seriesB, cosine) for different-speaker cross-meeting pairs
    All deterministic and exhaustive (the eval used the full diff set; n=7744 < 300k cap)."""
    by_spk = defaultdict(dict)
    for (m, t), me in mean_by.items():
        by_spk[t][m] = me
    same = []
    for spk, mm in by_spk.items():
        ms = sorted(mm)
        series = None  # speaker is series-pure; derive from any meeting
        for i in range(len(ms)):
            si = ms[i][:6]
            for j in range(i + 1, len(ms)):
                same.append((si, cos(mm[ms[i]], mm[ms[j]])))
    flat = [(m, t, me) for (m, t), me in mean_by.items()]
    n = len(flat)
    diff = []
    for i in range(n):
        for j in range(i + 1, n):
            if flat[i][1] != flat[j][1] and flat[i][0] != flat[j][0]:
                diff.append((flat[i][0][:6], flat[j][0][:6], cos(flat[i][2], flat[j][2])))
    return same, diff


def bands_for_subset(same, diff, drop_series=None):
    """Compute (same_mean, diff_mean, separation) over the subset that excludes drop_series."""
    s_vals = [c for (ser, c) in same if ser != drop_series]
    d_vals = [c for (sa, sb, c) in diff if sa != drop_series and sb != drop_series]
    sm = st.mean(s_vals); dm = st.mean(d_vals)
    return sm, dm, sm - dm, len(s_vals), len(d_vals)


def jackknife_se(loo_values):
    """Standard delete-1 jackknife SE from the n leave-one-out estimates."""
    n = len(loo_values)
    xbar = st.mean(loo_values)
    return (((n - 1) / n) * sum((x - xbar) ** 2 for x in loo_values)) ** 0.5, xbar


SERIES = ["ES2002", "ES2003", "ES2005", "ES2006", "ES2007", "ES2008", "ES2009", "ES2010"]
ARMS = ["clean", "opus24k", "opus16k", "opus12k", "opus8k", "g711u"]


def main():
    results = {}
    for arm in ARMS:
        mb = load_arm(arm)
        same, diff = build_pairs(mb)
        full = bands_for_subset(same, diff)  # no drop
        loo = {}
        for ser in SERIES:
            loo[ser] = bands_for_subset(same, diff, drop_series=ser)
        results[arm] = {"full": full, "loo": loo, "n_speakers": len(set(s for s in
                        set(t for (m, t) in mb)))}

    # ---- print full point estimates (verify vs lead) ----
    print("=" * 78)
    print("FULL-SAMPLE BAND POINT ESTIMATES (recomputed from dumps)")
    print("=" * 78)
    print(f"{'arm':8} {'same':>8} {'diff':>8} {'separation':>11} {'n_same':>7} {'n_diff':>7}")
    for arm in ARMS:
        sm, dm, sep, ns, nd = results[arm]["full"]
        print(f"{arm:8} {sm:8.4f} {dm:8.4f} {sep:11.4f} {ns:7d} {nd:7d}")

    # ---- jackknife each band, each arm ----
    print()
    print("=" * 78)
    print("LEAVE-ONE-SERIES-OUT JACKKNIFE (8 series)")
    print("=" * 78)
    for arm in ARMS:
        sep_loo = [results[arm]["loo"][s][2] for s in SERIES]
        same_loo = [results[arm]["loo"][s][0] for s in SERIES]
        diff_loo = [results[arm]["loo"][s][1] for s in SERIES]
        se_sep, jk_sep = jackknife_se(sep_loo)
        se_same, jk_same = jackknife_se(same_loo)
        se_diff, jk_diff = jackknife_se(diff_loo)
        full_sep = results[arm]["full"][2]
        print(f"\n[{arm}]  full separation = {full_sep:.4f}")
        print(f"   same:  jk_mean={jk_same:.4f}  jk_SE={se_same:.4f}")
        print(f"   diff:  jk_mean={jk_diff:.4f}  jk_SE={se_diff:.4f}")
        print(f"   SEP :  jk_mean={jk_sep:.4f}  jk_SE={se_sep:.4f}   "
              f"approx 95% = [{full_sep-1.96*se_sep:.4f}, {full_sep+1.96*se_sep:.4f}]")
        print(f"   LOO separations (drop each series):")
        for s in SERIES:
            ds = results[arm]["loo"][s][2]
            print(f"      drop {s}: sep={ds:.4f}  (delta vs full {ds-full_sep:+.4f})")
        # series with max influence on separation
        infl = sorted(((abs(results[arm]['loo'][s][2]-full_sep), s) for s in SERIES), reverse=True)
        print(f"   most-influential series on SEPARATION: {infl[0][1]} "
              f"(|delta|={infl[0][0]:.4f}), next {infl[1][1]} (|delta|={infl[1][0]:.4f})")

    # ---- ordering robustness: clean > opus12k > opus8k under every leave-out ----
    print()
    print("=" * 78)
    print("ORDERING ROBUSTNESS: separation  clean > opus12k > opus8k")
    print("=" * 78)
    target = ["clean", "opus12k", "opus8k"]
    print(f"{'drop':8} {'clean':>9} {'opus12k':>9} {'opus8k':>9}  {'cl>12k':>7} {'12k>8k':>7} {'all':>5}")
    full_ok = True
    a, b, c = (results[t]["full"][2] for t in target)
    print(f"{'<none>':8} {a:9.4f} {b:9.4f} {c:9.4f}  {str(a>b):>7} {str(b>c):>7} {str(a>b>c):>5}")
    all_hold = a > b > c
    margins_clean_12 = [a - b]
    margins_12_8 = [b - c]
    for ser in SERIES:
        ca = results["clean"]["loo"][ser][2]
        cb = results["opus12k"]["loo"][ser][2]
        cc = results["opus8k"]["loo"][ser][2]
        ok1, ok2 = ca > cb, cb > cc
        hold = ok1 and ok2
        all_hold = all_hold and hold
        margins_clean_12.append(ca - cb)
        margins_12_8.append(cb - cc)
        print(f"{('drop '+ser):8} {ca:9.4f} {cb:9.4f} {cc:9.4f}  {str(ok1):>7} {str(ok2):>7} {str(hold):>5}")
    print(f"\nordering clean>opus12k>opus8k holds in ALL leave-outs: {all_hold}")
    print(f"clean-vs-opus12k separation gap: min={min(margins_clean_12):.4f} "
          f"max={max(margins_clean_12):.4f} (full={margins_clean_12[0]:.4f})")
    print(f"opus12k-vs-opus8k separation gap: min={min(margins_12_8):.4f} "
          f"max={max(margins_12_8):.4f} (full={margins_12_8[0]:.4f})")

    # also report the raw per-series structure for the same-speaker band (the fragile one)
    print()
    print("=" * 78)
    print("PER-SERIES SAME-SPEAKER MEAN (the small-N / fragile band), clean arm")
    print("=" * 78)
    mb = load_arm("clean"); same, _ = build_pairs(mb)
    per = defaultdict(list)
    for ser, c in same:
        per[ser].append(c)
    for s in SERIES:
        v = per[s]
        print(f"  {s}: n={len(v):3d} same-mean={st.mean(v):.4f} "
              f"min={min(v):.4f} max={max(v):.4f}")


if __name__ == "__main__":
    main()
