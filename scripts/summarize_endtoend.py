#!/usr/bin/env python3
"""Summarize a model's end-to-end matcher sweep vs the WeSpeaker baseline. Picks the
candidate's best operating point (profiles_end nearest the true count, then fewest people
trapped) and compares to WeSpeaker at its shipping 0.60 and at its best-reachable point."""
import argparse, glob, json, os, statistics as st

NTRUE = 32


def people_trapped(s):
    return len({t for ids in s["false_merge"]["profiles"].values() for t in ids})


def reid_later(s):
    c = s["reid_curve_by_appearance"]; v = [x for k, x in c.items() if int(k) >= 2]
    return round(sum(v) / len(v), 3) if v else None


def row(s, m):
    pm = s["der"]["per_meeting"]
    return {"m": m, "pe": s["profiles_at_end"], "fm": s["false_merge"]["count"],
            "trap": people_trapped(s), "reid": reid_later(s),
            "der": round(st.mean(p["der"] for p in pm), 3)}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--model", required=True)
    ap.add_argument("--arms", default="clean opus12k opus8k g711u"); a = ap.parse_args()
    for arm in a.arms.split():
        D = f"data/eval/ami_{arm}__{a.model}/reports"
        cand = []
        for f in sorted(glob.glob(f"{D}/e2e_*.json")):
            m = os.path.basename(f)[4:-5]
            cand.append(row(json.load(open(f)), m))
        if not cand:
            print(f"\n[{arm}] no e2e reports"); continue
        best = sorted(cand, key=lambda r: (abs(r["pe"] - NTRUE), r["trap"], float(r["m"])))[0]
        # WeSpeaker baseline
        wsdir = f"data/eval/ami_{arm}/reports"
        ws60 = json.load(open(f"{wsdir}/cons_none_match_0.60.json")) if os.path.exists(f"{wsdir}/cons_none_match_0.60.json") else None
        wsall = [row(json.load(open(f)), os.path.basename(f).split("match_")[1][:-5])
                 for f in glob.glob(f"{wsdir}/cons_none_match_*.json")]
        wsbest = sorted(wsall, key=lambda r: (abs(r["pe"] - NTRUE), r["trap"], float(r["m"]))) [0] if wsall else None
        print(f"\n=== {arm}  (ideal profiles = {NTRUE}) ===")
        print(f"  {a.model} sweep (m: pe/fm/trapped/reID/DER):")
        for r in cand:
            star = " <== best" if r["m"] == best["m"] else ""
            print(f"    {r['m']}: {r['pe']}/{r['fm']}/{r['trap']}/{r['reid']}/{r['der']}{star}")
        if ws60:
            w = row(ws60, "0.60"); print(f"  WeSpeaker @0.60 (shipping): {w['pe']}/{w['fm']}/{w['trap']}/{w['reid']}/{w['der']}")
        if wsbest:
            print(f"  WeSpeaker best-reachable @{wsbest['m']}: {wsbest['pe']}/{wsbest['fm']}/{wsbest['trap']}/{wsbest['reid']}/{wsbest['der']}")
        print(f"  -> {a.model} BEST @{best['m']}: profiles {best['pe']} (vs ideal 32), trapped {best['trap']}, DER {best['der']}")


if __name__ == "__main__":
    main()
