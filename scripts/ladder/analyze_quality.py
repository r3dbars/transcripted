#!/usr/bin/env python3
"""analyze_quality.py — cross-audio-quality robustness analysis for the confidence ladder.

Consumes the qmatrix cells (data/eval/qmatrix/<corpus>_<quality>/ladder/ladder_policies_*.csv)
and answers: how do prompts-per-person and false-auto-rate degrade as audio quality drops,
and which gate stays under the false-auto budget across ALL qualities?

policyId is identical across every cell (buildGrid() is deterministic), so policies are joined
across qualities by policyId — enabling a true QUALITY-ROBUST operating point: the policy with
the fewest mean prompts whose false-auto stays <= target in EVERY tested quality.

Usage: analyze_quality.py voxceleb ami_scale [ami voxconverse ...]
       TARGET_FALSE_AUTO=0.005 analyze_quality.py ...
Outputs: data/eval/_analysis/quality_summary.json, quality_tables.md, quality_*.png
"""
import os, sys, csv, json, glob
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = float(os.environ.get("TARGET_FALSE_AUTO", "0.005"))
ANALYSIS = ROOT / "data" / "eval" / "_analysis"
QDIR = ROOT / "data" / "eval" / "qmatrix"

# display order: clean -> increasingly degraded
QORDER = ["orig", "mp3_64", "aac_32", "mp3_32", "opus_16k", "mp3_16", "opus_8k",
          "tel_g711", "reverb", "noisy_snr10", "noisy_snr5"]

FLOATCOLS = {"suggestFloor","autoBar","marginMin","promoParam","emaAlpha","promptsPerPerson",
             "typesPerPerson","tapsPerPerson","suggestPrecision","falseAutoRate","pctReachedAuto",
             "medMeetingsToAuto","meanContamDrift"}
INTCOLS = {"policyId","isBaseline","autos","autoWrong","appearances","nPeople"}

def load_cell(path):
    rows = {}
    with open(path) as f:
        for r in csv.DictReader(f):
            o = {}
            for k, v in r.items():
                if v == "" or v is None: o[k] = None
                elif k in FLOATCOLS: o[k] = float(v)
                elif k in INTCOLS: o[k] = int(v)
                else: o[k] = v
            rows[o["policyId"]] = o
    return rows

def promo_label(r):
    return f"fixed(cc>{int(r['promoParam'])})" if r["promoRule"] == "fixed" else f"evid(>={r['promoParam']:.2f})"

def policy_desc(r):
    return (f"floor={r['suggestFloor']:.2f} auto={r['autoBar']:.2f} margin={r['marginMin']:.2f} "
            f"promo={promo_label(r)} alpha={r['emaAlpha']:.2f} demote={r['demote']}")

def discover(corpus):
    cells = {}
    for d in sorted(glob.glob(str(QDIR / f"{corpus}_*"))):
        tag = os.path.basename(d)
        q = tag[len(corpus) + 1:]
        csvp = Path(d) / "ladder" / f"ladder_policies_{tag}.csv"
        if csvp.exists() and csvp.stat().st_size > 0:
            cells[q] = load_cell(csvp)
    # order
    return {q: cells[q] for q in QORDER if q in cells} | {q: cells[q] for q in cells if q not in QORDER}

def recommend(cell, target):
    elig = [r for r in cell.values() if r["isBaseline"] == 0 and r["falseAutoRate"] <= target]
    if not elig: return None
    elig.sort(key=lambda r: (r["promptsPerPerson"], r["falseAutoRate"], -r["pctReachedAuto"]))
    return elig[0]

def main():
    corpora = sys.argv[1:] or ["voxceleb", "ami_scale"]
    ANALYSIS.mkdir(parents=True, exist_ok=True)
    summary, tables = {}, []

    for corpus in corpora:
        cells = discover(corpus)
        if not cells:
            print(f"(no cells for {corpus})"); continue
        quals = list(cells.keys())

        # per-quality baseline + per-quality recommended
        per_q = {}
        for q, cell in cells.items():
            base = next((r for r in cell.values() if r["isBaseline"] == 1), None)
            rec = recommend(cell, TARGET)
            per_q[q] = {"baseline": base, "rec": rec, "nPeople": base["nPeople"] if base else None}

        # QUALITY-ROBUST gate: join by policyId across all qualities; eligible if false-auto<=target
        # in EVERY quality; pick min mean prompts.
        pids = set.intersection(*[set(c.keys()) for c in cells.values()]) if cells else set()
        robust = []
        for pid in pids:
            rows = [cells[q][pid] for q in quals]
            if any(r["isBaseline"] == 1 for r in rows): continue
            worst_fa = max(r["falseAutoRate"] for r in rows)
            mean_pp = sum(r["promptsPerPerson"] for r in rows) / len(rows)
            mean_reach = sum(r["pctReachedAuto"] for r in rows) / len(rows)
            if worst_fa <= TARGET:
                robust.append((mean_pp, worst_fa, -mean_reach, pid, rows[0]))
        robust.sort()
        robust_pick = robust[0] if robust else None

        # baseline robustness: production policy across qualities (policyId 0)
        base_curve = {q: cells[q].get(0) for q in quals}

        summary[corpus] = {
            "qualities": quals,
            "target": TARGET,
            "per_quality": {q: {
                "baseline_prompts": per_q[q]["baseline"]["promptsPerPerson"] if per_q[q]["baseline"] else None,
                "baseline_false_auto": per_q[q]["baseline"]["falseAutoRate"] if per_q[q]["baseline"] else None,
                "baseline_reach": per_q[q]["baseline"]["pctReachedAuto"] if per_q[q]["baseline"] else None,
                "rec_prompts": per_q[q]["rec"]["promptsPerPerson"] if per_q[q]["rec"] else None,
                "rec_false_auto": per_q[q]["rec"]["falseAutoRate"] if per_q[q]["rec"] else None,
                "rec_desc": policy_desc(per_q[q]["rec"]) if per_q[q]["rec"] else None,
            } for q in quals},
            "robust": ({
                "mean_prompts": robust_pick[0], "worst_false_auto": robust_pick[1],
                "mean_reach": -robust_pick[2], "policyId": robust_pick[3],
                "desc": policy_desc(robust_pick[4]),
                "per_quality_prompts": {q: cells[q][robust_pick[3]]["promptsPerPerson"] for q in quals},
                "per_quality_false_auto": {q: cells[q][robust_pick[3]]["falseAutoRate"] for q in quals},
            } if robust_pick else None),
            "n_robust_eligible": len(robust),
        }

        # markdown
        t = [f"### {corpus}  (people≈{per_q[quals[0]]['nPeople']}, qualities tested: {len(quals)})", ""]
        hdrpct = f"{TARGET*100:.1f}"
        t += [f"| quality | baseline prompts/p | baseline false-auto % | baseline reach-AUTO % | best@<{hdrpct}% prompts/p | best false-auto % |",
              "|---|---:|---:|---:|---:|---:|"]
        for q in quals:
            p = summary[corpus]["per_quality"][q]
            def g(x, s=1, pct=False): return "—" if x is None else (f"{x*100:.2f}" if pct else f"{x:.2f}")
            t.append(f"| {q} | {g(p['baseline_prompts'])} | {g(p['baseline_false_auto'],pct=True)} | "
                     f"{g(p['baseline_reach'],pct=True)} | {g(p['rec_prompts'])} | {g(p['rec_false_auto'],pct=True)} |")
        rb = summary[corpus]["robust"]
        if rb:
            t += ["", f"- **Quality-ROBUST gate** (false-auto ≤ {TARGET*100:.1f}% in *every* tested quality; "
                  f"{summary[corpus]['n_robust_eligible']} policies qualify): "
                  f"mean **{rb['mean_prompts']:.2f} prompts/person**, worst-case false-auto {rb['worst_false_auto']*100:.2f}%, "
                  f"mean reach-AUTO {rb['mean_reach']*100:.0f}%",
                  f"  - params: `{rb['desc']}`",
                  "", "  per-quality prompts/person: " + ", ".join(f"{q}={rb['per_quality_prompts'][q]:.2f}" for q in quals)]
        else:
            t += ["", f"- **No gate keeps false-auto ≤ {TARGET*100:.1f}% across all qualities** — the budget is "
                  f"unachievable on the worst quality in this corpus (see per-quality table)."]
        t.append("")
        tables.append("\n".join(t))

    (ANALYSIS / "quality_summary.json").write_text(json.dumps(summary, indent=2, default=str))
    (ANALYSIS / "quality_tables.md").write_text("\n".join(tables))

    # plots: degradation curves (baseline + robust) per corpus
    try:
        import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
        for corpus in corpora:
            if corpus not in summary: continue
            quals = summary[corpus]["qualities"]
            xs = list(range(len(quals)))
            fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))
            bp = [summary[corpus]["per_quality"][q]["baseline_prompts"] for q in quals]
            bf = [(summary[corpus]["per_quality"][q]["baseline_false_auto"] or 0)*100 for q in quals]
            ax1.plot(xs, bp, "-o", label="production baseline", color="#c0392b")
            ax2.plot(xs, bf, "-o", label="production baseline", color="#c0392b")
            rb = summary[corpus]["robust"]
            if rb:
                rp = [rb["per_quality_prompts"][q] for q in quals]
                rf = [rb["per_quality_false_auto"][q]*100 for q in quals]
                ax1.plot(xs, rp, "-s", label="quality-robust gate", color="#2980b9")
                ax2.plot(xs, rf, "-s", label="quality-robust gate", color="#2980b9")
            ax2.axhline(TARGET*100, ls="--", color="gray", lw=1, label=f"target {TARGET*100:.1f}%")
            for ax, ttl, yl in [(ax1, "prompts/person", "prompts per person"), (ax2, "false-auto", "false-auto %")]:
                ax.set_xticks(xs); ax.set_xticklabels(quals, rotation=45, ha="right", fontsize=8)
                ax.set_title(f"{corpus}: {ttl} vs audio quality"); ax.set_ylabel(yl); ax.grid(alpha=0.3); ax.legend(fontsize=8)
            fig.tight_layout(); fig.savefig(ANALYSIS / f"quality_{corpus}.png", dpi=130); plt.close(fig)
            print(f"wrote quality_{corpus}.png")
    except Exception as e:
        print(f"(plot skipped: {e})")

    print(json.dumps(summary, indent=2, default=str)[:3000])

if __name__ == "__main__":
    main()
