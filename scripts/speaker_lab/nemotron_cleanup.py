#!/usr/bin/env python3
"""Score Nemotron 3 output after a fingerprint-free version of SpeakerSeparation's cleanup:
fold voices under --fold seconds of talk into the voice that talks nearest in time, then
fold the quietest voices until the count fits the invite cap (+1 spare seat on 3+)."""
import argparse, json, os, sys
from collections import defaultdict
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from score import e2e_as_lab, score_meeting, summarize  # noqa: E402
ROOT = Path(os.environ.get("YODAS_ROOT", Path(__file__).resolve().parents[2] / "data" / "eval" / "yodas3"))

def nearest(segs, spk, others):
    best, dist = None, float("inf")
    mine = [s for s in segs if s["speaker"] == spk]
    for s in segs:
        if s["speaker"] in others:
            for m in mine:
                d = max(0.0, max(s["start"], m["start"]) - min(s["end"], m["end"]))
                if d < dist: best, dist = s["speaker"], d
    return best

def clean(segs, fold, cap):
    segs = [dict(s) for s in segs]
    def talk():
        t = defaultdict(float)
        for s in segs: t[s["speaker"]] += s["end"] - s["start"]
        return t
    def merge(a, b):
        for s in segs:
            if s["speaker"] == a: s["speaker"] = b
    t = talk()
    for spk in sorted(t, key=t.get):
        t = talk()
        if len(t) > 1 and spk in t and t[spk] < fold:
            merge(spk, nearest(segs, spk, set(t) - {spk}))
    while cap and len(talk()) > cap:
        t = talk(); q = min(t, key=t.get)
        merge(q, nearest(segs, q, set(t) - {q}))
    return segs

ap = argparse.ArgumentParser(); ap.add_argument("--model", default="nemotron3-offline"); ap.add_argument("--fold", type=float, default=5.0)
ap.add_argument("--no-cap", action="store_true"); a = ap.parse_args()
for s in ["p3-A", "p3-B", "p3-C", "p3-E"]:
    d0 = ROOT / "sim" / s; scored = []
    for m in json.load(open(d0 / "series.json"))["meetings"]:
        d = d0 / m["id"]; f = d / f"e2e_{a.model}.json"
        if not f.exists(): continue
        truth = json.load(open(d / "truth.json")); cal = json.load(open(d / "calendar.json"))
        n = sum(i["is_person"] for i in cal["invitees"]); cap = None if a.no_cap or not n else n + (1 if n >= 3 else 0)
        scored.append(score_meeting(truth, e2e_as_lab(truth, {"segments": clean(json.load(open(f))["segments"], a.fold, cap)})))
    c = summarize(scored); c = c[list(c)[0]]["system"]
    print(f"{s}: rows {c['rows_mean']:.1f} | exact {c['exact_pct']:.0f}% | merged-calls {c['any_blend_pct']:.0f}% | missed {c['missed_total']} | words {100*c['who_said_what_mean']:.1f}%")
