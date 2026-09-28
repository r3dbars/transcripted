#!/usr/bin/env python3
"""Build the speaker-lab voice bank from YODAS3 shards.

Two passes, split so the expensive part runs once:

  embed   Decode every video in a shard to 16 kHz mono FLAC, cut speech regions
          from the caption timestamps, and embed 3 s windows with two voice
          models that are NOT the app's (NVIDIA TitaNet-large and 3D-Speaker
          CAM++, via sherpa-onnx). Writes one .npz + one .json per video.

  select  Calibrate "same voice" thresholds from cross-video pairs, find each
          video's main voice under both models, and keep a video as a verified
          identity only when both models agree the main voice holds at least
          --min-main-share of its speech. Writes bank/<lang>/identities.jsonl,
          a sound-alike matrix, and the list of real multi-speaker (">>") videos.

Identity = the main voice of one video. YODAS3 IDs are encrypted, so videos from
the same uploader can't be linked from metadata (see YODAS_LAB_PLAN.md).

Everything is written under data/eval/yodas3/bank (gitignored). Run with the lab
venv: data/eval/yodas3/venv/bin/python scripts/speaker_lab/voicebank.py embed --lang en
"""
from __future__ import annotations

import argparse
import io
import json
import multiprocessing as mp
import os
import re
import sys
import tarfile
import time
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get("YODAS_ROOT", REPO_ROOT / "data" / "eval" / "yodas3"))
SR = 16000
WINDOW_S = 3.0
MAX_WINDOWS = 240
MIN_WINDOW_DB = -50.0
MODELS = {
    "tit": "nemo_en_titanet_large.onnx",
    # 3D-Speaker CAM++ (zh/en, 200k speakers). The voxceleb-only CAM++ export
    # scores the same voice 0.5 s later at 0.80 but 60 s later at 0.96 in this
    # data: it tracks the recording, not the voice. This one matches TitaNet
    # (0.9% EER on single-voice videos).
    "cam": "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
}
CUE = re.compile(r"^\s*[\[\(][^\]\)]*[\]\)]\s*$")  # "[Music]", "(applause)"


# ---------------------------------------------------------------- speech regions

def speech_regions(transcript: list[dict]) -> tuple[list[list[float]], list[list], bool]:
    """Speech intervals (seconds) and a flat word list from YODAS3 caption JSON.

    ASR tracks carry per-word offsets; a word ends at the next word's start,
    capped at 1 s. Uploader subtitles have no words, so a cue spans its own
    start..start+duration, clipped to the next cue's start.
    """
    words: list[list] = []
    spans: list[list[float]] = []
    has_words = any("words" in seg for seg in transcript)
    for i, seg in enumerate(transcript):
        text = (seg.get("text") or "").strip()
        if not text or CUE.match(text):
            continue
        start = seg["start"] / 1000.0
        dur = seg.get("duration", 0) / 1000.0
        nxt = transcript[i + 1]["start"] / 1000.0 if i + 1 < len(transcript) else start + dur
        if has_words and seg.get("words"):
            ws = seg["words"]
            for j, w in enumerate(ws):
                token = (w.get("w") or "").strip()
                if not token or CUE.match(token):
                    continue
                ws_start = start + w["t"] / 1000.0
                if j + 1 < len(ws):
                    ws_end = start + ws[j + 1]["t"] / 1000.0
                else:
                    ws_end = min(start + dur, nxt)
                ws_end = min(max(ws_end, ws_start + 0.08), ws_start + 1.0)
                words.append([round(ws_start, 3), round(ws_end, 3), token])
                spans.append([ws_start, ws_end])
        else:
            end = min(start + dur, nxt) if nxt > start else start + dur
            if end - start >= 0.3:
                spans.append([start, end])
    spans.sort()
    merged: list[list[float]] = []
    for s, e in spans:
        if merged and s - merged[-1][1] < 0.4:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    return [[round(s, 3), round(e, 3)] for s, e in merged], words, has_words


def window_starts(regions: list[list[float]], duration: float) -> np.ndarray:
    """Non-overlapping 3 s windows inside speech (regions merged across <0.6 s gaps)."""
    joined: list[list[float]] = []
    for s, e in regions:
        e = min(e, duration)
        if e <= s:
            continue
        if joined and s - joined[-1][1] < 0.6:
            joined[-1][1] = max(joined[-1][1], e)
        else:
            joined.append([s, e])
    starts = []
    for s, e in joined:
        t = s
        while t + WINDOW_S <= e:
            starts.append(t)
            t += WINDOW_S
    starts = np.array(starts, dtype=np.float64)
    if len(starts) > MAX_WINDOWS:
        idx = np.linspace(0, len(starts) - 1, MAX_WINDOWS).round().astype(int)
        starts = starts[idx]
    return starts


# ---------------------------------------------------------------- embed pass

_EXTRACTORS = None


def _init_worker() -> None:
    global _EXTRACTORS
    import sherpa_onnx

    _EXTRACTORS = {}
    for key, fname in MODELS.items():
        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=str(ROOT / "models" / fname), num_threads=1, provider="cpu"
        )
        _EXTRACTORS[key] = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)


def decode(blob: bytes) -> np.ndarray:
    import av

    with av.open(io.BytesIO(blob)) as c:
        rs = av.AudioResampler(format="flt", layout="mono", rate=SR)
        chunks = [f.to_ndarray().reshape(-1) for fr in c.decode(c.streams.audio[0]) for f in rs.resample(fr)]
        chunks += [f.to_ndarray().reshape(-1) for f in rs.resample(None)]
    return np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)


def embed_one(job: tuple) -> dict:
    vid, blob, meta, out_dir = job
    import soundfile as sf

    out_dir = Path(out_dir)
    try:
        transcript = json.loads(meta["transcript"]) if meta.get("transcript") else []
        regions, words, has_words = speech_regions(transcript)
        wav = decode(blob)
        duration = len(wav) / SR
        sf.write(out_dir / "audio16k" / f"{vid}.flac", np.clip(wav, -1, 1), SR, subtype="PCM_16")
        starts = window_starts(regions, duration)
        keep, tit, cam, dbs = [], [], [], []
        for t in starts:
            seg = wav[int(t * SR): int((t + WINDOW_S) * SR)]
            db = 20 * np.log10(np.sqrt(np.mean(seg * seg)) + 1e-9)
            if db < MIN_WINDOW_DB:
                continue
            embs = []
            for key in ("tit", "cam"):
                s = _EXTRACTORS[key].create_stream()
                s.accept_waveform(SR, seg)
                s.input_finished()
                v = np.asarray(_EXTRACTORS[key].compute(s), dtype=np.float32)
                embs.append(v / (np.linalg.norm(v) + 1e-9))
            keep.append(t)
            tit.append(embs[0])
            cam.append(embs[1])
            dbs.append(db)
        np.savez_compressed(
            out_dir / "windows" / f"{vid}.npz",
            starts=np.array(keep, dtype=np.float32),
            tit=np.array(tit, dtype=np.float16).reshape(len(keep), -1) if keep else np.zeros((0, 1), np.float16),
            cam=np.array(cam, dtype=np.float16).reshape(len(keep), -1) if keep else np.zeros((0, 1), np.float16),
            db=np.array(dbs, dtype=np.float32),
        )
        info = {
            "id": vid,
            "shard": meta.get("shard"),
            "length": duration,
            "speech_s": round(sum(e - s for s, e in regions), 1),
            "windows": len(keep),
            "asr_words": has_words,
            "has_turn_markers": ">>" in (meta.get("transcript") or ""),
            "bandwidth_hz": meta.get("estimated_bandwidth_hz"),
            "distinct_channels": meta.get("n_distinct_channels"),
            "regions": regions,
            "words": words,
        }
        with open(out_dir / "regions" / f"{vid}.json", "w") as f:
            json.dump(info, f)
        return {"id": vid, "ok": True, "windows": len(keep), "length": duration}
    except Exception as exc:  # one bad file must not stop the shard
        return {"id": vid, "ok": False, "error": repr(exc)[:300]}


def iter_jobs(lang: str, shard: str, out_dir: Path, min_length: float):
    import pyarrow.parquet as pq

    meta_rows = pq.read_table(ROOT / "raw" / lang / "metadata" / f"{shard}.parquet").to_pylist()
    meta = {r["id"]: r for r in meta_rows}
    done = {p.stem for p in (out_dir / "regions").glob("*.json")}
    with tarfile.open(ROOT / "raw" / lang / "audio" / f"{shard}.tar", "r|") as tf:
        for m in tf:
            if not m.name.endswith(".webm"):
                continue
            vid = m.name[:-5]
            row = meta.get(vid)
            if row is None or not row.get("transcript") or (row.get("length") or 0) < min_length or vid in done:
                continue
            yield (vid, tf.extractfile(m).read(), row, str(out_dir))


def cmd_embed(args: argparse.Namespace) -> None:
    out_dir = ROOT / "bank" / args.lang
    for sub in ("audio16k", "windows", "regions"):
        (out_dir / sub).mkdir(parents=True, exist_ok=True)
    shards = args.shards or sorted(p.stem for p in (ROOT / "raw" / args.lang / "audio").glob("*.tar"))
    ctx = mp.get_context("spawn")
    t0 = time.time()
    n_ok = n_fail = 0
    audio_s = 0.0
    with ctx.Pool(args.workers, initializer=_init_worker) as pool:
        for shard in shards:
            jobs = iter_jobs(args.lang, shard, out_dir, args.min_length)
            for r in pool.imap_unordered(embed_one, jobs, chunksize=1):
                if r["ok"]:
                    n_ok += 1
                    audio_s += r["length"]
                else:
                    n_fail += 1
                    print(f"[embed] FAIL {r['id']}: {r['error']}", file=sys.stderr)
                if (n_ok + n_fail) % 25 == 0:
                    el = time.time() - t0
                    print(f"[embed] {shard} {n_ok} ok / {n_fail} failed, {audio_s/3600:.1f} h audio, {el/60:.1f} min", flush=True)
    print(f"[embed] done: {n_ok} videos ({audio_s/3600:.1f} h), {n_fail} failed, {(time.time()-t0)/60:.1f} min")


# ---------------------------------------------------------------- select pass

def load_windows(out_dir: Path) -> dict[str, dict]:
    """Window embeddings per video, mean-centred per model and re-normalised.

    Raw embeddings share a large common direction (strangers score ~0.7 raw on
    some exports); subtracting the corpus mean removes it.
    """
    data = {}
    for p in sorted((out_dir / "windows").glob("*.npz")):
        z = np.load(p)
        if len(z["starts"]) == 0:
            continue
        data[p.stem] = {k: z[k].astype(np.float32) for k in ("starts", "tit", "cam", "db")}
    for key in ("tit", "cam"):
        if not data:
            break
        mu = np.concatenate([d[key] for d in data.values()]).mean(axis=0)
        for d in data.values():
            e = d[key] - mu
            d[key] = e / (np.linalg.norm(e, axis=1, keepdims=True) + 1e-9)
        np.save(out_dir / f"mean_{key}.npy", mu)
    return data


def calibrate(data: dict[str, dict], key: str, rng: np.random.Generator) -> dict:
    """Same-voice threshold from cross-video impostor pairs.

    Two random windows from two different videos are almost always two different
    people, so the high tail of that distribution tells us how similar strangers
    get. The threshold is the 99.5th percentile of impostor window pairs.
    """
    ids = list(data)
    imp = []
    for _ in range(40000):
        a, b = rng.choice(len(ids), 2, replace=False)
        ea = data[ids[a]][key]
        eb = data[ids[b]][key]
        imp.append(float(ea[rng.integers(len(ea))] @ eb[rng.integers(len(eb))]))
    gen = []
    for vid in ids:
        e = data[vid][key]
        if len(e) < 4:
            continue
        for _ in range(8):
            i, j = rng.choice(len(e), 2, replace=False)
            gen.append(float(e[i] @ e[j]))
    imp = np.array(imp)
    gen = np.array(gen)
    return {
        "impostor_p50": float(np.percentile(imp, 50)),
        "impostor_p99": float(np.percentile(imp, 99)),
        "impostor_p995": float(np.percentile(imp, 99.5)),
        "within_video_p10": float(np.percentile(gen, 10)),
        "within_video_p50": float(np.percentile(gen, 50)),
        "threshold": float(np.percentile(imp, 99.5)),
    }


def main_voice(emb: np.ndarray, threshold: float) -> tuple[np.ndarray, np.ndarray]:
    """Boolean mask of windows in the main voice, plus its unit centroid.

    Seed with the window that has the most neighbours above threshold, take the
    centroid of that neighbourhood, refine twice, and keep windows whose
    similarity to the centroid clears the threshold.
    """
    sims = emb @ emb.T
    seed = int(np.argmax((sims >= threshold).sum(axis=1)))
    mask = sims[seed] >= threshold
    for _ in range(2):
        c = emb[mask].mean(axis=0)
        c /= np.linalg.norm(c) + 1e-9
        mask = emb @ c >= threshold
    c = emb[mask].mean(axis=0) if mask.any() else emb.mean(axis=0)
    c /= np.linalg.norm(c) + 1e-9
    return mask, c


def cmd_select(args: argparse.Namespace) -> None:
    out_dir = ROOT / "bank" / args.lang
    rng = np.random.default_rng(7)
    data = load_windows(out_dir)
    print(f"[select] {len(data)} videos with windows")
    calib = {k: calibrate(data, k, rng) for k in ("tit", "cam")}
    for k, c in calib.items():
        print(f"[select] {k}: " + ", ".join(f"{a}={b:.3f}" for a, b in c.items()))
    # Same-voice bars come from the models' equal-error points on clean single-voice
    # videos (TitaNet 0.43, CAM++ 0.47; 0.9% EER each), not from the corpus-wide
    # stranger tail above: music and noise windows look alike across videos and
    # push that tail far above where real voices separate.
    thr = {"tit": args.tit_threshold, "cam": args.cam_threshold}
    print(f"[select] same-voice bars: {thr}")

    identities, multi = [], []
    cents = {"tit": [], "cam": []}
    rejected = {"too_few_windows": 0, "main_share": 0, "turn_markers": 0}
    for vid, d in data.items():
        info = json.load(open(out_dir / "regions" / f"{vid}.json"))
        if info.get("has_turn_markers"):
            multi.append({"id": vid, "length": info["length"], "speech_s": info["speech_s"]})
            rejected["turn_markers"] += 1
            continue
        if len(d["starts"]) < args.min_windows:
            rejected["too_few_windows"] += 1
            continue
        mt, ct = main_voice(d["tit"], thr["tit"])
        mc, cc = main_voice(d["cam"], thr["cam"])
        agree = mt & mc
        share = float(agree.mean())
        if share < args.min_main_share:
            rejected["main_share"] += 1
            continue
        starts = d["starts"][agree]
        clean_windows = [[round(float(s), 2), round(float(s) + WINDOW_S, 2)] for s in sorted(starts)]
        # Windows either model put outside the main voice. The simulator keeps
        # 1.5 s clear of each one, so a turn never carries a second voice.
        bad_windows = sorted(round(float(s), 2) for s in d["starts"][~agree])
        identities.append({
            "identity": f"yd3-{vid[:12]}",
            "video": vid,
            "shard": info["shard"],
            "length_s": round(info["length"], 1),
            "speech_s": info["speech_s"],
            "clean_s": round(len(clean_windows) * WINDOW_S, 1),
            "main_share": round(share, 3),
            "windows": len(d["starts"]),
            "asr_words": info["asr_words"],
            "bandwidth_hz": info["bandwidth_hz"],
            "distinct_channels": info["distinct_channels"],
            "clean_windows": clean_windows,
            "bad_windows": bad_windows,
            "sampled_all_windows": len(d["starts"]) < MAX_WINDOWS,
        })
        cents["tit"].append(ct)
        cents["cam"].append(cc)

    # Sort identities by clean minutes (most first) and keep centroid rows aligned.
    order = np.argsort([-r["clean_s"] for r in identities], kind="stable")
    identities = [identities[i] for i in order]
    ct = np.array(cents["tit"], dtype=np.float32)[order] if identities else np.zeros((0, 192), np.float32)
    cc = np.array(cents["cam"], dtype=np.float32)[order] if identities else np.zeros((0, 512), np.float32)
    # Sound-alike matrix: mean of both labeler models' centroid cosine. The
    # simulator casts high-similarity pairs on purpose as hard negatives.
    soundalike = ((ct @ ct.T) + (cc @ cc.T)) / 2.0
    np.savez_compressed(out_dir / "centroids.npz", ids=np.array([r["identity"] for r in identities]),
                        tit=ct, cam=cc, soundalike=soundalike.astype(np.float32))
    if len(identities) > 1:
        off = soundalike[~np.eye(len(identities), dtype=bool)]
        print(f"[select] sound-alike (cross-identity) p50 {np.median(off):.3f}, p99 {np.percentile(off, 99):.3f}, "
              f"max {off.max():.3f}")
    # Two videos can be the same uploader. A pair that clears the window-level
    # same-voice bar under BOTH models might be one person: the simulator must
    # never cast such a pair as two different people. These pairs are also the
    # seed for cross-video identity linking (plan, phase 3).
    tt, tc = thr["tit"], thr["cam"]
    maybe_same = []
    for i in range(len(identities)):
        for j in range(i + 1, len(identities)):
            if ct[i] @ ct[j] >= tt and cc[i] @ cc[j] >= tc:
                maybe_same.append([identities[i]["identity"], identities[j]["identity"],
                                   round(float(ct[i] @ ct[j]), 3), round(float(cc[i] @ cc[j]), 3)])
    with open(out_dir / "maybe_same_person.json", "w") as f:
        json.dump(maybe_same, f, indent=0)
    print(f"[select] {len(maybe_same)} identity pairs might be the same person (never co-cast)")

    with open(out_dir / "identities.jsonl", "w") as f:
        for r in identities:
            f.write(json.dumps(r) + "\n")
    with open(out_dir / "multispeaker.jsonl", "w") as f:
        for r in multi:
            f.write(json.dumps(r) + "\n")
    json.dump({"calibration": calib, "thresholds": thr, "rejected": rejected, "kept": len(identities),
               "min_main_share": args.min_main_share}, open(out_dir / "select_report.json", "w"), indent=1)
    print(f"[select] kept {len(identities)} identities; rejected {rejected}; {len(multi)} multi-speaker videos")
    mins = np.array([r["clean_s"] for r in identities]) / 60
    if len(mins):
        print(f"[select] clean minutes per identity: median {np.median(mins):.1f}, "
              f">=10 min: {(mins >= 10).sum()}, >=20 min: {(mins >= 20).sum()}")


# ---------------------------------------------------------------- verify pass

def _verify_one(job: tuple) -> dict:
    """Embed every 3 s window of one voice's usable speech; flag windows off its centroid."""
    import soundfile as sf

    ident, video, spans, ct, cc, mu_t, mu_c, thr_t, thr_c = job
    bad, n = [], 0
    with sf.SoundFile(str(ROOT / "bank" / "en" / "audio16k" / f"{video}.flac")) as f:
        for s, e in spans:
            t = s
            while t + WINDOW_S <= e:
                f.seek(int(t * SR))
                seg = f.read(int(WINDOW_S * SR), dtype="float32")
                t += WINDOW_S
                if len(seg) < WINDOW_S * SR * 0.9 or 20 * np.log10(np.sqrt(np.mean(seg * seg)) + 1e-9) < MIN_WINDOW_DB:
                    continue
                sims = []
                for key, mu, c in (("tit", mu_t, ct), ("cam", mu_c, cc)):
                    st = _EXTRACTORS[key].create_stream()
                    st.accept_waveform(SR, seg)
                    st.input_finished()
                    v = np.asarray(_EXTRACTORS[key].compute(st), dtype=np.float32) - mu
                    sims.append(float((v / (np.linalg.norm(v) + 1e-9)) @ c))
                n += 1
                if sims[0] < thr_t or sims[1] < thr_c:
                    bad.append(round(t - WINDOW_S, 2))
    return {"identity": ident, "checked": n, "bad": bad}


def cmd_verify(args: argparse.Namespace) -> None:
    """Dense check for long voices: the select pass samples at most 240 windows per
    video, so a second voice can hide between samples in a long video. Long voices
    are exactly the ones the simulator leans on (1:1 calls, the recurring cast)."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from meeting_sim import joined, subtract  # same span logic the simulator uses

    out_dir = ROOT / "bank" / args.lang
    rows = [json.loads(line) for line in open(out_dir / "identities.jsonl")]
    z = np.load(out_dir / "centroids.npz")
    index = {i: k for k, i in enumerate(z["ids"])}
    mu_t, mu_c = np.load(out_dir / "mean_tit.npy"), np.load(out_dir / "mean_cam.npy")
    thr = json.load(open(out_dir / "select_report.json"))["thresholds"]
    jobs = []
    for r in rows:
        if r.get("dense_verified"):
            continue
        info = json.load(open(out_dir / "regions" / f"{r['video']}.json"))
        holes = [(b - 1.5, b + WINDOW_S + 1.5) for b in r["bad_windows"]]
        spans = [sp for sp in subtract(joined(info["regions"], 0.6), holes) if sp[1] - sp[0] >= 1.0]
        if sum(e - s for s, e in spans) / 60 < args.min_minutes:
            continue
        k = index[r["identity"]]
        jobs.append((r["identity"], r["video"], spans, z["tit"][k], z["cam"][k], mu_t, mu_c, thr["tit"], thr["cam"]))
    print(f"[verify] {len(jobs)} voices with >= {args.min_minutes} usable minutes")
    by_id = {r["identity"]: r for r in rows}
    ctx = mp.get_context("spawn")
    with ctx.Pool(args.workers, initializer=_init_worker) as pool:
        for res in pool.imap_unordered(_verify_one, jobs):
            r = by_id[res["identity"]]
            share = len(res["bad"]) / max(1, res["checked"])
            r["bad_windows"] = sorted(set(r["bad_windows"]) | set(res["bad"]))
            r["dense_verified"] = True
            r["dense_bad_share"] = round(share, 4)
            # Too much off-voice speech means the video likely has a second regular voice.
            r["unreliable"] = share > args.max_bad_share
            print(f"[verify] {res['identity']}: {res['checked']} windows, {share:.1%} off-voice"
                  + ("  -> UNRELIABLE" if r["unreliable"] else ""), flush=True)
    with open(out_dir / "identities.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


# ---------------------------------------------------------------- music pass

def cmd_music(args: argparse.Namespace) -> None:
    """Real music for noisy-call stress tests: caption spans marked `[Music]` (at least
    --min-seconds long, not overlapping any speech caption) in videos already decoded to
    audio16k. Writes bank/<lang>/music.jsonl rows {video, start, end}."""
    import pyarrow.parquet as pq

    out_dir = ROOT / "bank" / args.lang
    have = {p.stem for p in (out_dir / "audio16k").glob("*.flac")}
    rows = []
    for meta in sorted((ROOT / "raw" / args.lang / "metadata").glob("*.parquet")):
        for r in pq.read_table(meta, columns=["id", "transcript"]).to_pylist():
            if r["id"] not in have or not r["transcript"]:
                continue
            segs = json.loads(r["transcript"])
            speech = [(x["start"] / 1000, (x["start"] + x.get("duration", 0)) / 1000) for x in segs
                      if (x.get("text") or "").strip() and not CUE.match(x["text"].strip())]
            for x in segs:
                if (x.get("text") or "").strip().lower() not in ("[music]", "[música]", "(music)"):
                    continue
                a, b = x["start"] / 1000, (x["start"] + x.get("duration", 0)) / 1000
                if b - a < args.min_seconds:
                    continue
                if any(sa < b and sb > a for sa, sb in speech):
                    continue
                rows.append({"video": r["id"], "start": round(a, 2), "end": round(b, 2)})
    with open(out_dir / "music.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    total = sum(r["end"] - r["start"] for r in rows)
    print(f"[music] {len(rows)} clips, {total / 60:.1f} min, from {len({r['video'] for r in rows})} videos")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("embed")
    e.add_argument("--lang", default="en")
    e.add_argument("--shards", nargs="*")
    e.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 4))
    e.add_argument("--min-length", type=float, default=45.0, help="skip videos shorter than this (s)")
    s = sub.add_parser("select")
    s.add_argument("--lang", default="en")
    s.add_argument("--min-windows", type=int, default=12, help="at least 36 s of windowed speech")
    s.add_argument("--min-main-share", type=float, default=0.9)
    s.add_argument("--tit-threshold", type=float, default=0.43)
    s.add_argument("--cam-threshold", type=float, default=0.47)
    v = sub.add_parser("verify")
    v.add_argument("--lang", default="en")
    v.add_argument("--min-minutes", type=float, default=10.0)
    v.add_argument("--max-bad-share", type=float, default=0.10)
    v.add_argument("--workers", type=int, default=max(2, (os.cpu_count() or 4) - 4))
    mu = sub.add_parser("music")
    mu.add_argument("--lang", default="en")
    mu.add_argument("--min-seconds", type=float, default=6.0)
    args = ap.parse_args()
    {"embed": cmd_embed, "select": cmd_select, "verify": cmd_verify, "music": cmd_music}[args.cmd](args)


if __name__ == "__main__":
    main()
