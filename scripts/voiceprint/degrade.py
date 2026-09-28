#!/usr/bin/env python3
"""Render call-audio degradations for a voiceprint eval set.

  VP/venv/bin/python scripts/voiceprint/degrade.py --set vox1o [--cond opus12,phone,noisy] [--workers 6]

Reads   VP/sets/<set>/segments.jsonl and VP/clips/<set>/clean/<seg_id>.wav
Writes  VP/clips/<set>/<cond>/<seg_id>.wav   16 kHz mono PCM16, same length as the clean clip
        VP/clips/<set>/<cond>/params.jsonl   what was drawn for each clip (RT60, SNR, noise clip, ...)
        VP/clips/<set>/<cond>/READY          written when every clip of the condition exists

Idempotent: files that already exist are skipped, anything missing is filled in. Every file is
written to a hidden temp name and renamed, so a killed run never leaves a half-written clip.
Deterministic: each clip's random draws are seeded from sha256(seg_id + "|" + cond).

Conditions (VOICEPRINT_BAKEOFF.md):
  opus12  100-7000 Hz band limit (a wideband call device, as in scripts/speaker_lab/meeting_sim.py),
          then a real libopus encode/decode at 12 kbps in VoIP mode (what Zoom/Meet run; SILK
          wideband at this rate). The codec delay is measured on the clip and removed, so the
          output lines up with the input sample for sample.
  phone   16k -> 8k, 300-3400 Hz bandpass, G.711 mu-law encode/decode (real 8-bit codes), 8k -> 16k.
  noisy   synthetic room (exponentially decaying noise RIR, RT60 U(0.3, 0.7) s, direct-path peak,
          direct-to-reverberant ratio U(0, 8) dB), then a clip from VP/sets/_noise added at
          SNR U(5, 15) dB measured on active speech (frames within 25 dB of the clip's loud
          frames). About half the noise clips are music, half babble. Needs VP/sets/_noise/READY.

Nothing else is normalized. If a result would overflow, the whole clip is scaled down to a 0.98 peak.

Exit code: 0 when every requested condition is complete, 3 when `noisy` was skipped because
_noise is not READY (or a set has missing clean clips), 1 when clips failed.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import sys
import time
from datetime import datetime, timezone
from multiprocessing import Pool
from pathlib import Path

# One thread per worker: parallelism comes from the pool.
for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_k] = "1"

import numpy as np
import soundfile as sf
from scipy.signal import butter, correlate, correlation_lags, fftconvolve, resample_poly, sosfiltfilt

REPO_ROOT = Path(__file__).resolve().parents[2]
VP = Path(os.environ.get("VOICEPRINT_ROOT", REPO_ROOT / "data" / "eval" / "voiceprint"))
SR = 16000
CONDS = ("opus12", "phone", "noisy")

OPUS_KBPS = 12
OPUS_APPLICATION = "voip"
OPUS_BAND = (100.0, 7000.0)            # wideband call device, as in meeting_sim.remote_device
PHONE_BAND = (300.0, 3400.0)
RT60_RANGE = (0.3, 0.7)
DRR_RANGE_DB = (0.0, 8.0)               # direct-to-reverberant energy ratio
SNR_RANGE_DB = (5.0, 15.0)
MUSIC_FRACTION = 0.5
ACTIVE_WINDOW_DB = 25.0                 # active speech = frames within this of the loud frames
PEAK_LIMIT = 0.98


# ---------------------------------------------------------------- helpers

def seed_for(seg_id: str, cond: str) -> np.random.Generator:
    digest = hashlib.sha256(f"{seg_id}|{cond}".encode()).digest()
    return np.random.default_rng(int.from_bytes(digest[:8], "big"))


def band_limit(x: np.ndarray, low: float | None, high: float | None) -> np.ndarray:
    """Zero-phase Butterworth: 4th-order high-pass, 6th-order low-pass (each run twice)."""
    if low:
        x = sosfiltfilt(butter(4, low, "highpass", fs=SR, output="sos"), x)
    if high and high < SR / 2 - 100:
        x = sosfiltfilt(butter(6, high, "lowpass", fs=SR, output="sos"), x)
    return x.astype(np.float32)


def guard(y: np.ndarray) -> tuple[np.ndarray, float]:
    """Clip guard: if the clip would overflow, scale the whole clip to a PEAK_LIMIT peak (no
    hard clipping, so nothing else about it changes). Returns the clip and the gain applied."""
    y = np.nan_to_num(y, nan=0.0, posinf=0.0, neginf=0.0).astype(np.float32)
    peak = float(np.abs(y).max()) if len(y) else 0.0
    if peak > PEAK_LIMIT:
        return y * np.float32(PEAK_LIMIT / peak), PEAK_LIMIT / peak
    return y, 1.0


def fit_length(y: np.ndarray, n: int) -> np.ndarray:
    return np.pad(y[:n], (0, max(0, n - len(y)))).astype(np.float32)


def active_power(x: np.ndarray, window_db: float = ACTIVE_WINDOW_DB) -> float:
    """Mean power over active frames: 20 ms frames within `window_db` of the clip's loud
    (95th percentile) frames. Falls back to the whole clip if nothing qualifies."""
    frame = 320
    n = len(x) // frame
    if n < 2:
        return float(np.mean(x.astype(np.float64) ** 2)) + 1e-12
    p = (x[: n * frame].astype(np.float64).reshape(n, frame) ** 2).mean(axis=1)
    db = 10 * np.log10(p + 1e-12)
    keep = db >= np.percentile(db, 95) - window_db
    return float(p[keep].mean()) + 1e-12


# ---------------------------------------------------------------- opus12

def _opus_roundtrip(x: np.ndarray, kbps: int) -> np.ndarray:
    import av

    buf = io.BytesIO()
    out = av.open(buf, "w", format="ogg")
    st = out.add_stream("libopus", rate=48000, options={"application": OPUS_APPLICATION})
    st.bit_rate = kbps * 1000
    st.layout = "mono"
    rs = av.AudioResampler(format="flt", layout="mono", rate=48000)
    fr = av.AudioFrame.from_ndarray(x.reshape(1, -1).astype(np.float32), format="flt", layout="mono")
    fr.sample_rate = SR
    for f in rs.resample(fr):
        for p in st.encode(f):
            out.mux(p)
    for p in st.encode(None):
        out.mux(p)
    out.close()
    buf.seek(0)
    with av.open(buf) as c:
        r2 = av.AudioResampler(format="flt", layout="mono", rate=SR)
        parts = [f.to_ndarray().reshape(-1) for pk in c.decode(c.streams.audio[0]) for f in r2.resample(pk)]
        parts += [f.to_ndarray().reshape(-1) for f in r2.resample(None)]
    return np.concatenate(parts).astype(np.float32) if parts else np.zeros(0, np.float32)


def _align(ref: np.ndarray, y: np.ndarray, max_lag: int = 160) -> tuple[np.ndarray, int]:
    """Shift y so it lines up with ref. ffmpeg's Ogg reader already drops the Opus pre-skip;
    what is left is the encoder's small filter delay (a few samples, varies by clip in
    VoIP mode), which is estimated by cross-correlation and removed."""
    n = min(len(ref), len(y))
    if n < 2 * max_lag:
        return y, 0
    c = correlate(y[:n].astype(np.float64), ref[:n].astype(np.float64), mode="full", method="fft")
    lags = correlation_lags(n, n)
    m = np.abs(lags) <= max_lag
    k = int(np.argmax(c[m]))
    denom = np.sqrt(float((ref[:n] ** 2).sum() * (y[:n] ** 2).sum())) + 1e-12
    if c[m][k] / denom < 0.3:
        return y, 0
    lag = int(lags[m][k])            # y[t + lag] ~ ref[t]
    if lag > 0:
        y = y[lag:]
    elif lag < 0:
        y = np.pad(y, (-lag, 0))
    return y, lag


def render_opus12(x: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, dict]:
    limited = band_limit(x, *OPUS_BAND)
    y = _opus_roundtrip(limited, OPUS_KBPS)
    y, lag = _align(limited, y)
    return fit_length(y, len(x)), {"kbps": OPUS_KBPS, "lag_removed": lag}


# ---------------------------------------------------------------- phone

def mulaw_encode(pcm: np.ndarray) -> np.ndarray:
    """G.711 mu-law: int16 samples -> 8-bit codes (0x84 bias, 32635 clip)."""
    s = pcm.astype(np.int32)
    sign = np.where(s < 0, 0x80, 0)
    mag = np.minimum(np.abs(s), 32635) + 0x84
    exponent = np.floor(np.log2(np.maximum(mag >> 7, 1))).astype(np.int32)
    mantissa = (mag >> (exponent + 3)) & 0x0F
    return (~(sign | (exponent << 4) | mantissa) & 0xFF).astype(np.uint8)


def mulaw_decode(code: np.ndarray) -> np.ndarray:
    u = ~code.astype(np.int32) & 0xFF
    exponent = (u >> 4) & 0x07
    mantissa = u & 0x0F
    mag = (((mantissa << 3) + 0x84) << exponent) - 0x84
    return np.where(u & 0x80, -mag, mag).astype(np.int16)


def render_phone(x: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, dict]:
    x8 = resample_poly(x.astype(np.float64), 1, 2)
    x8 = sosfiltfilt(butter(4, PHONE_BAND, "bandpass", fs=SR // 2, output="sos"), x8)
    pcm = np.clip(np.round(x8 * 32768.0), -32768, 32767).astype(np.int16)
    y8 = mulaw_decode(mulaw_encode(pcm)).astype(np.float64) / 32768.0
    y = resample_poly(y8, 2, 1)
    return fit_length(y.astype(np.float32), len(x)), {}


# ---------------------------------------------------------------- noisy

NOISE: dict = {"entries": [], "kinds": {}}   # filled by init_worker


def make_rir(rng: np.random.Generator, rt60: float, drr_db: float) -> np.ndarray:
    """Direct-path peak at sample 0 plus an exponentially decaying noise tail (starting 4 ms
    later) that falls 60 dB in `rt60` seconds, scaled to the requested direct-to-reverberant ratio."""
    length = int(1.2 * rt60 * SR)
    t = np.arange(length) / SR
    tail = rng.standard_normal(length) * np.exp(-6.907755 * t / rt60)
    tail[: int(0.004 * SR)] = 0.0
    tail *= np.sqrt(10 ** (-drr_db / 10) / (np.sum(tail ** 2) + 1e-12))
    h = tail
    h[0] = 1.0
    return h.astype(np.float32)


def _read_noise(entry: dict, start16: int, n: int) -> np.ndarray:
    """n samples of the noise file at 16 kHz mono, starting at start16 (16 kHz sample index)."""
    sr = entry["sr"]
    with sf.SoundFile(entry["path"]) as f:
        if sr == SR:
            f.seek(start16)
            x = f.read(n, dtype="float32", always_2d=True)
        else:
            f.seek(int(start16 * sr / SR))
            x = f.read(int(np.ceil(n * sr / SR)) + 64, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    if sr != SR:
        g = int(np.gcd(SR, sr))
        x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    return x[:n]


def draw_noise(rng: np.random.Generator, kind: str, n: int) -> tuple[np.ndarray, dict]:
    pool = NOISE["kinds"][kind]
    for _ in range(20):
        e = NOISE["entries"][pool[int(rng.integers(len(pool)))]]
        total = int(e["frames"] * SR / e["sr"])
        if total >= n:
            start = int(rng.integers(0, total - n + 1))
            x = _read_noise(e, start, n)
        else:                                            # short noise clip: loop it from a random point
            x = _read_noise(e, 0, total)
            x = np.tile(np.roll(x, int(rng.integers(len(x)))), int(np.ceil(n / max(1, len(x)))))
            start = 0
        x = fit_length(x, n)
        if float(np.mean(x.astype(np.float64) ** 2)) > 1e-9:      # skip digital silence
            return x, {"noise": e["id"], "noise_start_s": round(start / SR, 3)}
    raise RuntimeError(f"no usable {kind} noise found")


def render_noisy(x: np.ndarray, rng: np.random.Generator) -> tuple[np.ndarray, dict]:
    rt60 = float(rng.uniform(*RT60_RANGE))
    drr = float(rng.uniform(*DRR_RANGE_DB))
    snr = float(rng.uniform(*SNR_RANGE_DB))
    want_music = bool(rng.random() < MUSIC_FRACTION)
    kinds = NOISE["kinds"]
    kind = "music" if want_music else "babble"
    if kind not in kinds:
        kind = next(iter(kinds))
    h = make_rir(rng, rt60, drr)
    wet = fftconvolve(x.astype(np.float64), h.astype(np.float64))[: len(x)]
    noise, info = draw_noise(rng, kind, len(x))
    noise = noise.astype(np.float64)
    noise_power = float(np.mean(noise ** 2)) + 1e-12
    gain = np.sqrt(active_power(wet) / (noise_power * 10 ** (snr / 10)))
    y = wet + noise * gain
    return y, {"rt60": round(rt60, 3), "drr_db": round(drr, 2), "snr_db": round(snr, 2),
               "noise_kind": kind, **info}


def load_noise(noise_dir: Path) -> dict:
    """Index VP/sets/_noise. Any audio file below the directory counts; its kind comes from a
    jsonl manifest row if there is one, else from the path (music / babble)."""
    exts = {".wav", ".flac", ".ogg", ".mp3", ".m4a"}
    manifest: dict[str, str] = {}
    for name in ("segments.jsonl", "noise.jsonl", "manifest.jsonl", "index.jsonl", "clips.jsonl"):
        p = noise_dir / name
        if p.exists():
            for line in open(p):
                r = json.loads(line)
                path = next((r[k] for k in ("clip", "path", "file", "wav") if k in r), None)
                kind = next((r[k] for k in ("kind", "type", "category", "noise_type", "label") if k in r), None)
                if path and kind:
                    manifest[Path(path).name] = str(kind)
    entries, kinds = [], {}
    for p in sorted(noise_dir.rglob("*")):
        if p.suffix.lower() not in exts or p.name.startswith("."):
            continue
        rel = str(p.relative_to(noise_dir))
        label = (manifest.get(p.name) or rel).lower()
        kind = "music" if "music" in label else ("babble" if any(w in label for w in ("babble", "speech", "crowd", "talk", "cafe")) else None)
        if kind is None:
            continue
        try:
            info = sf.info(str(p))
        except Exception:
            continue
        if info.frames < SR // 2:
            continue
        kinds.setdefault(kind, []).append(len(entries))
        entries.append({"id": rel, "path": str(p), "sr": info.samplerate, "frames": info.frames, "kind": kind})
    return {"entries": entries, "kinds": kinds}


# ---------------------------------------------------------------- driver

RENDERERS = {"opus12": render_opus12, "phone": render_phone, "noisy": render_noisy}


def init_worker(noise: dict | None) -> None:
    if noise:
        NOISE.update(noise)


def render_task(task: tuple[str, str, str, str]) -> tuple[str, str, dict | None, str | None]:
    seg_id, cond, src, dst = task
    tmp = Path(dst).with_name(f".{Path(dst).name}.{os.getpid()}.tmp")
    try:
        x, sr = sf.read(src, dtype="float32", always_2d=True)
        if sr != SR:
            raise ValueError(f"{src}: sample rate {sr}, expected {SR}")
        x = x.mean(axis=1) if x.shape[1] > 1 else x[:, 0]
        y, params = RENDERERS[cond](x, seed_for(seg_id, cond))
        y, gain = guard(fit_length(y, len(x)))
        if gain < 1.0:
            params["guard_gain"] = round(gain, 4)
        sf.write(str(tmp), y, SR, subtype="PCM_16", format="WAV")
        os.replace(tmp, dst)
        return seg_id, cond, {"seg_id": seg_id, "cond": cond, **params}, None
    except Exception as e:  # noqa: BLE001 - report and keep going
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        return seg_id, cond, None, f"{type(e).__name__}: {e}"


def sweep_stale_tmp(d: Path) -> None:
    now = time.time()
    for p in d.glob(".*.tmp"):
        try:
            if now - p.stat().st_mtime > 600:
                p.unlink()
        except OSError:
            pass


def compact_params(path: Path) -> None:
    """params.jsonl is appended to as clips finish; keep one row per seg_id (the last)."""
    if not path.exists():
        return
    rows: dict[str, str] = {}
    for line in open(path):
        line = line.strip()
        if line:
            rows[json.loads(line)["seg_id"]] = line
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text("".join(f"{r}\n" for r in rows.values()))
    os.replace(tmp, path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", required=True)
    ap.add_argument("--cond", default=",".join(CONDS), help="comma list of opus12,phone,noisy")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--noise-dir", type=Path, default=VP / "sets" / "_noise",
                    help="noise bank for `noisy` (default VP/sets/_noise, which must be READY)")
    ap.add_argument("--limit", type=int, default=0, help="only the first N clips (testing)")
    args = ap.parse_args()

    conds = [c.strip() for c in args.cond.split(",") if c.strip()]
    bad = [c for c in conds if c not in CONDS]
    if bad:
        raise SystemExit(f"unknown condition(s) {bad}; choose from {list(CONDS)}")
    workers = max(1, min(args.workers, 6))

    seg_path = VP / "sets" / args.set / "segments.jsonl"
    if not seg_path.exists():
        raise SystemExit(f"{seg_path} does not exist")
    seg_ids = [json.loads(line)["seg_id"] for line in open(seg_path) if line.strip()]
    if args.limit:
        seg_ids = seg_ids[: args.limit]
    clean_dir = VP / "clips" / args.set / "clean"
    missing_clean = [s for s in seg_ids if not (clean_dir / f"{s}.wav").exists()]
    if missing_clean:
        print(f"[degrade] {args.set}: {len(missing_clean)} clean clips are missing (first: {missing_clean[0]}); "
              f"rendering the rest, no READY for any condition", file=sys.stderr)
    missing_set = set(missing_clean)
    seg_ok = [s for s in seg_ids if s not in missing_set]

    exit_code = 3 if missing_clean else 0
    noise = None
    if "noisy" in conds:
        if not (args.noise_dir / "READY").exists() and args.noise_dir == VP / "sets" / "_noise":
            print(f"[degrade] {args.noise_dir}/READY is not there yet: skipping noisy (rerun later)", file=sys.stderr)
            conds.remove("noisy")
            exit_code = 3
        else:
            noise = load_noise(args.noise_dir)
            if not noise["entries"]:
                print(f"[degrade] no music/babble audio found under {args.noise_dir}: skipping noisy", file=sys.stderr)
                conds.remove("noisy")
                exit_code = 3
            else:
                print(f"[degrade] noise bank: " + ", ".join(f"{k}={len(v)}" for k, v in noise["kinds"].items()))

    tasks: list[tuple[str, str, str, str]] = []
    for cond in conds:
        out_dir = VP / "clips" / args.set / cond
        out_dir.mkdir(parents=True, exist_ok=True)
        sweep_stale_tmp(out_dir)
        for s in seg_ok:
            dst = out_dir / f"{s}.wav"
            if not dst.exists():
                tasks.append((s, cond, str(clean_dir / f"{s}.wav"), str(dst)))
    tasks_by_cond = {c: sum(t[1] == c for t in tasks) for c in conds}
    print(f"[degrade] {args.set}: {len(seg_ids)} clips x {conds} -> {len(tasks)} to render, {workers} workers", flush=True)

    failures: dict[str, list[str]] = {c: [] for c in conds}
    params_fh = {c: open(VP / "clips" / args.set / c / "params.jsonl", "a") for c in conds}
    t0 = time.time()
    done = 0
    try:
        if tasks:
            with Pool(workers, initializer=init_worker, initargs=(noise,)) as pool:
                for seg_id, cond, params, err in pool.imap_unordered(render_task, tasks, chunksize=8):
                    done += 1
                    if err:
                        failures[cond].append(f"{seg_id}: {err}")
                        if len(failures[cond]) <= 5:
                            print(f"[degrade] FAILED {cond} {seg_id}: {err}", file=sys.stderr, flush=True)
                    else:
                        params_fh[cond].write(json.dumps(params) + "\n")
                    if done % 250 == 0 or done == len(tasks):
                        print(f"[degrade] {done}/{len(tasks)}  {time.time() - t0:.0f}s", flush=True)
    finally:
        for fh in params_fh.values():
            fh.close()

    for cond in conds:
        out_dir = VP / "clips" / args.set / cond
        compact_params(out_dir / "params.jsonl")
        have = sum((out_dir / f"{s}.wav").exists() for s in seg_ids)
        if have == len(seg_ids) and not missing_clean and not args.limit:
            ready = out_dir / "READY"
            if tasks_by_cond.get(cond) or not ready.exists():     # leave an existing READY alone if nothing changed
                ready.write_text(
                    json.dumps({"set": args.set, "cond": cond, "clips": have,
                                "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}) + "\n")
            print(f"[degrade] {args.set}/{cond}: READY ({have} clips)")
        else:
            print(f"[degrade] {args.set}/{cond}: incomplete ({have}/{len(seg_ids)})", file=sys.stderr)
            exit_code = 1 if failures[cond] else max(exit_code, 3)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
