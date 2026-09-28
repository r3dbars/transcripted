#!/usr/bin/env python3
"""Answer-key audit, part 4: silence, clipping, level, length and SNR sanity for every clip.

For every set and condition (clean, opus12, phone, noisy) under VP/clips/<set>/<cond>/:
  * format: 16 kHz, mono, PCM16, length == bucket * 16000
  * level: RMS dBFS, peak, share of full-scale samples, DC offset
  * silence: share of 25 ms frames within 35 dB of the loudest frame (the builders' "active"
    rule), share of frames below -60 dBFS, longest quiet run
  * PCM sha1 (exact-duplicate check across seg_ids)
  * degraded clips: envelope correlation with their own clean clip, and the best envelope lag
    (catches a degraded file rendered from the wrong clean clip, or shifted)
  * noisy: rebuild the clean->reverb part exactly (degrade.py is deterministic per seg_id), fit
    file = a*wet + b*noise, and measure the real SNR the way degrade.py defines it
    (active-speech power of the reverberant speech over mean noise power). Compared with the
    recorded snr_db in params.jsonl.

Writes VP/results/audit/audio_<set>.csv (one row per seg_id x cond). Read-only on everything else.
At most 3 threads.

  VP/venv/bin/python scripts/voiceprint/audit/audit_audio.py [--sets vox1o,libri,...]
"""
from __future__ import annotations

import os

for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_k] = "1"

import argparse  # noqa: E402
import csv  # noqa: E402
import hashlib  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from concurrent.futures import ThreadPoolExecutor  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
from scipy.signal import fftconvolve  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
OUT = VP / "results" / "audit"
SR = 16000
SETS = ("vox1o", "libri", "ami", "icsi", "yodas")
CONDS = ("clean", "opus12", "phone", "noisy")

spec = importlib.util.spec_from_file_location("degrade", REPO / "scripts" / "voiceprint" / "degrade.py")
degrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(degrade)


def frame_db(x: np.ndarray, frame: int = 400, hop: int = 160) -> np.ndarray:
    if len(x) < frame:
        x = np.pad(x, (0, frame - len(x)))
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    ms = np.mean(x[idx].astype(np.float64) ** 2, axis=1)
    return 10 * np.log10(np.maximum(ms, 1e-12))


def longest_run(mask: np.ndarray) -> int:
    best = cur = 0
    for v in mask:
        cur = cur + 1 if v else 0
        best = max(best, cur)
    return best


def env_corr(a_db: np.ndarray, b_db: np.ndarray, max_lag: int = 20) -> tuple[float, int]:
    n = min(len(a_db), len(b_db))
    a, b = a_db[:n], b_db[:n]
    best = (-2.0, 0)
    for k in range(-max_lag, max_lag + 1):
        if k >= 0:
            x, y = a[: n - k], b[k:]
        else:
            x, y = a[-k:], b[: n + k]
        if len(x) < 10 or x.std() == 0 or y.std() == 0:
            continue
        c = float(np.corrcoef(x, y)[0, 1])
        if c > best[0]:
            best = (c, k)
    return best


def noisy_snr(seg_id: str, clean: np.ndarray, y: np.ndarray) -> dict:
    """Rebuild wet speech + noise exactly as degrade.render_noisy drew them, then fit the file."""
    rng = degrade.seed_for(seg_id, "noisy")
    rt60 = float(rng.uniform(*degrade.RT60_RANGE))
    drr = float(rng.uniform(*degrade.DRR_RANGE_DB))
    snr = float(rng.uniform(*degrade.SNR_RANGE_DB))
    want_music = bool(rng.random() < degrade.MUSIC_FRACTION)
    kinds = degrade.NOISE["kinds"]
    kind = "music" if want_music else "babble"
    if kind not in kinds:
        kind = next(iter(kinds))
    h = degrade.make_rir(rng, rt60, drr)
    wet = fftconvolve(clean.astype(np.float64), h.astype(np.float64))[: len(clean)]
    noise, info = degrade.draw_noise(rng, kind, len(clean))
    noise = noise.astype(np.float64)
    A = np.stack([wet, noise], axis=1)
    coef, *_ = np.linalg.lstsq(A, y.astype(np.float64), rcond=None)
    a, b = float(coef[0]), float(coef[1])
    res = y - A @ coef
    sp = degrade.active_power(a * wet)
    npow = float(np.mean((b * noise) ** 2)) + 1e-12
    return {
        "snr_drawn": round(snr, 2),
        "snr_meas": round(10 * np.log10(sp / npow), 2),
        "fit_resid_db": round(10 * np.log10((np.mean(res ** 2) + 1e-15) / (np.mean(y.astype(np.float64) ** 2) + 1e-15)), 1),
        "noise_kind": kind,
        "noise_id": info.get("noise"),
        "noise_start_s": info.get("noise_start_s"),
        "rt60": round(rt60, 3),
    }


def analyse(set_name: str, row: dict, params: dict) -> list[dict]:
    seg = row["seg_id"]
    out = []
    clean_x = None
    clean_db = None
    for cond in CONDS:
        p = VP / "clips" / set_name / cond / f"{seg}.wav"
        r = {"seg_id": seg, "cond": cond, "bucket": row["bucket"], "speaker": row["speaker"], "session": row["session"]}
        if not p.exists():
            r["missing"] = 1
            out.append(r)
            continue
        info = sf.info(str(p))
        pcm, sr = sf.read(str(p), dtype="int16", always_2d=True)
        r.update({"missing": 0, "sr": sr, "channels": pcm.shape[1], "subtype": info.subtype,
                  "n": pcm.shape[0], "len_ok": int(pcm.shape[0] == row["bucket"] * SR)})
        pcm = pcm[:, 0]
        r["sha1"] = hashlib.sha1(pcm.tobytes()).hexdigest()
        x = pcm.astype(np.float32) / 32768.0
        rms = float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))
        r["rms_db"] = round(20 * np.log10(max(rms, 1e-9)), 2)
        r["peak_db"] = round(20 * np.log10(max(float(np.abs(x).max()), 1e-9)), 2)
        r["fullscale_frac"] = round(float(np.mean(np.abs(pcm.astype(np.int32)) >= 32767)), 6)
        r["near_fs_frac"] = round(float(np.mean(np.abs(x) >= 0.99)), 6)
        r["dc"] = round(float(np.mean(x)), 5)
        fdb = frame_db(x)
        r["active_frac"] = round(float(np.mean(fdb > fdb.max() - 35.0)), 3)
        r["silent_frac"] = round(float(np.mean(fdb < -60.0)), 3)
        r["longest_quiet_s"] = round(longest_run(fdb < fdb.max() - 40.0) * 0.01, 2)
        env = frame_db(x, 320, 320)
        if cond == "clean":
            clean_x, clean_db = x, env
        elif clean_db is not None:
            c, lag = env_corr(clean_db, env)
            r["env_corr"] = round(c, 3)
            r["env_lag"] = lag
            if cond == "noisy" and degrade.NOISE["entries"]:
                try:
                    r.update(noisy_snr(seg, clean_x, x))
                except Exception as e:  # noqa: BLE001
                    r["snr_err"] = f"{type(e).__name__}: {e}"[:120]
                pr = params.get(seg)
                if pr:
                    r["snr_param"] = pr.get("snr_db")
                    r["guard_gain"] = pr.get("guard_gain", 1.0)
                    r["param_noise"] = pr.get("noise")
        out.append(r)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default=",".join(SETS))
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    degrade.NOISE.update(degrade.load_noise(VP / "sets" / "_noise"))
    for set_name in [s for s in args.sets.split(",") if s]:
        t0 = time.time()
        rows = [json.loads(l) for l in open(VP / "sets" / set_name / "segments.jsonl") if l.strip()]
        if args.limit:
            rows = rows[: args.limit]
        params = {}
        pp = VP / "clips" / set_name / "noisy" / "params.jsonl"
        if pp.exists():
            for l in open(pp):
                if l.strip():
                    d = json.loads(l)
                    params[d["seg_id"]] = d
        res = []
        with ThreadPoolExecutor(3) as ex:
            for i, rr in enumerate(ex.map(lambda r: analyse(set_name, r, params), rows)):
                res.extend(rr)
                if (i + 1) % 500 == 0:
                    print(f"{set_name}: {i + 1}/{len(rows)} {time.time() - t0:.0f}s", flush=True)
        keys = []
        for r in res:
            for k in r:
                if k not in keys:
                    keys.append(k)
        suffix = "" if not args.limit else "_sample"
        with open(OUT / f"audio_{set_name}{suffix}.csv", "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(res)
        print(f"{set_name}: done {len(rows)} clips in {time.time() - t0:.0f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
