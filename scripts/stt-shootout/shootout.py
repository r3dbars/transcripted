#!/usr/bin/env python3
"""Speech-to-text model shootout: how much faster (and how accurate) is each
on-device model than the Parakeet V3 model Transcripted ships?

Run it on an Apple Silicon Mac through the wrapper, which sets up Python:

  bash scripts/stt-shootout/run.sh                  # the full hour-long test
  bash scripts/stt-shootout/run.sh --minutes 3      # quick check that every model runs
  bash scripts/stt-shootout/run.sh --list-engines

What it does:
  1. Downloads an hour-long YouTube video's audio plus its human-made English
     captions (yt-dlp). The captions are the answer key for word error rate.
  2. Converts the audio to 16 kHz mono WAV (afconvert, built into macOS) and
     cuts a 10-second clip for the latency test.
  3. Runs every model in its own process, so one model's memory or crash
     can't touch another's numbers. Each gets its own Python env.
  4. Per model: load time, 10-second clip latency (cold and warm), time for
     the whole hour, speed vs real time, speed vs Parakeet V3, peak memory
     (the "Memory" number Activity Monitor shows), and word error rate.
  5. Writes report.md, report.json, report.csv and every transcript.

Everything is local. The only network use is the video download and each
model's first-time weight download.
"""

from __future__ import annotations

import argparse
import csv
import ctypes
import ctypes.util
import hashlib
import html
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import threading
import time
import unicodedata
import wave
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY_ENGINES = HERE / "engines" / "py_engines.py"
APPLE_SPEECH_SWIFT = HERE / "engines" / "apple_speech.swift"
WHISPERKIT_PACKAGE = HERE / "engines" / "whisperkit-bench"
PYTHON_VERSION = "3.12"
# Downloads, installs and builds get a generous cap so a network stall can't
# hang an unattended run forever.
SETUP_TIMEOUT = 45 * 60

# Human-captioned, Creative Commons (MIT OpenCourseWare, CC BY-NC-SA) lectures
# of about an hour. The first one that still has human-made English captions
# wins. Override with --url.
DEFAULT_VIDEOS = [
    # MIT 6.006 Introduction to Algorithms, Fall 2011, Lecture 1 (~53 min)
    "https://www.youtube.com/watch?v=HtSuA80QTyo",
    # MIT 6.006 Introduction to Algorithms, Spring 2020, Lecture 1 (~53 min)
    "https://www.youtube.com/watch?v=ZA-tUyM_y7s",
    # MIT 6.034 Artificial Intelligence, Fall 2010, Lecture 1 (~47 min)
    "https://www.youtube.com/watch?v=TjZBTDzGeGg",
]

APP_CLI_CANDIDATES = [
    Path("/Applications/Transcripted.app/Contents/Helpers/transcripted-cli"),
    Path.home() / "Applications/Transcripted.app/Contents/Helpers/transcripted-cli",
]
ULTRA_DIR = (
    Path.home()
    / "Library/Application Support/Transcripted/models/parakeet-ultra/parakeet-tdt-0.6b-v3"
)
FLUIDAUDIO_V3_CACHE = Path.home() / "Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3"
V3_FOLDER = "parakeet-tdt-0.6b-v3"
ULTRA_MARKER = "transcripted-model.json"
BASELINE = "parakeet-v3"


@dataclass
class Engine:
    name: str
    label: str
    kind: str  # "python" | "app-cli" | "apple-speech" | "whisperkit"
    deps: list[str] = field(default_factory=list)
    notes: str = ""
    english_only: bool = False
    default: bool = True
    # Where the process footprint misses model memory (see report notes).
    memory_note: str = ""


ENGINES: list[Engine] = [
    Engine(
        BASELINE,
        "Parakeet V3 (what the app uses today)",
        "app-cli",
        notes="Transcripted's own transcripted-cli: FluidAudio + Core ML, run on a throwaway copy of the app's model files.",
        memory_note="lower bound (Core ML)",
    ),
    Engine(
        "parakeet-ultra",
        "Parakeet Ultra (experimental)",
        "app-cli",
        notes="Same CLI on a throwaway copy of the Ultra install from PR #1783. Skipped until installed.",
        memory_note="lower bound (Core ML)",
    ),
    Engine(
        "apple-speech",
        "Apple Speech (built into macOS 26)",
        "apple-speech",
        notes="SpeechAnalyzer + SpeechTranscriber, compiled from engines/apple_speech.swift.",
        memory_note="n/a (model runs in a macOS system process)",
    ),
    Engine(
        "whisperkit-turbo",
        "Whisper large-v3-turbo (the app's Whisper option)",
        "whisperkit",
        notes="WhisperKit + Core ML, the same engine, model and revision as the app's Whisper choice. "
              "The whole-file run uses WhisperKit's VAD chunking with 4 workers (its fast path; the app decodes "
              "one segment at a time).",
        memory_note="lower bound (Core ML)",
    ),
    Engine(
        "whisper-turbo",
        "Whisper large-v3-turbo (MLX)",
        "python",
        deps=["mlx-whisper==0.4.3", "numpy"],
        notes="mlx-community/whisper-large-v3-turbo on the GPU via MLX.",
    ),
    Engine(
        "distil-whisper",
        "Distil-Whisper large-v3 (MLX)",
        "python",
        deps=["mlx-whisper==0.4.3", "numpy"],
        english_only=True,
        notes="mlx-community/distil-whisper-large-v3 on the GPU via MLX. English only.",
    ),
    Engine(
        "parakeet-v3-mlx",
        "Parakeet V3 (MLX, GPU)",
        "python",
        deps=["parakeet-mlx==0.5.2", "numpy"],
        notes="Same model as the app, but on the GPU via MLX instead of Core ML. Shows what the runtime alone is worth.",
    ),
    Engine(
        "parakeet-v2-mlx",
        "Parakeet V2 English (MLX, GPU)",
        "python",
        deps=["parakeet-mlx==0.5.2", "numpy"],
        english_only=True,
        notes="NVIDIA's English-only Parakeet TDT 0.6b v2, top of the English accuracy charts.",
    ),
    Engine(
        "canary-1b-v2",
        "NVIDIA Canary 1B v2 (ONNX, CPU)",
        "python",
        deps=["onnx-asr[cpu,hub]==0.12.0", "numpy"],
        notes="nemo-canary-1b-v2 through onnx-asr with Silero VAD chunking (one segment at a time), on the CPU.",
    ),
    Engine(
        "canary-180m-flash",
        "NVIDIA Canary 180M Flash (ONNX, CPU)",
        "python",
        deps=["onnx-asr[cpu,hub]==0.12.0", "numpy"],
        notes="istupakov/canary-180m-flash-onnx through onnx-asr with Silero VAD chunking (one segment at a time), on the CPU.",
    ),
    Engine(
        "moonshine-base",
        "Moonshine base (English)",
        "python",
        deps=["moonshine-voice==0.1.5", "numpy"],
        english_only=True,
        notes="Useful Sensors' Moonshine base through its own runtime (moonshine-voice), built-in VAD.",
    ),
    Engine(
        "moonshine-medium",
        "Moonshine medium streaming (English)",
        "python",
        deps=["moonshine-voice==0.1.5", "numpy"],
        english_only=True,
        notes="Moonshine's newest medium streaming model, same runtime.",
    ),
    Engine(
        "whisper-cpp-turbo",
        "Whisper large-v3-turbo (whisper.cpp, Metal)",
        "python",
        deps=["pywhispercpp==1.5.1", "numpy"],
        notes="ggml large-v3-turbo through whisper.cpp with Metal.",
    ),
    Engine(
        "granite-speech",
        "IBM Granite Speech 4.0 1B (MLX)",
        "python",
        deps=["mlx-audio[stt]==0.5.5", "jinja2", "numpy"],
        notes="ibm-granite/granite-4.0-1b-speech via mlx-audio, fed 30 s pieces. Near the top of the Open ASR Leaderboard.",
    ),
    Engine(
        "nemotron-streaming",
        "NVIDIA Nemotron streaming 0.6B (MLX)",
        "python",
        deps=["mlx-audio[stt]==0.5.5", "numpy"],
        english_only=True,
        notes="mlx-community/nemotron-3.5-asr-streaming-0.6b via mlx-audio, 30 s chunks.",
    ),
]
ENGINES_BY_NAME = {e.name: e for e in ENGINES}


# --------------------------------------------------------------------------
# Small helpers


def log(message: str) -> None:
    stamp = datetime.now().strftime("%H:%M:%S")
    print(f"[{stamp}] {message}", file=sys.stderr, flush=True)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kwargs)


def is_mac() -> bool:
    return sys.platform == "darwin"


def fmt_duration(seconds: float | None) -> str:
    if seconds is None:
        return "n/a"
    if seconds < 1:
        return f"{seconds * 1000:.0f} ms"
    if seconds < 90:
        return f"{seconds:.1f} s"
    minutes, secs = divmod(int(round(seconds)), 60)
    if minutes < 60:
        return f"{minutes}m {secs:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m"


# --------------------------------------------------------------------------
# Peak memory: macOS proc_pid_rusage(RUSAGE_INFO_V4).ri_lifetime_max_phys_footprint
# is the same "Memory" figure Activity Monitor shows, and unlike RSS it counts
# GPU (Metal) allocations on Apple Silicon's unified memory.

RUSAGE_INFO_V4 = 4
# rusage_info_v4 starts with a 16-byte uuid, then uint64 fields. Indexes into
# the uint64 run that follows the uuid (see <sys/resource.h>).
_RI_PHYS_FOOTPRINT = 7
_RI_LIFETIME_MAX_PHYS_FOOTPRINT = 28


class _RusageInfo(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 40)]


_libproc = None


def footprint_bytes(pid: int) -> int | None:
    """Lifetime max physical footprint of a live process, or None."""
    global _libproc
    if not is_mac():
        return _linux_peak_rss(pid)
    if _libproc is None:
        _libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib", use_errno=True)
    info = _RusageInfo()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(RUSAGE_INFO_V4), ctypes.byref(info)) != 0:
        return None
    return int(max(info.values[_RI_LIFETIME_MAX_PHYS_FOOTPRINT], info.values[_RI_PHYS_FOOTPRINT]))


def _linux_peak_rss(pid: int) -> int | None:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmHWM:"):
                return int(line.split()[1]) * 1024
    except OSError:
        return None
    return None


class MemoryWatcher:
    """Polls a child's peak footprint until it exits."""

    def __init__(self, pid: int, interval: float = 0.2):
        self.pid = pid
        self.interval = interval
        self.peak = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def _loop(self) -> None:
        while not self._stop.is_set():
            value = footprint_bytes(self.pid)
            if value:
                self.peak = max(self.peak, value)
            self._stop.wait(self.interval)

    def __enter__(self) -> "MemoryWatcher":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        self._thread.join()


def run_measured(cmd: list[str], log_path: Path, timeout: float, env: dict | None = None) -> tuple[int, float, int, str]:
    """Run a child with memory polling. Returns (exit code, wall seconds, peak bytes, stdout)."""
    started = time.monotonic()
    with open(log_path, "w") as err:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=err, text=True, env=env)
        with MemoryWatcher(proc.pid) as watcher:
            try:
                stdout, _ = proc.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                proc.kill()
                stdout, _ = proc.communicate()
                err.write(f"\nshootout: killed after {timeout:.0f}s timeout\n")
                return 124, time.monotonic() - started, watcher.peak, stdout or ""
    return proc.returncode, time.monotonic() - started, watcher.peak, stdout or ""


# --------------------------------------------------------------------------
# Captions -> reference text

_TAG = re.compile(r"<[^>]+>")
_TIMING = re.compile(r"(\d+:)?\d{2}:\d{2}[.,]\d{3}\s+-->\s+(\d+:)?\d{2}:\d{2}[.,]\d{3}")
_SPEAKER = re.compile(r"(?:^|(?<=[\s.?!]))(>>\s*)?([A-Z][A-Z0-9.'\-]+(?: [A-Z][A-Z0-9.'\-]+){0,3}|\[[^\]]+\]|\([^)]+\)):\s+")
_ANNOTATION = re.compile(r"\[[^\]]*\]|\([^)]*\)|♪[^♪]*♪|♪")


def _to_seconds(stamp: str) -> float:
    parts = stamp.replace(",", ".").split(":")
    seconds = float(parts[-1])
    minutes = int(parts[-2]) if len(parts) >= 2 else 0
    hours = int(parts[-3]) if len(parts) >= 3 else 0
    return hours * 3600 + minutes * 60 + seconds


def parse_vtt(text: str) -> list[tuple[float, float, str]]:
    """Cue list (start, end, text) with markup, speaker labels and sound notes removed."""
    cues: list[tuple[float, float, str]] = []
    blocks = re.split(r"\n\s*\n", text.replace("\r\n", "\n").replace("\r", "\n"))
    for block in blocks:
        lines = [line.strip() for line in block.split("\n") if line.strip()]
        timing_index = next((i for i, line in enumerate(lines) if _TIMING.search(line)), None)
        if timing_index is None:
            continue
        start_s, end_s = [s.strip().split()[0] for s in lines[timing_index].split("-->")]
        body_lines = []
        for line in lines[timing_index + 1:]:
            line = html.unescape(_TAG.sub("", line))
            line = _SPEAKER.sub(" ", line)
            line = _ANNOTATION.sub(" ", line)
            line = re.sub(r"\s+", " ", line.lstrip("-> ")).strip()
            if line:
                body_lines.append(line)
        body = " ".join(body_lines).strip()
        if not body:
            continue
        # Rolling captions repeat the previous line; keep only what's new.
        if cues and body == cues[-1][2]:
            continue
        cues.append((_to_seconds(start_s), _to_seconds(end_s), body))
    return cues


def reference_from_cues(cues: list[tuple[float, float, str]], limit_seconds: float | None) -> str:
    kept = [c for c in cues if limit_seconds is None or c[1] <= limit_seconds + 0.5]
    return "\n".join(c[2] for c in kept)


# --------------------------------------------------------------------------
# Text normalization + WER

_normalizer = None


def normalize_words(text: str) -> list[str]:
    """Whisper's English normalizer when installed (the Open ASR Leaderboard
    standard: spelled-out numbers, British spellings, fillers like "um" all
    normalized), else a plain lowercase/no-punctuation fallback."""
    global _normalizer
    if _normalizer is None:
        try:
            from whisper_normalizer.english import EnglishTextNormalizer  # type: ignore

            _normalizer = EnglishTextNormalizer()
        except Exception:  # noqa: BLE001 - fallback is intentional
            _normalizer = False
    if _normalizer:
        return _normalizer(text).split()
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[‘’]", "'", text)
    text = re.sub(r"[^\w\s']", " ", text)
    fillers = {"um", "uh", "hmm", "mm", "mhm", "er", "ah"}
    return [w.strip("'") for w in text.split() if w.strip("'") and w.strip("'") not in fillers]


def normalizer_name() -> str:
    normalize_words("")
    return "Whisper English normalizer" if _normalizer else "basic fallback (whisper-normalizer missing)"


def word_errors(reference: list[str], hypothesis: list[str]) -> dict:
    """Word-level edit counts (substitutions, deletions, insertions)."""
    try:
        import jiwer  # type: ignore

        out = jiwer.process_words(" ".join(reference) or "<empty>", " ".join(hypothesis) or "<empty>")
        return {
            "substitutions": out.substitutions,
            "deletions": out.deletions,
            "insertions": out.insertions,
            "reference_words": len(reference),
        }
    except ImportError:
        pass
    # Plain dynamic programming fallback, O(n*m) but fine for a self-test.
    n, m = len(reference), len(hypothesis)
    prev = [(j, 0, 0, j) for j in range(m + 1)]  # (cost, subs, dels, ins)
    for i in range(1, n + 1):
        cur = [(i, 0, i, 0)]
        for j in range(1, m + 1):
            same = reference[i - 1] == hypothesis[j - 1]
            diag = prev[j - 1]
            options = [
                (diag[0] + (0 if same else 1), diag[1] + (0 if same else 1), diag[2], diag[3]),
                (prev[j][0] + 1, prev[j][1], prev[j][2] + 1, prev[j][3]),
                (cur[j - 1][0] + 1, cur[j - 1][1], cur[j - 1][2], cur[j - 1][3] + 1),
            ]
            cur.append(min(options))
        prev = cur
    _, subs, dels, ins = prev[m]
    return {"substitutions": subs, "deletions": dels, "insertions": ins, "reference_words": n}


def score(reference_text: str, hypothesis_text: str) -> dict:
    ref = normalize_words(reference_text)
    hyp = normalize_words(hypothesis_text)
    counts = word_errors(ref, hyp)
    errors = counts["substitutions"] + counts["deletions"] + counts["insertions"]
    counts["wer"] = errors / max(1, counts["reference_words"])
    counts["hypothesis_words"] = len(hyp)
    return counts


# --------------------------------------------------------------------------
# Test audio


def find_js_runtime() -> list[str]:
    """yt-dlp needs a JavaScript runtime for YouTube. Use deno/node when on
    PATH, else the Node that ships with a GitHub Actions runner install."""
    for name in ("deno", "node", "bun"):
        found = shutil.which(name)
        if found:
            return ["--js-runtimes", f"{name}:{found}"]
    for candidate in sorted(Path.home().glob("actions-runner/externals*/node*/bin/node"), reverse=True):
        if os.access(candidate, os.X_OK):
            return ["--js-runtimes", f"node:{candidate}"]
    return []


def yt_dlp(args: list[str], capture: bool = False) -> subprocess.CompletedProcess:
    cmd = [sys.executable, "-m", "yt_dlp", "--no-playlist", *find_js_runtime(), *args]
    return subprocess.run(cmd, check=True, text=True, capture_output=capture, timeout=SETUP_TIMEOUT)


def english_caption_track(subtitles: dict) -> str | None:
    for key in ("en", "en-US", "en-GB", "en-CA"):
        if key in subtitles:
            return key
    for key in subtitles:
        if key.lower().startswith("en") and "orig" not in key.lower():
            return key
    return None


def fetch_video(urls: list[str], media_dir: Path) -> dict:
    """Download audio + human English captions for the first URL that has them."""
    media_dir.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha1(json.dumps(urls).encode()).hexdigest()[:10]
    meta_path = media_dir / f"video-{key}.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())
        if meta.get("url") in urls and Path(meta["audio"]).exists() and Path(meta["captions"]).exists():
            log(f"Using the video already downloaded: {meta['title']}")
            return meta

    problems = []
    for url in urls:
        log(f"Checking {url} for human-made English captions...")
        try:
            info = json.loads(yt_dlp(["-J", "--skip-download", url], capture=True).stdout)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
            problems.append(f"{url}: yt-dlp failed ({(getattr(error, 'stderr', '') or str(error)).strip()[-300:]})")
            continue
        track = english_caption_track(info.get("subtitles") or {})
        if not track:
            problems.append(f"{url}: no human-made English captions (auto captions don't count)")
            continue
        video_id = info["id"]
        log(f"Downloading '{info.get('title')}' ({fmt_duration(info.get('duration'))}) + '{track}' captions...")
        try:
            # AAC (m4a/mp4) because afconvert can read it and can't read WebM.
            yt_dlp([
                "-f", "bestaudio[ext=m4a]/best[ext=mp4]/bestaudio",
                "--write-subs", "--no-write-auto-subs",
                "--sub-langs", track, "--sub-format", "vtt",
                "-o", str(media_dir / f"{video_id}.%(ext)s"),
                url,
            ])
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            problems.append(f"{url}: download failed ({error})")
            continue
        audio = next((p for p in media_dir.glob(f"{video_id}.*")
                      if p.suffix.lower() in {".m4a", ".webm", ".mp4", ".opus", ".mp3"}), None)
        captions = next(iter(media_dir.glob(f"{video_id}.*.vtt")), None)
        if not audio or not captions:
            problems.append(f"{url}: download finished but audio or captions are missing")
            continue
        meta = {
            "url": url,
            "id": video_id,
            "title": info.get("title"),
            "channel": info.get("channel") or info.get("uploader"),
            "duration_seconds": info.get("duration"),
            "license": info.get("license"),
            "caption_track": track,
            "audio": str(audio),
            "captions": str(captions),
            "downloaded_at": datetime.now(timezone.utc).isoformat(),
        }
        meta_path.write_text(json.dumps(meta, indent=2))
        return meta
    sys.exit("Couldn't get a test video:\n  " + "\n  ".join(problems))


def to_wav16k(source: Path, target: Path) -> None:
    if target.exists() and target.stat().st_mtime >= source.stat().st_mtime:
        return
    tmp = target.with_suffix(".tmp.wav")
    attempts = []
    if shutil.which("afconvert"):
        attempts += [
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", "--mix", str(source), str(tmp)],
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(source), str(tmp)],
        ]
    if shutil.which("ffmpeg"):
        attempts.append(["ffmpeg", "-y", "-loglevel", "error", "-i", str(source), "-ac", "1", "-ar", "16000",
                         "-c:a", "pcm_s16le", str(tmp)])
    for cmd in attempts:
        if subprocess.run(cmd, capture_output=True).returncode == 0 and tmp.exists():
            tmp.replace(target)
            return
    sys.exit(f"Couldn't convert {source.name} to 16 kHz WAV (need afconvert or ffmpeg; "
             "YouTube .webm audio needs ffmpeg).")


def wav_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / float(w.getframerate())


def cut_wav(source: Path, target: Path, start: float, seconds: float | None) -> None:
    with wave.open(str(source), "rb") as src:
        rate = src.getframerate()
        src.setpos(min(src.getnframes(), int(start * rate)))
        frames = src.readframes(src.getnframes() if seconds is None else int(seconds * rate))
        with wave.open(str(target), "wb") as dst:
            dst.setnchannels(src.getnchannels())
            dst.setsampwidth(src.getsampwidth())
            dst.setframerate(rate)
            dst.writeframes(frames)


def pick_clip_start(cues: list[tuple[float, float, str]], clip_seconds: float, audio_seconds: float) -> float:
    """A 10 s window with lots of caption words, a little way in (skipping intros)."""
    best_start, best_words = min(120.0, max(0.0, audio_seconds - clip_seconds)), -1
    for start, _, _ in cues:
        if start < 60 or start + clip_seconds > min(audio_seconds, 900):
            continue
        words = sum(len(t.split()) for s, e, t in cues if s >= start and e <= start + clip_seconds)
        if words > best_words:
            best_start, best_words = start, words
    return best_start


def prepare_test_audio(args: argparse.Namespace, media: Path, work: Path) -> dict:
    media.mkdir(parents=True, exist_ok=True)
    if args.audio:
        source = Path(args.audio).expanduser().resolve()
        meta = {"url": None, "title": source.name, "audio": str(source), "license": None}
        reference_text = Path(args.reference).expanduser().read_text() if args.reference else None
        cues: list[tuple[float, float, str]] = []
        if args.reference and args.reference.endswith(".vtt"):
            cues = parse_vtt(reference_text or "")
            reference_text = None
    else:
        meta = fetch_video(args.url or DEFAULT_VIDEOS, media)
        source = Path(meta["audio"])
        cues = parse_vtt(Path(meta["captions"]).read_text(encoding="utf-8", errors="replace"))
        reference_text = None

    # Many recordings share a file name (every Transcripted meeting has a
    # microphone.m4a), so the converted copy is keyed by path, size and mtime.
    stat = source.stat()
    key = hashlib.sha1(f"{source}|{stat.st_size}|{stat.st_mtime_ns}".encode()).hexdigest()[:10]
    full_wav = media / f"{source.stem}-{key}-16k.wav"
    if source.suffix.lower() == ".wav" and _is_16k_mono(source):
        full_wav = source
    else:
        to_wav16k(source, full_wav)

    total_seconds = wav_seconds(full_wav)
    limit = args.minutes * 60 if args.minutes else None
    test_wav = full_wav
    if limit and limit < total_seconds:
        test_wav = media / f"{source.stem}-{key}-first-{args.minutes:g}min-16k.wav"
        cut_wav(full_wav, test_wav, 0, limit)
    test_seconds = wav_seconds(test_wav)

    if reference_text is None and cues:
        reference_text = reference_from_cues(cues, test_seconds if limit else None)
    if reference_text is not None:
        (work / "reference.txt").write_text(reference_text)

    clip_start = pick_clip_start(cues, args.clip_seconds, test_seconds)
    clip_wav = work / "latency-clip.wav"
    cut_wav(full_wav, clip_wav, clip_start, args.clip_seconds)

    meta.update({
        "test_wav": str(test_wav),
        "test_seconds": test_seconds,
        "clip_wav": str(clip_wav),
        "clip_start_seconds": clip_start,
        "clip_seconds": wav_seconds(clip_wav),
        "reference_words": len(normalize_words(reference_text)) if reference_text else 0,
    })
    return meta | {"reference_text": reference_text}


def _is_16k_mono(path: Path) -> bool:
    try:
        with wave.open(str(path), "rb") as w:
            return w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
    except (wave.Error, EOFError):
        return False


# --------------------------------------------------------------------------
# Engine runners. Every runner writes the same result JSON:
#   load_seconds, clip_cold_seconds, clip_warm_seconds (list), full_seconds,
#   text, self_peak_bytes (optional), plus anything engine-specific.


MIN_FREE_GB = 20


def folder_gb(path: Path) -> float:
    total = 0
    for p in path.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink():
                total += p.stat().st_size
        except OSError:
            pass
    return total / 1024**3


def free_gb(path: Path) -> float:
    return shutil.disk_usage(path).free / 1024**3


def check_disk(path: Path) -> None:
    """Stop before a model download could fill the disk under a live recording."""
    free = free_gb(path)
    if free < MIN_FREE_GB:
        raise SkipEngine(f"only {free:.0f} GB free; the shootout stops at {MIN_FREE_GB} GB so recordings keep room")


def child_env(base: Path) -> dict:
    """Keep every model download under the shootout folder, so one rm -rf cleans up."""
    return {
        **os.environ,
        "HF_HOME": str(base / "hf"),
        "STT_SHOOTOUT_MODELS": str(base / "models"),
        "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1",
    }


def hf_revisions(base: Path) -> dict:
    """Snapshot hash of every Hugging Face repo downloaded so far."""
    revisions = {}
    for ref in sorted((base / "hf" / "hub").glob("models--*/refs/main")):
        repo = ref.parent.parent.name.removeprefix("models--").replace("--", "/")
        revisions[repo] = ref.read_text().strip()
    # onnx-asr models live in plain folders (see OnnxAsr in py_engines.py);
    # the Hub client leaves the commit in each file's .metadata there.
    for folder in sorted((base / "models" / "onnx-asr").glob("*--*")):
        for meta in sorted(folder.glob(".cache/huggingface/download/**/*.metadata")):
            first = meta.read_text(errors="replace").splitlines()[:1]
            if first and re.fullmatch(r"[0-9a-f]{40}", first[0].strip()):
                revisions[folder.name.replace("--", "/", 1)] = first[0].strip()
                break
    return revisions


def ensure_uv() -> str:
    found = shutil.which("uv") or next((str(p) for p in [Path.home() / ".local/bin/uv", Path.home() / ".cargo/bin/uv"] if p.exists()), None)
    if not found:
        sys.exit("uv is missing. run.sh installs it; or: curl -LsSf https://astral.sh/uv/install.sh | sh")
    return found


def python_env(engine: Engine, work: Path) -> Path:
    """One venv per engine so model packages can't fight over versions."""
    env_dir = work / "envs" / engine.name
    python = env_dir / "bin" / "python"
    stamp = env_dir / ".deps"
    wanted = json.dumps(sorted(engine.deps))
    if python.exists() and stamp.exists() and stamp.read_text() == wanted:
        return python
    uv = ensure_uv()
    log(f"Setting up Python for {engine.label} ({', '.join(engine.deps)})...")
    shutil.rmtree(env_dir, ignore_errors=True)
    run([uv, "venv", "--quiet", "--python", PYTHON_VERSION, str(env_dir)], timeout=SETUP_TIMEOUT)
    run([uv, "pip", "install", "--quiet", "--python", str(python), *engine.deps], timeout=SETUP_TIMEOUT)
    freeze = subprocess.run([uv, "pip", "freeze", "--python", str(python)], capture_output=True, text=True)
    (env_dir / "packages.txt").write_text(freeze.stdout)
    stamp.write_text(wanted)
    return python


def find_app_cli(explicit: str | None) -> Path | None:
    candidates = [Path(explicit)] if explicit else []
    if os.environ.get("TRANSCRIPTED_CLI"):
        candidates.append(Path(os.environ["TRANSCRIPTED_CLI"]))
    candidates += APP_CLI_CANDIDATES
    return next((c for c in candidates if c.is_file() and os.access(c, os.X_OK)), None)


class SkipEngine(Exception):
    pass


def run_python_engine(engine: Engine, meta: dict, work: Path, args: argparse.Namespace, out: Path) -> dict:
    check_disk(args.base)
    python = python_env(engine, args.base)
    cmd = [str(python), str(PY_ENGINES), "--engine", engine.name, "--audio", meta["test_wav"],
           "--clip", meta["clip_wav"], "--runs", str(args.latency_runs), "--out", str(out)]
    result = _run_child(engine, cmd, work, args, env=child_env(args.base))
    packages = python.parent.parent / "packages.txt"
    if packages.exists():
        result["packages"] = [line for line in packages.read_text().splitlines() if line.strip()]
    return result


def run_app_cli_engine(engine: Engine, meta: dict, work: Path, args: argparse.Namespace, out: Path) -> dict:
    cli = find_app_cli(args.cli)
    if not cli:
        raise SkipEngine("transcripted-cli not found (install Transcripted in /Applications or pass --cli)")
    check_disk(args.base)
    models = stage_app_models(engine, cli, args.base)
    cmd = [str(cli), "transcribe", "--json", "--no-download", "--models-dir", str(models)]
    # The CLI loads the model once, then transcribes each file in order and
    # reports per-file processing time: the clip copies give cold + warm
    # latency, the last file is the full test.
    clips_dir = work / "clips"
    clips_dir.mkdir(exist_ok=True)
    clips = []
    for i in range(args.latency_runs + 1):
        copy = clips_dir / f"clip-{i}.wav"
        shutil.copyfile(meta["clip_wav"], copy)
        clips.append(str(copy))
    cmd += [*clips, meta["test_wav"]]
    # Per-file JSON outputs, so nothing a library prints to stdout can break parsing.
    cli_out = work / "cli-out" / engine.name
    shutil.rmtree(cli_out, ignore_errors=True)
    cmd[3:3] = ["--output-dir", str(cli_out)]
    env = {**os.environ, "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"}
    started = time.monotonic()
    code, wall, peak, _ = run_measured(cmd, work / "logs" / f"{engine.name}.log", args.timeout, env)
    if code != 0:
        raise RuntimeError(f"transcripted-cli exited {code}; see logs/{engine.name}.log")
    if engine.name == "parakeet-ultra" and not (models / ULTRA_MARKER).exists():
        # FluidAudio swaps a folder it can't load for a stock V3 download.
        raise RuntimeError("the Ultra model didn't load (FluidAudio replaced it with stock V3), so these aren't Ultra numbers")
    outputs = []
    for media in [*clips, meta["test_wav"]]:
        decoded = json.loads((cli_out / f"{Path(media).stem}.json").read_text())
        outputs.append(decoded[0] if isinstance(decoded, list) else decoded)
    clip_times = [o["processingSeconds"] for o in outputs[:-1]]
    full = outputs[-1]
    # No separate load timer in the CLI: wall time minus transcription time is
    # model load plus audio decoding, reported as load.
    result = {
        "load_seconds": max(0.0, wall - sum(o["processingSeconds"] for o in outputs)),
        "load_includes_decode": True,
        "clip_cold_seconds": clip_times[0],
        "clip_warm_seconds": clip_times[1:],
        "full_seconds": full["processingSeconds"],
        "text": full["text"],
        "clip_text": outputs[0]["text"],
        "wall_seconds": time.monotonic() - started,
        "peak_bytes": peak,
        "cli": str(cli),
    }
    out.write_text(json.dumps(result, indent=2))
    return result


def stage_app_models(engine: Engine, cli: Path, base: Path) -> Path:
    """Copy the model folder the app uses into the shootout folder and run on the copy.

    FluidAudio deletes and re-downloads a model folder it fails to load, even
    with --no-download. Pointed at the app's own files, a load failure could
    delete the model inside the signed app bundle or swap the Ultra install
    for stock V3. An APFS clone (cp -c) costs no disk and takes the hit instead.
    """
    if engine.name == "parakeet-ultra":
        if not (ULTRA_DIR / ULTRA_MARKER).exists():
            raise SkipEngine("Parakeet Ultra isn't installed (scripts/models/parakeet-ultra/install.sh from PR #1783)")
        source = ULTRA_DIR
    else:
        bundled = cli.resolve().parent.parent / "Resources" / "parakeet-models" / V3_FOLDER
        source = next((p for p in (bundled, FLUIDAUDIO_V3_CACHE) if p.is_dir() and any(p.glob("*.mlmodelc"))), None)
        if source is None:
            raise SkipEngine(f"no Parakeet V3 model files in the app bundle or {FLUIDAUDIO_V3_CACHE}")
    # FluidAudio expects the folder itself to be named parakeet-tdt-0.6b-v3.
    target = base / "models" / "app-cli" / engine.name / V3_FOLDER
    shutil.rmtree(target, ignore_errors=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-cR", str(source), str(target)], capture_output=True).returncode != 0:
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(source, target, symlinks=True)
    return target


def build_apple_speech(base: Path, work: Path) -> Path:
    binary = base / "bin" / "apple-speech-bench"
    if binary.exists() and binary.stat().st_mtime >= APPLE_SPEECH_SWIFT.stat().st_mtime:
        return binary
    if not shutil.which("xcrun"):
        raise SkipEngine("xcrun missing (install Xcode Command Line Tools)")
    binary.parent.mkdir(parents=True, exist_ok=True)
    log("Compiling the Apple Speech helper...")
    result = subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                             str(APPLE_SPEECH_SWIFT), "-o", str(binary)],
                            capture_output=True, text=True, timeout=SETUP_TIMEOUT)
    if result.returncode != 0:
        (work / "logs" / "apple-speech-build.log").write_text(result.stdout + result.stderr)
        raise RuntimeError("Apple Speech helper didn't compile; see logs/apple-speech-build.log")
    return binary


def build_whisperkit(base: Path, work: Path) -> Path:
    scratch = base / "build" / "whisperkit-bench"
    binary = scratch / "release" / "whisperkit-bench"
    sources = [WHISPERKIT_PACKAGE / "Package.swift", *WHISPERKIT_PACKAGE.glob("Sources/**/*.swift")]
    if binary.exists() and all(binary.stat().st_mtime >= p.stat().st_mtime for p in sources):
        return binary
    if not shutil.which("xcrun"):
        raise SkipEngine("xcrun missing (install Xcode Command Line Tools)")
    log("Building the WhisperKit helper (first time takes a few minutes)...")
    result = subprocess.run(["xcrun", "swift", "build", "-c", "release", "--package-path", str(WHISPERKIT_PACKAGE),
                             "--scratch-path", str(scratch), "--product", "whisperkit-bench"],
                            capture_output=True, text=True, timeout=SETUP_TIMEOUT)
    if result.returncode != 0 or not binary.exists():
        (work / "logs" / "whisperkit-build.log").write_text(result.stdout + result.stderr)
        raise RuntimeError("WhisperKit helper didn't build; see logs/whisperkit-build.log")
    return binary


def run_whisperkit_engine(engine: Engine, meta: dict, work: Path, args: argparse.Namespace, out: Path) -> dict:
    if not is_mac():
        raise SkipEngine("macOS only")
    check_disk(args.base)
    binary = build_whisperkit(args.base, work)
    cmd = [str(binary), "--audio", meta["test_wav"], "--clip", meta["clip_wav"], "--runs", str(args.latency_runs),
           "--models-dir", str(args.base / "models" / "whisperkit"), "--out", str(out)]
    result = _run_child(engine, cmd, work, args, env=child_env(args.base))
    result["model_files"] = whisperkit_model_record(args.base / "models" / "whisperkit", result.get("model", ""))
    return result


def whisperkit_model_record(root: Path, variant: str) -> dict:
    """Which WhisperKit model files were measured: the Hub commit when the
    download left one in its metadata, plus a size fingerprint either way."""
    folder = next((p for p in root.rglob(f"*{variant}") if p.is_dir()), None) if variant else None
    if folder is None:
        return {"variant": variant, "found": False}
    files = sorted(p for p in folder.rglob("*") if p.is_file())
    fingerprint = hashlib.sha1("".join(f"{p.relative_to(folder)}:{p.stat().st_size};" for p in files).encode())
    commits = set()
    for meta in root.rglob("*.metadata"):
        try:
            first = meta.read_text().splitlines()[0].strip()
        except (OSError, IndexError, UnicodeDecodeError):
            continue
        if re.fullmatch(r"[0-9a-f]{40}", first):
            commits.add(first)
    return {"variant": variant, "found": True, "files": len(files),
            "size_fingerprint": fingerprint.hexdigest()[:16], "hub_commits": sorted(commits)}


def run_apple_speech_engine(engine: Engine, meta: dict, work: Path, args: argparse.Namespace, out: Path) -> dict:
    if not is_mac():
        raise SkipEngine("macOS only")
    binary = build_apple_speech(args.base, work)
    cmd = [str(binary), "--audio", meta["test_wav"], "--clip", meta["clip_wav"],
           "--runs", str(args.latency_runs), "--locale", args.locale, "--out", str(out)]
    return _run_child(engine, cmd, work, args)


def _run_child(engine: Engine, cmd: list[str], work: Path, args: argparse.Namespace, env: dict | None = None) -> dict:
    out = Path(cmd[cmd.index("--out") + 1])
    out.unlink(missing_ok=True)
    code, wall, peak, _ = run_measured(cmd, work / "logs" / f"{engine.name}.log", args.timeout, env)
    try:
        result = json.loads(out.read_text())
    except (OSError, json.JSONDecodeError):
        raise RuntimeError(f"exited {code} without results; see logs/{engine.name}.log") from None
    # Results written before a crash in teardown still count.
    result["exit_code"] = code
    result["wall_seconds"] = wall
    result["peak_bytes"] = max(peak, int(result.get("self_peak_bytes") or 0))
    out.write_text(json.dumps(result, indent=2))
    return result


RUNNERS = {
    "python": run_python_engine,
    "app-cli": run_app_cli_engine,
    "apple-speech": run_apple_speech_engine,
    "whisperkit": run_whisperkit_engine,
}


# --------------------------------------------------------------------------
# Report


def summarize(engine: Engine, result: dict, meta: dict) -> dict:
    row = {
        "engine": engine.name,
        "label": engine.label,
        "english_only": engine.english_only,
        "memory_note": engine.memory_note,
        "status": result.get("status", "ok"),
        "error": result.get("error"),
    }
    if row["status"] != "ok":
        return row
    audio = meta["test_seconds"]
    warm = result.get("clip_warm_seconds") or []
    row.update({
        "load_seconds": result.get("load_seconds"),
        "clip_cold_seconds": result.get("clip_cold_seconds"),
        "clip_warm_seconds": statistics.median(warm) if warm else result.get("clip_cold_seconds"),
        "full_seconds": result["full_seconds"],
        "speed_x_realtime": audio / result["full_seconds"] if result["full_seconds"] else None,
        "rtf": result["full_seconds"] / audio if audio else None,
        "peak_memory_mb": (result.get("peak_bytes") or 0) / 1_048_576 or None,
        "packages": result.get("packages"),
        "model": result.get("model"),
        "model_files": result.get("model_files"),
        "settings": result.get("settings"),
        "conditions": result.get("conditions"),
    })
    if meta.get("reference_text"):
        row.update({f"wer_{k}" if k != "wer" else "wer": v for k, v in score(meta["reference_text"], result.get("text", "")).items()})
        row["broken_output"] = broken_output(row)
    return row


def broken_output(row: dict) -> str | None:
    """A WER this far off means the model or its adapter is broken (looping,
    wrong language, dropped audio), not that it's a bit less accurate."""
    ref, hyp = row.get("wer_reference_words") or 0, row.get("wer_hypothesis_words") or 0
    if ref and hyp > 1.5 * ref:
        return f"made up words: {hyp:,} words out vs {ref:,} in the answer key"
    if ref and hyp < 0.5 * ref:
        return f"dropped speech: {hyp:,} words out vs {ref:,} in the answer key"
    if row.get("wer", 0) > 0.5:
        return f"WER {row['wer'] * 100:.0f}%"
    return None


def busy_conditions(row: dict) -> list[str]:
    """What might have slowed this row: the app running, or battery power,
    checked right before and right after the model ran."""
    found = []
    for when in ("before", "after"):
        state = (row.get("conditions") or {}).get(when) or {}
        if state.get("transcripted_running") and "Transcripted was running" not in found:
            found.append("Transcripted was running")
        if state.get("on_battery") and "on battery" not in found:
            found.append("on battery")
    return found


def write_report(rows: list[dict], meta: dict, work: Path, args: argparse.Namespace) -> Path:
    baseline = next((r for r in rows if r["engine"] == BASELINE and r["status"] == "ok"), None)
    for row in rows:
        if row["status"] == "ok" and baseline and row["full_seconds"]:
            row["speed_vs_parakeet"] = baseline["full_seconds"] / row["full_seconds"]
            if "wer" in row and "wer" in baseline:
                row["wer_vs_parakeet_points"] = (row["wer"] - baseline["wer"]) * 100

    ok = sorted((r for r in rows if r["status"] == "ok"), key=lambda r: r["full_seconds"])
    not_ok = [r for r in rows if r["status"] != "ok"]

    report = json.dumps({
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "machine": machine_info(),
        "conditions": run_conditions(),
        "normalizer": normalizer_name(),
        "hf_model_revisions": hf_revisions(args.base),
        "test": {k: v for k, v in meta.items() if k != "reference_text"},
        "results": rows,
    }, indent=2)
    # No personal paths in anything that gets pasted around.
    (work / "report.json").write_text(report.replace(str(Path.home()), "~"))

    csv_fields = ["engine", "label", "status", "full_seconds", "speed_x_realtime", "speed_vs_parakeet",
                  "clip_warm_seconds", "clip_cold_seconds", "load_seconds", "peak_memory_mb", "wer",
                  "wer_vs_parakeet_points", "english_only", "error"]
    with open(work / "report.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=csv_fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(ok + not_ok)

    def pct(v):
        return "n/a" if v is None else f"{v * 100:.1f}%"

    lines = [
        "# Speech-to-text shootout",
        "",
        f"Test audio: **{meta.get('title')}** ({fmt_duration(meta['test_seconds'])})"
        + (f", {meta['url']}" if meta.get("url") else ""),
        f"Machine: {machine_info()['summary']}",
        "Answer key: " + (
            f"{'human-made YouTube captions' if meta.get('url') else 'reference transcript'}, {meta['reference_words']} words"
            if meta.get("reference_words") else "none, so no WER"),
        "",
        "| Model | Whole test took | Speed (× real time) | vs Parakeet V3 | Latency (10 s clip) | First-use latency | Load | Peak memory | WER |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in ok:
        ratio = r.get("speed_vs_parakeet")
        vs = "n/a" if not ratio else (f"{ratio:.1f}× faster" if ratio >= 1 else f"{1 / ratio:.1f}× slower")
        if r["engine"] == BASELINE:
            vs = "baseline"
        mem = f"{r['peak_memory_mb'] / 1024:.1f} GB" if r.get("peak_memory_mb") and r["peak_memory_mb"] >= 1024 else (
            f"{r['peak_memory_mb']:.0f} MB" if r.get("peak_memory_mb") else "n/a")
        if r.get("memory_note", "").startswith("n/a"):
            mem = "n/a †"
        elif r.get("memory_note"):
            mem += " †"
        label = r["label"] + (" *" if r["english_only"] else "") + (" ‡" if busy_conditions(r) else "")
        speed = f"{r['speed_x_realtime']:.0f}×" if r.get("speed_x_realtime") else "n/a"
        lines.append(
            f"| {label} | {fmt_duration(r['full_seconds'])} | {speed} | {vs} | "
            f"{fmt_duration(r.get('clip_warm_seconds'))} | {fmt_duration(r.get('clip_cold_seconds'))} | "
            f"{fmt_duration(r.get('load_seconds'))} | {mem} | {pct(r.get('wer'))}{' ⚠' if r.get('broken_output') else ''} |"
        )
    lines += [
        "",
        "\\* English only." + (" ‡ Something else might have slowed this row (see below)." if any(busy_conditions(r) for r in ok) else "")
        + (" ⚠ Broken output (see below), left out of the pick." if any(r.get("broken_output") for r in ok) else ""),
        "",
        "- **Latency** is how long a 10-second dictation takes to come back with the model already loaded "
        "(median of the warm runs). **First-use latency** is the very first run after loading.",
        "- **WER** (word error rate) is the share of words wrong vs the captions, lower is better. "
        "Captions are cleaned up a little by the people who write them, so every model has the same floor; "
        "compare models to each other, not to zero.",
        "- **Peak memory** is the model process's peak footprint (the Activity Monitor number; MLX GPU memory "
        "included). † Not comparable: Core ML rows (Parakeet via the app, WhisperKit) likely under-count Neural "
        "Engine memory, so read them as a lower bound, and Apple Speech runs its model inside a macOS system "
        "process this can't see.",
        "- WhisperKit's whole-hour time uses its VAD chunking with 4 parallel workers (its fast path). The app "
        "decodes one segment at a time, so the app would be slower than this row on a long file.",
        "- The app-CLI rows' **Load** includes process start and decoding the audio files. Apple Speech has "
        "no separate load step, so its model load shows up in **First-use latency**.",
        f"- Text normalizer: {meta.get('normalizer', normalizer_name())}.",
        "- **Load** is only comparable on a warm cache: the quick `--minutes 3` pass downloads every model's files first.",
    ]
    pick = recommend(ok, baseline)
    if pick:
        lines += ["", f"**Pick:** {pick}"]
    broken = [r for r in ok if r.get("broken_output")]
    if broken:
        lines += ["", "## Broken output", ""]
        lines += [f"- {r['label']}: {r['broken_output']}. Check `transcripts/{r['engine']}.txt`." for r in broken]
    busy = [r for r in ok if busy_conditions(r)]
    if busy:
        lines += ["", "## Might be slowed down", ""]
        lines += [f"- {r['label']}: {', '.join(busy_conditions(r))}." for r in busy]
    if not_ok:
        lines += ["", "## Didn't run", ""]
        lines += [f"- {r['label']}: {r.get('error')}" for r in not_ok]
    path = work / "report.md"
    path.write_text("\n".join(lines) + "\n")
    return path


def recommend(ok: list[dict], baseline: dict | None) -> str | None:
    """Fastest model whose WER is within 0.5 points of the most accurate one."""
    scored = [r for r in ok if r.get("wer") is not None and not r.get("broken_output")]
    if not scored:
        return None
    best_wer = min(r["wer"] for r in scored)
    close = sorted((r for r in scored if r["wer"] <= best_wer + 0.005), key=lambda r: r["full_seconds"])
    pick = close[0]
    note = f"{pick['label']}: fastest of the models within half a point of the best WER"
    if baseline and pick["engine"] != BASELINE:
        note += f" ({pick['speed_vs_parakeet']:.1f}× Parakeet V3's speed, WER {pick['wer'] * 100:.1f}% vs {baseline['wer'] * 100:.1f}%)"
    elif pick["engine"] == BASELINE:
        note += " (nothing beat what the app already uses)"
    return note + "."


def rerun_wanted(rerun: str, name: str) -> bool:
    return rerun == "all" or name in {n.strip() for n in rerun.split(",")}


def run_conditions() -> dict:
    """Things that skew speed numbers: the app competing for the GPU/ANE, battery power."""
    conditions: dict = {}
    if not is_mac():
        return conditions
    running = subprocess.run(["pgrep", "-x", "Transcripted"], capture_output=True).returncode == 0
    conditions["transcripted_running"] = running
    power = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout
    conditions["on_battery"] = "Battery Power" in power
    return conditions


def machine_info() -> dict:
    info = {"python": platform.python_version(), "platform": platform.platform()}
    if is_mac():
        def sysctl(key):
            try:
                return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True).stdout.strip()
            except OSError:
                return ""
        info["chip"] = sysctl("machdep.cpu.brand_string")
        mem = sysctl("hw.memsize")
        info["memory_gb"] = round(int(mem) / 1024**3) if mem.isdigit() else None
        info["macos"] = platform.mac_ver()[0]
        info["summary"] = f"{info['chip']}, {info['memory_gb']} GB, macOS {info['macos']}"
    else:
        info["summary"] = platform.platform()
    return info


# --------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--work", type=Path, default=Path.home() / "stt-shootout",
                        help="Where downloads, envs, transcripts and the report go (default ~/stt-shootout)")
    parser.add_argument("--url", action="append", help="YouTube URL to test with (repeatable; first one with human captions wins)")
    parser.add_argument("--audio", help="Use a local audio/video file instead of YouTube")
    parser.add_argument("--reference", help="Reference transcript for --audio (.txt, or .vtt captions)")
    parser.add_argument("--minutes", type=float, help="Only use the first N minutes (quick check)")
    parser.add_argument("--engines", help="Comma list of models to run (default: all)")
    parser.add_argument("--skip", help="Comma list of models to skip")
    parser.add_argument("--rerun", nargs="?", const="all", default="",
                        help="Re-run models that already have results: all of them, or a comma list "
                             "(the rest reuse their results, so the report stays complete)")
    parser.add_argument("--latency-runs", type=int, default=3, help="Warm 10 s clip runs per model (default 3)")
    parser.add_argument("--clip-seconds", type=float, default=10.0)
    parser.add_argument("--timeout", type=float, default=3 * 3600, help="Per-model time limit in seconds")
    parser.add_argument("--locale", default="en-US", help="Apple Speech locale")
    parser.add_argument("--cli", help="Path to transcripted-cli (default: the installed app's)")
    parser.add_argument("--json-out", type=Path, help="Also copy report.json here (for other tools, like the test lab)")
    parser.add_argument("--list-engines", action="store_true")
    parser.add_argument("--self-test", action="store_true", help="Check caption parsing and scoring, then exit")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return
    if args.list_engines:
        for e in ENGINES:
            print(f"{e.name:18} {e.label}{'  [English only]' if e.english_only else ''}\n{'':18} {e.notes}")
        return

    selected = [e for e in ENGINES if e.default]
    if args.engines:
        names = [n.strip() for n in args.engines.split(",") if n.strip()]
        unknown = [n for n in names if n not in ENGINES_BY_NAME and n != "fake"]
        if unknown:
            sys.exit(f"Unknown model(s): {', '.join(unknown)}. See --list-engines.")
        selected = [ENGINES_BY_NAME.get(n) or Engine("fake", "Fake engine (self-check)", "python", deps=["numpy"]) for n in names]
    if args.skip:
        skip = {n.strip() for n in args.skip.split(",")}
        selected = [e for e in selected if e.name not in skip]

    base = args.work.expanduser().resolve()
    tag = f"first-{args.minutes:g}min" if args.minutes else "full"
    if args.audio or args.url:
        # A different test file must not reuse another file's results.
        tag += "-" + hashlib.sha1(json.dumps([args.audio, args.url, args.reference]).encode()).hexdigest()[:8]
    args.base = base
    work = base / "runs" / tag
    for sub in ("logs", "results", "transcripts"):
        (work / sub).mkdir(parents=True, exist_ok=True)

    meta = prepare_test_audio(args, base / "media", work)
    conditions = run_conditions()
    if conditions.get("transcripted_running"):
        log("Heads up: Transcripted is running, so it shares the GPU and Neural Engine with the models. "
            "Quit it (when you're not recording) for cleaner numbers.")
    if conditions.get("on_battery"):
        log("Heads up: on battery. Plug in so the Mac doesn't throttle the later models.")
    log(f"{free_gb(base):.0f} GB free; the shootout stops downloading models below {MIN_FREE_GB} GB.")
    log(f"Test audio: {fmt_duration(meta['test_seconds'])}, latency clip at {meta['clip_start_seconds']:.0f}s, "
        f"{meta['reference_words']} reference words")

    rows = []
    for engine in selected:
        out = work / "results" / f"{engine.name}.json"
        result: dict
        settings = {"clip_seconds": args.clip_seconds, "latency_runs": args.latency_runs,
                    "clip_start_seconds": meta["clip_start_seconds"], "test_seconds": round(meta["test_seconds"], 1)}
        previous = json.loads(out.read_text()) if out.exists() and not rerun_wanted(args.rerun, engine.name) else None
        if previous and previous.get("settings") == settings:
            result = previous
            log(f"{engine.label}: reusing earlier result (--rerun to redo)")
        else:
            log(f"Running {engine.label}...")
            before = run_conditions()
            try:
                result = RUNNERS[engine.kind](engine, meta, work, args, out)
                result["status"] = "ok"
                result["settings"] = settings
                result["conditions"] = {"before": before, "after": run_conditions()}
                out.write_text(json.dumps(result, indent=2))
                log(f"  done: {fmt_duration(result['full_seconds'])} for the whole test")
            except SkipEngine as skip:
                result = {"status": "skipped", "error": str(skip)}
                log(f"  skipped: {skip}")
            except Exception as error:  # noqa: BLE001 - one model failing must not stop the rest
                result = {"status": "failed", "error": str(error)}
                log(f"  failed: {error}")
        if result.get("status") == "ok":
            (work / "transcripts" / f"{engine.name}.txt").write_text(result.get("text", "") + "\n")
        rows.append(summarize(engine, result, meta))

    report = write_report(rows, meta, work, args)
    print(report.read_text())
    if args.json_out:
        args.json_out.expanduser().parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(work / "report.json", args.json_out.expanduser())
    log(f"Report: {report}")
    log(f"Everything the shootout downloaded is in {base} (about {folder_gb(base):.0f} GB). "
        f"To remove it all: rm -rf {base} ~/stt-shootout-src && git -C ~/transcripted worktree prune")


def self_test() -> None:
    vtt = """WEBVTT
Kind: captions
Language: en

00:00:00.000 --> 00:00:03.000
PROFESSOR: So today we're going to talk
about <c>peak finding</c>.

00:00:03.000 --> 00:00:05.500
[LAUGHTER]

00:00:05.500 --> 00:00:08.000
>> AUDIENCE: Is it O(n)?

00:00:08.000 --> 00:00:10.000
It's 10 &amp; that's it.

00:00:10.000 --> 00:00:12.000
That's the license. PROFESSOR: So f of x. Note: fine.
"""
    cues = parse_vtt(vtt)
    assert [c[2] for c in cues] == [
        "So today we're going to talk about peak finding.",
        "Is it O ?",
        "It's 10 & that's it.",
        "That's the license. So f of x. Note: fine.",
    ], cues
    assert reference_from_cues(cues, 8.0).count("\n") == 1
    assert cues[0][0] == 0.0 and cues[2][1] == 10.0 and len(cues) == 4

    r = score("the cat sat on the mat", "the cat sat on a mat um")
    assert r["substitutions"] == 1 and r["deletions"] == 0, r
    assert abs(r["wer"] - 1 / 6) < 1e-9 or abs(r["wer"] - 2 / 6) < 1e-9, r  # "um" dropped by normalizer
    assert score("", "")["wer"] == 0

    assert _to_seconds("01:02:03.500") == 3723.5
    assert pick_clip_start([(70.0, 75.0, "a b c"), (75.0, 80.0, "d e f g")], 10, 3000) == 70.0
    assert fmt_duration(0.25) == "250 ms" and fmt_duration(3720) == "1h 02m"

    # The first Mac run: Canary 180M wrote 15,489 words for a 7,191-word key.
    looping = {"wer": 1.41, "wer_reference_words": 7191, "wer_hypothesis_words": 15489}
    assert broken_output(looping).startswith("made up words")
    assert broken_output({"wer": 0.07, "wer_reference_words": 7191, "wer_hypothesis_words": 7100}) is None
    assert broken_output({"wer": 0.6, "wer_reference_words": 100, "wer_hypothesis_words": 100}) == "WER 60%"
    fast_but_broken = {"engine": "x", "label": "X", "wer": 1.41, "full_seconds": 1.0, "broken_output": "loop"}
    good = {"engine": BASELINE, "label": "V3", "wer": 0.072, "full_seconds": 7.0}
    assert recommend([fast_but_broken, good], good).startswith("V3")
    assert busy_conditions({"conditions": {"before": {"transcripted_running": False},
                                           "after": {"transcripted_running": True, "on_battery": True}}}) == [
        "Transcripted was running", "on battery"]
    assert busy_conditions({}) == []
    assert rerun_wanted("all", "x") and rerun_wanted("a, x", "x") and not rerun_wanted("a", "x") and not rerun_wanted("", "x")
    print("self-test ok")


if __name__ == "__main__":
    main()
