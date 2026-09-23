#!/usr/bin/env python3
"""Python model runners for the STT shootout (one model per process).

  python py_engines.py --engine whisper-turbo --audio full.wav --clip clip.wav --runs 3 --out result.json

Timing protocol, shared with engines/apple_speech.swift and the app CLI:
  load_seconds        load the model (first run also downloads weights; the
                      shootout's quick check run warms that cache)
  clip_cold_seconds   first transcription of the 10 s clip after loading
  clip_warm_seconds   the next --runs transcriptions of the same clip
  full_seconds        the whole test file

Audio is read with the standard library and handed to each model as a 16 kHz
mono float32 array, so no model needs ffmpeg.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import sys
import time
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000


def log(message: str) -> None:
    print(f"{ENGINE_NAME}: {message}", file=sys.stderr, flush=True)


def load_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise SystemExit(f"{path}: expected 16 kHz mono 16-bit WAV")
        data = w.readframes(w.getnframes())
    return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0


def self_peak_bytes() -> int:
    """Lifetime max physical footprint of this process (macOS), incl. GPU memory."""
    if sys.platform != "darwin":
        return 0
    class Info(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 40)]
    libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
    info = Info()
    import os
    if libproc.proc_pid_rusage(os.getpid(), 4, ctypes.byref(info)) != 0:
        return 0
    return int(info.values[28])


def speech_chunks(audio: np.ndarray, max_seconds: float = 30.0, min_gap: float = 0.3) -> list[np.ndarray]:
    """Cut long audio into <= max_seconds pieces at the quietest nearby spot.

    Energy-based, dependency-free: for models that only take short inputs
    (Moonshine). Cuts land in the lowest-energy 20 ms frame of the last third
    of each window, so words are rarely split.
    """
    frame = int(0.02 * SAMPLE_RATE)
    window = int(max_seconds * SAMPLE_RATE)
    chunks = []
    start = 0
    while start < len(audio):
        end = min(len(audio), start + window)
        if end < len(audio):
            search_from = start + int(window * 2 / 3)
            region = audio[search_from:end]
            usable = len(region) // frame * frame
            if usable:
                energy = (region[:usable].reshape(-1, frame) ** 2).mean(axis=1)
                end = search_from + int(np.argmin(energy)) * frame + frame // 2
        piece = audio[start:end]
        if len(piece) >= int(min_gap * SAMPLE_RATE) and float(np.abs(piece).max(initial=0)) > 1e-3:
            chunks.append(piece)
        start = end
    return chunks


# --------------------------------------------------------------------------
# Engines: each is a class with load() and transcribe(audio) -> str.


class Fake:
    """Self-check engine: returns silence-aware placeholder text. Linux-safe."""

    def load(self) -> None:
        time.sleep(0.05)

    def transcribe(self, audio: np.ndarray) -> str:
        time.sleep(len(audio) / SAMPLE_RATE / 500)
        return " ".join("word" for _ in range(max(1, len(audio) // SAMPLE_RATE * 2)))


class MlxWhisper:
    """mlx-whisper: Whisper on the GPU via MLX. Handles long audio itself."""

    repo = "mlx-community/whisper-large-v3-turbo"

    def load(self) -> None:
        import mlx.core as mx
        from mlx_whisper.transcribe import ModelHolder

        ModelHolder.get_model(self.repo, mx.float16)
        self.details = {"model": self.repo}

    def transcribe(self, audio: np.ndarray) -> str:
        import mlx_whisper

        result = mlx_whisper.transcribe(audio, path_or_hf_repo=self.repo, language="en", fp16=True)
        return result["text"]


class DistilWhisper(MlxWhisper):
    repo = "mlx-community/distil-whisper-large-v3"


class ParakeetMlx:
    """parakeet-mlx: NVIDIA Parakeet TDT on the GPU via MLX.

    transcribe() only takes a path and decodes it with ffmpeg, so the array is
    swapped in for its audio loader; its own 120 s chunk + 15 s overlap merge
    (the parakeet-mlx CLI defaults) still does the long-audio work.
    """

    repo = "mlx-community/parakeet-tdt-0.6b-v3"

    def load(self) -> None:
        from parakeet_mlx import from_pretrained

        self.model = from_pretrained(self.repo)
        self.details = {"model": self.repo, "chunk_duration": 120, "overlap_duration": 15}

    def transcribe(self, audio: np.ndarray) -> str:
        import mlx.core as mx
        import parakeet_mlx.parakeet as parakeet_module

        parakeet_module.load_audio = lambda filename, sampling_rate, dtype=None: mx.array(audio).astype(dtype or mx.bfloat16)
        duration = len(audio) / SAMPLE_RATE
        chunk = 120.0 if duration > 120 else None
        result = self.model.transcribe("in-memory.wav", chunk_duration=chunk, overlap_duration=15.0)
        return result.text


class ParakeetV2Mlx(ParakeetMlx):
    repo = "mlx-community/parakeet-tdt-0.6b-v2"


class OnnxAsr:
    """onnx-asr: NeMo models exported to ONNX, cut into speech segments by
    Silero VAD (the models only take ~20-30 s at a time). CPU: onnx-asr drops
    Core ML for Canary-style models anyway, so all runs stay comparable."""

    model_name = "nemo-canary-1b-v2"

    def load(self) -> None:
        import onnx_asr

        providers = ["CPUExecutionProvider"]
        vad = onnx_asr.load_vad("silero", providers=providers)
        model = onnx_asr.load_model(self.model_name, providers=providers)
        self.model = model.with_vad(vad, max_speech_duration_s=20)
        self.details = {"model": self.model_name, "providers": providers}

    def transcribe(self, audio: np.ndarray) -> str:
        segments = self.model.recognize(audio, sample_rate=SAMPLE_RATE, language="en")
        return " ".join(segment.text.strip() for segment in segments)


class Canary180mFlash(OnnxAsr):
    model_name = "istupakov/canary-180m-flash-onnx"


class Moonshine:
    """moonshine-voice: Moonshine's own runtime (bundled ONNX Runtime + VAD
    that splits lines at 15 s). The whole array goes straight to the C API;
    the Python wrapper copies samples one by one, far too slow for an hour."""

    arch_name = "BASE"

    def load(self) -> None:
        from moonshine_voice import ModelArch, Transcriber, get_model_for_language

        path, arch = get_model_for_language("en", getattr(ModelArch, self.arch_name))
        self.transcriber = Transcriber(model_path=path, model_arch=arch, options={"return_audio_data": "false"})
        self.details = {"model": f"moonshine {self.arch_name.lower()}", "model_path": str(path)}

    def transcribe(self, audio: np.ndarray) -> str:
        from moonshine_voice.moonshine_api import TranscriptC

        samples = np.ascontiguousarray(audio, dtype=np.float32)
        out = ctypes.POINTER(TranscriptC)()
        t = self.transcriber
        error = t._lib.moonshine_transcribe_without_streaming(
            t._handle,
            samples.ctypes.data_as(ctypes.POINTER(ctypes.c_float)),
            len(samples),
            SAMPLE_RATE,
            0,
            ctypes.byref(out),
        )
        if error != 0:
            raise RuntimeError(f"moonshine_transcribe_without_streaming returned {error}")
        transcript = t._parse_transcript(out)
        return " ".join(line.text.strip() for line in transcript.lines)


class MoonshineMedium(Moonshine):
    arch_name = "MEDIUM_STREAMING"


class WhisperCpp:
    """pywhispercpp: whisper.cpp with Metal, large-v3-turbo. Long audio built in."""

    model_name = "large-v3-turbo"

    def load(self) -> None:
        import os
        from pywhispercpp.model import Model

        threads = max(4, (os.cpu_count() or 8) - 2)
        self.model = Model(self.model_name, n_threads=threads, language="en", print_progress=False, print_realtime=False)
        self.details = {"model": f"ggml-{self.model_name}", "threads": threads}

    def transcribe(self, audio: np.ndarray) -> str:
        return " ".join(segment.text.strip() for segment in self.model.transcribe(audio))


class MlxAudio:
    """mlx-audio STT models on the GPU via MLX."""

    repo = ""
    chunk_seconds: float | None = None  # cut audio ourselves when the model can't

    def load(self) -> None:
        from mlx_audio.stt import load

        self.model = load(self.repo)
        self.details = {"model": self.repo}

    def generate(self, audio: np.ndarray) -> str:
        return self.model.generate(audio).text

    def transcribe(self, audio: np.ndarray) -> str:
        if self.chunk_seconds and len(audio) > self.chunk_seconds * SAMPLE_RATE:
            return " ".join(self.generate(piece).strip() for piece in speech_chunks(audio, self.chunk_seconds))
        return self.generate(audio)


class GraniteSpeech(MlxAudio):
    """IBM Granite Speech 4.0 1B (tops the Open ASR Leaderboard's English
    average). An LLM decoder, so it's fed 30 s pieces."""

    repo = "ibm-granite/granite-4.0-1b-speech"
    chunk_seconds = 30.0


class NemotronStreaming(MlxAudio):
    """NVIDIA Nemotron streaming ASR 0.6B (cache-aware streaming FastConformer).
    Chunks long audio itself (30 s)."""

    repo = "mlx-community/nemotron-3.5-asr-streaming-0.6b"

    def generate(self, audio: np.ndarray) -> str:
        import mlx.core as mx

        return self.model.generate(mx.array(audio), chunk_duration=30.0).text


ENGINES: dict[str, type] = {
    "fake": Fake,
    "whisper-turbo": MlxWhisper,
    "distil-whisper": DistilWhisper,
    "parakeet-v3-mlx": ParakeetMlx,
    "parakeet-v2-mlx": ParakeetV2Mlx,
    "canary-1b-v2": OnnxAsr,
    "canary-180m-flash": Canary180mFlash,
    "moonshine-base": Moonshine,
    "moonshine-medium": MoonshineMedium,
    "whisper-cpp-turbo": WhisperCpp,
    "granite-speech": GraniteSpeech,
    "nemotron-streaming": NemotronStreaming,
}


# --------------------------------------------------------------------------

ENGINE_NAME = "engine"


def main() -> None:
    global ENGINE_NAME
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", required=True, choices=sorted(ENGINES))
    parser.add_argument("--audio", required=True)
    parser.add_argument("--clip", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    ENGINE_NAME = args.engine

    audio = load_wav(args.audio)
    clip = load_wav(args.clip)
    engine = ENGINES[args.engine]()

    started = time.perf_counter()
    engine.load()
    load_seconds = time.perf_counter() - started
    log(f"loaded in {load_seconds:.2f}s")

    clip_times = []
    clip_text = ""
    for run in range(args.runs + 1):
        started = time.perf_counter()
        clip_text = engine.transcribe(clip)
        clip_times.append(time.perf_counter() - started)
        log(f"clip run {run}: {clip_times[-1]:.3f}s")

    log(f"transcribing {len(audio) / SAMPLE_RATE / 60:.1f} min...")
    started = time.perf_counter()
    text = engine.transcribe(audio)
    full_seconds = time.perf_counter() - started
    log(f"full file in {full_seconds:.1f}s")

    Path(args.out).write_text(json.dumps({
        "load_seconds": load_seconds,
        "clip_cold_seconds": clip_times[0],
        "clip_warm_seconds": clip_times[1:],
        "full_seconds": full_seconds,
        "text": text.strip(),
        "clip_text": clip_text.strip(),
        "self_peak_bytes": self_peak_bytes(),
        **getattr(engine, "details", {}),
    }, indent=2))


if __name__ == "__main__":
    main()
