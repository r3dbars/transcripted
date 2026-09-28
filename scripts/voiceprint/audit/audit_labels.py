#!/usr/bin/env python3
"""Answer-key audit, parts 2, 3 (embedding side) and 5: label errors by model consensus, second
talkers, embedding near-duplicates, and the yodas labeler bias.

Reads VP/emb/<model>/<set>__clean.npz for every model that has it. Everything is done on
L2-normalized, set-mean-centered, re-normalized embeddings ("centered cosine"), so models with
squashed raw cosines behave.

Per set:
  strength   quick clean EER per model (cross-session targets vs all different-speaker pairs), used
             to choose the consensus panel (strong and diverse; the yodas labelers TitaNet-large and
             CAM++ common-advanced are never on the yodas panel)
  clip       for each clip of a speaker with 2+ sessions: centroids of every speaker built from
             clips *outside the clip's own session* (so nobody gets a same-channel advantage), and
             margin = cos(own) - max cos(other). A clip is suspect when the panel puts it closer to
             another speaker. "norm_margin" = margin / the model's median margin on the set.
  session    same, one step up: a session's centroid vs its speaker's other sessions and every
             other speaker
  outlier    clips unusually far from their own speaker (possible second talker / wrong voice):
             z-score of cos(own cross-session centroid) within the speaker, per model
  twins      cross-speaker session pairs whose centroids are as close as typical same-speaker
             cross-session pairs under every panel model (possible one person under two ids)
  neardup    cross-session pairs (any speakers) with centered cosine > 0.97 under 2+ panel models
Bias:
  EER per model per set; for yodas, how much better the two labeler models do there than their
  human-set standing predicts.

Writes VP/results/audit/labels/<set>_{clips,sessions,twins,neardup}.csv and labels/summary.json.

  VP/venv/bin/python scripts/voiceprint/audit/audit_labels.py [--sets ...] [--panel m1,m2,...]
"""
from __future__ import annotations

import os

for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_k] = "3"

import argparse  # noqa: E402
import collections  # noqa: E402
import csv  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
OUT = VP / "results" / "audit" / "labels"
SETS = ("vox1o", "libri", "ami", "icsi", "yodas")
LABELERS = ("titanet-large", "3dspeaker-campplus-zh-en-common-advanced")
# preferred panel members, strongest/most diverse first; the first PANEL_SIZE available (and strong) are used
PREFERRED = (
    "wespeaker-resnet293-lm", "redimnet2-b6-vox2-lm", "redimnet2-b6-vb2-vox2-cnc2-lm", "titanet-large",
    "3dspeaker-eres2net-en-voxceleb", "ecapa2", "3dspeaker-campplus-zh-en-common-advanced",
    "wespeaker-resnet221-lm", "redimnet-b6-vox2-lm", "redimnet2-b3-vb2-vox2-cnc2-lm", "redimnet2-b4-vox2-lm",
    "app-wespeaker-coreml", "wespeaker-resnet34-lm", "speechbrain-ecapa-vox", "redimnet2-b2-vox2-lm",
    "3dspeaker-eres2netv2-zh-cn-common", "wespeaker-campplus-lm",
)
def family(m: str) -> str:
    """Architecture family: the panel takes at most one model per family, so near-copies can't fake
    a consensus."""
    if m.startswith("redimnet"):
        return "redimnet"
    if m.startswith("wespeaker-resnet") or m == "app-wespeaker-coreml":
        return "resnet"
    if "campplus" in m:
        return "campplus"
    if "eres2net" in m:
        return "eres2net"
    if m.startswith("titanet") or m == "speakernet":
        return "nemo"
    if "ecapa" in m:
        return "ecapa"
    if m.startswith(("wavlm", "unispeech")):
        return "ssl"
    return m


PANEL_SIZE = 5
NEARDUP = 0.97


def load_rows(s: str) -> list[dict]:
    return [json.loads(l) for l in open(VP / "sets" / s / "segments.jsonl") if l.strip()]


def load_emb(model: str, s: str, cond: str = "clean") -> dict[str, np.ndarray] | None:
    p = VP / "emb" / model / f"{s}__{cond}.npz"
    if not p.exists():
        p = VP / "results" / "audit" / "emb" / model / f"{s}__{cond}.npz"     # audit-only runs (audit_embed.py)
    if not p.exists():
        return None
    try:
        z = np.load(p, allow_pickle=False)
        ids = [str(x) for x in z["seg_id"]]
        return dict(zip(ids, z["emb"].astype(np.float64)))
    except Exception:
        return None


def prep(E: np.ndarray) -> np.ndarray:
    E = E / (np.linalg.norm(E, axis=1, keepdims=True) + 1e-12)
    E = E - E.mean(axis=0, keepdims=True)
    return E / (np.linalg.norm(E, axis=1, keepdims=True) + 1e-12)


def eer(tar: np.ndarray, non: np.ndarray) -> float:
    s = np.concatenate([tar, non])
    y = np.concatenate([np.ones(len(tar)), np.zeros(len(non))])
    o = np.argsort(-s, kind="stable")
    y = y[o]
    tp = np.cumsum(y) / max(1, len(tar))
    fp = np.cumsum(1 - y) / max(1, len(non))
    fnr = 1 - tp
    i = int(np.argmin(np.abs(fnr - fp)))
    return float((fnr[i] + fp[i]) / 2)


class SetData:
    def __init__(self, s: str):
        self.s = s
        self.rows = load_rows(s)
        self.ids = [r["seg_id"] for r in self.rows]
        self.spk = np.asarray([r["speaker"] for r in self.rows])
        self.ses = np.asarray([r["session"] for r in self.rows])
        self.bucket = np.asarray([r["bucket"] for r in self.rows])
        sess_per = collections.defaultdict(set)
        for r in self.rows:
            sess_per[r["speaker"]].add(r["session"])
        self.multi = np.asarray([len(sess_per[r["speaker"]]) >= 2 for r in self.rows])
        self.speakers = sorted(sess_per)
        self.spk_idx = {s_: i for i, s_ in enumerate(self.speakers)}
        self.si = np.asarray([self.spk_idx[x] for x in self.spk])
        sessions = sorted(set(self.ses))
        self.ses_idx = {s_: i for i, s_ in enumerate(sessions)}
        self.sei = np.asarray([self.ses_idx[x] for x in self.ses])
        self.sessions = sessions

    def matrix(self, emb: dict) -> tuple[np.ndarray, np.ndarray]:
        have = np.asarray([i in emb for i in self.ids])
        E = np.zeros((len(self.ids), len(next(iter(emb.values())))))
        for k, i in enumerate(self.ids):
            if i in emb:
                E[k] = emb[i]
        E[have] = prep(E[have])
        return E, have


def model_eer(d: SetData, E: np.ndarray, have: np.ndarray) -> float:
    idx = np.flatnonzero(have)
    S = E[idx] @ E[idx].T
    si, sei = d.si[idx], d.sei[idx]
    iu = np.triu_indices(len(idx), 1)
    same = si[iu[0]] == si[iu[1]]
    xs = sei[iu[0]] != sei[iu[1]]
    multi = d.multi[idx][iu[0]]
    s = S[iu]
    return eer(s[same & xs & multi], s[~same])


def xsess_centroids(d: SetData, E: np.ndarray, have: np.ndarray):
    """For every session q: centroid of every speaker using clips NOT in q. Returns sums/counts per
    speaker overall and per (speaker, session) so centroids can be built quickly."""
    nS, nQ = len(d.speakers), len(d.sessions)
    D = E.shape[1]
    tot = np.zeros((nS, D))
    cnt = np.zeros(nS)
    per = collections.defaultdict(lambda: np.zeros(D))
    perc = collections.Counter()
    for k in np.flatnonzero(have):
        tot[d.si[k]] += E[k]
        cnt[d.si[k]] += 1
        per[(d.si[k], d.sei[k])] += E[k]
        perc[(d.si[k], d.sei[k])] += 1
    return tot, cnt, per, perc


def clip_margins(d: SetData, E: np.ndarray, have: np.ndarray):
    tot, cnt, per, perc = xsess_centroids(d, E, have)
    n = len(d.ids)
    margin = np.full(n, np.nan)
    own_cos = np.full(n, np.nan)
    best_other = np.full(n, np.nan)
    best_other_spk = np.full(n, -1)
    rank = np.full(n, -1)
    # group by session for speed: the "outside session q" centroids are the same for every clip in q
    for q in range(len(d.sessions)):
        members = np.flatnonzero((d.sei == q) & have)
        if len(members) == 0:
            continue
        T = tot.copy()
        C = cnt.copy()
        for (si, qi), v in per.items():
            if qi == q:
                T[si] -= v
                C[si] -= perc[(si, qi)]
        ok = C > 0
        cen = np.zeros_like(T)
        cen[ok] = T[ok] / C[ok, None]
        cen[ok] /= np.linalg.norm(cen[ok], axis=1, keepdims=True) + 1e-12
        sims = E[members] @ cen.T                        # [m, nS]
        sims[:, ~ok] = -np.inf
        for j, k in enumerate(members):
            own = d.si[k]
            if not ok[own]:
                continue
            row = sims[j].copy()
            oc = row[own]
            row[own] = -np.inf
            bo = int(np.argmax(row))
            own_cos[k] = oc
            best_other[k] = row[bo]
            best_other_spk[k] = bo
            margin[k] = oc - row[bo]
            rank[k] = int(np.sum(sims[j] > oc))            # 0 = own speaker is the nearest
    return margin, own_cos, best_other, best_other_spk, rank


def session_margins(d: SetData, E: np.ndarray, have: np.ndarray):
    tot, cnt, per, perc = xsess_centroids(d, E, have)
    out = {}
    for (si, qi), v in per.items():
        T = tot.copy()
        C = cnt.copy()
        for (sj, qj), w in per.items():
            if qj == qi:
                T[sj] -= w
                C[sj] -= perc[(sj, qj)]
        ok = C > 0
        if not ok[si]:
            continue
        cen = np.zeros_like(T)
        cen[ok] = T[ok] / C[ok, None]
        cen[ok] /= np.linalg.norm(cen[ok], axis=1, keepdims=True) + 1e-12
        sc = v / (np.linalg.norm(v) + 1e-12)
        sims = cen @ sc
        sims[~ok] = -np.inf
        oc = sims[si]
        sims2 = sims.copy()
        sims2[si] = -np.inf
        bo = int(np.argmax(sims2))
        out[(si, qi)] = (float(oc), float(sims2[bo]), bo, int(perc[(si, qi)]))
    return out


def session_centroids(d: SetData, E: np.ndarray, have: np.ndarray):
    keys = sorted({(d.si[k], d.sei[k]) for k in np.flatnonzero(have)})
    C = np.zeros((len(keys), E.shape[1]))
    for n_, (si, qi) in enumerate(keys):
        m = (d.si == si) & (d.sei == qi) & have
        v = E[m].mean(axis=0)
        C[n_] = v / (np.linalg.norm(v) + 1e-12)
    return keys, C


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys or ["none"])
        w.writeheader()
        w.writerows(rows)


def choose_panel(s: str, eers: dict[str, float], forced: list[str] | None) -> list[str]:
    if forced:
        return [m for m in forced if m in eers and not (s == "yodas" and m in LABELERS)]
    # on yodas, keep the labelers' whole families (NeMo, CAM++) off the panel: they share its bias
    avail = [m for m in eers if not (s == "yodas" and family(m) in ("nemo", "campplus")) and not m.startswith("speechbrain-xvector")]
    best = min(eers[m] for m in avail) if avail else 0
    panel, fams = [], set()
    for m in sorted(avail, key=lambda m: eers[m]):
        if eers[m] > max(2.5 * best, best + 0.03):      # too weak to vote
            continue
        f = family(m)
        if f in fams:
            continue
        panel.append(m)
        fams.add(f)
        if len(panel) >= PANEL_SIZE:
            break
    return panel


def audit_set(s: str, forced_panel: list[str] | None, all_models: list[str]) -> dict:
    d = SetData(s)
    embs = {}
    for m in all_models:
        e = load_emb(m, s)
        if e is not None and len(e) >= 0.98 * len(d.ids):
            embs[m] = e
    mats = {m: d.matrix(e) for m, e in embs.items()}
    eers = {m: model_eer(d, *mats[m]) for m in mats}
    panel = choose_panel(s, eers, forced_panel)
    print(f"{s}: models with clean emb {len(mats)}; EER " + ", ".join(f"{m}={eers[m]:.3f}" for m in sorted(eers, key=eers.get)), flush=True)
    print(f"{s}: panel {panel}", flush=True)
    res = {"set": s, "eer": eers, "panel": panel}
    if len(panel) < 3:
        res["note"] = "fewer than 3 strong panel models; consensus not computed"
        return res

    # ---------------- clip-level consensus
    per_model = {}
    for m in panel:
        E, have = mats[m]
        mg, oc, bo, bos, rk = clip_margins(d, E, have)
        med = np.nanmedian(mg[d.multi])
        per_model[m] = {"margin": mg, "norm": mg / med if med > 0 else mg, "own": oc, "other": bo, "other_spk": bos, "rank": rk}
    clip_rows = []
    n_neg_all = []
    for k, r in enumerate(d.rows):
        if not d.multi[k]:
            continue
        neg = [m for m in panel if per_model[m]["margin"][k] < 0]
        vals = {m: per_model[m]["norm"][k] for m in panel}
        other_votes = collections.Counter(per_model[m]["other_spk"][k] for m in neg)
        top_other = d.speakers[other_votes.most_common(1)[0][0]] if other_votes else ""
        n_neg_all.append(len(neg))
        if len(neg) >= 1:
            clip_rows.append({
                "seg_id": r["seg_id"], "speaker": r["speaker"], "session": r["session"], "bucket": r["bucket"],
                "n_models_closer_to_other": len(neg), "panel": len(panel),
                "closest_other_speaker": top_other,
                "other_same_session_group": "",
                "max_norm_margin": round(max(vals.values()), 3), "min_norm_margin": round(min(vals.values()), 3),
                **{f"nm_{m}": round(float(vals[m]), 3) for m in panel},
            })
    n_neg_all = np.asarray(n_neg_all)
    write_csv(OUT / f"{s}_clips.csv", sorted(clip_rows, key=lambda r: (-r["n_models_closer_to_other"], r["max_norm_margin"])))
    res["clips_scored"] = int(d.multi.sum())
    res["clips_closer_to_other"] = {f"{k}_of_{len(panel)}": int((n_neg_all >= k).sum()) for k in range(1, len(panel) + 1)}
    for m in panel:
        res.setdefault("per_model_clip_errors", {})[m] = int((per_model[m]["margin"][d.multi] < 0).sum())

    # ---------------- outliers (possible second talker): own-centroid similarity z within speaker
    z_all = {}
    for m in panel:
        oc = per_model[m]["own"]
        z = np.full(len(oc), np.nan)
        for si in range(len(d.speakers)):
            mm = (d.si == si) & ~np.isnan(oc)
            if mm.sum() >= 5:
                v = oc[mm]
                med = np.median(v)
                mad = np.median(np.abs(v - med)) * 1.4826 + 1e-6
                z[mm] = (v - med) / mad
        z_all[m] = z
    Z = np.stack([z_all[m] for m in panel], axis=1)
    zmax = np.nanmax(Z, axis=1)       # least-extreme model
    out_rows = []
    for k in np.flatnonzero(zmax < -3.0):
        out_rows.append({"seg_id": d.ids[k], "speaker": d.spk[k], "session": d.ses[k], "bucket": int(d.bucket[k]),
                         "z_least_extreme": round(float(zmax[k]), 2),
                         **{f"z_{m}": round(float(z_all[m][k]), 2) for m in panel}})
    write_csv(OUT / f"{s}_outliers.csv", sorted(out_rows, key=lambda r: r["z_least_extreme"]))
    res["outliers_all_models_z_below_-3"] = len(out_rows)
    res["outliers_by_bucket"] = dict(collections.Counter(r["bucket"] for r in out_rows))

    # ---------------- session-level
    sess_model = {m: session_margins(d, *mats[m]) for m in panel}
    sess_rows = []
    keys = sorted(set.intersection(*[set(v) for v in sess_model.values()]))
    for key in keys:
        vals = {m: sess_model[m][key] for m in panel}
        neg = [m for m in panel if vals[m][0] < vals[m][1]]
        margins = {m: vals[m][0] - vals[m][1] for m in panel}
        row = {"speaker": d.speakers[key[0]], "session": d.sessions[key[1]], "clips": vals[panel[0]][3],
               "n_models_closer_to_other": len(neg),
               "closest_other": collections.Counter(d.speakers[vals[m][2]] for m in panel).most_common(1)[0][0],
               **{f"margin_{m}": round(margins[m], 3) for m in panel}}
        sess_rows.append(row)
    write_csv(OUT / f"{s}_sessions.csv", sorted(sess_rows, key=lambda r: (-r["n_models_closer_to_other"], min(r[f"margin_{m}"] for m in panel))))
    res["sessions_scored"] = len(sess_rows)
    res["sessions_closer_to_other"] = {f"{k}_of_{len(panel)}": sum(r["n_models_closer_to_other"] >= k for r in sess_rows) for k in range(1, len(panel) + 1)}

    # ---------------- twins: cross-speaker session pairs as close as same-speaker cross-session pairs
    tw = {}
    thr = {}
    for m in panel:
        E, have = mats[m]
        keys_s, C = session_centroids(d, E, have)
        S = C @ C.T
        spk_k = np.asarray([k[0] for k in keys_s])
        ses_k = np.asarray([k[1] for k in keys_s])
        iu = np.triu_indices(len(keys_s), 1)
        same = spk_k[iu[0]] == spk_k[iu[1]]
        xs = ses_k[iu[0]] != ses_k[iu[1]]
        tvals = S[iu][same & xs]
        thr[m] = float(np.percentile(tvals, 10)) if len(tvals) else 1.0     # 10th pct of true same-person
        diff = ~same
        sel = diff & (S[iu] >= thr[m])
        for a, b, v in zip(iu[0][sel], iu[1][sel], S[iu][sel]):
            ka, kb = keys_s[a], keys_s[b]
            key = tuple(sorted([(d.speakers[ka[0]], d.sessions[ka[1]]), (d.speakers[kb[0]], d.sessions[kb[1]])]))
            tw.setdefault(key, {})[m] = float(v)
    twin_rows = []
    for key, v in tw.items():
        if len(v) >= len(panel) - 1:
            twin_rows.append({"a_speaker": key[0][0], "a_session": key[0][1], "b_speaker": key[1][0], "b_session": key[1][1],
                              "same_session": key[0][1] == key[1][1],
                              "n_models": len(v), **{f"cos_{m}": round(v.get(m, float('nan')), 3) for m in panel}})
    write_csv(OUT / f"{s}_twins.csv", sorted(twin_rows, key=lambda r: -r["n_models"]))
    res["twin_threshold_p10_same_person"] = {m: round(v, 3) for m, v in thr.items()}
    res["twin_session_pairs"] = {"all_panel": sum(r["n_models"] == len(panel) for r in twin_rows),
                                 "panel_minus_one": len(twin_rows),
                                 "cross_session_only": sum((not r["same_session"]) and r["n_models"] == len(panel) for r in twin_rows)}
    twin_spk = collections.Counter(tuple(sorted((r["a_speaker"], r["b_speaker"]))) for r in twin_rows if r["n_models"] == len(panel) and not r["same_session"])
    res["twin_speaker_pairs"] = [f"{a}~{b}:{c}" for (a, b), c in twin_spk.most_common(30)]

    # ---------------- embedding near-duplicates across sessions (all models with emb, report panel votes)
    nd = collections.defaultdict(dict)
    for m in mats:
        E, have = mats[m]
        idx = np.flatnonzero(have)
        S = E[idx] @ E[idx].T
        iu = np.triu_indices(len(idx), 1)
        sel = (S[iu] > NEARDUP) & (d.sei[idx][iu[0]] != d.sei[idx][iu[1]])
        for a, b, v in zip(idx[iu[0][sel]], idx[iu[1][sel]], S[iu][sel]):
            nd[(int(a), int(b))][m] = float(v)
    nd_rows = []
    for (a, b), v in nd.items():
        nd_rows.append({"a": d.ids[a], "b": d.ids[b], "same_speaker": d.spk[a] == d.spk[b], "n_models": len(v),
                        "n_panel": sum(m in v for m in panel), "models": " ".join(f"{m}={x:.3f}" for m, x in sorted(v.items()))})
    write_csv(OUT / f"{s}_neardup.csv", sorted(nd_rows, key=lambda r: (-r["n_models"])))
    res["neardup_pairs_2plus_models"] = sum(r["n_models"] >= 2 for r in nd_rows)
    res["neardup_pairs_any"] = len(nd_rows)
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default=",".join(SETS))
    ap.add_argument("--panel", default="")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    all_models = sorted({p.name for p in (VP / "emb").iterdir() if p.is_dir()} |
                        {p.name for p in (VP / "results" / "audit" / "emb").glob("*") if p.is_dir()})
    summ_path = OUT / "summary.json"
    summary = json.loads(summ_path.read_text()) if summ_path.exists() else {}
    for s in [x for x in args.sets.split(",") if x]:
        summary[s] = audit_set(s, [m for m in args.panel.split(",") if m] or None, all_models)
        summ_path.write_text(json.dumps(summary, indent=1))
        print(json.dumps({k: v for k, v in summary[s].items() if k not in ("eer",)}, indent=1), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
