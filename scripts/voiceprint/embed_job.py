#!/usr/bin/env python3
"""Embed one (model, set, condition) for the voiceprint bake-off.

Loads VP/models/<model>/model.json, imports scripts/voiceprint/runtimes/<runtime>.py,
embeds every clip of VP/sets/<set>/segments.jsonl under VP/clips/<set>/<cond>/, and
writes VP/emb/<model>/<set>__<cond>.npz (seg_id, emb) plus a .json with timing.
The .npz is written to a temp name and renamed, so a half-written file never exists.
Run by embed_daemon.py; see Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

REPO = Path(__file__).resolve().parents[2]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
RUNTIMES = Path(__file__).resolve().parent / "runtimes"


def model_signature(model_dir: Path, runtime: str) -> str:
    """Hash of model.json + the runtime module: a change to either makes old embeddings stale."""
    h = hashlib.sha1((model_dir / "model.json").read_bytes())
    h.update((RUNTIMES / f"{runtime}.py").read_bytes())
    return h.hexdigest()[:16]


def load_runtime(name: str):
    path = RUNTIMES / f"{name}.py"
    spec = importlib.util.spec_from_file_location(f"vp_runtime_{name}", path)
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(RUNTIMES))
    spec.loader.exec_module(module)
    return module


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--set", required=True)
    ap.add_argument("--cond", required=True)
    ap.add_argument("--threads", type=int, default=3)
    args = ap.parse_args()

    model_dir = VP / "models" / args.model
    meta = json.loads((model_dir / "model.json").read_text())
    rows = [json.loads(l) for l in (VP / "sets" / args.set / "segments.jsonl").read_text().splitlines() if l.strip()]
    clip_dir = VP / "clips" / args.set / args.cond

    signature = model_signature(model_dir, meta["runtime"])
    set_sig = hashlib.sha1((VP / "sets" / args.set / "segments.jsonl").read_bytes()).hexdigest()[:16]
    runtime = load_runtime(meta["runtime"])
    load_start = time.time()
    embedder = runtime.Embedder(model_dir, meta, threads=args.threads)
    load_s = time.time() - load_start

    ids, vecs, failed = [], [], []
    audio_s = 0.0
    compute_s = 0.0
    for row in rows:
        path = clip_dir / f"{row['seg_id']}.wav"
        try:
            wav, sr = sf.read(path, dtype="float32", always_2d=False)
            if wav.ndim > 1:
                wav = wav.mean(axis=1)
            if sr != 16000:
                raise ValueError(f"sample rate {sr}")
            t0 = time.perf_counter()
            vec = np.asarray(embedder.embed(wav), dtype=np.float32).reshape(-1)
            compute_s += time.perf_counter() - t0
            if not np.all(np.isfinite(vec)) or not np.any(vec):
                raise ValueError("non-finite or zero embedding")
            ids.append(row["seg_id"])
            vecs.append(vec)
            audio_s += len(wav) / 16000
        except Exception as exc:  # one bad clip must not sink the job
            failed.append({"seg_id": row["seg_id"], "error": f"{type(exc).__name__}: {exc}"[:200]})

    if not vecs:
        print(json.dumps({"error": "no clips embedded", "failed": failed[:5]}))
        return 2
    out_dir = VP / "emb" / args.model
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{args.set}__{args.cond}"
    tmp = out_dir / f".{stem}.tmp.npz"
    np.savez(tmp, seg_id=np.array(ids), emb=np.stack(vecs))
    info = {
        "model_id": args.model, "set": args.set, "cond": args.cond, "dim": int(vecs[0].shape[0]),
        "clips": len(ids), "failed": len(failed), "failed_examples": failed[:10],
        "seconds_audio": round(audio_s, 1), "seconds_compute": round(compute_s, 2),
        "ms_per_clip": round(1000 * compute_s / len(ids), 2), "load_s": round(load_s, 2),
        "model_sig": signature, "set_sig": set_sig, "threads": args.threads, "device": str(getattr(embedder, "device", "cpu")),
        "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    (out_dir / f"{stem}.json").write_text(json.dumps(info, indent=1))
    os.replace(tmp, out_dir / f"{stem}.npz")
    print(json.dumps({k: info[k] for k in ("model_id", "set", "cond", "clips", "failed", "ms_per_clip")}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
