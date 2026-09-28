"""Hugging Face x-vector runtime: microsoft/wavlm-base-plus-sv and
microsoft/unispeech-sat-base-plus-sv (transformers AutoFeatureExtractor +
AutoModelForAudioXVector, `embeddings` output).

Embedder(model_dir, meta, threads) -> .embed(wav) -> 1-D float32 (raw, not
length-normalized; the model card L2-normalizes before cosine, which the
scorers do anyway).

Offline at embed time: HF_HUB_OFFLINE=1 and the model is loaded from a local
directory, never from ~/.cache.

meta keys used (all optional):
  device      "cpu" (default) or "mps"
  input_norm  "none" (default: exactly what the model card / feature extractor
              config does, i.e. raw waveform, do_normalize=false), or "zmuv"
              (per-clip zero mean, unit variance), or "rms" (scale to -25 dBFS
              RMS, a typical LibriSpeech level). Base+ was pretrained without
              waveform normalization, so it can be level-sensitive.
"""
from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")

import numpy as np
import torch
from transformers import AutoFeatureExtractor, AutoModelForAudioXVector


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
        self.extractor = AutoFeatureExtractor.from_pretrained(str(model_dir), local_files_only=True)
        self.model = AutoModelForAudioXVector.from_pretrained(str(model_dir), local_files_only=True)
        self.model.eval().to(self.device)
        self.sample_rate = int(getattr(self.extractor, "sampling_rate", 16000))
        self.dim = int(meta.get("dim", 0)) or None
        self.input_norm = str(meta.get("input_norm", "none"))
        if self.input_norm not in ("none", "zmuv", "rms"):
            raise ValueError(f"unknown input_norm {self.input_norm!r}")

    def embed(self, wav: np.ndarray) -> np.ndarray:
        x = np.ascontiguousarray(wav, dtype=np.float32).reshape(-1)
        if self.input_norm == "zmuv":
            x = (x - x.mean()) / (x.std() + 1e-7)
        elif self.input_norm == "rms":
            x = x * (10 ** (-25 / 20) / (float(np.sqrt(np.mean(x * x))) + 1e-9))
        inputs = self.extractor(x, sampling_rate=self.sample_rate, return_tensors="pt", padding=False)
        input_values = inputs["input_values"].to(self.device)
        with torch.inference_mode():
            out = self.model(input_values=input_values)
        return out.embeddings.reshape(-1).float().cpu().numpy().astype(np.float32)
