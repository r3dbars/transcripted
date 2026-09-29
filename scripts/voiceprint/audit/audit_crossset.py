#!/usr/bin/env python3
"""Answer-key audit, extra: the same person in two sets?

yodas is the AS-norm cohort for every human set, and each set's impostors are assumed to be
strangers to its targets. A person who shows up in two sets (a VoxCeleb celebrity in a YODAS
video, a LibriVox reader on YouTube) quietly breaks that. For every pair of sets, compare speaker
centroids (centered cosine) and flag pairs that every model scores at or above the 10th
percentile of that model's same-person cross-session centroid similarity.

Writes VP/results/audit/crossset.csv.
"""
from __future__ import annotations

import os

os.environ.setdefault("OMP_NUM_THREADS", "3")

import csv  # noqa: E402
import sys  # noqa: E402
from itertools import combinations  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_labels import SetData, load_emb  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "data" / "eval" / "voiceprint" / "results" / "audit"
SETS = ("vox1o", "libri", "ami", "icsi", "yodas")


def main() -> int:
    models = [m for m in sys.argv[1].split(",")] if len(sys.argv) > 1 else \
        ["redimnet2-b2-vox2-lm", "app-wespeaker-coreml", "3dspeaker-eres2net-en-voxceleb"]
    data = {s: SetData(s) for s in SETS}
    cents, thr = {}, {}
    for m in models:
        allE, keys = [], []
        for s, d in data.items():
            e = load_emb(m, s)
            if e is None:
                print(f"{m} has no {s}; skipping model")
                allE = None
                break
            E = np.stack([e[i] for i in d.ids])
            E /= np.linalg.norm(E, axis=1, keepdims=True)
            allE.append(E)
            keys.append(s)
        if allE is None:
            continue
        mu = np.concatenate(allE).mean(axis=0)
        tvals = []
        for s, E in zip(keys, allE):
            d = data[s]
            E = E - mu
            E /= np.linalg.norm(E, axis=1, keepdims=True)
            for si, sp in enumerate(d.speakers):
                v = E[d.si == si].mean(axis=0)
                cents.setdefault(m, {})[(s, sp)] = v / np.linalg.norm(v)
                # same-person cross-session reference: centroid of one session vs the rest
                ses = sorted(set(d.sei[d.si == si]))
                if len(ses) >= 2:
                    a = E[(d.si == si) & (d.sei == ses[0])].mean(axis=0)
                    b = E[(d.si == si) & (d.sei != ses[0])].mean(axis=0)
                    tvals.append(float(a @ b / np.linalg.norm(a) / np.linalg.norm(b)))
        thr[m] = float(np.percentile(tvals, 10))
    ms = list(cents)
    rows = []
    for s1, s2 in combinations(SETS, 2):
        k1 = [k for k in cents[ms[0]] if k[0] == s1]
        k2 = [k for k in cents[ms[0]] if k[0] == s2]
        sims = {m: np.stack([cents[m][k] for k in k1]) @ np.stack([cents[m][k] for k in k2]).T for m in ms}
        ok = np.ones_like(sims[ms[0]], dtype=bool)
        for m in ms:
            ok &= sims[m] >= thr[m]
        for i, j in zip(*np.nonzero(ok)):
            rows.append({"a": k1[i][1], "b": k2[j][1], **{f"cos_{m}": round(float(sims[m][i, j]), 3) for m in ms}})
        top = max(float(np.min([sims[m][i, j] - thr[m] for m in ms])) for i in range(len(k1)) for j in range(len(k2)))
        print(f"{s1} x {s2}: {int(ok.sum())} speaker pairs above every model's same-person p10; closest margin {top:+.3f}")
    with open(OUT / "crossset.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["a", "b"] + [f"cos_{m}" for m in ms])
        w.writeheader()
        w.writerows(rows)
    print("thresholds", {m: round(v, 3) for m, v in thr.items()})
    return 0


if __name__ == "__main__":
    sys.exit(main())
