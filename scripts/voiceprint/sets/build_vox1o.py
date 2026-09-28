#!/usr/bin/env python3
"""Build the `vox1o` voiceprint set from the VoxCeleb1 test split (Vox1-O: 40 speakers, 4,874 utterances).

Source: Hugging Face dataset ProgramComputer/voxceleb, file vox1/vox1_test_wav.zip (the original
id1xxxx/<youtube_video_id>/<utt>.wav layout). See VP/sets/vox1o/README.md.

speaker = VoxCeleb id, session = YouTube video id. Every utterance is one talker by construction.

Deterministic (fixed seed, sorted inputs) and re-runnable. Reads the zip in place; writes only
VP/clips/vox1o/clean/, VP/sets/vox1o/segments.jsonl and VP/sets/vox1o/READY.

Usage:
    VP/venv/bin/python scripts/voiceprint/sets/build_vox1o.py [--total 3000] [--dry-run]
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import random
import re
import sys
import zipfile
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf

SET = "vox1o"
SEED = "vox1o-v1"
SR = 16000
BUCKETS = (2, 4, 8)
MAX_PER_SESSION_BUCKET = 3
MIN_RMS_DBFS = -45.0
MIN_SPEECH_FRAC = 0.5      # frames within 35 dB of the clip's loudest frame
MIN_EDGE_GAP = 0.0         # utterances are already trimmed by VoxCeleb; no extra margin needed

REPO = Path(__file__).resolve().parents[3]
VP = REPO / "data" / "eval" / "voiceprint"
ZIP_PATH = VP / "raw" / SET / "vox1_test_wav.zip"
META_CSV = VP / "raw" / SET / "vox1_meta.csv"
SET_DIR = VP / "sets" / SET
CLIP_DIR = VP / "clips" / SET / "clean"


def safe(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.:-]", "_", s)


def frame_db(x: np.ndarray, frame: int = 400, hop: int = 160) -> np.ndarray:
    """Per-frame RMS in dBFS (x is float32 in [-1, 1])."""
    if len(x) < frame:
        x = np.pad(x, (0, frame - len(x)))
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    ms = np.mean(x[idx].astype(np.float64) ** 2, axis=1)
    return 10 * np.log10(np.maximum(ms, 1e-12))


def rms_db(x: np.ndarray) -> float:
    return float(10 * np.log10(max(float(np.mean(x.astype(np.float64) ** 2)), 1e-12)))


def clip_ok(x: np.ndarray) -> bool:
    if rms_db(x) < MIN_RMS_DBFS:
        return False
    fd = frame_db(x)
    return float(np.mean(fd > fd.max() - 35.0)) >= MIN_SPEECH_FRAC


def read_wav(zf: zipfile.ZipFile, name: str) -> tuple[np.ndarray, int]:
    data, sr = sf.read(io.BytesIO(zf.read(name)), dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)
    return data, sr


def to_16k(x: np.ndarray, sr: int) -> np.ndarray:
    if sr == SR:
        return x
    from scipy.signal import resample_poly
    from math import gcd
    g = gcd(SR, sr)
    return resample_poly(x, SR // g, sr // g).astype(np.float32)


def water_fill(caps: dict[str, int], total: int) -> dict[str, int]:
    """Give every key an equal share, capped by its capacity; hand leftovers to keys with room."""
    quota = {k: 0 for k in caps}
    remaining = total
    open_keys = sorted(k for k in caps if caps[k] > 0)
    while remaining > 0 and open_keys:
        share = max(remaining // len(open_keys), 1)
        progressed = 0
        for k in list(open_keys):
            give = min(share, caps[k] - quota[k], remaining)
            quota[k] += give
            remaining -= give
            progressed += give
            if quota[k] >= caps[k]:
                open_keys.remove(k)
            if remaining == 0:
                break
        if progressed == 0:
            break
    return quota


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--total", type=int, default=3000, help="cap on clean clips")
    ap.add_argument("--dry-run", action="store_true", help="plan only, write nothing")
    args = ap.parse_args()

    if not ZIP_PATH.exists():
        print(f"missing {ZIP_PATH}", file=sys.stderr)
        return 1

    gender = {}
    with META_CSV.open() as f:
        for row in csv.DictReader(f, delimiter="\t"):
            gender[row["VoxCeleb1 ID"]] = row["Gender"]

    # ---- pass 1: index every utterance (duration + overall loudness) ----
    zf = zipfile.ZipFile(ZIP_PATH)
    names = sorted(n for n in zf.namelist() if n.lower().endswith(".wav"))
    utts = []  # dicts
    for n in names:
        parts = n.split("/")
        # expected: [wav/]id1xxxx/<video>/<utt>.wav
        spk, vid, fn = parts[-3], parts[-2], parts[-1]
        if not re.fullmatch(r"id\d{5}", spk):
            continue
        x, sr = read_wav(zf, n)
        n_samp = int(round(len(x) * SR / sr))
        utts.append({
            "name": n, "spk": spk, "vid": vid, "utt": fn[:-4], "sr": sr,
            "dur": n_samp / SR, "rms": rms_db(x) if len(x) else -120.0,
        })
    print(f"indexed {len(utts)} utterances in zip", flush=True)
    utts = [u for u in utts if u["rms"] >= MIN_RMS_DBFS]
    print(f"{len(utts)} above {MIN_RMS_DBFS} dBFS overall", flush=True)

    by_spk: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))
    for u in utts:
        by_spk[u["spk"]][u["vid"]].append(u)
    speakers = sorted(by_spk)
    print(f"{len(speakers)} speakers, {sum(len(v) for v in by_spk.values())} sessions", flush=True)

    # ---- capacity per (speaker, bucket): sum over sessions of min(3, utterances long enough) ----
    def session_cap(utt_list, b):
        return min(MAX_PER_SESSION_BUCKET, sum(1 for u in utt_list if u["dur"] >= b))

    cap = {b: {s: sum(session_cap(v, b) for v in by_spk[s].values()) for s in speakers} for b in BUCKETS}

    # ---- per-bucket quotas: equal split of the total across buckets, leftovers shift to other buckets ----
    per_bucket = {b: args.total // len(BUCKETS) for b in BUCKETS}
    quota: dict[int, dict[str, int]] = {}
    for _ in range(3):
        for b in BUCKETS:
            quota[b] = water_fill(cap[b], per_bucket[b])
        short = {b: per_bucket[b] - sum(quota[b].values()) for b in BUCKETS}
        lacking = [b for b in BUCKETS if short[b] > 0]
        if not lacking:
            break
        room = [b for b in BUCKETS if short[b] <= 0]
        extra = sum(short[b] for b in lacking)
        for b in lacking:
            per_bucket[b] -= short[b]
        for b in room:
            per_bucket[b] += extra // max(len(room), 1)
    print("bucket targets:", {b: sum(quota[b].values()) for b in BUCKETS}, flush=True)

    # ---- pick clips ----
    # per speaker: for each bucket, round-robin over shuffled sessions, up to 3 clips per session.
    # A crop never overlaps another crop already taken from the same utterance.
    used: dict[str, list[tuple[float, float]]] = defaultdict(list)  # utt name -> [(start, end)]
    cache: dict[str, np.ndarray] = {}
    picks = []  # (spk, vid, bucket, utt dict, start_sec, samples)

    def load(u):
        if u["name"] not in cache:
            x, sr = read_wav(zf, u["name"])
            cache[u["name"]] = to_16k(x, sr)
            if len(cache) > 64:
                cache.pop(next(iter(cache)))
        return cache[u["name"]]

    def try_crop(u, b, rng):
        x = load(u)
        n = b * SR
        if len(x) < n:
            return None
        # candidate starts on a 0.25 s grid, in a seeded shuffled order; first that is free and clean wins
        max_start = len(x) - n
        grid = list(range(0, max_start + 1, SR // 4)) or [0]
        if grid[-1] != max_start:
            grid.append(max_start)
        rng.shuffle(grid)
        checked = 0
        for s in grid:
            st, en = s / SR, (s + n) / SR
            if any(not (en <= a or st >= c) for a, c in used[u["name"]]):
                continue
            seg = x[s:s + n]
            if clip_ok(seg):
                return s, seg
            checked += 1
            if checked >= 24:
                break
        return None

    for spk in speakers:
        sessions = sorted(by_spk[spk])
        rng_s = random.Random(f"{SEED}|{spk}|sessions")
        for b in sorted(BUCKETS, reverse=True):  # longest first: they are the hardest to place
            want = quota[b][spk]
            if want <= 0:
                continue
            order = sessions[:]
            rng_s.shuffle(order)
            got = 0
            for rnd in range(MAX_PER_SESSION_BUCKET):
                if got >= want:
                    break
                for vid in order:
                    if got >= want:
                        break
                    already = sum(1 for p in picks if p[0] == spk and p[1] == vid and p[2] == b)
                    if already != rnd:
                        continue  # this session had nothing left for this round
                    rng = random.Random(f"{SEED}|{spk}|{vid}|{b}|{rnd}")
                    # utterances not yet used in this (session, bucket) come first, then ones already cropped
                    pool = [u for u in by_spk[spk][vid] if u["dur"] >= b]
                    pool.sort(key=lambda u: (len(used[u["name"]]), u["utt"]))
                    rng.shuffle(pool)
                    pool.sort(key=lambda u: len(used[u["name"]]))
                    for u in pool:
                        res = try_crop(u, b, rng)
                        if res is None:
                            continue
                        s, seg = res
                        used[u["name"]].append((s / SR, s / SR + b))
                        picks.append((spk, vid, b, u, s / SR, seg))
                        got += 1
                        break
            if got < want:
                print(f"  note: {spk} bucket {b}s got {got}/{want}", flush=True)

    print(f"picked {len(picks)} clips", flush=True)

    # ---- assign ids, write ----
    picks.sort(key=lambda p: (p[0], p[1], p[2], p[3]["utt"], p[4]))
    counters: dict[tuple[str, str], int] = defaultdict(int)
    rows = []
    wavs = []
    sess_per_spk: dict[str, set] = defaultdict(set)
    for spk, vid, b, u, start, seg in picks:
        sess_per_spk[spk].add(vid)
    for spk, vid, b, u, start, seg in picks:
        n = counters[(spk, vid)]
        counters[(spk, vid)] += 1
        seg_id = safe(f"{SET}:{spk}:{vid}:{n}")
        row = {
            "seg_id": seg_id,
            "set": SET,
            "speaker": f"{SET}:{spk}",
            "session": f"{SET}:{safe(vid)}",
            "bucket": b,
            "dur": float(b),
            "clip": f"clips/{SET}/clean/{seg_id}.wav",
            "src": {"file": u["name"], "start": round(start, 3), "end": round(start + b, 3)},
        }
        if spk in gender:
            row["gender"] = gender[spk]
        if len(sess_per_spk[spk]) < 2:
            row["stranger_only"] = True
        rows.append(row)
        wavs.append(seg)

    n_sess = sum(len(v) for v in sess_per_spk.values())
    per_bucket_n = {b: sum(1 for r in rows if r["bucket"] == b) for b in BUCKETS}
    print(f"speakers={len(sess_per_spk)} sessions={n_sess} clips={len(rows)} per_bucket={per_bucket_n}")
    mins = sorted(len(v) for v in sess_per_spk.values())
    print(f"sessions per speaker: min={mins[0]} median={mins[len(mins)//2]} max={mins[-1]}")
    if args.dry_run:
        return 0

    # Only delete inside the clip dir this script owns.
    ready = SET_DIR / "READY"
    SET_DIR.mkdir(parents=True, exist_ok=True)
    if ready.exists():
        ready.unlink()
    CLIP_DIR.mkdir(parents=True, exist_ok=True)
    root = (VP / "clips" / SET).resolve()
    for old in CLIP_DIR.glob("*.wav"):
        assert root in old.resolve().parents, old
        old.unlink()
    for row, seg in zip(rows, wavs):
        pcm = np.clip(np.round(seg * 32768.0), -32768, 32767).astype(np.int16)
        assert len(pcm) == row["bucket"] * SR
        sf.write(str(VP / row["clip"]), pcm, SR, subtype="PCM_16", format="WAV")
    with (SET_DIR / "segments.jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row, sort_keys=False) + "\n")
    missing = [r["clip"] for r in rows if not (VP / r["clip"]).exists()]
    if missing:
        print(f"missing clips: {len(missing)}", file=sys.stderr)
        return 1
    ready.write_text(f"{len(rows)} clips\n")
    print("READY written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
