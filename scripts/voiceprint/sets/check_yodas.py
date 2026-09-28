#!/usr/bin/env python3
"""Independent sanity check of the `yodas` set, using models that did NOT label it.

The yodas labels come from TitaNet-large + CAM++ (see build_yodas.py), so this embeds each
session with two other voiceprint models (WeSpeaker ResNet34-LM and SpeechBrain ECAPA, both
VoxCeleb-trained, via scripts/voiceprint/runtimes) and checks two things:

  1. Separation: cross-session same-speaker cosines sit well above different-speaker cosines.
  2. Possible unlabeled twins: two sessions labeled as different speakers that both models score
     as very close are probably one person the labelers missed. Prints, and writes to
     VP/sets/yodas/dupe_check.json, the strangers to drop (`drop_strangers`); build_yodas.py keeps
     that list in DROP_STRANGERS so a rebuild is reproducible.

Only read access to the set and the models. Rewrites the block between the `indep-check` markers in
VP/sets/yodas/README.md. Run with the VP venv, at most 3 threads.

  data/eval/voiceprint/venv/bin/python scripts/voiceprint/sets/check_yodas.py [--flag 0.42]
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "3")

import numpy as np
import soundfile as sf

REPO = Path(__file__).resolve().parents[3]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
MODELS = ("wespeaker-resnet34-lm", "speechbrain-ecapa-vox")
START, END = "<!-- indep-check:start -->", "<!-- indep-check:end -->"


def load_embedder(model_id: str):
    meta = json.loads((VP / "models" / model_id / "model.json").read_text())
    path = REPO / "scripts" / "voiceprint" / "runtimes" / f"{meta['runtime']}.py"
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(f"vp_rt_{meta['runtime']}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.Embedder(VP / "models" / model_id, meta, threads=3)


def session_centroids(rows: list[dict], model_id: str, per_session: int) -> tuple[list[str], np.ndarray]:
    emb = load_embedder(model_id)
    by: dict[str, list[dict]] = collections.defaultdict(list)
    for r in rows:
        by[r["session"]].append(r)
    sessions = sorted(by)
    vecs = []
    for s in sessions:
        picks = sorted(by[s], key=lambda r: (-r["bucket"], r["seg_id"]))[:per_session]
        vecs.append(np.array([np.asarray(emb.embed(sf.read(VP / r["clip"], dtype="float32")[0]), dtype=np.float32)
                              for r in picks]))
    mu = np.concatenate(vecs).mean(axis=0)
    cents = []
    for e in vecs:
        e = e - mu
        e = e / (np.linalg.norm(e, axis=1, keepdims=True) + 1e-9)
        c = e.mean(axis=0)
        cents.append(c / (np.linalg.norm(c) + 1e-9))
    return sessions, np.array(cents)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--flag", type=float, default=0.42, help="mean of the two models' session cosines that marks a probable twin")
    ap.add_argument("--per-session", type=int, default=3, help="longest clips embedded per session")
    args = ap.parse_args()
    rows = [json.loads(l) for l in (VP / "sets" / "yodas" / "segments.jsonl").read_text().splitlines() if l.strip()]
    spk = {r["session"]: r["speaker"] for r in rows}
    stranger = {r["session"]: r["stranger_only"] for r in rows}
    n_clips = collections.Counter(r["session"] for r in rows)

    t0 = time.time()
    sims, stats = {}, {}
    sessions = None
    for m in MODELS:
        ss, C = session_centroids(rows, m, args.per_session)
        assert sessions is None or sessions == ss
        sessions = ss
        sims[m] = C @ C.T
    n = len(sessions)
    same = np.array([[spk[a] == spk[b] for b in sessions] for a in sessions])
    iu = np.triu(np.ones((n, n), dtype=bool), 1)
    for m in MODELS:
        pos, neg = sims[m][iu & same], sims[m][iu & ~same]
        stats[m] = {
            "same_speaker_cross_session": {"pairs": int(len(pos)), "min": round(float(pos.min()), 2),
                                           "p10": round(float(np.percentile(pos, 10)), 2), "median": round(float(np.median(pos)), 2)},
            "different_speaker": {"pairs": int(len(neg)), "median": round(float(np.median(neg)), 2),
                                  "p99": round(float(np.percentile(neg, 99)), 2), "p99.9": round(float(np.percentile(neg, 99.9)), 2),
                                  "max": round(float(neg.max()), 2)},
        }
    mean = sum(sims.values()) / len(MODELS)
    cand = sorted(((float(mean[i, j]), i, j) for i, j in np.argwhere(iu & ~same) if mean[i, j] >= args.flag), reverse=True)
    dropped: list[str] = []
    flagged = []
    for m_, i, j in cand:
        a, b = sessions[i], sessions[j]
        flagged.append({"a": a, "b": b, "mean": round(m_, 3), **{k: round(float(sims[k][i, j]), 3) for k in MODELS},
                        "a_target": not stranger[a], "b_target": not stranger[b]})
        if a in dropped or b in dropped:
            continue
        if stranger[a] and stranger[b]:
            victim = min((a, b), key=lambda s: (n_clips[s], s))  # keep the session with more clips
        elif stranger[a] or stranger[b]:
            victim = a if stranger[a] else b
        else:
            flagged[-1]["note"] = "two targets of different speakers: kept, review by hand"
            continue
        dropped.append(victim)
    out = {"models": list(MODELS), "sessions": n, "flag_mean_cosine": args.flag, "stats": stats,
           "flagged_pairs": flagged, "drop_strangers": sorted(s.split(":", 1)[1] for s in dropped),
           "seconds": round(time.time() - t0)}
    (VP / "sets" / "yodas" / "dupe_check.json").write_text(json.dumps(out, indent=1) + "\n")

    lines = [START, "## Independent check (models that did not label the set)", "",
             f"`scripts/voiceprint/sets/check_yodas.py` embeds each session (its {args.per_session} longest clips, mean-centered) with "
             f"{' and '.join(MODELS)} (VoxCeleb-trained) and compares session centroids over {n} sessions.", ""]
    for m in MODELS:
        p, q = stats[m]["same_speaker_cross_session"], stats[m]["different_speaker"]
        lines.append(f"* `{m}`: same speaker across videos ({p['pairs']} pairs): min {p['min']}, p10 {p['p10']}, "
                     f"median {p['median']}. Different speakers ({q['pairs']} pairs): median {q['median']}, p99 {q['p99']}, "
                     f"p99.9 {q['p99.9']}, max {q['max']}.")
    spec = importlib.util.spec_from_file_location("build_yodas", Path(__file__).with_name("build_yodas.py"))
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    lines += ["", f"Probable unlabeled twins: pairs of differently-labeled sessions whose mean cosine across the two models is "
              f"{args.flag} or more. An earlier pass at this bar found {len(build.DROP_STRANGERS)} strangers to drop; they are "
              f"listed in `DROP_STRANGERS` in the build script, so a rebuild is reproducible. This pass flags {len(flagged)} pairs "
              f"(would drop {len(dropped)} more). Pruning with two candidate models removes a few hard negatives they would "
              "have scored as strangers, which slightly flatters WeSpeaker and ECAPA on this set.", END]
    readme = VP / "sets" / "yodas" / "README.md"
    text = readme.read_text()
    block = "\n".join(lines)
    if START in text and END in text:
        text = text[:text.index(START)] + block + text[text.index(END) + len(END):]
    else:
        text = text.rstrip("\n") + "\n\n" + block + "\n"
    readme.write_text(text)
    print(json.dumps({k: out[k] for k in ("stats", "drop_strangers", "seconds")}, indent=1))
    print(f"{len(flagged)} flagged pairs, {len(dropped)} strangers to drop")
    for f in flagged:
        print(f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
