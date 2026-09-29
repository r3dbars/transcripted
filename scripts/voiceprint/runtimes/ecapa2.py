"""ECAPA2 (Jenthe/ECAPA2, TorchScript `ecapa2.pt`) runtime.

Reference only: the model card is CC BY-NC 4.0, so it can't ship in the app.
It shows how much headroom exists above the shippable models.

Embedder(model_dir, meta, threads) -> .embed(wav) -> 1-D float32 (192-d, raw).

meta keys used (all optional):
  device   "cpu" (default) or "mps"
"""
from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")

import numpy as np
import torch


class Embedder:
    def __init__(self, model_dir, meta: dict | None = None, threads: int = 3):
        meta = meta or {}
        model_dir = Path(model_dir)
        torch.set_num_threads(int(threads))
        try:
            torch.set_num_interop_threads(1)
        except RuntimeError:
            pass
        self.device = meta.get("device", "cpu")
        if self.device == "mps" and not torch.backends.mps.is_available():
            self.device = "cpu"
        fname = (meta.get("files") or ["ecapa2.pt"])[0]
        self.model = torch.jit.load(str(model_dir / fname), map_location=self.device)
        self.dim = int(meta.get("dim", 0)) or None

    def embed(self, wav: np.ndarray) -> np.ndarray:
        x = np.ascontiguousarray(wav, dtype=np.float32).reshape(-1)
        t = torch.from_numpy(x).unsqueeze(0).to(self.device)
        # The card notes the JIT optimizer can stall on early calls; the model
        # switches itself to eval/no_grad, so no extra context is needed.
        with torch.jit.optimized_execution(False):
            emb = self.model(t)
        return emb.reshape(-1).float().cpu().numpy().astype(np.float32)
