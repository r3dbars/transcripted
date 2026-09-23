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


ENGINES: dict[str, type] = {
    "fake": Fake,
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
