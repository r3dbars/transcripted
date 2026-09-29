"""SpeechBrain speaker-embedding runtime (ECAPA-TDNN, ResNet, x-vector).

Embedder(model_dir, meta, threads) -> .embed(wav) -> 1-D float32.

model_dir is a local snapshot of the HF repo (hyperparams.yaml plus the .ckpt
files). Loading is fully offline: the hyperparams `pretrained_path` is
overridden to the local dir, so nothing is fetched at embed time.

meta keys used (all optional):
  device   "cpu" (default) or "mps"
Embeddings come back raw (not length-normalized) so the coordinator can decide.
"""
from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

import numpy as np

# This file is named speechbrain.py, but it lives inside the `runtimes` package
# directory, so `import speechbrain` resolves to the real library unless
# runtimes/ itself is on sys.path. Guard against that shadowing.
import sys as _sys

_here = str(Path(__file__).resolve().parent)
_saved = list(_sys.path)
_sys.path[:] = [p for p in _sys.path if os.path.abspath(p or ".") != _here]
try:
    import torch
    from speechbrain.inference.speaker import EncoderClassifier
finally:
    _sys.path[:] = _saved


class Embedder:
    def __init__(self, model_dir, meta: dict | None = None, threads: int = 3):
        meta = meta or {}
        model_dir = Path(model_dir)
        torch.set_num_threads(int(threads))
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:
            pass  # already set in this process
        self.device = meta.get("device", "cpu")
        if self.device == "mps" and not torch.backends.mps.is_available():
            self.device = "cpu"
        self.model_dir = model_dir
        self.dim = int(meta.get("dim", 0)) or None
        self.model = EncoderClassifier.from_hparams(
            source=str(model_dir),
            savedir=str(model_dir),
            overrides={"pretrained_path": str(model_dir)},
            run_opts={"device": self.device},
        )
        self.model.eval()

    def embed(self, wav: np.ndarray) -> np.ndarray:
        x = np.ascontiguousarray(wav, dtype=np.float32).reshape(-1)
        t = torch.from_numpy(x).unsqueeze(0).to(self.device)
        with torch.inference_mode():
            emb = self.model.encode_batch(t)  # [1, 1, D]
        return emb.reshape(-1).float().cpu().numpy().astype(np.float32)
