#!/usr/bin/env python3
"""Answer-key audit, part 5: how much the yodas labels flatter the two models that made them.

yodas speaker groups came from TitaNet-large + CAM++ (common_advanced) agreeing, and every clip
was re-checked against its video's voice with both. So those two should look better on yodas than
their standing on the human-labeled sets predicts. This measures that.

Per (model, set), on clean clips with centered cosine: EER and TAR at FAR 1e-3 over every
cross-session same-speaker pair (targets) and every different-speaker pair (non-targets). No
sampling, so all models see exactly the same trials.

Standing = log(EER) minus the median log(EER) of the models scored on the same set, so
it's comparable across sets. bias = standing on yodas - mean standing on the human sets the model
has; negative = the model looks better on yodas than on human labels. The labelers' excess is
their bias minus the median bias of the other models.

Writes VP/results/audit/bias.json and bias.csv.
"""
from __future__ import annotations

import os

for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_k] = "3"

import csv  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audit_labels import LABELERS, SetData, family, load_emb, prep  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
VP = REPO / "data" / "eval" / "voiceprint"
OUT = VP / "results" / "audit"
HUMAN = ("vox1o", "libri", "ami", "icsi")


def scores(d: SetData, emb: dict):
    have = np.asarray([i in emb for i in d.ids])
    if have.mean() < 0.98:
        return None
    idx = np.flatnonzero(have)
    E = prep(np.stack([emb[d.ids[k]] for k in idx]))
    S = E @ E.T
    si, sei = d.si[idx], d.sei[idx]
    iu = np.triu_indices(len(idx), 1)
    same = si[iu[0]] == si[iu[1]]
    xs = sei[iu[0]] != sei[iu[1]]
    s = S[iu]
    return s[same & xs], s[~same]


def metrics(tar: np.ndarray, non: np.ndarray) -> dict:
    s = np.concatenate([tar, non])
    y = np.concatenate([np.ones(len(tar)), np.zeros(len(non))])
    o = np.argsort(-s, kind="stable")
    y = y[o]
    tp = np.cumsum(y) / len(tar)
    fp = np.cumsum(1 - y) / len(non)
    fnr = 1 - tp
    i = int(np.argmin(np.abs(fnr - fp)))
    eer = float((fnr[i] + fp[i]) / 2)
    ok = fp <= 1e-3
    tar3 = float(tp[ok].max()) if ok.any() else 0.0
    return {"eer": eer, "tar@1e-3": tar3, "n_tar": int(len(tar)), "n_non": int(len(non))}


def main() -> int:
    models = sorted({p.name for p in (VP / "emb").iterdir() if p.is_dir()} |
                    {p.name for p in (OUT / "emb").glob("*") if p.is_dir()})
    res: dict[str, dict[str, dict]] = {}
    for s in HUMAN + ("yodas",):
        d = SetData(s)
        for m in models:
            e = load_emb(m, s)
            if e is None:
                continue
            sc = scores(d, e)
            if sc is None:
                continue
            res.setdefault(m, {})[s] = metrics(*sc)
            print(f"{s} {m}: EER {res[m][s]['eer']*100:.2f}% TAR@1e-3 {res[m][s]['tar@1e-3']*100:.1f}%", flush=True)
    # the pool: models scored on yodas and on every human set both labelers have, so every model is
    # compared on the same sets against the same reference crowd
    common = [s for s in HUMAN if all(s in res.get(m, {}) for m in LABELERS)] or list(HUMAN)
    pool = [m for m in res if "yodas" in res[m] and all(s in res[m] for s in common)
            and not m.startswith("speechbrain-xvector")]
    print("human sets used:", common, "pool:", len(pool), flush=True)

    def val(m, s, metric):
        v = res[m][s]["eer"] if metric == "eer" else 1.0 - res[m][s]["tar@1e-3"]
        return float(np.log(max(v, 1e-4)))
    rows = []
    base = {}
    stand = {}
    for metric in ("eer", "miss@1e-3"):
        st = {m: {} for m in pool}
        for s in common + ["yodas"]:
            med = float(np.median([val(m, s, metric) for m in pool]))
            for m in pool:
                st[m][s] = val(m, s, metric) - med
        stand[metric] = st
        bias = {m: st[m]["yodas"] - float(np.mean([st[m][s] for s in common])) for m in pool}
        others = [bias[m] for m in pool if family(m) not in ("nemo", "campplus")]
        base[metric] = float(np.median(others)) if others else 0.0
        for m in pool:
            r = next((x for x in rows if x["model"] == m), None)
            if r is None:
                r = {"model": m, "family": family(m), "labeler": m in LABELERS, "human_sets": " ".join(common),
                     **{f"eer_{s}": round(res[m][s]["eer"] * 100, 2) for s in common + ["yodas"]},
                     **{f"tar3_{s}": round(res[m][s]["tar@1e-3"] * 100, 1) for s in common + ["yodas"]}}
                rows.append(r)
            r[f"{metric}_human_standing"] = round(float(np.mean([st[m][s] for s in common])), 3)
            r[f"{metric}_yodas_standing"] = round(st[m]["yodas"], 3)
            r[f"{metric}_bias"] = round(bias[m], 3)
            r[f"{metric}_excess"] = round(bias[m] - base[metric], 3)
            r[f"{metric}_yodas_multiplier_vs_expected"] = round(float(np.exp(bias[m] - base[metric])), 2)
    rows.sort(key=lambda r: r["eer_bias"])
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(OUT / "bias.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)
    (OUT / "bias.json").write_text(json.dumps({"metrics": res, "standing": stand, "rows": rows, "pool": pool,
                                               "median_bias_non_labeler_families": base, "human_sets_used": common}, indent=1))
    for r in rows:
        print(f"{r['model']:45s} EER x{r['eer_yodas_multiplier_vs_expected']:<5} miss@1e-3 x{r['miss@1e-3_yodas_multiplier_vs_expected']:<5} "
              f"EER human {' '.join(str(r[f'eer_{s}']) for s in common)} yodas {r['eer_yodas']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
