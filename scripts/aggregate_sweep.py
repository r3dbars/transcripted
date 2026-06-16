#!/usr/bin/env python3
"""Aggregate per-combo score JSONs (from score_speaker_eval.py --out-json) into one
threshold-sweep table: DER, fragmentation, false-merge, re-ID, profile count."""
import argparse, json

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scores", required=True, help="comma-separated score JSON paths")
    ap.add_argument("--out-md")
    args = ap.parse_args()

    rows = []
    for path in args.scores.split(","):
        s = json.load(open(path))
        cfg = s["config"]
        curve = s["reid_curve_by_appearance"]
        # mean re-ID across appearances #2+ (re-ID only meaningful after first sighting)
        later = [v for k, v in curve.items() if int(k) >= 2]
        reid_later = round(sum(later) / len(later), 3) if later else None
        rows.append({
            "cons": str(cfg["consolidationThreshold"]),
            "match": cfg["matchThreshold"],
            "der": s["der"]["mean_der"],
            "frag_mean": s["fragmentation"]["mean_profiles_per_person"],
            "frag_max": s["fragmentation"]["max_profiles_per_person"],
            "false_merge": s["false_merge"]["count"],
            "reid_curve": curve,
            "reid_later": reid_later,
            "profiles_end": s["profiles_at_end"],
            "n_true": len(s["true_speakers"]),
        })

    rows.sort(key=lambda r: (r["cons"], r["match"]))
    n_true = rows[0]["n_true"] if rows else 0

    out = []
    out.append("# Speaker-naming threshold sweep — AMI ES2002 (a–d), one recurring 4-person series\n")
    out.append(f"True speakers in series: **{n_true}**. Ideal profiles_end = {n_true}. "
               "Ideal fragmentation = 1.0/person. Ideal false-merge = 0. Ideal re-ID = 1.0.\n")
    out.append("| consolidation | match | mean DER | frag mean | frag max | false-merge | re-ID #2+ | profiles_end |")
    out.append("|---|---|---|---|---|---|---|---|")
    for r in rows:
        flag = " ⭐" if (r["profiles_end"] == n_true and r["false_merge"] == 0) else ""
        out.append(f"| {r['cons']} | {r['match']} | {r['der']} | {r['frag_mean']} | {r['frag_max']} | "
                   f"{r['false_merge']} | {r['reid_later']} | {r['profiles_end']}{flag} |")
    out.append("")
    out.append("Notes: DER uses optimal per-file label mapping (isolates diarizer quality; ~flat across "
               "match thresholds since it doesn't depend on cross-meeting naming). Fragmentation / false-merge "
               "/ re-ID / profiles_end depend on the thresholds. ⭐ = ends with exactly the true number of "
               "profiles and no cross-person merges.\n")

    # ---- pick a recommendation: closest to ideal (profiles_end==n_true, fm==0, max reid, min frag) ----
    def score(r):
        return (
            abs((r["profiles_end"] or 99) - n_true),     # want exactly n_true profiles
            r["false_merge"],                             # want 0 cross-person merges
            (r["frag_mean"] or 9) - 1.0,                  # want frag -> 1
            -(r["reid_later"] or 0),                      # want high re-ID
        )
    best = sorted(rows, key=score)[:5]
    out.append("## Closest-to-ideal combos\n")
    out.append("| consolidation | match | profiles_end | false-merge | frag mean | re-ID #2+ | DER |")
    out.append("|---|---|---|---|---|---|---|")
    for r in best:
        out.append(f"| {r['cons']} | {r['match']} | {r['profiles_end']} | {r['false_merge']} | "
                   f"{r['frag_mean']} | {r['reid_later']} | {r['der']} |")
    md = "\n".join(out)
    print(md)
    if args.out_md:
        open(args.out_md, "w").write(md)

if __name__ == "__main__":
    main()
