#!/usr/bin/env python3
"""Assemble the master embedding-model scorecard from data/eval/scorecards/*.json into
clean grids: within-meeting coverage, error (DER), and cross-call separability (AUC),
for every model x codec arm. The "all models, all numbers" view."""
import glob, json, os

ARMS = ["clean", "opus24k", "opus16k", "opus12k", "opus8k", "g711u"]
MODEL_ORDER = ["wespeaker", "ecapa", "xvect", "wavlm", "unisat", "redimnet_b6", "campplus", "eres2net"]
LABEL = {"wespeaker": "WeSpeaker (current)", "ecapa": "ECAPA-TDNN", "xvect": "x-vector (control)",
         "wavlm": "WavLM-SV", "unisat": "UniSpeech-SAT", "redimnet_b6": "ReDimNet-b6",
         "campplus": "CAM++", "eres2net": "ERes2Net"}

cards = {}
for f in glob.glob("data/eval/scorecards/*.json"):
    d = json.load(open(f)); cards[(d["model"], d["arm"])] = d

models = [m for m in MODEL_ORDER if any((m, a) in cards for a in ARMS)]
dims = {m: next((cards[(m, a)]["dim"] for a in ARMS if (m, a) in cards), "?") for m in models}


def grid(title, getter, fmt="{:.3f}"):
    out = [f"\n### {title}\n"]
    out.append("| model | dim | " + " | ".join(ARMS) + " |")
    out.append("|" + "---|" * (len(ARMS) + 2))
    for m in models:
        cells = []
        for a in ARMS:
            c = cards.get((m, a))
            cells.append(fmt.format(getter(c)) if c else "·")
        out.append(f"| {LABEL[m]} | {dims[m]} | " + " | ".join(cells) + " |")
    return "\n".join(out)


lines = ["# Master embedding scorecard — all models × all codec arms\n",
         "Within-meeting = how well speakers are separated inside a meeting (oracle-k). "
         "Cross-call AUC = threshold-free same-vs-different separability (1.0 = perfect). "
         "Coverage/AUC higher = better; DER lower = better. `·` = not run."]
lines.append(grid("Within-meeting coverage — speakers correctly separated (higher better)",
                  lambda c: c["within"]["coverage_frac"]))
lines.append(grid("Within-meeting error — DER (lower better)",
                  lambda c: c["within"]["mean_der"]))
lines.append(grid("Within-meeting purity (higher better)",
                  lambda c: c["within"]["mean_purity"]))
lines.append(grid("Cross-call separability — AUC (higher better, 1.0=perfect)",
                  lambda c: c["cross_meeting"]["auc_raw"], "{:.4f}"))
lines.append(grid("Cross-call raw separation — same minus different cosine (higher=less anisotropic)",
                  lambda c: c["cross_meeting"]["sep_raw"]))

md = "\n".join(lines)
print(md)
open("data/eval/MASTER_SCORECARD.md", "w").write(md)
