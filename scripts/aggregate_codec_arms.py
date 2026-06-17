#!/usr/bin/env python3
"""Cross-arm comparison for the AMI codec re-ID sweep (measurement only).

Reads every data/eval/ami_<tag>/reports/{cons_none_match_*.json, bands.json} and emits
one master table: for each compression arm, the optimal match threshold X plus the
re-ID / false-merge / profile-count behavior across the match grid, and the same- vs
different-speaker embedding-band collapse. This is the X-vs-compression curve.

X definition (the actionable one): the LOWEST match threshold that lands at the true
profile count (one profile per real person) with the fewest false-merges — i.e. the
most lenient threshold that still re-identifies returning speakers without fusing
strangers. Also reports the band-separation-optimal threshold for cross-check.
"""
import argparse, glob, json, os, statistics as st

ARM_ORDER = ["clean", "opus24k", "opus16k", "opus12k", "opus8k", "g711u"]
GRID = ["0.40", "0.45", "0.50", "0.55", "0.60", "0.65", "0.70"]


def arm_tag(p):
    return os.path.basename(os.path.dirname(os.path.dirname(p)))[4:]  # ami_<tag>/reports -> <tag>


def load_combo(repdir, m):
    f = os.path.join(repdir, f"cons_none_match_{m}.json")
    return json.load(open(f)) if os.path.exists(f) else None


def pick_X(rows, n_true):
    # lowest match that hits profile count closest to ideal with min false-merge,
    # tie-break on higher re-ID. rows: list of dicts with match/profiles_end/false_merge/reid.
    def key(r):
        return (abs((r["profiles_end"] or 99) - n_true), r["false_merge"],
                -(r["reid"] or 0), float(r["match"]))
    return sorted(rows, key=key)[0] if rows else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="data/eval")
    ap.add_argument("--out-md")
    args = ap.parse_args()

    arms = {}
    for repdir in glob.glob(os.path.join(args.root, "ami_*", "reports")):
        tag = os.path.basename(os.path.dirname(repdir))[4:]
        rows = []
        n_true = None
        for m in GRID:
            s = load_combo(repdir, m)
            if not s:
                continue
            n_true = len(s["true_speakers"])
            pm = s["der"]["per_meeting"]
            curve = s["reid_curve_by_appearance"]
            later = [v for k, v in curve.items() if int(k) >= 2]
            rows.append({
                "match": m,
                "der": round(st.mean(p["der"] for p in pm), 4),
                "conf": round(st.mean(p["confusion"] for p in pm), 4),
                "frag": s["fragmentation"]["mean_profiles_per_person"],
                "false_merge": s["false_merge"]["count"],
                "reid": round(sum(later) / len(later), 4) if later else None,
                "profiles_end": s["profiles_at_end"],
            })
        bands = None
        bf = os.path.join(repdir, "bands.json")
        if os.path.exists(bf):
            bands = json.load(open(bf))
        if rows:
            arms[tag] = {"rows": rows, "n_true": n_true, "bands": bands,
                         "X": pick_X(rows, n_true)}

    out = ["# AMI codec re-ID sweep — X vs compression\n"]
    # master: optimal X per arm
    out.append("## Optimal match threshold X by compression level\n")
    out.append("| arm | n_true | **X (optimal match)** | profiles@X (ideal=n_true) | false-merge@X | re-ID@X | DER@X | same-spk band | diff-spk band | band sep |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for tag in [t for t in ARM_ORDER if t in arms] + [t for t in arms if t not in ARM_ORDER]:
        a = arms[tag]; X = a["X"]; b = a["bands"]
        sm = b["same_speaker_cross_meeting"]["mean"] if b else None
        dm = b["different_speaker_cross_meeting"]["mean"] if b else None
        sep = round((sm - dm), 3) if (sm is not None and dm is not None) else None
        out.append(f"| {tag} | {a['n_true']} | **{X['match']}** | {X['profiles_end']} | {X['false_merge']} | "
                   f"{X['reid']} | {X['der']} | {sm} | {dm} | {sep} |")
    out.append("")
    # per-arm full grid
    for tag in [t for t in ARM_ORDER if t in arms]:
        a = arms[tag]
        out.append(f"## {tag}  (ideal profiles = {a['n_true']})\n")
        out.append("| match | profiles_end | false-merge | re-ID #2+ | frag | DER | conf |")
        out.append("|---|---|---|---|---|---|---|")
        for r in a["rows"]:
            star = " ⭐" if r["profiles_end"] == a["n_true"] and r["false_merge"] == 0 else ""
            out.append(f"| {r['match']} | {r['profiles_end']}{star} | {r['false_merge']} | {r['reid']} | "
                       f"{r['frag']} | {r['der']} | {r['conf']} |")
        if a["bands"]:
            tt = a["bands"]["threshold_tradeoff"]
            out.append("\n_band tradeoff (re-ID recall / false-merge pressure / separation):_  " +
                       " · ".join(f"{m}: {tt[m]['reid_recall']}/{tt[m]['false_merge_pressure']}/{tt[m]['separation']}"
                                  for m in ["0.4", "0.5", "0.6", "0.7"] if m in tt))
            ds = a["bands"]["diarizer_segmentation"]
            out.append(f"\n_diarizer: under {ds['under']} / exact {ds['exact']} / over {ds['over']}, "
                       f"mean {ds['mean_clusters_per_true']} clusters/true_\n")
    md = "\n".join(out)
    print(md)
    if args.out_md:
        open(args.out_md, "w").write(md)


if __name__ == "__main__":
    main()
