"""ReDimNet / ReDimNet2 speaker-embedding runtime for the voiceprint bake-off.

One module serves both families:
  * ReDimNet  (IDRnD/redimnet, Interspeech 2024)   -> package `redimnet_upstream`
    (upstream calls it `redimnet`; renamed in the local copy because this module owns that name)
  * ReDimNet2 (PalabraAI/redimnet2, Interspeech 2026) -> package `redimnet2`

Each model dir is self-contained and needs no network at embed time:

    VP/models/<model_id>/
        model.json
        code/redimnet_upstream/ (or code/redimnet2/)   copy of the upstream package (MIT)
        <weights>.pt                          official release checkpoint

model.json fields this runtime reads (beyond the shared schema):
    redimnet_pkg   "redimnet_upstream" or "redimnet2"
    code_dir       folder with the package, relative to the model dir (default "code")
    device         "cpu" (default) or "mps"; set by the setup agent after checking
                   that MPS output matches CPU (cosine > 0.999)
    files[0]       the checkpoint
    level_norm_dbfs  optional float. If set, every clip is rescaled to this RMS level
                   (gain capped so the peak stays under 0.99) before embedding. Set to
                   -26 for the models whose front end does not normalize the signal
                   (`norm_signal: false`, i.e. the original b2 and b6): their embeddings
                   drift at low input levels (AMI headset mix sits near -50 dBFS).

Input is float32 mono 16 kHz in [-1, 1] (what torchaudio.load returns; the
log-mel front end is scale-sensitive, so do not pass int16 values).
Output is the raw, un-normalized embedding (float32, 1-D).
"""
from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

import numpy as np
import torch

# Shorter than this and the mel front end has almost no frames; wrap-pad.
_MIN_SAMPLES = 8000  # 0.5 s


def _load_checkpoint(path: Path) -> dict:
    # weights_only=True first: refuses to run arbitrary pickled code.
    try:
        return torch.load(path, map_location="cpu", weights_only=True)
    except Exception:
        # Official IDRnD / PalabraAI release files, kept local and checksummed
        # by the setup agent. Some carry non-tensor config objects.
        return torch.load(path, map_location="cpu", weights_only=False)


class Embedder:
    def __init__(self, model_dir, meta: dict, threads: int = 3):
        self.model_dir = Path(model_dir)
        self.meta = meta
        torch.set_num_threads(int(threads))

        pkg = meta.get("redimnet_pkg", "redimnet_upstream")
        v2 = pkg == "redimnet2"
        code_dir = self.model_dir / meta.get("code_dir", "code")
        if str(code_dir) not in sys.path:
            sys.path.insert(0, str(code_dir))
        mod = importlib.import_module(f"{pkg}.redimnet2" if v2 else f"{pkg}.model")
        wrap_cls = getattr(mod, "ReDimNet2Wrap" if v2 else "ReDimNetWrap")

        weights = self.model_dir / meta["files"][0]
        ckpt = _load_checkpoint(weights)
        model = wrap_cls(**ckpt["model_config"])
        res = model.load_state_dict(ckpt["state_dict"])
        if res.missing_keys or res.unexpected_keys:
            raise RuntimeError(
                f"{weights.name}: missing={res.missing_keys} unexpected={res.unexpected_keys}")
        model.eval()
        for p in model.parameters():
            p.requires_grad_(False)

        want = os.environ.get("REDIMNET_DEVICE") or meta.get("device") or "cpu"
        if want == "mps" and not torch.backends.mps.is_available():
            want = "cpu"
        self.device = torch.device(want)
        self.model = model.to(self.device)
        self.dim = int(meta.get("dim") or ckpt["model_config"].get("embed_dim", 0))
        lv = meta.get("level_norm_dbfs")
        self.level_norm = None if lv is None else float(lv)

    # ------------------------------------------------------------------ helpers
    def _prep(self, wav: np.ndarray) -> np.ndarray:
        w = np.asarray(wav, dtype=np.float32).reshape(-1)
        if self.level_norm is not None and w.shape[0]:
            rms = float(np.sqrt(np.mean(w.astype(np.float64) ** 2)))
            peak = float(np.max(np.abs(w)))
            if rms > 1e-7 and peak > 0:
                g = min(10 ** (self.level_norm / 20) / rms, 0.99 / peak)
                w = (w * np.float32(g)).astype(np.float32)
        if w.shape[0] < _MIN_SAMPLES:
            reps = -(-_MIN_SAMPLES // max(1, w.shape[0]))
            w = np.tile(w, reps)[:_MIN_SAMPLES] if w.shape[0] else np.zeros(_MIN_SAMPLES, np.float32)
        return w

    def _run(self, batch: np.ndarray) -> np.ndarray:
        x = torch.from_numpy(np.ascontiguousarray(batch)).to(self.device)
        with torch.inference_mode():
            y = self.model(x)
        if self.device.type == "mps":
            torch.mps.synchronize()
        return y.float().cpu().numpy()

    # ---------------------------------------------------------------------- API
    def embed(self, wav: np.ndarray) -> np.ndarray:
        """float32 mono 16 kHz in, 1-D float32 embedding out (raw, not normalized)."""
        return self._run(self._prep(wav)[None, :])[0].astype(np.float32, copy=False)

    def embed_batch(self, wavs) -> np.ndarray:
        """Optional convenience: [N, D] float32 for a list of clips, in order.

        Deliberately a plain loop: measured on this Mac, stacking clips into one
        forward pass is no faster on MPS and about 3x slower per clip on CPU.
        Tip for callers: MPS compiles a kernel per new input length (0.4-1.5 s the
        first time), so feed clips of identical length (the 2/4/8 s buckets) and
        it stays at steady-state speed."""
        return np.stack([self.embed(w) for w in wavs])
