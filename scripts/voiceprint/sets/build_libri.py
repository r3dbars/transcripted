#!/usr/bin/env python3
"""Build the `libri` voiceprint set from LibriSpeech dev-clean/dev-other/test-clean/test-other.

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md

Labels
  speaker = LibriVox reader id      -> libri:<spk>
  session = chapter                 -> libri:<spk>-<chapter>
  gender  = SPEAKERS.TXT (M / F)

Each clip is an exact crop of ONE utterance (single speaker, no overlap by
construction), cut to 2, 4 or 8 seconds. Up to 3 clips per (speaker, chapter,
bucket), each from a different utterance spread across the chapter. If more
than MAX_CLIPS clips are possible, clips are dropped round-robin so every
speaker keeps a balanced share (favours more speakers over more clips each).

Deterministic: all randomness is seeded from stable string hashes, listings are
sorted. Re-running rebuilds the same files and prunes stale clips.

Usage:
  VP/venv/bin/python scripts/voiceprint/sets/build_libri.py [--vp DIR] [--max-clips 3000]
"""
from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import os
import random
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf

SUBSETS = ["dev-clean", "dev-other", "test-clean", "test-other"]
BASE_URL = "https://www.openslr.org/resources/12"
BUCKETS = (8, 4, 2)  # longest first: fewest eligible utterances get first pick
PER_GROUP = 3
SR = 16000
MIN_RMS_DBFS = -45.0
MARGIN = 0.1  # utterance must be at least bucket + MARGIN seconds long
ACTIVE_DB = -55.0  # 25 ms frame counts as active above this
FRAME = 400
GRID_S = 0.25
SET = "libri"

REPO = Path(__file__).resolve().parents[3]
DEFAULT_VP = REPO / "data" / "eval" / "voiceprint"


def seed_of(*parts: str) -> int:
    h = hashlib.sha256("|".join(parts).encode()).digest()
    return int.from_bytes(h[:8], "big")


def safe(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.:-]", "_", s)


# ----------------------------------------------------------------------------
# download + extract
# ----------------------------------------------------------------------------

def ensure_extracted(raw: Path) -> None:
    for sub in SUBSETS:
        done = raw / f".extracted-{sub}"
        if done.exists() and (raw / "LibriSpeech" / sub).is_dir():
            continue
        tgz = raw / f"{sub}.tar.gz"
        if not tgz.exists():
            print(f"downloading {sub} ...", flush=True)
            subprocess.run(
                ["curl", "-sSL", "-C", "-", "--retry", "8", "--retry-delay", "5",
                 "-o", str(tgz), f"{BASE_URL}/{sub}.tar.gz"], check=True)
        print(f"extracting {sub} ...", flush=True)
        subprocess.run(["tar", "xzf", str(tgz), "-C", str(raw)], check=True)
        done.write_text("ok\n")


def parse_speakers(path: Path) -> dict[str, dict]:
    """SPEAKERS.TXT: ID | SEX | SUBSET | MINUTES | NAME  (';' lines are comments)."""
    out = {}
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip() or line.startswith(";"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            continue
        out[parts[0]] = {"gender": parts[1], "subset": parts[2]}
    return out


def parse_chapters(path: Path) -> dict[str, dict]:
    """CHAPTERS.TXT: ID | READER | MINUTES | SUBSET | PROJ | BOOK ID | TITLE | PROJECT TITLE"""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip() or line.startswith(";"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 6:
            continue
        out[parts[0]] = {"reader": parts[1], "minutes": parts[2], "subset": parts[3],
                         "project": parts[4], "book_id": parts[5]}
    return out


# ----------------------------------------------------------------------------
# audio helpers
# ----------------------------------------------------------------------------

def dbfs(x: np.ndarray) -> float:
    if x.size == 0:
        return -120.0
    r = float(np.sqrt(np.mean(np.square(x.astype(np.float64)))))
    return 20.0 * np.log10(max(r, 1e-9))


def frame_active_fraction(x: np.ndarray) -> float:
    n = x.size // FRAME
    if n == 0:
        return 0.0
    fr = x[: n * FRAME].reshape(n, FRAME).astype(np.float64)
    r = np.sqrt(np.mean(fr * fr, axis=1))
    return float(np.mean(20.0 * np.log10(np.maximum(r, 1e-9)) > ACTIVE_DB))


def pick_crop(wav: np.ndarray, bucket: int, rng: random.Random) -> int | None:
    """Return start sample of a `bucket`-second crop, or None if no window is loud enough."""
    n = bucket * SR
    if wav.size < n:
        return None
    max_start = wav.size - n
    step = int(GRID_S * SR)
    starts = list(range(0, max_start + 1, step))
    if starts[-1] != max_start:
        starts.append(max_start)
    scored = []
    for s in starts:
        w = wav[s:s + n]
        scored.append((frame_active_fraction(w), dbfs(w), s))
    good = [s for a, d, s in scored if a >= 0.85 and d >= MIN_RMS_DBFS]
    if good:
        return rng.choice(good)
    ok = [(a, s) for a, d, s in scored if d >= MIN_RMS_DBFS]
    if not ok:
        return None
    best = max(a for a, _ in ok)
    return rng.choice([s for a, s in ok if a >= best - 1e-9])


def spread_order(items: list, k: int, rng: random.Random) -> list:
    """Order `items` (sorted by place in chapter) so the first k are spread across it,
    then the remaining ones as seeded-shuffled fallbacks."""
    n = len(items)
    if n == 0:
        return []
    ideal = []
    if n <= k:
        ideal = list(range(n))
    else:
        for i in range(k):
            ideal.append(min(n - 1, int((i + rng.uniform(0.2, 0.8)) / k * n)))
    seen, ordered = set(), []
    for i in ideal:
        if i not in seen:
            seen.add(i)
            ordered.append(items[i])
    rest = [items[i] for i in range(n) if i not in seen]
    rng.shuffle(rest)
    return ordered + rest


# ----------------------------------------------------------------------------
# build
# ----------------------------------------------------------------------------

def scan_utterances(libri: Path) -> dict[tuple[str, str], list[dict]]:
    """(speaker, chapter) -> utterances sorted by name, each {path, dur, subset}."""
    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for sub in SUBSETS:
        for spk_dir in sorted((libri / sub).iterdir()):
            if not spk_dir.is_dir():
                continue
            for ch_dir in sorted(spk_dir.iterdir()):
                if not ch_dir.is_dir():
                    continue
                for f in sorted(ch_dir.glob("*.flac")):
                    info = sf.info(str(f))
                    if info.samplerate != SR:
                        raise SystemExit(f"unexpected sample rate {info.samplerate} in {f}")
                    groups[(spk_dir.name, ch_dir.name)].append(
                        {"path": f, "dur": info.frames / info.samplerate, "subset": sub})
    return groups


def candidates_for_group(spk: str, ch: str, utts: list[dict]) -> list[dict]:
    """Choose up to PER_GROUP clips per bucket for one chapter. Returns clip dicts
    (audio already cropped) with `rank` = order within the (speaker, chapter, bucket)."""
    used: set[Path] = set()
    out = []
    for bucket in BUCKETS:
        eligible = [u for u in utts if u["dur"] >= bucket + MARGIN]
        fresh = [u for u in eligible if u["path"] not in used]
        rng = random.Random(seed_of(SET, spk, ch, str(bucket), "order"))
        order = spread_order(fresh, PER_GROUP, rng)
        # utterances already used by a longer bucket are a last resort
        stale = [u for u in eligible if u["path"] in used]
        order += spread_order(stale, PER_GROUP, rng)
        picked = 0
        for u in order:
            if picked >= PER_GROUP:
                break
            wav, sr = sf.read(str(u["path"]), dtype="float32")
            if wav.ndim > 1:
                wav = wav.mean(axis=1)
            crng = random.Random(seed_of(SET, spk, ch, str(bucket), u["path"].name, "crop"))
            start = pick_crop(wav, bucket, crng)
            if start is None:
                continue
            n = bucket * SR
            out.append({
                "spk": spk, "chapter": ch, "bucket": bucket, "rank": picked,
                "utt": u["path"], "start": start / SR, "end": start / SR + bucket,
                "pcm": np.clip(np.round(wav[start:start + n] * 32768.0), -32768, 32767).astype(np.int16),
            })
            used.add(u["path"])
            picked += 1
    return out


def trim_to_cap(clips: list[dict], cap: int) -> list[dict]:
    """Drop clips down to `cap`, keeping speakers balanced and chapters/buckets spread.

    Per speaker, clips are ordered rank-major (every chapter/bucket's first clip, then
    every second clip, ...). Then speakers take turns, fewest-kept-first."""
    if len(clips) <= cap:
        return clips
    per_spk: dict[str, list[dict]] = defaultdict(list)
    for c in clips:
        per_spk[c["spk"]].append(c)
    for spk, lst in per_spk.items():
        lst.sort(key=lambda c: (c["rank"], c["chapter"], -c["bucket"]))
    heap = [(0, spk, 0) for spk in sorted(per_spk)]
    heapq.heapify(heap)
    kept = []
    while heap and len(kept) < cap:
        n, spk, i = heapq.heappop(heap)
        kept.append(per_spk[spk][i])
        if i + 1 < len(per_spk[spk]):
            heapq.heappush(heap, (n + 1, spk, i + 1))
    return kept


def write_wav(path: Path, pcm: np.ndarray) -> None:
    tmp = path.with_name(path.name + ".tmp")
    sf.write(str(tmp), pcm, SR, subtype="PCM_16", format="WAV")
    os.replace(tmp, path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vp", type=Path, default=DEFAULT_VP)
    ap.add_argument("--max-clips", type=int, default=3000)
    args = ap.parse_args()
    vp: Path = args.vp.absolute()

    raw = vp / "raw" / "libri"
    set_dir = vp / "sets" / SET
    clean_dir = vp / "clips" / SET / "clean"
    raw.mkdir(parents=True, exist_ok=True)
    set_dir.mkdir(parents=True, exist_ok=True)
    clean_dir.mkdir(parents=True, exist_ok=True)

    ready = set_dir / "READY"
    if ready.exists():
        ready.unlink()

    ensure_extracted(raw)
    libri = raw / "LibriSpeech"
    speakers = parse_speakers(libri / "SPEAKERS.TXT")
    chapters_meta = parse_chapters(libri / "CHAPTERS.TXT")

    groups = scan_utterances(libri)
    print(f"scanned {sum(len(v) for v in groups.values())} utterances in {len(groups)} chapters, "
          f"{len({s for s, _ in groups})} speakers", flush=True)

    clips: list[dict] = []
    for i, ((spk, ch), utts) in enumerate(sorted(groups.items())):
        clips.extend(candidates_for_group(spk, ch, utts))
        if (i + 1) % 50 == 0:
            print(f"  cut candidates for {i + 1}/{len(groups)} chapters ({len(clips)} clips)", flush=True)
    print(f"candidate clips: {len(clips)}", flush=True)

    clips = trim_to_cap(clips, args.max_clips)
    print(f"kept clips: {len(clips)}", flush=True)

    # session counts after trimming decide stranger_only
    spk_sessions: dict[str, set[str]] = defaultdict(set)
    for c in clips:
        spk_sessions[c["spk"]].add(c["chapter"])

    # deterministic final order + per-(speaker, session) index n
    clips.sort(key=lambda c: (c["spk"], c["chapter"], -c["bucket"], c["rank"]))
    counters: dict[tuple[str, str], int] = defaultdict(int)
    rows = []
    keep_files = set()
    for c in clips:
        spk, ch = c["spk"], c["chapter"]
        n = counters[(spk, ch)]
        counters[(spk, ch)] += 1
        speaker = f"{SET}:{spk}"
        session = f"{SET}:{spk}-{ch}"
        seg_id = safe(f"{SET}:{spk}:{ch}:{n}")
        rel = f"clips/{SET}/clean/{seg_id}.wav"
        write_wav(vp / rel, c["pcm"])
        keep_files.add(f"{seg_id}.wav")
        row = {
            "seg_id": seg_id,
            "set": SET,
            "speaker": speaker,
            "session": session,
            "bucket": c["bucket"],
            "dur": float(c["bucket"]),
            "clip": rel,
            "src": {"file": str(c["utt"].relative_to(vp)), "start": round(c["start"], 3),
                    "end": round(c["end"], 3)},
        }
        g = speakers.get(spk, {}).get("gender")
        if g in ("M", "F"):
            row["gender"] = g
        if len(spk_sessions[spk]) < 2:
            row["stranger_only"] = True
        rows.append(row)

    # prune stale clips (only inside our own clean dir)
    assert clean_dir.resolve().parent.parent.name == "clips"
    for f in clean_dir.iterdir():
        if f.name not in keep_files:
            f.unlink()

    with open(set_dir / "segments.jsonl", "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=False) + "\n")

    # side info: chapter -> book, for scorers that want to know which sessions share a book
    sessions_meta = {}
    for spk, chs in sorted(spk_sessions.items()):
        for ch in sorted(chs):
            m = chapters_meta.get(ch, {})
            sessions_meta[f"{SET}:{spk}-{ch}"] = {
                "chapter": ch, "book_id": m.get("book_id"), "project": m.get("project"),
                "subset": groups[(spk, ch)][0]["subset"]}
    (set_dir / "chapters.json").write_text(json.dumps(sessions_meta, indent=1, sort_keys=True))

    write_readme(set_dir, rows, spk_sessions, speakers, args.max_clips)
    ready.write_text(f"{len(rows)} clips\n")
    print(f"done: {len(rows)} clips, READY written", flush=True)


def write_readme(set_dir: Path, rows: list[dict], spk_sessions: dict, speakers: dict, cap: int) -> None:
    bucket_counts = defaultdict(int)
    for r in rows:
        bucket_counts[r["bucket"]] += 1
    n_spk = len(spk_sessions)
    n_sess = len({r["session"] for r in rows})
    multi = sum(1 for s in spk_sessions.values() if len(s) >= 2)
    stranger = n_spk - multi
    sess_hist = defaultdict(int)
    for s in spk_sessions.values():
        sess_hist[len(s)] += 1
    gender = defaultdict(int)
    for spk in spk_sessions:
        gender[speakers.get(spk, {}).get("gender", "?")] += 1
    per_spk = defaultdict(int)
    for r in rows:
        per_spk[r["speaker"]] += 1
    vals = sorted(per_spk.values())
    text = f"""# libri set

Human-labeled read speech from LibriSpeech, subsets dev-clean, dev-other, test-clean and test-other.

- Source: https://www.openslr.org/12 (LibriSpeech, Panayotov et al. 2015; audio from LibriVox)
- License: CC BY 4.0. Local evaluation only, never committed or uploaded.
- Built by: `scripts/voiceprint/sets/build_libri.py` (deterministic, re-runnable)
- Raw download: `raw/libri/` (tarballs plus extracted `LibriSpeech/`)

## Labels

- speaker = LibriVox reader id, `libri:<spk>`. Speakers are disjoint across the four subsets.
- session = chapter, `libri:<spk>-<chapter>`. A reader's chapters are often, but not always, recorded on
  different days. Chapters of the same book by the same reader may share a mic and room, so
  `chapters.json` maps each session to its LibriVox book id so a scorer can tell those apart.
- gender = SPEAKERS.TXT.
- Each clip is an exact crop of one utterance (single talker, no overlap by construction), cut to
  2, 4 or 8 s. Up to {PER_GROUP} clips per (speaker, chapter, bucket), each from a different
  utterance spread across the chapter. Windows must have RMS >= {MIN_RMS_DBFS:.0f} dBFS and prefer
  mostly-active frames. Audio is 16 kHz mono PCM16, no normalization. Original FLAC is already
  16 kHz.
- `src.file` is relative to the voiceprint data dir; `start` and `end` are seconds inside that utterance file.
- seg_id = `libri:<speaker id>:<chapter id>:<n>`, n counted per (speaker, chapter).
- When more than {cap} clips were possible, the surplus was dropped round-robin across speakers
  (rank-1 clips of every chapter and bucket first), so speaker coverage stays even.

## Counts

- clips: {len(rows)} (2 s: {bucket_counts[2]}, 4 s: {bucket_counts[4]}, 8 s: {bucket_counts[8]})
- speakers: {n_spk} ({gender.get('F', 0)} F, {gender.get('M', 0)} M)
- sessions (chapters): {n_sess}
- speakers with 2+ chapters: {multi}
- `stranger_only` speakers (one chapter): {stranger}
- chapters per speaker histogram: {dict(sorted(sess_hist.items()))}
- clips per speaker: min {vals[0]}, median {vals[len(vals) // 2]}, max {vals[-1]}

Files: `segments.jsonl`, `chapters.json`, `../../clips/libri/clean/*.wav`, `READY` (written last).
"""
    (set_dir / "README.md").write_text(text)


if __name__ == "__main__":
    main()
