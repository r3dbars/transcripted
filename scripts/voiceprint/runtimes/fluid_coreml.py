"""Runtime for the app's own voiceprint: FluidAudio's offline WeSpeaker Core ML models.

The app (`Sources/TranscriptedCore/Speaker/FluidOfflineWeSpeakerSegmentEmbedder.swift`)
runs `FBank.mlmodelc` (10 s of 16 kHz audio -> 80x998 log-mel fbank, mean-normalized
over the window) and feeds it to `Embedding.mlmodelc` (WeSpeaker ResNet34, pyannote
community-1) with a 589-frame weight mask. Compute units match FluidAudio's defaults:
fbank on CPU only, embedding on `.all`.

Modes (model.json `mode`, default `app_isolated`):

- `app_isolated`: the clip at the start of the 10 s window, zeros after it, weights on
  only over the clip's frames. This is exactly `embed(samples:sampleRate:)` in the app
  for a clip with no surrounding audio. Clips longer than 10 s are cut into 10 s pieces
  (a trailing piece under 0.5 s is skipped once something was embedded), each piece is
  embedded, and the vectors are averaged by piece length.
- `app_context_free_tiled`: the clip (or 10 s piece) is repeated to fill the whole
  window, weights on over the whole window. Same network, but the fbank mean is taken
  over real speech instead of speech plus zeros.

`embed` returns the model's output (already L2-normalized by the Core ML graph); for
multi-piece clips it returns the length-weighted average, L2-normalized, as the app does.
"""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000
WINDOW = 160_000
MODES = ("app_isolated", "app_context_free_tiled")


def _compute_unit(ct, name: str):
    return {
        "all": ct.ComputeUnit.ALL,
        "cpu": ct.ComputeUnit.CPU_ONLY,
        "cpu_gpu": ct.ComputeUnit.CPU_AND_GPU,
        "cpu_ne": ct.ComputeUnit.CPU_AND_NE,
    }[name]


class Embedder:
    def __init__(self, model_dir: Path, meta: dict, threads: int = 3):
        import coremltools as ct  # imported here so the module loads without it

        model_dir = Path(model_dir)
        self.mode = meta.get("mode", "app_isolated")
        if self.mode not in MODES:
            raise ValueError(f"unknown fluid_coreml mode {self.mode!r}; expected one of {MODES}")
        self.fbank = ct.models.CompiledMLModel(
            str(model_dir / "FBank.mlmodelc"),
            compute_units=_compute_unit(ct, meta.get("fbank_compute_units", "cpu")),
        )
        self.embedding = ct.models.CompiledMLModel(
            str(model_dir / "Embedding.mlmodelc"),
            compute_units=_compute_unit(ct, meta.get("embedding_compute_units", "all")),
        )
        self.weight_frames = 589
        self.dim = int(meta.get("dim", 256))
        self.threads = threads  # Core ML has no thread knob; kept for the interface.

    # One 10 s window: `window` is exactly WINDOW samples, mask on for [active_from, active_to).
    def _embed_window(self, window: np.ndarray, active_from: int, active_to: int) -> np.ndarray | None:
        audio = np.ascontiguousarray(window, dtype=np.float32).reshape(1, 1, WINDOW)
        feats = self.fbank.predict({"audio": audio})["fbank_features"]
        weights = np.zeros((1, self.weight_frames), dtype=np.float32)
        wf = self.weight_frames
        first = max(0, min(wf - 1, math.floor(active_from / WINDOW * wf)))
        last = max(first + 1, min(wf, math.ceil(active_to / WINDOW * wf)))
        weights[0, first:last] = 1.0
        out = self.embedding.predict({"fbank_features": feats, "weights": weights})["embedding"]
        vec = np.asarray(out, dtype=np.float32).reshape(-1)
        return vec if np.all(np.isfinite(vec)) and vec.size == self.dim else None

    def _piece(self, piece: np.ndarray) -> np.ndarray | None:
        n = piece.shape[0]
        if self.mode == "app_isolated":
            window = np.zeros(WINDOW, dtype=np.float32)
            window[:n] = piece
            return self._embed_window(window, 0, n)
        # app_context_free_tiled
        reps = int(math.ceil(WINDOW / n))
        window = np.tile(piece, reps)[:WINDOW]
        return self._embed_window(window, 0, WINDOW)

    def embed(self, wav: np.ndarray) -> np.ndarray:
        wav = np.asarray(wav, dtype=np.float32).reshape(-1)
        if wav.size == 0:
            raise ValueError("empty clip")
        acc = np.zeros(self.dim, dtype=np.float64)
        total = 0.0
        start = 0
        while start < wav.size:
            piece = wav[start : start + WINDOW]
            if piece.size < SAMPLE_RATE // 2 and total > 0:
                break
            vec = self._piece(piece)
            if vec is not None:
                acc += vec.astype(np.float64) * piece.size
                total += piece.size
            start += WINDOW
        if total <= 0:
            raise RuntimeError("fluid_coreml produced no finite embedding")
        norm = np.linalg.norm(acc)
        if not np.isfinite(norm) or norm <= 0:
            raise RuntimeError("fluid_coreml produced a zero embedding")
        return (acc / norm).astype(np.float32)

    # The app's meeting path (`embed(audio:startSample:endSample:)`): a real 10 s window of
    # the recording around the turn, mask on only over the turn. Not part of the bake-off
    # interface (clips are isolated); used by the parity check on AMI meetings.
    def embed_in_context(self, audio: np.ndarray, start: int, end: int) -> np.ndarray:
        audio = np.asarray(audio, dtype=np.float32).reshape(-1)
        start = max(0, min(start, audio.size))
        end = max(start, min(end, audio.size))
        if end <= start:
            raise ValueError("empty span")
        acc = np.zeros(self.dim, dtype=np.float64)
        total = 0.0
        piece_start = start
        while piece_start < end:
            piece_end = min(end, piece_start + WINDOW)
            length = piece_end - piece_start
            if length < SAMPLE_RATE // 2 and total > 0:
                break
            slack = WINDOW - length
            w0 = piece_start - slack // 2
            w0 = max(0, min(w0, audio.size - WINDOW))
            w0 = max(0, w0)
            wlen = min(WINDOW, audio.size - w0)
            window = np.zeros(WINDOW, dtype=np.float32)
            window[:wlen] = audio[w0 : w0 + wlen]
            vec = self._embed_window(window, piece_start - w0, piece_end - w0)
            if vec is not None:
                acc += vec.astype(np.float64) * length
                total += length
            piece_start = piece_end
        if total <= 0:
            raise RuntimeError("fluid_coreml produced no finite embedding")
        return (acc / np.linalg.norm(acc)).astype(np.float32)
