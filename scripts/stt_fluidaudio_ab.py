#!/usr/bin/env python3
"""FluidAudio A/B for Parakeet V3: does a FluidAudio bump change what users get?

Run it on an Apple Silicon Mac through the wrapper, which builds the CLI twice
(once per FluidAudio version) and then calls this file:

    bash scripts/stt_fluidaudio_ab.sh            # baseline origin/main @ 0.15.4 vs HEAD @ 0.17.0
    bash scripts/stt_fluidaudio_ab.sh --quick    # 3-minute plumbing check

It answers the two questions that block the FluidAudio 0.17 bump:

1. Accuracy. Word error rate on a captioned lecture: one long piece (default
   the first 20 minutes, which exercises the >15 s chunk merging that 0.17
   changed) plus dictation-length pieces (default 10 x ~45 s, cut on caption
   boundaries). Gate: candidate WER no worse than baseline + 0.5 points.
2. Dictation stop time on audio with nothing to hear. FluidAudio PR #909
   retries a blank V3 decode up to 5 more times, so silence, near-silence and
   short noise could take longer to come back, and dictation stop waits on
   exactly that call. Gate, per clip: candidate median <= 1.25 x baseline
   median AND at most +300 ms. Short spoken clips (macOS `say`) are timed and
   reported too, but not gated.

Reuse:
- Test audio, caption parsing, the WER scorer (Whisper English normalizer +
  jiwer), model staging idea, memory polling and machine info all come from the
  STT shootout (scripts/stt-shootout/shootout.py, PR #1788). If that file is not
  in this checkout yet, it is read from a git ref (origin/main, then the
  shootout branch) into <base>/vendor/. Its lecture download is shared with a
  shootout run through ~/stt-shootout/media when that folder exists.
- Speech clips are made the same way as the hill-climb dictation-stop bench:
  `say` (Samantha, 170 wpm) + `afconvert` to 16 kHz mono.

Timing is `processingSeconds` from `transcripted-cli transcribe --json`: wall
clock around AsrManager.transcribe only, the same call the app's dictation stop
makes (ParakeetEngine), with the model already loaded. Each CLI process loads
the model once, transcribes two warm-up clips (thrown away), then every clip
`--repeats` times, interleaved. `--rounds` processes per side run in ABBA
order so thermal drift hits both sides alike. Medians over all runs.

Output: <out-dir>/result.json and <out-dir>/report.md; the last stdout line is
the result.json path. Exit 0 = gate passed, 3 = gate failed, 1 = a side could
not run (result.json still written when possible).

Unit tests (Linux, no Swift): python3 scripts/test_stt_fluidaudio_ab.py
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
import platform
import random
import shutil
import statistics
import subprocess
import sys
import wave
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SCHEMA = "transcripted.stt-fluidaudio-ab/1"
SAMPLE_RATE = 16_000
SIDES = ("baseline", "candidate")

SHOOTOUT_PATH = "scripts/stt-shootout/shootout.py"
SHOOTOUT_REFS = ("origin/main", "origin/claude/stt-model-shootout-0647al")

APP_MODEL_DIRS = (
    Path("/Applications/Transcripted.app/Contents/Resources/parakeet-models"),
    Path.home() / "Applications/Transcripted.app/Contents/Resources/parakeet-models",
)

# Same voice and rate as scripts/hillclimb/benches/dictation_stop.py.
SAY_VOICE = "Samantha"
SAY_RATE = 170

# Dictation-stop clips. "blank" clips have nothing to transcribe: they are the
# case PR #909's blank-retry slows down, and the only ones the time gate checks.
STOP_CASES: tuple[dict, ...] = (
    {"id": "silence-1s", "kind": "silence", "seconds": 1.0},
    {"id": "silence-3s", "kind": "silence", "seconds": 3.0},
    {"id": "silence-8s", "kind": "silence", "seconds": 8.0},
    # About +-2 LSB of dither: what a muted or very quiet mic really delivers.
    {"id": "near-silence-3s", "kind": "noise", "seconds": 3.0, "dbfs": -84.0, "color": "white", "seed": 11},
    {"id": "noise-white-3s", "kind": "noise", "seconds": 3.0, "dbfs": -50.0, "color": "white", "seed": 12},
    # Low rumble at a room-tone level (fan, HVAC).
    {"id": "noise-room-8s", "kind": "noise", "seconds": 8.0, "dbfs": -40.0, "color": "brown", "seed": 13},
    # A short noisy tap of the hotkey: 0.5 s, the CLI pads it to 1 s like the app.
    {"id": "noise-burst-0.5s", "kind": "noise", "seconds": 0.5, "dbfs": -35.0, "color": "white", "seed": 14},
    {"id": "say-okay", "kind": "speech", "text": "Okay."},
    {"id": "say-okay-then-3s-silence", "kind": "speech", "text": "Okay.", "trailing_silence": 3.0},
    {"id": "say-send-it", "kind": "speech", "text": "Send it."},
    {"id": "say-sentence", "kind": "speech",
     "text": "Move the design review to Thursday afternoon and send the notes to the team."},
)

DEFAULT_THRESHOLDS = {
    "max_wer_delta_pp": 0.5,
    "max_time_ratio": 1.25,
    "max_time_delta_ms": 300.0,
}


def log(message: str) -> None:
    print(f"[stt-ab] {message}", file=sys.stderr, flush=True)


def case_class(case: Mapping[str, Any]) -> str:
    return "speech" if case.get("kind") == "speech" else "blank"


# ------------------------------------------------------------------ shootout


def resolve_shootout(explicit: str | None, repo: Path, cache_dir: Path) -> tuple[Path, str]:
    """Find the STT shootout module: --shootout, this checkout, then a git ref."""
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_file():
            raise SystemExit(f"--shootout {explicit}: no such file")
        return path, f"file {path}"
    in_tree = repo / SHOOTOUT_PATH
    if in_tree.is_file():
        return in_tree, f"checkout {SHOOTOUT_PATH}"
    for ref in SHOOTOUT_REFS:
        shown = subprocess.run(["git", "-C", str(repo), "show", f"{ref}:{SHOOTOUT_PATH}"],
                               capture_output=True, text=True)
        if shown.returncode != 0 or not shown.stdout.strip():
            continue
        digest = hashlib.sha256(shown.stdout.encode()).hexdigest()[:12]
        cache_dir.mkdir(parents=True, exist_ok=True)
        path = cache_dir / f"shootout-{digest}.py"
        if not path.exists():
            path.write_text(shown.stdout)
        return path, f"git {ref}:{SHOOTOUT_PATH}"
    raise SystemExit(
        "Couldn't find the STT shootout (scripts/stt-shootout/shootout.py). "
        "Run `git fetch origin` or pass --shootout PATH."
    )


def load_shootout(path: Path):
    spec = importlib.util.spec_from_file_location("stt_shootout", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"Couldn't load {path}")
    module = importlib.util.module_from_spec(spec)
    # dataclasses look the module up by name while the class body runs.
    sys.modules["stt_shootout"] = module
    spec.loader.exec_module(module)
    return module


# ------------------------------------------------------------------ audio fixtures


def write_wav(path: Path, samples: Sequence[int], rate: int = SAMPLE_RATE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"".join(int(s).to_bytes(2, "little", signed=True) for s in samples))


def read_wav_samples(path: Path) -> list[int]:
    with wave.open(str(path), "rb") as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 1:
            raise ValueError(f"{path}: expected 16-bit mono")
        raw = w.readframes(w.getnframes())
    return [int.from_bytes(raw[i:i + 2], "little", signed=True) for i in range(0, len(raw), 2)]


def wav_duration(path: Path) -> float:
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / float(w.getframerate())


def synth_samples(case: Mapping[str, Any], rate: int = SAMPLE_RATE) -> list[int]:
    """Silence or seeded noise at an RMS level in dBFS (16-bit full scale)."""
    count = int(round(float(case["seconds"]) * rate))
    if case["kind"] == "silence":
        return [0] * count
    rng = random.Random(int(case.get("seed", 0)))
    raw = [rng.gauss(0.0, 1.0) for _ in range(count)]
    if case.get("color") == "brown":
        # Leaky integrator: most energy below ~50 Hz, like room rumble.
        level, shaped = 0.0, []
        for value in raw:
            level = 0.98 * level + value
            shaped.append(level)
        mean = sum(shaped) / max(1, len(shaped))
        raw = [v - mean for v in shaped]
    rms = math.sqrt(sum(v * v for v in raw) / max(1, len(raw))) or 1.0
    target = 32768.0 * 10 ** (float(case["dbfs"]) / 20.0)
    scale = target / rms
    return [max(-32768, min(32767, int(round(v * scale)))) for v in raw]


def rms_dbfs(samples: Sequence[int]) -> float:
    if not samples:
        return float("-inf")
    rms = math.sqrt(sum(s * s for s in samples) / len(samples))
    return 20 * math.log10(rms / 32768.0) if rms > 0 else float("-inf")


def say_to_wav(text: str, target: Path, trailing_silence: float = 0.0) -> None:
    """macOS `say` -> 16 kHz mono 16-bit WAV, optionally with silence after."""
    target.parent.mkdir(parents=True, exist_ok=True)
    aiff = target.with_suffix(".say.aiff")
    tmp = target.with_suffix(".tmp.wav")
    spoken = subprocess.run(["say", "-v", SAY_VOICE, "-r", str(SAY_RATE), "-o", str(aiff), text],
                            capture_output=True, text=True)
    if spoken.returncode != 0:  # voice not installed: system default voice
        subprocess.run(["say", "-r", str(SAY_RATE), "-o", str(aiff), text], check=True, capture_output=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(tmp)],
                   check=True, capture_output=True)
    aiff.unlink(missing_ok=True)
    samples = read_wav_samples(tmp)
    tmp.unlink(missing_ok=True)
    samples += [0] * int(round(trailing_silence * SAMPLE_RATE))
    write_wav(target, samples)


def prepare_stop_fixtures(directory: Path, speech: bool = True,
                          say: Callable[[str, Path, float], None] = say_to_wav) -> tuple[list[dict], list[str]]:
    """Write every stop clip. Returns (cases with path/class/audio_seconds, notes)."""
    directory.mkdir(parents=True, exist_ok=True)
    cases, notes = [], []
    tools_present = shutil.which("say") is not None and shutil.which("afconvert") is not None
    can_say = speech and (say is not say_to_wav or tools_present)
    if speech and not can_say:
        notes.append("speech clips skipped: macOS `say`/`afconvert` not found")
    for spec in STOP_CASES:
        case = dict(spec)
        path = directory / f"{case['id']}.wav"
        if case["kind"] == "speech":
            if not can_say:
                continue
            try:
                say(case["text"], path, float(case.get("trailing_silence", 0.0)))
            except (OSError, subprocess.CalledProcessError) as error:
                notes.append(f"{case['id']} skipped: `say` failed ({error})")
                continue
            case["reference"] = case["text"]
        else:
            write_wav(path, synth_samples(case))
            case["level_dbfs"] = None if case["kind"] == "silence" else round(rms_dbfs(read_wav_samples(path)), 1)
        case["class"] = case_class(case)
        case["path"] = str(path)
        case["audio_seconds"] = round(wav_duration(path), 3)
        cases.append(case)
    return cases, notes


# ------------------------------------------------------------------ WER set


def cue_windows(cues: Sequence[tuple[float, float, str]], start_after: float, count: int,
                target_seconds: float, min_seconds: float = 20.0,
                audio_seconds: float | None = None) -> list[tuple[float, float, str]]:
    """Back-to-back runs of whole caption cues, each <= target_seconds long and
    >= min_seconds, starting at or after start_after; `count` of them picked
    evenly across the audio."""
    windows: list[tuple[float, float, str]] = []
    i = next((k for k, cue in enumerate(cues) if cue[0] >= start_after), len(cues))
    while i < len(cues):
        start = cues[i][0]
        j = i
        while j < len(cues) and cues[j][1] - start <= target_seconds:
            j += 1
        if j == i:  # one cue longer than the window
            i += 1
            continue
        end = cues[j - 1][1]
        if end - start >= min_seconds and (audio_seconds is None or end <= audio_seconds):
            windows.append((start, end, " ".join(c[2] for c in cues[i:j])))
        i = j
    if count <= 0:
        return []
    if len(windows) <= count:
        return windows
    if count == 1:
        return [windows[len(windows) // 2]]
    picks = sorted({round(k * (len(windows) - 1) / (count - 1)) for k in range(count)})
    return [windows[p] for p in picks]


def prepare_wer_set(sh, args: argparse.Namespace, media: Path, work: Path) -> tuple[list[dict], dict]:
    """The long piece + dictation-length pieces, each with its reference text."""
    media.mkdir(parents=True, exist_ok=True)
    wer_dir = work / "wer-audio"
    wer_dir.mkdir(parents=True, exist_ok=True)
    plain_reference: str | None = None
    cues: list = []
    if args.audio:
        source = Path(args.audio).expanduser().resolve()
        if not args.reference:
            raise SystemExit("--audio needs --reference (a .txt transcript or .vtt captions) for WER")
        reference_text = Path(args.reference).expanduser().read_text(encoding="utf-8", errors="replace")
        if args.reference.lower().endswith(".vtt"):
            cues = sh.parse_vtt(reference_text)
        else:
            plain_reference = reference_text
        meta = {"title": source.name, "url": None, "license": None, "source": "local file"}
    else:
        meta = dict(sh.fetch_video(args.url or sh.DEFAULT_VIDEOS, media))
        source = Path(meta["audio"])
        cues = sh.parse_vtt(Path(meta["captions"]).read_text(encoding="utf-8", errors="replace"))

    if source.suffix.lower() == ".wav" and sh._is_16k_mono(source):
        full_wav = source
    else:
        stat = source.stat()
        key = hashlib.sha1(f"{source}|{stat.st_size}|{stat.st_mtime_ns}".encode()).hexdigest()[:10]
        full_wav = media / f"{source.stem}-{key}-16k.wav"
        sh.to_wav16k(source, full_wav)
    total = sh.wav_seconds(full_wav)

    limit = args.minutes * 60 if args.minutes else total
    notes = []
    if plain_reference is not None and limit < total:
        notes.append("plain-text reference can't be cut, so the long piece is the whole file")
        limit = total
    long_wav = wer_dir / "wer-long.wav"
    sh.cut_wav(full_wav, long_wav, 0, min(limit, total))
    long_seconds = sh.wav_seconds(long_wav)
    long_reference = plain_reference if plain_reference is not None else sh.reference_from_cues(
        cues, long_seconds if long_seconds < total - 0.5 else None)
    items = [{"id": "wer-long", "subset": "long", "path": str(long_wav),
              "audio_seconds": round(long_seconds, 3), "reference": long_reference}]

    if cues and args.segments > 0:
        # Prefer speech the long piece didn't cover; fall back to the whole file.
        need = args.segments * args.segment_seconds
        start_after = long_seconds if total - long_seconds >= need else 0.0
        windows = cue_windows(cues, start_after, args.segments, args.segment_seconds,
                              min_seconds=min(20.0, args.segment_seconds), audio_seconds=total)
        for k, (start, end, text) in enumerate(windows):
            path = wer_dir / f"wer-seg-{k:02d}.wav"
            begin = max(0.0, start - 0.25)
            sh.cut_wav(full_wav, path, begin, (end + 0.25) - begin)
            items.append({"id": f"wer-seg-{k:02d}", "subset": "dictation-length", "path": str(path),
                          "start_seconds": round(start, 2), "audio_seconds": round(sh.wav_seconds(path), 3),
                          "reference": text})
    elif args.segments > 0:
        notes.append("no caption timings, so no dictation-length pieces")

    meta.update({"full_seconds": round(total, 1), "notes": notes})
    meta.pop("reference_text", None)
    return items, meta


# ------------------------------------------------------------------ models


def find_model_source(explicit: str | None, sh) -> Path:
    """The Parakeet V3 folder the app itself would load."""
    if explicit:
        path = Path(explicit).expanduser().resolve()
        if not path.is_dir():
            raise SystemExit(f"--models-source {explicit}: not a folder")
        return path
    candidates = [d / sh.V3_FOLDER for d in APP_MODEL_DIRS] + [Path(sh.FLUIDAUDIO_V3_CACHE)]
    for path in candidates:
        if path.is_dir() and any(path.glob("*.mlmodelc")):
            return path
    raise SystemExit("No Parakeet V3 model files in Transcripted.app or the FluidAudio cache; pass --models-source")


def stage_models(source: Path, target: Path) -> Path:
    """Private copy per side (APFS clone on a Mac, so no extra disk). FluidAudio
    deletes and re-downloads a folder it fails to load; this keeps the app's
    own files out of reach and keeps one side from changing the other's."""
    shutil.rmtree(target, ignore_errors=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    cloned = False
    if platform.system() == "Darwin":
        cloned = subprocess.run(["cp", "-cR", str(source), str(target)], capture_output=True).returncode == 0
    if not cloned:
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(source, target, symlinks=True)
    return target


def folder_fingerprint(folder: Path) -> dict:
    rows = []
    for p in sorted(folder.rglob("*")):
        if p.is_file() and not p.is_symlink():
            rows.append(f"{p.relative_to(folder)}\t{p.stat().st_size}")
    return {"files": len(rows), "digest": hashlib.sha256("\n".join(rows).encode()).hexdigest()[:16]}


# ------------------------------------------------------------------ running the CLI


def round_order(round_index: int) -> tuple[str, str]:
    """ABBA: even rounds baseline first, odd rounds candidate first."""
    return SIDES if round_index % 2 == 0 else (SIDES[1], SIDES[0])


def timing_plan(cases: Sequence[Mapping[str, Any]], repeats: int, stage_dir: Path,
                tag: str) -> list[tuple[str | None, Path]]:
    """Files for one CLI process: two warm-ups (case None), then every case
    `repeats` times, interleaved. Unique stems, since the CLI names each
    output after its input."""
    stage_dir.mkdir(parents=True, exist_ok=True)
    plan: list[tuple[str | None, Path]] = []
    warm_sources = [c for c in cases if c["class"] == "speech"][:1] + [c for c in cases if c["class"] == "blank"][:1]
    for k, case in enumerate(warm_sources or list(cases)[:1]):
        copy = stage_dir / f"warmup-{tag}-{k}.wav"
        shutil.copyfile(case["path"], copy)
        plan.append((None, copy))
    for rep in range(repeats):
        for case in cases:
            copy = stage_dir / f"{case['id']}--{tag}-r{rep}.wav"
            shutil.copyfile(case["path"], copy)
            plan.append((case["id"], copy))
    return plan


def read_cli_outputs(out_dir: Path, files: Iterable[Path]) -> dict[str, dict]:
    """<stem>.json per input (a one-element list) -> {stem: output}."""
    outputs = {}
    for f in files:
        path = out_dir / f"{Path(f).stem}.json"
        try:
            decoded = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        entry = decoded[0] if isinstance(decoded, list) and decoded else decoded
        if isinstance(entry, dict):
            outputs[Path(f).stem] = entry
    return outputs


def run_cli(sh, cli: Path, models: Path, files: Sequence[Path], out_dir: Path, log_path: Path,
            timeout: float) -> dict:
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True, exist_ok=True)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(cli), "transcribe", "--json", "--no-download", "--models-dir", str(models),
           "--output-dir", str(out_dir), *[str(f) for f in files]]
    env = {**os.environ, "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"}
    code, wall, peak, _ = sh.run_measured(cmd, log_path, timeout, env)
    outputs = read_cli_outputs(out_dir, files)
    return {"exit_code": code, "wall_seconds": round(wall, 3), "peak_bytes": peak,
            "outputs": outputs, "missing": [Path(f).name for f in files if Path(f).stem not in outputs]}


# ------------------------------------------------------------------ scoring


def _median(values: Sequence[float]) -> float | None:
    return statistics.median(values) if values else None


def summarize_timing(cases: Sequence[Mapping[str, Any]], samples: Mapping[str, Mapping[str, list]],
                     texts: Mapping[str, Mapping[str, list]], thresholds: Mapping[str, float],
                     scorer: Callable[[str, str], dict] | None = None) -> list[dict]:
    rows = []
    for case in cases:
        cid = case["id"]
        row: dict[str, Any] = {"id": cid, "class": case["class"], "kind": case["kind"],
                               "audio_seconds": case.get("audio_seconds")}
        if case.get("reference"):
            row["reference"] = case["reference"]
        for side in SIDES:
            vals = list(samples.get(side, {}).get(cid, []))
            outs = [t or "" for t in texts.get(side, {}).get(cid, [])]
            nonblank = [t for t in outs if t.strip()]
            side_row: dict[str, Any] = {
                "runs": len(vals),
                "median_s": _round(_median(vals), 4),
                "min_s": _round(min(vals), 4) if vals else None,
                "max_s": _round(max(vals), 4) if vals else None,
                "blank_runs": len(outs) - len(nonblank),
                "distinct_texts": len(set(outs)),
            }
            if nonblank:
                # Most common non-blank text: the transcript for speech, the
                # hallucination for a blank clip. Local report only.
                side_row["text"] = max(set(nonblank), key=nonblank.count)
            if scorer and case.get("reference"):
                side_row["wer"] = _round(scorer(case["reference"], side_row.get("text", ""))["wer"], 4)
            row[side] = side_row
        a, b = row["baseline"]["median_s"], row["candidate"]["median_s"]
        if a is not None and b is not None:
            row["delta_ms"] = round((b - a) * 1000, 1)
            row["ratio"] = round(b / a, 3) if a > 0 else None
        if case["class"] == "blank":
            row["pass"] = time_row_passes(row, thresholds)
        rows.append(row)
    return rows


def time_row_passes(row: Mapping[str, Any], thresholds: Mapping[str, float]) -> bool:
    if row.get("delta_ms") is None or row.get("ratio") is None:
        return False
    return row["ratio"] <= thresholds["max_time_ratio"] and row["delta_ms"] <= thresholds["max_time_delta_ms"]


def summarize_wer(items: Sequence[Mapping[str, Any]], texts: Mapping[str, Mapping[str, str | None]],
                  scorer: Callable[[str, str], dict]) -> dict:
    rows = []
    pools: dict[str, dict[str, dict[str, int]]] = {}
    for item in items:
        row: dict[str, Any] = {"id": item["id"], "subset": item["subset"],
                               "audio_seconds": item.get("audio_seconds")}
        for side in SIDES:
            hyp = texts.get(side, {}).get(item["id"])
            if hyp is None:
                row[side] = {"missing": True}
                continue
            counts = scorer(item["reference"], hyp)
            errors = counts["substitutions"] + counts["deletions"] + counts["insertions"]
            row["reference_words"] = counts["reference_words"]
            row[side] = {"wer": _round(counts["wer"], 5), "errors": errors,
                         "substitutions": counts["substitutions"], "deletions": counts["deletions"],
                         "insertions": counts["insertions"], "hypothesis_words": counts.get("hypothesis_words")}
            for pool in ("all", item["subset"]):
                bucket = pools.setdefault(pool, {}).setdefault(side, {"errors": 0, "reference_words": 0, "items": 0})
                bucket["errors"] += errors
                bucket["reference_words"] += counts["reference_words"]
                bucket["items"] += 1
        if "wer" in row["baseline"] and "wer" in row["candidate"]:
            row["delta_pp"] = round((row["candidate"]["wer"] - row["baseline"]["wer"]) * 100, 3)
        rows.append(row)

    def pooled(name: str) -> dict:
        out: dict[str, Any] = {}
        for side in SIDES:
            bucket = pools.get(name, {}).get(side)
            if bucket:
                out[side] = {**bucket, "wer": _round(bucket["errors"] / max(1, bucket["reference_words"]), 5)}
        if all(side in out for side in SIDES):
            out["delta_pp"] = round((out["candidate"]["wer"] - out["baseline"]["wer"]) * 100, 3)
        return out

    subsets = sorted({i["subset"] for i in items})
    complete = all("wer" in r["baseline"] and "wer" in r["candidate"] for r in rows)
    return {"items": rows, "pooled": pooled("all"), "subsets": {s: pooled(s) for s in subsets},
            "complete": complete and bool(rows)}


def evaluate_gate(wer: Mapping[str, Any] | None, timing_rows: Sequence[Mapping[str, Any]],
                  thresholds: Mapping[str, float], problems: Sequence[str]) -> dict:
    checks = []
    checks.append({"name": "both sides ran", "pass": not problems,
                   "detail": "; ".join(problems) if problems else "every clip transcribed on both sides"})

    if wer and wer.get("complete") and "delta_pp" in wer.get("pooled", {}):
        delta = wer["pooled"]["delta_pp"]
        checks.append({
            "name": "word error rate", "pass": delta <= thresholds["max_wer_delta_pp"],
            "detail": (f"{wer['pooled']['baseline']['wer'] * 100:.2f}% -> {wer['pooled']['candidate']['wer'] * 100:.2f}% "
                       f"({delta:+.2f} points, limit +{thresholds['max_wer_delta_pp']:g})"),
        })
    else:
        checks.append({"name": "word error rate", "pass": False, "detail": "not measured on both sides"})

    blank = [r for r in timing_rows if r["class"] == "blank"]
    failing = [r for r in blank if not r.get("pass")]
    if not blank:
        checks.append({"name": "blank-audio stop time", "pass": False, "detail": "no blank clips measured"})
    else:
        detail = (f"{len(blank) - len(failing)}/{len(blank)} clips within {thresholds['max_time_ratio']:g}x "
                  f"and +{thresholds['max_time_delta_ms']:g} ms")
        if failing:
            detail += "; over: " + ", ".join(
                f"{r['id']} ({_fmt_ms(r['baseline']['median_s'])} -> {_fmt_ms(r['candidate']['median_s'])})"
                for r in failing)
        checks.append({"name": "blank-audio stop time", "pass": not failing, "detail": detail})
    return {"pass": all(c["pass"] for c in checks), "checks": checks}


def collect_warnings(timing_rows: Sequence[Mapping[str, Any]], wer: Mapping[str, Any] | None,
                     models: Mapping[str, Any]) -> list[str]:
    warnings = []
    for r in timing_rows:
        b, c = r["baseline"], r["candidate"]
        if r["class"] == "blank" and _text_rate(c) > _text_rate(b):
            warnings.append(f"{r['id']}: candidate returned text on {c['runs'] - c['blank_runs']}/{c['runs']} runs "
                            f"(baseline {b['runs'] - b['blank_runs']}/{b['runs']}): {c.get('text', '')!r}")
        if r["class"] == "speech" and b.get("text") != c.get("text"):
            warnings.append(f"{r['id']}: text changed {b.get('text', '')!r} -> {c.get('text', '')!r}")
        for side in SIDES:
            if r[side].get("distinct_texts", 0) > 1:
                warnings.append(f"{r['id']}: {side} gave {r[side]['distinct_texts']} different outputs across runs")
    for side, info in models.items():
        if info.get("before") and info.get("after") and info["before"] != info["after"]:
            warnings.append(f"{side}: FluidAudio changed its model folder during the run "
                            f"(it re-downloads a folder it can't load), so check the log")
    return warnings


def _text_rate(side_row: Mapping[str, Any]) -> float:
    """Share of runs that came back with text."""
    runs = side_row.get("runs", 0)
    return (runs - side_row.get("blank_runs", 0)) / runs if runs else 0.0


def _round(value: float | None, digits: int) -> float | None:
    return None if value is None else round(value, digits)


def _fmt_ms(seconds: float | None) -> str:
    return "n/a" if seconds is None else f"{seconds * 1000:.0f} ms"


# ------------------------------------------------------------------ report


def render_report(result: Mapping[str, Any]) -> str:
    gate = result["gate"]
    sides = result["sides"]
    th = result["thresholds"]
    name = {s: sides[s].get("label") or s for s in SIDES}
    lines = [
        "# FluidAudio A/B: Parakeet V3",
        "",
        f"**{'PASS' if gate['pass'] else 'FAIL'}**: {name['candidate']} vs {name['baseline']}"
        + (" (quick run, not for the merge decision)" if result.get("quick") else ""),
        "",
        f"Run {result['created_at']} on {result['machine'].get('summary', 'unknown machine')}.",
    ]
    cond = result.get("conditions") or {}
    if cond.get("transcripted_running") or cond.get("on_battery"):
        lines.append("Timing caveat: " + ", ".join(
            t for t, on in (("Transcripted was running", cond.get("transcripted_running")),
                            ("the Mac was on battery", cond.get("on_battery"))) if on) + ".")
    lines += ["", "| Check | Result | Detail |", "|---|---|---|"]
    lines += [f"| {c['name']} | {'pass' if c['pass'] else 'FAIL'} | {c['detail']} |" for c in gate["checks"]]

    lines += ["", "## Builds", "", "| Side | FluidAudio | Ref | Commit |", "|---|---|---|---|"]
    for s in SIDES:
        info = sides[s]
        lines.append(f"| {s} | {info.get('fluidaudio_version', '?')} | {info.get('ref', '?')} | "
                     f"{str(info.get('commit', '?'))[:10]} |")

    wer = result.get("wer")
    if wer:
        lines += ["", "## Word error rate", "",
                  f"Reference: {result['wer_audio'].get('title')} "
                  f"({result['wer_audio'].get('url') or 'local file'}). Normalizer: {result.get('normalizer')}.",
                  f"Gate: candidate at most +{th['max_wer_delta_pp']:g} points over baseline, pooled over every piece.",
                  "", "| Set | Audio | Words | Baseline | Candidate | Change |", "|---|---|---|---|---|---|"]

        def wer_row(label: str, pool: Mapping[str, Any], seconds: float) -> str:
            if not all(s in pool for s in SIDES):
                return f"| {label} | {seconds / 60:.1f} min | | n/a | n/a | |"
            return (f"| {label} | {seconds / 60:.1f} min | {pool['baseline']['reference_words']} | "
                    f"{pool['baseline']['wer'] * 100:.2f}% | {pool['candidate']['wer'] * 100:.2f}% | "
                    f"{pool.get('delta_pp', 0):+.2f} pts |")

        seconds_by_subset: dict[str, float] = {}
        for item in wer["items"]:
            seconds_by_subset[item["subset"]] = seconds_by_subset.get(item["subset"], 0.0) + (item.get("audio_seconds") or 0)
        lines.append(wer_row("all", wer["pooled"], sum(seconds_by_subset.values())))
        for subset, pool in wer["subsets"].items():
            lines.append(wer_row(subset, pool, seconds_by_subset.get(subset, 0.0)))

    timing = result.get("timing") or []
    if timing:
        lines += ["", "## Dictation stop time (transcribe call, model loaded)", "",
                  f"Median of {result['settings']['repeats'] * result['settings']['rounds']} runs per clip. "
                  f"Blank clips must stay within {th['max_time_ratio']:g}x and +{th['max_time_delta_ms']:g} ms.",
                  "", "| Clip | Audio | Baseline | Candidate | Ratio | Blank runs (B / C) | Gate |",
                  "|---|---|---|---|---|---|---|"]
        for r in timing:
            ratio = r.get("ratio")
            lines.append(
                f"| {r['id']} | {r.get('audio_seconds') or 0:.1f} s | {_fmt_ms(r['baseline']['median_s'])} | "
                f"{_fmt_ms(r['candidate']['median_s'])} | {'n/a' if ratio is None else f'{ratio:.2f}x'} | "
                f"{r['baseline']['blank_runs']}/{r['baseline']['runs']} / {r['candidate']['blank_runs']}/{r['candidate']['runs']} | "
                f"{('pass' if r['pass'] else 'FAIL') if 'pass' in r else 'info'} |")

    if result.get("warnings"):
        lines += ["", "## Worth a look", ""] + [f"- {w}" for w in result["warnings"]]
    if result.get("notes"):
        lines += ["", "## Notes", ""] + [f"- {n}" for n in result["notes"]]
    lines += ["", "Raw numbers: result.json. Transcripts: transcripts/. CLI logs: logs/.", ""]
    return "\n".join(lines)


# ------------------------------------------------------------------ main


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base", type=Path, default=Path.home() / "stt-fluidaudio-ab",
                   help="Work folder (default ~/stt-fluidaudio-ab)")
    p.add_argument("--out-dir", type=Path, help="Run folder (default <base>/runs/<UTC stamp>)")
    for side in SIDES:
        p.add_argument(f"--{side}-cli", type=Path, required=True, help=f"transcripted-cli for the {side} side")
        p.add_argument(f"--{side}-build-json", type=Path, help=f"Build record for the {side} side (from the wrapper)")
    p.add_argument("--shootout", help="Path to scripts/stt-shootout/shootout.py (default: this checkout, then git)")
    p.add_argument("--media-dir", type=Path,
                   help="Where the lecture download lives (default ~/stt-shootout/media when it exists, so a "
                        "shootout download is reused; else <base>/media)")
    p.add_argument("--url", action="append", help="YouTube URL with human captions for WER (repeatable)")
    p.add_argument("--audio", help="Local audio for WER instead of the lecture (needs --reference)")
    p.add_argument("--reference", help="Transcript (.txt) or captions (.vtt) for --audio")
    p.add_argument("--minutes", type=float, default=20.0, help="Length of the long WER piece (default 20)")
    p.add_argument("--segments", type=int, default=10, help="Dictation-length WER pieces (default 10)")
    p.add_argument("--segment-seconds", type=float, default=45.0, help="Target length of each piece (default 45)")
    p.add_argument("--repeats", type=int, default=5, help="Runs of each stop clip per process (default 5)")
    p.add_argument("--rounds", type=int, default=2, help="Timing processes per side, ABBA order (default 2)")
    p.add_argument("--no-speech-clips", action="store_true", help="Skip the `say` speech clips")
    p.add_argument("--models-source", help="Parakeet V3 folder to copy (default: the app's bundled copy)")
    p.add_argument("--timeout", type=float, default=3600.0, help="Seconds per CLI process (default 3600)")
    p.add_argument("--quick", action="store_true",
                   help="3-minute plumbing check: --minutes 3 --segments 3 --repeats 2 --rounds 1")
    p.add_argument("--max-wer-delta-pp", type=float, default=DEFAULT_THRESHOLDS["max_wer_delta_pp"],
                   help="Max WER increase, percentage points absolute (default 0.5)")
    p.add_argument("--max-time-ratio", type=float, default=DEFAULT_THRESHOLDS["max_time_ratio"],
                   help="Max candidate/baseline median time on blank clips (default 1.25)")
    p.add_argument("--max-time-delta-ms", type=float, default=DEFAULT_THRESHOLDS["max_time_delta_ms"],
                   help="Max candidate-baseline median time on blank clips, ms (default 300)")
    args = p.parse_args(argv)
    if args.quick:
        args.minutes, args.segments, args.repeats, args.rounds = 3.0, 3, 2, 1
    if args.repeats < 1 or args.rounds < 1:
        p.error("--repeats and --rounds must be at least 1")
    return args


def load_build_record(path: Path | None, cli: Path) -> dict:
    record: dict = {}
    if path and path.is_file():
        try:
            record = json.loads(path.read_text())
        except json.JSONDecodeError:
            record = {"build_record_error": f"unreadable {path}"}
    record["cli"] = str(cli)
    version = record.get("fluidaudio_version")
    record.setdefault("label", f"FluidAudio {version}" if version else None)
    return record


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    base = args.base.expanduser().resolve()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = (args.out_dir or base / "runs" / stamp).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)
    thresholds = {"max_wer_delta_pp": args.max_wer_delta_pp, "max_time_ratio": args.max_time_ratio,
                  "max_time_delta_ms": args.max_time_delta_ms}

    shootout_path, shootout_source = resolve_shootout(args.shootout, REPO, base / "vendor")
    sh = load_shootout(shootout_path)
    log(f"Using the STT shootout helpers from {shootout_source}")

    clis = {side: getattr(args, f"{side}_cli").expanduser().resolve() for side in SIDES}
    for side, cli in clis.items():
        if not (cli.is_file() and os.access(cli, os.X_OK)):
            raise SystemExit(f"--{side}-cli {cli}: not an executable")
    sides = {side: load_build_record(getattr(args, f"{side}_build_json"), clis[side]) for side in SIDES}

    notes: list[str] = []
    media = args.media_dir or (Path.home() / "stt-shootout" / "media"
                               if (Path.home() / "stt-shootout" / "media").is_dir() else base / "media")
    log("Preparing the WER audio...")
    wer_items, wer_meta = prepare_wer_set(sh, args, media.expanduser(), out)
    notes += wer_meta.pop("notes", [])
    log("Making the dictation-stop clips...")
    cases, fixture_notes = prepare_stop_fixtures(out / "stop-audio", speech=not args.no_speech_clips)
    notes += fixture_notes

    source = find_model_source(args.models_source, sh)
    models: dict[str, dict] = {}
    staged: dict[str, Path] = {}
    for side in SIDES:
        staged[side] = stage_models(source, base / "models" / side / sh.V3_FOLDER)
        models[side] = {"source": str(source), "before": folder_fingerprint(staged[side])}

    problems: list[str] = []
    samples: dict[str, dict[str, list]] = {s: {} for s in SIDES}
    texts: dict[str, dict[str, list]] = {s: {} for s in SIDES}
    processes: list[dict] = []
    for rnd in range(args.rounds):
        for side in round_order(rnd):
            plan = timing_plan(cases, args.repeats, out / "stop-runs" / f"{side}-round{rnd}", f"{side}{rnd}")
            log(f"Timing round {rnd + 1}/{args.rounds}: {side} ({len(plan)} clips)...")
            ran = run_cli(sh, clis[side], staged[side], [p for _, p in plan], out / "cli-out" / f"stop-{side}-{rnd}",
                          out / "logs" / f"stop-{side}-round{rnd}.log", args.timeout)
            processes.append({"phase": "stop", "side": side, "round": rnd, "exit_code": ran["exit_code"],
                              "wall_seconds": ran["wall_seconds"], "peak_mb": round(ran["peak_bytes"] / 1_048_576)})
            if ran["exit_code"] != 0 or ran["missing"]:
                problems.append(f"{side} timing round {rnd + 1}: exit {ran['exit_code']}, "
                                f"{len(ran['missing'])} clips missing (logs/stop-{side}-round{rnd}.log)")
            for case_id, path in plan:
                output = ran["outputs"].get(path.stem)
                if case_id is None or output is None:
                    continue
                samples[side].setdefault(case_id, []).append(float(output["processingSeconds"]))
                texts[side].setdefault(case_id, []).append(output.get("text") or "")

    wer_texts: dict[str, dict[str, str | None]] = {s: {} for s in SIDES}
    transcripts = out / "transcripts"
    transcripts.mkdir(exist_ok=True)
    for side in SIDES:
        warm = next((c for c in cases if c["class"] == "speech"), cases[0] if cases else None)
        files = [Path(i["path"]) for i in wer_items]
        if warm:
            warm_copy = out / "wer-audio" / f"warmup-{side}.wav"
            shutil.copyfile(warm["path"], warm_copy)
            files.insert(0, warm_copy)
        log(f"WER: {side} ({sum(i['audio_seconds'] for i in wer_items) / 60:.1f} min of audio)...")
        ran = run_cli(sh, clis[side], staged[side], files, out / "cli-out" / f"wer-{side}",
                      out / "logs" / f"wer-{side}.log", args.timeout)
        processes.append({"phase": "wer", "side": side, "exit_code": ran["exit_code"],
                          "wall_seconds": ran["wall_seconds"], "peak_mb": round(ran["peak_bytes"] / 1_048_576)})
        if ran["exit_code"] != 0 or ran["missing"]:
            problems.append(f"{side} WER run: exit {ran['exit_code']}, {len(ran['missing'])} files missing "
                            f"(logs/wer-{side}.log)")
        for item in wer_items:
            output = ran["outputs"].get(Path(item["path"]).stem)
            if output is None:
                continue
            wer_texts[side][item["id"]] = output.get("text") or ""
            item.setdefault("processing_seconds", {})[side] = round(float(output["processingSeconds"]), 3)
            (transcripts / f"{item['id']}.{side}.txt").write_text(wer_texts[side][item["id"]] + "\n")
        models[side]["after"] = folder_fingerprint(staged[side])
    for item in wer_items:
        (transcripts / f"{item['id']}.reference.txt").write_text(item["reference"] + "\n")

    wer = summarize_wer(wer_items, wer_texts, sh.score)
    for row, item in zip(wer["items"], wer_items):
        row["processing_seconds"] = item.get("processing_seconds", {})
        if "start_seconds" in item:
            row["start_seconds"] = item["start_seconds"]
    timing_rows = summarize_timing(cases, samples, texts, thresholds, scorer=lambda r, h: sh.score(r, h))
    gate = evaluate_gate(wer, timing_rows, thresholds, problems)

    result = {
        "schema": SCHEMA,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "quick": bool(args.quick),
        "gate": gate,
        "thresholds": thresholds,
        "sides": sides,
        "machine": sh.machine_info(),
        "conditions": sh.run_conditions(),
        "settings": {"minutes": args.minutes, "segments": args.segments, "segment_seconds": args.segment_seconds,
                     "repeats": args.repeats, "rounds": args.rounds, "timing_source": "cli processingSeconds"},
        "shootout": {"source": shootout_source,
                     "sha256": hashlib.sha256(shootout_path.read_bytes()).hexdigest()[:16]},
        "normalizer": sh.normalizer_name(),
        "wer_audio": {k: v for k, v in wer_meta.items() if k in ("title", "url", "id", "license", "caption_track",
                                                                "full_seconds", "source")},
        "wer": wer,
        "timing": timing_rows,
        "models": models,
        "processes": processes,
        "warnings": collect_warnings(timing_rows, wer, models),
        "notes": notes,
    }
    result_path = out / "result.json"
    result_path.write_text(json.dumps(result, indent=2, default=_json_default) + "\n")
    (out / "report.md").write_text(render_report(result))
    log(f"{'PASS' if gate['pass'] else 'FAIL'}. Report: {out / 'report.md'}")
    print(result_path)
    if problems:
        return 1
    return 0 if gate["pass"] else 3


def _json_default(value: Any) -> Any:
    if isinstance(value, Path):
        return str(value)
    raise TypeError(f"not JSON serializable: {type(value)}")


if __name__ == "__main__":
    sys.exit(main())
