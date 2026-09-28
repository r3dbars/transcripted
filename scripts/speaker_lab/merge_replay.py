#!/usr/bin/env python3
"""Replay "split generously, then merge smartly" policies on raw diarizer clusters.

Input: <meeting>/emb_raw-<tag>.json from `speaker-eval-harness dump-set --embeddings`
(raw production diarizer output with each segment's WeSpeaker vector), plus the
meeting's calendar.json and truth.json. Each policy merges clusters after the
diarizer and is scored with score.py's rules, so results line up with the
end-to-end tables.

Policies:
  none            raw clusters
  sim@T           merge the most similar pair of cluster centroids while cosine >= T
                  (centroids recomputed, duration-weighted, after each merge)
  cap             calendar cap: while clusters > invite size (+1 on 3+), merge the
                  cluster with the least talk time into its most similar cluster
  sim@T+cap       sim@T first, then cap
  small@S+...     clusters under S seconds of talk are folded into their most
                  similar cluster before anything else

  data/eval/yodas3/venv/bin/python scripts/speaker_lab/merge_replay.py --tag thr070
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from score import e2e_as_lab, score_meeting, summarize  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get("YODAS_ROOT", REPO_ROOT / "data" / "eval" / "yodas3"))


def unit(v):
    return v / (np.linalg.norm(v) + 1e-9)


def clusters_of(dump: dict) -> dict[int, dict]:
    """Per raw cluster: talk seconds and a quality-filtered mean embedding
    (production's filter: quality >= 0.3 and >= 1 s, falling back to all)."""
    out: dict[int, dict] = defaultdict(lambda: {"dur": 0.0, "good": [], "all": []})
    for s in dump["segments"]:
        c = out[s["speaker"]]
        d = s["end"] - s["start"]
        c["dur"] += d
        if s.get("embedding"):
            e = np.array(s["embedding"], dtype=np.float32)
            c["all"].append((e, d))
            if (s.get("quality") or 0) >= 0.3 and d >= 1.0:
                c["good"].append((e, d))
    res = {}
    for k, c in out.items():
        src = c["good"] or c["all"]
        if not src:
            continue
        res[k] = {"dur": c["dur"], "emb": unit(sum(e * d for e, d in src))}
    return res


def invite_size(cal: dict) -> int:
    return sum(1 for i in cal["invitees"] if i["is_person"])


def merge(clusters: dict[int, dict], policy: dict, cap: int | None) -> dict[int, int]:
    """Returns raw cluster id -> merged cluster id."""
    label = {k: k for k in clusters}
    live = {k: dict(v) for k, v in clusters.items()}

    def fold(src: int, dst: int) -> None:
        a, b = live[src], live[dst]
        live[dst] = {"dur": a["dur"] + b["dur"], "emb": unit(a["emb"] * a["dur"] + b["emb"] * b["dur"])}
        del live[src]
        for k, v in label.items():
            if v == src:
                label[k] = dst

    def best_partner(k: int) -> tuple[int | None, float]:
        others = [(float(live[k]["emb"] @ live[o]["emb"]), o) for o in live if o != k]
        if not others:
            return None, -1.0
        s, o = max(others)
        return o, s

    small = policy.get("small")
    if small:
        for k in sorted(list(live), key=lambda k: live[k]["dur"]):
            if k in live and live[k]["dur"] < small and len(live) > 1:
                o, _ = best_partner(k)
                if o is not None:
                    fold(k, o)
    t = policy.get("sim")
    if t is not None:
        while len(live) > 1:
            ks = list(live)
            best = (-2.0, None, None)
            for i in range(len(ks)):
                for j in range(i + 1, len(ks)):
                    s = float(live[ks[i]]["emb"] @ live[ks[j]]["emb"])
                    if s > best[0]:
                        best = (s, ks[i], ks[j])
            if best[0] < t:
                break
            a, b = best[1], best[2]
            src, dst = (a, b) if live[a]["dur"] < live[b]["dur"] else (b, a)
            fold(src, dst)
    if policy.get("cap") and cap is not None:
        while len(live) > max(1, cap):
            k = min(live, key=lambda k: live[k]["dur"])
            o, _ = best_partner(k)
            if o is None:
                break
            fold(k, o)
    return label


POLICIES = {
    "none": {},
    "sim@0.5": {"sim": 0.5},
    "sim@0.6": {"sim": 0.6},
    "sim@0.7": {"sim": 0.7},
    "cap": {"cap": True},
    "sim@0.6+cap": {"sim": 0.6, "cap": True},
    "sim@0.7+cap": {"sim": 0.7, "cap": True},
    "small@5+sim@0.6+cap": {"small": 5.0, "sim": 0.6, "cap": True},
    "small@10+sim@0.6+cap": {"small": 10.0, "sim": 0.6, "cap": True},
    "small@10+sim@0.7+cap": {"small": 10.0, "sim": 0.7, "cap": True},
    "small@3 (no calendar)": {"small": 3.0},
    "small@5 (no calendar)": {"small": 5.0},
    "small@8 (no calendar)": {"small": 8.0},
    # No calendar match: the fallback has only talk time and voice similarity.
    "small@5+sim@0.6 (no calendar)": {"small": 5.0, "sim": 0.6},
    "small@5+sim@0.5 (no calendar)": {"small": 5.0, "sim": 0.5},
    "small@10+sim@0.5 (no calendar)": {"small": 10.0, "sim": 0.5},
    "small@5+sim@0.55 (no calendar)": {"small": 5.0, "sim": 0.55},
}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", default="thr070")
    ap.add_argument("--sets", nargs="*", default=["p0-A", "p0-B", "p0-C", "p0-E"])
    args = ap.parse_args()
    lines = [f"# Merge replay on raw clusters ({args.tag})", "",
             "| policy | " + " | ".join(f"{s}: rows / exact / missed / merged-row mtgs / words" for s in args.sets) + " |",
             "|---|" + "---|" * len(args.sets)]
    for name, pol in POLICIES.items():
        cells = []
        for s in args.sets:
            set_dir = ROOT / "sim" / s
            scored = []
            for m in json.load(open(set_dir / "series.json"))["meetings"]:
                d = set_dir / m["id"]
                f = d / f"emb_raw-{args.tag}.json"
                if not f.exists():
                    continue
                dump = json.load(open(f))
                truth = json.load(open(d / "truth.json"))
                cal = json.load(open(d / "calendar.json"))
                n = invite_size(cal)
                cap = (n + (1 if n >= 3 else 0)) if n else None
                label = merge(clusters_of(dump), pol, cap)
                merged = {"segments": [{"speaker": label.get(x["speaker"], x["speaker"]), "start": x["start"],
                                        "end": x["end"]} for x in dump["segments"]]}
                scored.append(score_meeting(truth, e2e_as_lab(truth, merged)))
            summ = summarize(scored)
            c = summ[list(summ)[0]]["system"]
            cells.append(f"{c['rows_mean']:.1f} / {c['exact_pct']:.0f}% / {c['missed_total']} / "
                         f"{c['any_blend_pct']:.0f}% / {100 * c['who_said_what_mean']:.1f}%")
        lines.append(f"| {name} | " + " | ".join(cells) + " |")
    text = "\n".join(lines) + "\n"
    out = ROOT / "sim" / f"merge_replay_{args.tag}.md"
    out.write_text(text)
    print(text)


if __name__ == "__main__":
    main()
