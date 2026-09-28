"""Core ML fused-model runtime for the voiceprint bake-off.

Runs a model built by scripts/voiceprint/convert_coreml.py: one Core ML graph that
takes raw 16 kHz mono float32 audio ("audio", [1, N]) and returns the raw speaker
embedding ("embedding", [1, D]); the model's own front end is inside the graph.
This is the exact artifact that would ship in the app.

model.json fields this runtime reads (beyond the shared schema):
    files[0]      the .mlpackage, relative to the model dir (usually
                  ../../coreml/<source_model_id>/model.mlpackage)
    compiled      optional .mlmodelc next to it (preferred: no compile at load)
    device        "ane" (compute units ALL, default), "cpu" (CPU_ONLY), "gpu"
                  (CPU_AND_GPU) or "ne" (CPU_AND_NE). Env COREML_FUSED_DEVICE overrides.
    coreml.enumerated_samples   input lengths the model accepts (enumerated shapes, or the
                                lengths of a multifunction build), or
    coreml.range_samples        [min, max] for a RangeDim model
    coreml.functions            {length: function name} for a multifunction build (one
                                static-shape function per length, weights shared)

Clip lengths the model does not accept (bake-off clips are exactly 2 / 4 / 8 s,
which it does): shorter than the smallest length -> tiled up to it; otherwise the
centre is cropped to the largest accepted length that fits; longer than the max ->
max-length windows, each embedded, L2-normalized and averaged (like the Swift
ERes2NetEmbedder), then rescaled to the mean window norm.

`threads` is accepted for the shared interface; Core ML schedules its own threads.
"""
from __future__ import annotations

import collections
import os
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000

_UNITS = {"ane": "ALL", "all": "ALL", "cpu": "CPU_ONLY", "gpu": "CPU_AND_GPU", "ne": "CPU_AND_NE"}


class Embedder:
    def __init__(self, model_dir, meta: dict, threads: int = 3):
        import coremltools as ct

        model_dir = Path(model_dir)
        pkg = (model_dir / meta["files"][0]).resolve()
        compiled = meta.get("compiled")
        mlc = (model_dir / compiled).resolve() if compiled else pkg.with_suffix(".mlmodelc")
        dev = (os.environ.get("COREML_FUSED_DEVICE") or meta.get("device") or "ane").lower()
        units = getattr(ct.ComputeUnit, _UNITS.get(dev, "ALL"))
        cm = meta.get("coreml") or {}
        # multifunction build: one static-shape function per input length, loaded lazily
        self._keep = collections.deque(maxlen=64)
        self._functions = {int(k): v for k, v in (cm.get("functions") or {}).items()} or None
        self._models = {}
        if self._functions:
            if not mlc.is_dir():
                raise FileNotFoundError(str(mlc))
            self._loader = lambda fn: ct.models.CompiledMLModel(str(mlc), compute_units=units, function_name=fn)
            self._model = None
        elif mlc.is_dir():
            self._model = ct.models.CompiledMLModel(str(mlc), compute_units=units)
        elif pkg.exists():
            self._model = ct.models.MLModel(str(pkg), compute_units=units)
        else:
            raise FileNotFoundError(str(pkg))
        self._input = cm.get("input", "audio")
        self._output = cm.get("output", "embedding")
        enum = cm.get("enumerated_samples")
        rng = cm.get("range_samples")
        self._lengths = sorted(int(n) for n in enum) if enum else None
        self._range = (int(rng[0]), int(rng[1])) if rng else None
        self.dim = int(meta.get("dim") or 0)
        self.device = f"coreml:{dev}"
        self.sample_rate = SAMPLE_RATE

    # ------------------------------------------------------------------ helpers
    def _max_len(self) -> int:
        return self._lengths[-1] if self._lengths else self._range[1]

    def _fit(self, w: np.ndarray) -> np.ndarray:
        n = w.shape[0]
        if self._lengths is None:
            lo, hi = self._range
            if n < lo:
                return np.tile(w, -(-lo // max(1, n)))[:lo]
            return w[:hi]
        if n in self._lengths:
            return w
        if n < self._lengths[0]:
            target = self._lengths[0]
            return np.tile(w, -(-target // max(1, n)))[:target]
        target = max(L for L in self._lengths if L <= n)
        start = (n - target) // 2
        return w[start:start + target]

    def _run(self, w: np.ndarray) -> np.ndarray:
        model = self._model
        if self._functions:
            fn = self._functions[w.shape[0]]
            model = self._models.get(fn)
            if model is None:
                model = self._models[fn] = self._loader(fn)
        arr = np.ascontiguousarray(w, dtype=np.float32).reshape(1, -1)
        # Core ML drops its reference to the input later, on its own thread; if that is the
        # last reference the buffer is freed without the GIL (segfault). Keep recent inputs.
        self._keep.append(arr)
        out = model.predict({self._input: arr})
        return np.asarray(out[self._output], dtype=np.float32).reshape(-1)

    # ---------------------------------------------------------------------- API
    def embed(self, wav: np.ndarray) -> np.ndarray:
        """float32 mono 16 kHz in, 1-D float32 embedding out (raw, not normalized)."""
        w = np.asarray(wav, dtype=np.float32).reshape(-1)
        if w.shape[0] == 0:
            raise ValueError("empty clip")
        hi = self._max_len()
        if w.shape[0] <= hi:
            return self._run(self._fit(w))
        vecs = [self._run(self._fit(w[s:s + hi])) for s in range(0, w.shape[0], hi)
                if w[s:s + hi].shape[0] >= min(hi, (self._lengths or [self._range[0]])[0])]
        norms = [float(np.linalg.norm(v)) or 1.0 for v in vecs]
        mean = np.mean([v / n for v, n in zip(vecs, norms)], axis=0)
        mean = mean / (np.linalg.norm(mean) or 1.0) * float(np.mean(norms))
        return mean.astype(np.float32)
