"""sherpa-onnx speaker-embedding runtime for the voiceprint bake-off.

Runs any model from the k2-fsa/sherpa-onnx `speaker-recongition-models` release
(WeSpeaker, NeMo TitaNet/SpeakerNet, 3D-Speaker CAM++/ERes2Net). Features (fbank,
mean norm, etc.) are computed inside sherpa from each model's ONNX metadata, so
the input is just raw float32 mono 16 kHz audio.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

SAMPLE_RATE = 16000


class Embedder:
    def __init__(self, model_dir: Path, meta: dict, threads: int = 3):
        import sherpa_onnx

        model_dir = Path(model_dir)
        files = meta.get("files") or []
        onnx = [f for f in files if str(f).endswith(".onnx")]
        if not onnx:
            raise ValueError(f"{meta.get('model_id')}: model.json has no .onnx file in `files`")
        model_path = model_dir / onnx[0]
        if not model_path.is_file():
            raise FileNotFoundError(str(model_path))

        config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(model_path),
            num_threads=int(threads),
            debug=False,
            provider="cpu",
        )
        if hasattr(config, "validate") and not config.validate():
            raise RuntimeError(f"invalid sherpa config for {model_path.name}")
        self._extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
        self.dim = int(self._extractor.dim)
        self.sample_rate = SAMPLE_RATE

    def embed(self, wav: np.ndarray) -> np.ndarray:
        wav = np.ascontiguousarray(np.asarray(wav, dtype=np.float32).reshape(-1))
        stream = self._extractor.create_stream()
        stream.accept_waveform(sample_rate=self.sample_rate, waveform=wav)
        stream.input_finished()
        if not self._extractor.is_ready(stream):
            raise ValueError("clip too short for this model")
        emb = self._extractor.compute(stream)
        return np.asarray(emb, dtype=np.float32).reshape(-1)
