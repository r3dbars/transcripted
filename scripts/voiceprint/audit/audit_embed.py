#!/usr/bin/env python3
"""Small, audit-only embedding runs for (model, set) pairs the daemon has not reached yet.

Writes VP/results/audit/emb/<model>/<set>__clean.npz (seg_id, emb) in the same format as VP/emb,
never VP/emb itself (that belongs to the coordinator's embed_daemon). Skips a pair when VP/emb
already has it. 3 threads.

  VP/venv/bin/python scripts/voiceprint/audit/audit_embed.py --pairs titanet-large:yodas,...
"""
from __future__ import annotations

import os

for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_k] = "3"

import argparse  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
RUNTIMES = REPO / "scripts" / "voiceprint" / "runtimes"
OUT = VP / "results" / "audit" / "emb"


def load_runtime(name: str):
    spec = importlib.util.spec_from_file_location(f"vp_runtime_{name}", RUNTIMES / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(RUNTIMES))
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", required=True, help="model:set,model:set,...")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    for pair in args.pairs.split(","):
        model, s = pair.split(":")
        if (VP / "emb" / model / f"{s}__clean.npz").exists() and not args.force:
            print(f"{pair}: already in VP/emb, skipping", flush=True)
            continue
        dst = OUT / model / f"{s}__clean.npz"
        if dst.exists() and not args.force:
            print(f"{pair}: already done", flush=True)
            continue
        meta = json.loads((VP / "models" / model / "model.json").read_text())
        emb = load_runtime(meta["runtime"]).Embedder(VP / "models" / model, meta, threads=3)
        rows = [json.loads(l) for l in open(VP / "sets" / s / "segments.jsonl") if l.strip()]
        ids, E = [], []
        t0 = time.time()
        for i, r in enumerate(rows):
            x, sr = sf.read(str(VP / "clips" / s / "clean" / f"{r['seg_id']}.wav"), dtype="float32")
            ids.append(r["seg_id"])
            E.append(emb.embed(x))
            if (i + 1) % 500 == 0:
                print(f"{pair}: {i + 1}/{len(rows)} {time.time() - t0:.0f}s", flush=True)
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(f".{dst.stem}.tmp.npz")
        np.savez(tmp, seg_id=np.asarray(ids), emb=np.stack(E).astype(np.float32))
        os.replace(tmp, dst)
        print(f"{pair}: wrote {dst} in {time.time() - t0:.0f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
