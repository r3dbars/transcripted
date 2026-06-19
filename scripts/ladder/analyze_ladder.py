#!/usr/bin/env python3
"""analyze_ladder.py — turn ladder_policies_<corpus>.csv sweeps into a decision-ready report.

Computes, per domain:
  - the production baseline point (isBaseline=1)
  - the Pareto frontier over (prompts-per-person, false-auto-rate)  [minimize both]
  - the recommended operating point = LOOSEST policy (fewest prompts/person) whose
    false-auto-rate <= TARGET (default 0.5%), with exact parameters
  - baseline-vs-best deltas
  - fixed-count vs evidence-score promotion head-to-head
  - demote / un-blend contamination-drift comparison
Emits: pareto_<corpus>.csv per domain, _analysis/summary.json, _analysis/report_tables.md,
and _analysis/pareto.png (matplotlib). Prints key findings.

Usage: analyze_ladder.py ami voxceleb [voxconverse ...]   (conventional data/eval/<c>/ladder paths)
       TARGET_FALSE_AUTO=0.005 analyze_ladder.py ...
"""
import os, sys, csv, json, math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = float(os.environ.get("TARGET_FALSE_AUTO", "0.005"))
ANALYSIS = ROOT / "data" / "eval" / "_analysis"

FLOATCOLS = {"suggestFloor","autoBar","marginMin","promoParam","emaAlpha","promptsPerPerson",
             "typesPerPerson","tapsPerPerson","suggestPrecision","falseAutoRate","pctReachedAuto",
             "medMeetingsToAuto","meanContamDrift","acc1","acc2","acc3","acc4","acc5","acc6","acc7","acc8plus"}
INTCOLS = {"policyId","isBaseline","maturityBonus","separationCheck","nPeople","appearances","types",
           "taps","corrections","prompts","unknowns","falseUnknowns","suggests","suggestWrong","autos",
           "autoWrong","reachedAuto","poisonedProfiles"}

def load(corpus):
    path = ROOT / "data" / "eval" / corpus / "ladder" / f"ladder_policies_{corpus}.csv"
    rows = []
    with open(path) as f:
        for r in csv.DictReader(f):
            o = {}
            for k, v in r.items():
                if v == "" or v is None: o[k] = None
                elif k in FLOATCOLS: o[k] = float(v)
                elif k in INTCOLS: o[k] = int(v)
                else: o[k] = v
            rows.append(o)
    return rows

def pareto_front(rows, xk="promptsPerPerson", yk="falseAutoRate"):
    """non-dominated set minimizing (x, y)."""
    pts = sorted(rows, key=lambda r: (r[xk], r[yk]))
    front, best_y = [], math.inf
    for r in pts:
        if r[yk] < best_y - 1e-12:
            front.append(r); best_y = r[yk]
    return front

def promo_label(r):
    if r["promoRule"] == "fixed": return f"fixed(callCount>{int(r['promoParam'])})"
    return f"evidence(>={r['promoParam']:.2f})"

def policy_desc(r):
    return (f"floor={r['suggestFloor']:.2f} auto={r['autoBar']:.2f} margin={r['marginMin']:.2f} "
            f"promo={promo_label(r)} alpha={r['emaAlpha']:.2f} demote={r['demote']} "
            f"mat={r['maturityBonus']} sep={r['separationCheck']}")

def recommend(rows, target):
    """loosest (fewest prompts) policy with falseAutoRate <= target."""
    elig = [r for r in rows if r["falseAutoRate"] <= target]
    if not elig: return None
    elig.sort(key=lambda r: (r["promptsPerPerson"], r["falseAutoRate"], -r["pctReachedAuto"]))
    return elig[0]

def fmt(r, *keys):
    return {k: r[k] for k in keys}

def main():
    corpora = sys.argv[1:] or ["ami", "voxceleb"]
    ANALYSIS.mkdir(parents=True, exist_ok=True)
    summary, tables = {}, []
    frontiers = {}

    for c in corpora:
        rows = load(c)
        main_rows = [r for r in rows if r["isBaseline"] == 0]
        baseline = next((r for r in rows if r["isBaseline"] == 1), None)
        front = pareto_front(rows)
        frontiers[c] = front
        rec = recommend(main_rows, TARGET)
        rec_strict = recommend(main_rows, 0.0)  # zero-false-auto safest

        # write per-corpus frontier csv
        fcsv = ROOT / "data" / "eval" / c / "ladder" / f"pareto_{c}.csv"
        with open(fcsv, "w") as f:
            w = csv.writer(f)
            w.writerow(["promptsPerPerson","falseAutoRate","autoBar","suggestFloor","marginMin",
                        "promo","emaAlpha","demote","pctReachedAuto","medMeetingsToAuto","suggestPrecision"])
            for r in front:
                w.writerow([f"{r['promptsPerPerson']:.4f}", f"{r['falseAutoRate']:.5f}", r['autoBar'],
                            r['suggestFloor'], r['marginMin'], promo_label(r), r['emaAlpha'], r['demote'],
                            f"{r['pctReachedAuto']:.3f}", r['medMeetingsToAuto'], f"{r['suggestPrecision']:.3f}"])

        # fixed vs evidence head-to-head: best (min prompts) at false-auto<=target for each family
        def best_of(family):
            sub = [r for r in main_rows if r["promoRule"] == family and r["falseAutoRate"] <= TARGET]
            sub.sort(key=lambda r: r["promptsPerPerson"])
            return sub[0] if sub else None
        best_fixed, best_evid = best_of("fixed"), best_of("evidence")

        # demote/un-blend contamination: MATCHED-PAIR analysis. Group policies by every
        # parameter except `demote`, then compare modes within each matched group (so the
        # comparison isn't confounded by reckless floor/autoBar combos). Report mean paired
        # deltas vs `off` and how often each mode helps/hurts.
        def keyer(r):
            return (r["suggestFloor"], r["autoBar"], r["marginMin"], r["promoRule"], r["promoParam"],
                    r["emaAlpha"], r["maturityBonus"], r["separationCheck"])
        groups = {}
        for r in main_rows:
            groups.setdefault(keyer(r), {})[r["demote"]] = r
        paired = {m: {"dFalseAuto": [], "dDrift": [], "dPrompts": [], "dPoison": []} for m in ["demote","demoteUnblend"]}
        for g in groups.values():
            if "off" not in g: continue
            base = g["off"]
            for m in ["demote","demoteUnblend"]:
                if m in g:
                    paired[m]["dFalseAuto"].append(g[m]["falseAutoRate"] - base["falseAutoRate"])
                    paired[m]["dDrift"].append(g[m]["meanContamDrift"] - base["meanContamDrift"])
                    paired[m]["dPrompts"].append(g[m]["promptsPerPerson"] - base["promptsPerPerson"])
                    paired[m]["dPoison"].append(g[m]["poisonedProfiles"] - base["poisonedProfiles"])
        def mean(xs): return sum(xs)/len(xs) if xs else 0.0
        def frac_neg(xs): return sum(1 for x in xs if x < -1e-9)/len(xs) if xs else 0.0
        demote_stats = {}
        for dm in ["off","demote","demoteUnblend"]:
            sub = [r for r in main_rows if r["demote"] == dm]
            if not sub: continue
            demote_stats[dm] = {
                "n": len(sub),
                "meanContamDrift": sum(r["meanContamDrift"] for r in sub)/len(sub),
                "meanFalseAutoRate": sum(r["falseAutoRate"] for r in sub)/len(sub),
                "meanPoisoned": sum(r["poisonedProfiles"] for r in sub)/len(sub),
            }
        demote_paired = {m: {
            "n_pairs": len(paired[m]["dFalseAuto"]),
            "meanDeltaFalseAuto": mean(paired[m]["dFalseAuto"]),
            "meanDeltaDrift": mean(paired[m]["dDrift"]),
            "meanDeltaPrompts": mean(paired[m]["dPrompts"]),
            "fracReducesFalseAuto": frac_neg(paired[m]["dFalseAuto"]),
            "fracReducesDrift": frac_neg(paired[m]["dDrift"]),
        } for m in ["demote","demoteUnblend"]}

        summary[c] = {
            "n_policies": len(rows),
            "baseline": fmt(baseline, "promptsPerPerson","typesPerPerson","tapsPerPerson","falseAutoRate",
                            "pctReachedAuto","medMeetingsToAuto","suggestPrecision","meanContamDrift","nPeople","appearances") if baseline else None,
            "recommended_target": {**fmt(rec, "policyId","suggestFloor","autoBar","marginMin","promoRule","promoParam",
                                          "emaAlpha","demote","promptsPerPerson","typesPerPerson","tapsPerPerson",
                                          "falseAutoRate","pctReachedAuto","medMeetingsToAuto","suggestPrecision",
                                          "meanContamDrift"), "desc": policy_desc(rec)} if rec else None,
            "recommended_zero_fa": {**fmt(rec_strict,"promptsPerPerson","falseAutoRate","pctReachedAuto",
                                          "medMeetingsToAuto"), "desc": policy_desc(rec_strict)} if rec_strict else None,
            "best_fixed": ({**fmt(best_fixed,"promptsPerPerson","falseAutoRate","pctReachedAuto"), "desc": policy_desc(best_fixed)} if best_fixed else None),
            "best_evidence": ({**fmt(best_evid,"promptsPerPerson","falseAutoRate","pctReachedAuto"), "desc": policy_desc(best_evid)} if best_evid else None),
            "demote_stats": demote_stats,
            "demote_paired": demote_paired,
            "target": TARGET,
        }

        # markdown tables
        t = [f"### {c}", ""]
        if baseline:
            t += [f"- **People / appearances**: {baseline['nPeople']} people, {baseline['appearances']} appearances",
                  f"- **Production baseline**: {baseline['promptsPerPerson']:.2f} prompts/person "
                  f"({baseline['typesPerPerson']:.2f} types + {baseline['tapsPerPerson']:.2f} taps), "
                  f"false-auto={baseline['falseAutoRate']*100:.2f}%, reach-AUTO={baseline['pctReachedAuto']*100:.0f}%, "
                  f"median meetings→AUTO={baseline['medMeetingsToAuto']:.0f}, contam-drift={baseline['meanContamDrift']:.4f}"]
        if rec:
            saved = baseline['promptsPerPerson'] - rec['promptsPerPerson'] if baseline else 0
            pct = saved/baseline['promptsPerPerson']*100 if baseline and baseline['promptsPerPerson'] else 0
            t += ["", f"- **Recommended @ false-auto<{TARGET*100:.1f}%**: {rec['promptsPerPerson']:.2f} prompts/person "
                  f"({rec['typesPerPerson']:.2f} types + {rec['tapsPerPerson']:.2f} taps), "
                  f"false-auto={rec['falseAutoRate']*100:.2f}%, reach-AUTO={rec['pctReachedAuto']*100:.0f}%, "
                  f"median meetings→AUTO={rec['medMeetingsToAuto']:.0f}",
                  f"  - params: `{policy_desc(rec)}`",
                  (f"  - **Δ vs baseline: {saved:+.2f} prompts/person saved ({pct:+.0f}% fewer prompts)**, "
                   f"reach-AUTO {baseline['pctReachedAuto']*100:.0f}%→{rec['pctReachedAuto']*100:.0f}%, "
                   f"false-auto {baseline['falseAutoRate']*100:.2f}%→{rec['falseAutoRate']*100:.2f}%") if baseline else ""]
        # frontier table (deduped, compact)
        t += ["", "| prompts/person | false-auto % | autoBar | floor | margin | promo | alpha | demote | %reach-AUTO |",
              "|---:|---:|---:|---:|---:|---|---:|---|---:|"]
        seen = set()
        for r in front:
            key = (round(r['promptsPerPerson'],2), round(r['falseAutoRate'],4))
            if key in seen: continue
            seen.add(key)
            t.append(f"| {r['promptsPerPerson']:.2f} | {r['falseAutoRate']*100:.2f} | {r['autoBar']:.2f} | "
                     f"{r['suggestFloor']:.2f} | {r['marginMin']:.2f} | {promo_label(r)} | {r['emaAlpha']:.2f} | "
                     f"{r['demote']} | {r['pctReachedAuto']*100:.0f} |")
        if best_fixed and best_evid:
            t += ["", f"- **fixed vs evidence @ false-auto<{TARGET*100:.1f}%**: "
                  f"best fixed = {best_fixed['promptsPerPerson']:.2f} prompts/person ({promo_label(best_fixed)}); "
                  f"best evidence = {best_evid['promptsPerPerson']:.2f} prompts/person ({promo_label(best_evid)})"]
        if demote_paired:
            t += ["", f"- **demote / un-blend — MATCHED-PAIR vs `off` ({demote_paired['demote']['n_pairs']} matched param groups):**",
                  "", "| mode | Δ false-auto (pp) | Δ contam-drift | Δ prompts/person | % of groups it reduces false-auto |",
                  "|---|---:|---:|---:|---:|"]
            for m in ["demote","demoteUnblend"]:
                s = demote_paired[m]
                t.append(f"| {m} vs off | {s['meanDeltaFalseAuto']*100:+.3f} | {s['meanDeltaDrift']:+.4f} | "
                         f"{s['meanDeltaPrompts']:+.3f} | {s['fracReducesFalseAuto']*100:.0f}% |")
        t.append("")
        tables.append("\n".join(x for x in t if x is not None))

    (ANALYSIS / "summary.json").write_text(json.dumps(summary, indent=2))
    (ANALYSIS / "report_tables.md").write_text("\n".join(tables))

    # Pareto plot
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(8, 5.5))
        colors = {"ami":"#c0392b","voxceleb":"#2980b9","voxconverse":"#27ae60","icsi":"#8e44ad"}
        for c in corpora:
            front = frontiers[c]
            xs = [r["promptsPerPerson"] for r in front]
            ys = [r["falseAutoRate"]*100 for r in front]
            col = colors.get(c, None)
            ax.plot(xs, ys, "-o", ms=3, label=f"{c} frontier", color=col, alpha=0.85)
            base = summary[c]["baseline"]
            if base:
                ax.scatter([base["promptsPerPerson"]],[base["falseAutoRate"]*100], marker="*", s=240,
                           color=col, edgecolor="black", zorder=5, label=f"{c} production baseline")
        ax.axhline(TARGET*100, ls="--", color="gray", lw=1, label=f"target {TARGET*100:.1f}% false-auto")
        ax.set_xlabel("prompts per person  (types + taps)")
        ax.set_ylabel("false-auto-name rate  (%)")
        ax.set_title("Confidence-ladder Pareto frontier: prompts vs false-positives")
        ax.legend(fontsize=8); ax.grid(alpha=0.3)
        fig.tight_layout(); fig.savefig(ANALYSIS / "pareto.png", dpi=130)
        print(f"wrote {ANALYSIS/'pareto.png'}")
    except Exception as e:
        print(f"(plot skipped: {e})")

    print(json.dumps(summary, indent=2))

if __name__ == "__main__":
    main()
