#!/usr/bin/env python3
"""Compare the mean-centering modes against the uncentered baseline on the DOWNSTREAM
matcher metrics (measurement only). The headline false-positive metric here is
PEOPLE-TRAPPED — the count of distinct true speakers stuck in a profile that fuses >=2
people — because raw false_merge.count and re-ID are both distorted by mega-profile
collapse at low thresholds / heavy compression.

Reads baseline data/eval/ami_<arm>/reports and centered data/eval/ami_<arm>_<mode>/reports.
Two views: (1) at the production threshold match=0.60, (2) at each cell's own best match.
"""
import argparse, json, os

ARMS = ["clean", "opus24k", "opus16k", "opus12k", "opus8k", "g711u"]
MODES = ["baseline", "normonly", "global", "running"]
GRID = ["0.40", "0.45", "0.50", "0.55", "0.60", "0.65", "0.70"]
NTRUE = 32


def repdir(arm, mode):
    return f"data/eval/ami_{arm}/reports" if mode == "baseline" else f"data/eval/ami_{arm}_{mode}/reports"


def load(arm, mode, m):
    f = os.path.join(repdir(arm, mode), f"cons_none_match_{m}.json")
    return json.load(open(f)) if os.path.exists(f) else None


def people_trapped(s):
    return len({t for ids in s["false_merge"]["profiles"].values() for t in ids})


def reid_later(s):
    c = s["reid_curve_by_appearance"]; later = [v for k, v in c.items() if int(k) >= 2]
    return round(sum(later) / len(later), 3) if later else None


def cell(arm, mode, m):
    s = load(arm, mode, m)
    if not s:
        return None
    return {"match": m, "pe": s["profiles_at_end"], "trapped": people_trapped(s),
            "fm": s["false_merge"]["count"], "reid": reid_later(s)}


def band_sep(arm, mode):
    f = os.path.join(repdir(arm, mode), "bands.json")
    if not os.path.exists(f):
        return None
    b = json.load(open(f))
    return round(b["same_speaker_cross_meeting"]["mean"] - b["different_speaker_cross_meeting"]["mean"], 3)


def best(arm, mode):
    cells = [cell(arm, mode, m) for m in GRID]
    cells = [c for c in cells if c]
    if not cells:
        return None
    # best = profile count nearest 32, then fewest people trapped, then lower match
    return sorted(cells, key=lambda c: (abs(c["pe"] - NTRUE), c["trapped"], float(c["match"])))[0]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--out-md"); args = ap.parse_args()
    out = ["# Mean-centering matcher experiment — does it fix the downstream false positives?\n"]
    out.append(f"Ideal profiles = {NTRUE}. people-trapped = distinct real speakers stuck in a >=2-person "
               "profile (the honest false-positive count; lower is better).\n")

    out.append("## At the production threshold (match = 0.60)\n")
    out.append("| arm | mode | profiles_end (ideal 32) | people-trapped | false-merge | re-ID#2+ | band sep |")
    out.append("|---|---|---|---|---|---|---|")
    for arm in ARMS:
        for mode in MODES:
            c = cell(arm, mode, "0.60")
            if not c:
                continue
            sep = band_sep(arm, mode)
            mark = " ←" if mode == "global" else ""
            out.append(f"| {arm} | {mode} | {c['pe']} | {c['trapped']} | {c['fm']} | {c['reid']} | {sep}{mark} |")
        out.append("| | | | | | | |")

    out.append("\n## At each cell's own best match (profiles nearest 32, then fewest trapped)\n")
    out.append("| arm | mode | best match | profiles_end | people-trapped | re-ID#2+ |")
    out.append("|---|---|---|---|---|---|")
    for arm in ARMS:
        for mode in MODES:
            b = best(arm, mode)
            if not b:
                continue
            out.append(f"| {arm} | {mode} | {b['match']} | {b['pe']} | {b['trapped']} | {b['reid']} |")
        out.append("| | | | | | |")

    md = "\n".join(out)
    print(md)
    if args.out_md:
        open(args.out_md, "w").write(md)


if __name__ == "__main__":
    main()
