#!/usr/bin/env python3
"""Answer-key audit, part 1: leaks and duplicates.

A leak is the same audio on both sides of a "different session" trial. It makes every model look
good. This script looks for shared audio with landmark fingerprints (fp.py), which survive
re-encoding (a YouTube re-upload, a LibriVox re-release), not just exact PCM hashes.

Jobs (all read-only on the sets; results in VP/results/audit/leaks/):
  meta     segments.jsonl sanity: duplicate seg_ids, stranger_only flags, src files reused across
           sessions, overlapping source windows between seg_ids
  exact    identical PCM (sha1) between different seg_ids, per condition (from audio_<set>.csv)
  clips    every clean clip of every set against every other: shared audio at one time offset
  vox1o    source level: every utterance in the zip vs every utterance of the same celebrity in
           other videos (finds re-uploaded videos even where the chosen clips differ)
  libri    source level: every utterance of every chapter in the set vs the same reader's other
           chapters
  yodas    source level: full videos of each target speaker vs its other sessions (dense), and all
           275 videos against each other (sparse, re-uploads and reused segments)
  meetings ami / icsi: whole-file sha1 and a 3 x 60 s fingerprint of each meeting vs every other

  VP/venv/bin/python scripts/voiceprint/audit/audit_leaks.py [--jobs meta,exact,clips,vox1o,libri,yodas,meetings]
"""
from __future__ import annotations

import os

for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ[_k] = "1"

import argparse  # noqa: E402
import collections  # noqa: E402
import csv  # noqa: E402
import hashlib  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
import zipfile  # noqa: E402
from concurrent.futures import ThreadPoolExecutor  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fp  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
OUT = VP / "results" / "audit" / "leaks"
SR = 16000
SETS = ("vox1o", "libri", "ami", "icsi", "yodas")
MIN_MATCH = 15          # hashes agreeing on one offset: a shared-audio match
MIN_MATCH_FRAC = 0.03   # ... and at least this share of the smaller item's hashes
THREADS = 3


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def load_rows(s: str) -> list[dict]:
    return [json.loads(l) for l in open(VP / "sets" / s / "segments.jsonl") if l.strip()]


def src_path(r: dict) -> Path:
    f = r["src"]["file"]
    for base in (VP, REPO):
        p = base / f
        if p.exists():
            return p
    return Path(f)


def resample16(x: np.ndarray, sr: int) -> np.ndarray:
    if sr == SR:
        return x
    from math import gcd
    from scipy.signal import resample_poly
    g = gcd(SR, sr)
    return resample_poly(x, SR // g, sr // g).astype(np.float32)


def fingerprint_many(items: list, loader, pps: int = fp.PEAKS_PER_S, fanout: int = fp.FANOUT):
    """items: list of keys; loader(key) -> float32 audio. Returns H, T, I (flat) and per-item counts."""
    def one(k):
        x = loader(k)
        return fp.hashes(x, pps, fanout)
    H, T, I, n = [], [], [], []
    with ThreadPoolExecutor(THREADS) as ex:
        for i, (h, t) in enumerate(ex.map(one, items)):
            H.append(h)
            T.append(t)
            I.append(np.full(len(h), i, dtype=np.int32))
            n.append(len(h))
    if not H:
        return np.zeros(0, np.int64), np.zeros(0, np.int32), np.zeros(0, np.int32), np.zeros(0, int)
    return np.concatenate(H), np.concatenate(T), np.concatenate(I), np.asarray(n)


def significant(best: dict, n: np.ndarray) -> list[tuple[int, int, int, int, float]]:
    out = []
    for (a, b), (c, off) in best.items():
        frac = c / max(1, min(n[a], n[b]))
        if c >= MIN_MATCH and frac >= MIN_MATCH_FRAC:
            out.append((a, b, c, off, round(frac, 3)))
    return sorted(out, key=lambda r: -r[2])


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys or ["none"])
        w.writeheader()
        w.writerows(rows)


# ------------------------------------------------------------------ meta
def job_meta() -> dict:
    rep = {}
    by_file_all = collections.defaultdict(list)
    for s in SETS:
        rows = load_rows(s)
        ids = collections.Counter(r["seg_id"] for r in rows)
        sess = collections.defaultdict(set)
        for r in rows:
            sess[r["speaker"]].add(r["session"])
        strangers = {r["speaker"] for r in rows if r.get("stranger_only")}
        wrong_flag = sorted(sp for sp, v in sess.items() if (len(v) < 2) != (sp in strangers))
        bad_prefix = [r["seg_id"] for r in rows if not (r["speaker"].startswith(s + ":") and r["session"].startswith(s + ":") and r["seg_id"].startswith(s + ":"))]
        # sessions shared by two speakers is normal (meetings); a session id reused for different src files is not
        sess_files = collections.defaultdict(set)
        file_sess = collections.defaultdict(set)
        for r in rows:
            sess_files[r["session"]].add(r["src"]["file"].split("/")[-2] if s in ("vox1o",) else r["src"]["file"])
            by_file_all[r["src"]["file"]].append(r)
        for r in rows:
            file_sess[r["src"]["file"]].add(r["session"])
        multi_sess_files = {f: sorted(v) for f, v in file_sess.items() if len(v) > 1}
        # overlapping windows in one source file
        overlaps = []
        by_file = collections.defaultdict(list)
        for r in rows:
            by_file[r["src"]["file"]].append(r)
        for f, rs in by_file.items():
            rs = sorted(rs, key=lambda r: r["src"]["start"])
            for i in range(len(rs)):
                for j in range(i + 1, len(rs)):
                    if rs[j]["src"]["start"] >= rs[i]["src"]["end"]:
                        break
                    ov = min(rs[i]["src"]["end"], rs[j]["src"]["end"]) - rs[j]["src"]["start"]
                    overlaps.append({"a": rs[i]["seg_id"], "b": rs[j]["seg_id"], "overlap_s": round(ov, 3),
                                     "same_speaker": rs[i]["speaker"] == rs[j]["speaker"],
                                     "same_session": rs[i]["session"] == rs[j]["session"]})
        # guard gap between clips of different speakers in one meeting file
        near_other = []
        if s in ("ami", "icsi"):
            for f, rs in by_file.items():
                rs = sorted(rs, key=lambda r: r["src"]["start"])
                for i in range(len(rs)):
                    for j in range(i + 1, len(rs)):
                        if rs[j]["src"]["start"] > rs[i]["src"]["end"] + 1.0:
                            break
                        if rs[i]["speaker"] != rs[j]["speaker"]:
                            gap = rs[j]["src"]["start"] - rs[i]["src"]["end"]
                            near_other.append({"a": rs[i]["seg_id"], "b": rs[j]["seg_id"], "gap_s": round(gap, 3)})
        dur_bad = [r["seg_id"] for r in rows if abs((r["src"]["end"] - r["src"]["start"]) - r["bucket"]) > 0.002 or float(r["dur"]) != float(r["bucket"])]
        rep[s] = {
            "clips": len(rows),
            "duplicate_seg_ids": [k for k, v in ids.items() if v > 1],
            "speakers": len(sess),
            "sessions": len({r["session"] for r in rows}),
            "stranger_flag_mismatch": wrong_flag,
            "bad_prefix": bad_prefix[:20],
            "src_file_in_2plus_sessions": multi_sess_files,
            "src_window_overlaps": {
                "total": len(overlaps),
                "same_speaker_same_session": sum(o["same_speaker"] and o["same_session"] for o in overlaps),
                "cross_session": [o for o in overlaps if not o["same_session"]],
                "different_speaker": [o for o in overlaps if not o["same_speaker"]],
                "examples": overlaps[:10],
            },
            "different_speaker_clips_within_1s": near_other[:50],
            "different_speaker_clips_within_1s_count": len(near_other),
            "src_len_mismatch": dur_bad[:20],
            "src_len_mismatch_count": len(dur_bad),
        }
    cross_set = {f: sorted({r["set"] for r in rs}) for f, rs in by_file_all.items() if len({r["set"] for r in rs}) > 1}
    rep["_cross_set_src_files"] = cross_set
    # noise bank vs yodas set
    idx = json.loads((VP / "sets" / "_noise" / "index.json").read_text())
    yrows = load_rows("yodas")
    y_ids = {r.get("identity") for r in yrows} | {r["session"].split(":", 1)[1] for r in yrows}
    y_files = {r["src"]["file"].split("/")[-1][:12] for r in yrows}
    babble_hits = [(b["id"], v) for b in idx.get("babble", []) for v in b.get("voices", []) if v in y_ids]
    music_hits = [m["id"] for m in idx.get("music", []) if Path(m["src"]["file"]).name[:12] in y_files]
    rep["_noise_bank"] = {"babble_voices_in_yodas_set": babble_hits, "music_from_yodas_set_videos": music_hits,
                          "babble_clips": len(idx.get("babble", [])), "music_clips": len(idx.get("music", []))}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "meta.json").write_text(json.dumps(rep, indent=1))
    for s in SETS:
        r = rep[s]
        log(f"meta {s}: dup_ids={len(r['duplicate_seg_ids'])} flag_mismatch={len(r['stranger_flag_mismatch'])} "
            f"src_multi_session={len(r['src_file_in_2plus_sessions'])} overlaps={r['src_window_overlaps']['total']} "
            f"(cross-session {len(r['src_window_overlaps']['cross_session'])}, diff-speaker {len(r['src_window_overlaps']['different_speaker'])}) "
            f"len_mismatch={r['src_len_mismatch_count']}")
    log(f"meta: cross-set src files {len(cross_set)}; noise bank hits {rep['_noise_bank']['babble_voices_in_yodas_set'][:5]} {music_hits[:5]}")
    return rep


# ------------------------------------------------------------------ exact
def job_exact() -> dict:
    rep = {}
    allh = collections.defaultdict(list)
    for s in SETS:
        p = VP / "results" / "audit" / f"audio_{s}.csv"
        if not p.exists():
            log(f"exact: {p} missing, run audit_audio.py first")
            continue
        with open(p) as f:
            for r in csv.DictReader(f):
                if r.get("sha1"):
                    allh[(r["cond"], r["sha1"])].append(r["seg_id"])
    for (cond, h), ids in allh.items():
        if len(ids) > 1:
            rep.setdefault(cond, []).append(ids)
    (OUT / "exact.json").write_text(json.dumps(rep, indent=1))
    log(f"exact: duplicate PCM groups per cond: { {c: len(v) for c, v in rep.items()} }")
    return rep


# ------------------------------------------------------------------ clips (all sets, all vs all)
def job_clips() -> list[dict]:
    rows = [r for s in SETS for r in load_rows(s)]
    log(f"clips: fingerprinting {len(rows)} clean clips")

    def loader(i):
        x, _ = sf.read(str(VP / rows[i]["clip"]), dtype="float32")
        return x
    H, T, I, n = fingerprint_many(list(range(len(rows))), loader)
    log(f"clips: {len(H)} hashes; matching")
    best = fp.match_all(H, T, I, max_bucket=600, min_count=8)
    out = []
    for a, b, c, off, frac in significant(best, n):
        ra, rb = rows[a], rows[b]
        out.append({"a": ra["seg_id"], "b": rb["seg_id"], "match": c, "frac": frac, "offset_s": off / 100,
                    "same_set": ra["set"] == rb["set"], "same_speaker": ra["speaker"] == rb["speaker"],
                    "same_session": ra["session"] == rb["session"],
                    "src_a": f"{ra['src']['file']}@{ra['src']['start']}", "src_b": f"{rb['src']['file']}@{rb['src']['start']}"})
    write_csv(OUT / "clips_shared_audio.csv", out)
    # near-threshold distribution for the record
    hist = collections.Counter(min(v[0], 100) // 5 * 5 for v in best.values())
    (OUT / "clips_match_hist.json").write_text(json.dumps(dict(sorted(hist.items()))))
    kinds = collections.Counter((o["same_speaker"], o["same_session"]) for o in out)
    log(f"clips: {len(out)} shared-audio pairs; (same_speaker, same_session) -> {dict(kinds)}")
    return out


# ------------------------------------------------------------------ vox1o source level
def job_vox1o() -> list[dict]:
    rows = load_rows("vox1o")
    zf = zipfile.ZipFile(VP / "raw" / "vox1o" / "vox1_test_wav.zip")
    names = sorted(n for n in zf.namelist() if n.endswith(".wav"))
    by_spk = collections.defaultdict(list)
    for n in names:
        p = n.split("/")
        by_spk[p[-3]].append(n)
    out = []
    vid_pairs = collections.defaultdict(lambda: {"utt_pairs": 0, "max_match": 0, "examples": []})
    n_utt = collections.Counter()
    for spk in sorted(by_spk):
        utts = by_spk[spk]
        for u in utts:
            n_utt[(spk, u.split("/")[-2])] += 1

        def loader(u):
            x, sr = sf.read(io.BytesIO(zf.read(u)), dtype="float32")
            return resample16(x if x.ndim == 1 else x.mean(axis=1), sr)
        # zipfile is not thread-safe for concurrent reads of one handle: read bytes serially
        data = {u: zf.read(u) for u in utts}

        def loader2(u):
            x, sr = sf.read(io.BytesIO(data[u]), dtype="float32")
            return resample16(x if x.ndim == 1 else x.mean(axis=1), sr)
        H, T, I, n = fingerprint_many(utts, loader2)
        vids = np.asarray([hash(u.split("/")[-2]) for u in utts], dtype=np.int64)
        best = fp.match_all(H, T, I, group=vids, max_bucket=400, min_count=8)
        for a, b, c, off, frac in significant(best, n):
            va, vb = utts[a].split("/")[-2], utts[b].split("/")[-2]
            key = (spk, *sorted((va, vb)))
            d = vid_pairs[key]
            d["utt_pairs"] += 1
            d["max_match"] = max(d["max_match"], c)
            if len(d["examples"]) < 3:
                d["examples"].append(f"{utts[a].split('/')[-1]}~{utts[b].split('/')[-1]}:{c}")
    set_vids = {r["session"].split(":", 1)[1] for r in rows}
    set_ids = collections.Counter(r["session"].split(":", 1)[1] for r in rows)
    for (spk, va, vb), d in sorted(vid_pairs.items()):
        out.append({"speaker": spk, "video_a": va, "video_b": vb, "utts_a": n_utt[(spk, va)], "utts_b": n_utt[(spk, vb)],
                    "matched_utt_pairs": d["utt_pairs"], "max_match": d["max_match"],
                    "a_in_set": va in set_vids, "b_in_set": vb in set_vids,
                    "clips_a": set_ids.get(va, 0), "clips_b": set_ids.get(vb, 0),
                    "examples": " ".join(d["examples"])})
    write_csv(OUT / "vox1o_video_pairs.csv", out)
    log(f"vox1o: {len(out)} cross-video pairs share audio ({sum(o['a_in_set'] and o['b_in_set'] for o in out)} with both videos in the set)")
    return out


# ------------------------------------------------------------------ libri source level
def job_libri() -> list[dict]:
    rows = load_rows("libri")
    chapters = collections.defaultdict(set)
    for r in rows:
        p = Path(r["src"]["file"])
        chapters[r["speaker"]].add(p.parent)
    out = []
    for spk in sorted(chapters):
        chs = sorted(chapters[spk])
        if len(chs) < 2:
            continue
        utts = [f for ch in chs for f in sorted((VP / ch).glob("*.flac"))]

        def loader(f):
            x, sr = sf.read(str(f), dtype="float32")
            return x
        H, T, I, n = fingerprint_many(utts, loader)
        grp = np.asarray([hash(f.parent.name) for f in utts], dtype=np.int64)
        best = fp.match_all(H, T, I, group=grp, max_bucket=400, min_count=8)
        for a, b, c, off, frac in significant(best, n):
            out.append({"speaker": spk, "utt_a": utts[a].name, "utt_b": utts[b].name, "match": c, "frac": frac,
                        "offset_s": off / 100})
    write_csv(OUT / "libri_cross_chapter.csv", out)
    log(f"libri: {len(out)} cross-chapter utterance pairs share audio")
    return out


# ------------------------------------------------------------------ yodas source level
def job_yodas() -> dict:
    rows = load_rows("yodas")
    vid_of = {}
    for r in rows:
        vid_of[r["session"]] = src_path(r)
    spk_sess = collections.defaultdict(set)
    for r in rows:
        spk_sess[r["speaker"]].add(r["session"])
    targets = {s: sorted(v) for s, v in spk_sess.items() if len(v) > 1}
    dense = []
    # (a) each target speaker: clips vs the speaker's other videos (dense)
    for spk, sess in sorted(targets.items()):
        clips = [r for r in rows if r["speaker"] == spk]
        items = [("clip", r["seg_id"], r["session"], VP / r["clip"]) for r in clips] + \
                [("video", s, s, vid_of[s]) for s in sess]

        def loader(it):
            x, sr = sf.read(str(it[3]), dtype="float32", always_2d=True)
            return resample16(x.mean(axis=1), sr)
        H, T, I, n = fingerprint_many(items, loader)
        grp = np.asarray([hash(it[2]) for it in items], dtype=np.int64)
        best = fp.match_all(H, T, I, group=grp, max_bucket=800, min_count=8)
        for a, b, c, off, frac in significant(best, n):
            ia, ib = items[a], items[b]
            if ia[0] == "clip" and ib[0] == "clip":
                kind = "clip-clip"
            elif ia[0] == "video" and ib[0] == "video":
                kind = "video-video"
            else:
                kind = "clip-video"
            dense.append({"speaker": spk, "kind": kind, "a": ia[1], "b": ib[1], "match": c, "frac": frac,
                          "offset_s": off / 100})
        log(f"yodas dense {spk}: {len(sess)} videos, hits so far {len(dense)}")
    write_csv(OUT / "yodas_target_shared.csv", dense)
    # (b) all videos vs all videos, sparse
    sess_all = sorted(vid_of)

    def loader_v(s):
        x, sr = sf.read(str(vid_of[s]), dtype="float32", always_2d=True)
        return resample16(x.mean(axis=1), sr)
    log(f"yodas sparse: fingerprinting {len(sess_all)} videos")
    H, T, I, n = fingerprint_many(sess_all, loader_v, pps=8, fanout=3)
    log(f"yodas sparse: {len(H)} hashes; matching")
    best = fp.match_all(H, T, I, max_bucket=300, min_count=10)
    spk_of_sess = {}
    for r in rows:
        spk_of_sess[r["session"]] = r["speaker"]
    sparse = []
    for (a, b), (c, off) in sorted(best.items(), key=lambda kv: -kv[1][0]):
        if c < 25:
            continue
        sa, sb = sess_all[a], sess_all[b]
        sparse.append({"session_a": sa, "session_b": sb, "speaker_a": spk_of_sess[sa], "speaker_b": spk_of_sess[sb],
                       "same_speaker": spk_of_sess[sa] == spk_of_sess[sb], "match": c, "offset_s": off / 100,
                       "hashes_a": int(n[a]), "hashes_b": int(n[b])})
    write_csv(OUT / "yodas_video_pairs.csv", sparse)
    hist = collections.Counter(min(v[0], 200) // 10 * 10 for v in best.values())
    (OUT / "yodas_video_match_hist.json").write_text(json.dumps(dict(sorted(hist.items()))))
    log(f"yodas sparse: {len(sparse)} video pairs with >=25 aligned hashes")
    return {"dense": dense, "sparse": sparse}


# ------------------------------------------------------------------ meetings
def job_meetings() -> list[dict]:
    out = []
    for s in ("ami", "icsi"):
        rows = load_rows(s)
        files = sorted({str(src_path(r)) for r in rows})
        sha = {}
        for f in files:
            h = hashlib.sha1()
            with open(f, "rb") as fh:
                while True:
                    b = fh.read(1 << 22)
                    if not b:
                        break
                    h.update(b)
            sha[f] = h.hexdigest()
        dup = collections.defaultdict(list)
        for f, h in sha.items():
            dup[h].append(f)
        for h, fs in dup.items():
            if len(fs) > 1:
                out.append({"set": s, "kind": "identical_file", "a": fs[0], "b": fs[1], "match": -1})
        items = [(f, k) for f in files for k in range(3)]

        def loader(it):
            f, k = it
            info = sf.info(f)
            start = int(info.frames * (0.2 + 0.3 * k))
            x, sr = sf.read(f, start=start, frames=60 * SR, dtype="float32", always_2d=True)
            return x.mean(axis=1)
        H, T, I, n = fingerprint_many(items, loader, pps=15, fanout=4)
        grp = np.asarray([hash(it[0]) for it in items], dtype=np.int64)
        best = fp.match_all(H, T, I, group=grp, max_bucket=400, min_count=8)
        for a, b, c, off, frac in significant(best, n):
            out.append({"set": s, "kind": "shared_audio", "a": f"{Path(items[a][0]).name}#{items[a][1]}",
                        "b": f"{Path(items[b][0]).name}#{items[b][1]}", "match": c, "frac": frac})
        log(f"meetings {s}: {len(files)} files, identical {sum(1 for fs in dup.values() if len(fs) > 1)}, "
            f"shared-audio windows {sum(1 for o in out if o['set'] == s and o['kind'] == 'shared_audio')}")
    write_csv(OUT / "meetings.csv", out)
    return out


JOBS = {"meta": job_meta, "exact": job_exact, "clips": job_clips, "vox1o": job_vox1o, "libri": job_libri,
        "yodas": job_yodas, "meetings": job_meetings}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", default="meta,exact,clips,vox1o,libri,meetings,yodas")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for j in args.jobs.split(","):
        t0 = time.time()
        JOBS[j]()
        log(f"job {j} done in {time.time() - t0:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
