"""WeSpeaker ONNX runtime with WeSpeaker's own training front end.

The sherpa-onnx release ONNX files for WeSpeaker carry no `feature_normalize_type`
metadata, so sherpa-onnx skips per-utterance mean normalization and uses a povey
window, mel up to 7600 Hz and snip_edges=false. That is not what these networks
were trained with. This runtime does it the WeSpeaker way and runs the ONNX
network directly with onnxruntime:

    waveform * 2**15 -> torchaudio kaldi fbank (80 mel, 25 ms / 10 ms, hamming,
    dither 0, snip_edges=True) -> subtract the mean over time (CMN) -> ONNX `feats`

Reference: models/app-wespeaker-coreml/parity_check.py (`onnx_kaldi_cmn`).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000


class Embedder:
    def __init__(self, model_dir: Path, meta: dict, threads: int = 3):
        import onnxruntime as ort
        import torch

        model_dir = Path(model_dir)
        onnx = [f for f in (meta.get("files") or []) if str(f).endswith(".onnx")]
        if not onnx:
            raise ValueError(f"{meta.get('model_id')}: model.json has no .onnx file in `files`")
        path = model_dir / onnx[0]
        if not path.is_file():
            raise FileNotFoundError(str(path))

        torch.set_num_threads(max(1, int(threads)))
        so = ort.SessionOptions()
        so.intra_op_num_threads = int(threads)
        so.inter_op_num_threads = 1
        self._sess = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])
        inputs = self._sess.get_inputs()
        if len(inputs) != 1:
            raise ValueError(f"unexpected ONNX inputs: {[i.name for i in inputs]}")
        self._input = inputs[0].name  # "feats", shape [B, T, 80]
        self._torch = torch
        self.dim = int(self._sess.get_outputs()[0].shape[-1])
        self.sample_rate = SAMPLE_RATE

    def features(self, wav: np.ndarray) -> np.ndarray:
        import torchaudio.compliance.kaldi as K

        w = self._torch.from_numpy(np.ascontiguousarray(np.asarray(wav, dtype=np.float32).reshape(-1)))
        fb = K.fbank(
            w[None] * (1 << 15),
            num_mel_bins=80,
            frame_length=25,
            frame_shift=10,
            dither=0.0,
            sample_frequency=SAMPLE_RATE,
            window_type="hamming",
            use_energy=False,
        ).numpy()
        return fb - fb.mean(axis=0, keepdims=True)

    def embed(self, wav: np.ndarray) -> np.ndarray:
        fb = self.features(wav)
        if fb.shape[0] < 1:
            raise ValueError("clip too short for the fbank front end")
        out = self._sess.run(None, {self._input: fb[None].astype(np.float32)})[0]
        return np.asarray(out[0], dtype=np.float32).reshape(-1)
