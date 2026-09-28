#!/usr/bin/env python3
"""Build the `yodas` voiceprint set and the shared `_noise` set from the YODAS3 voice bank.

SECONDARY SET. The speaker labels here were made by two models agreeing (NVIDIA
TitaNet-large and 3D-Speaker CAM++ common_advanced, see scripts/speaker_lab/voicebank.py),
not by humans. That biases the set toward those two models. Every row carries
"label_source": "model". Never use it as the deciding set for a model ranking.

Inputs (all under data/eval/yodas3/bank/en, read only):
  identities.jsonl                one row per single-voice video (session = video)
  regions/<video>.json            speech regions from captions
  audio16k/<video>.flac           the audio
  cross_recording_identities.json groups of videos judged the same person, plus likely_synthetic
  maybe_same_person.json          pairs that might be the same person
  music.jsonl                     caption-marked [Music] spans

Outputs (under VP = data/eval/voiceprint, or $VP_ROOT):
  clips/yodas/clean/<seg_id>.wav  16 kHz mono PCM16
  sets/yodas/segments.jsonl, README.md, READY (last)
  sets/_noise/music/*.wav, sets/_noise/babble/*.wav, index.json, README.md, READY (last)

Speakers: each usable cross-video group is one speaker (session = video), its clips are the
targets. Single-video identities that are not in any group and are not in an unresolved
maybe-same pair are strangers ("stranger_only": true). Synthetic voices are excluded, and so is
every group that contains one. Every clip is re-checked here against its own video's voice
centroid with both labeler models, so a second voice hiding between the sampled windows is caught.

Run: data/eval/voiceprint/venv/bin/python scripts/voiceprint/sets/build_yodas.py [--stage all|yodas|noise]
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import multiprocessing as mp
import os
import re
import shutil
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "2")

import numpy as np
import soundfile as sf

REPO = Path(__file__).resolve().parents[3]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
YODAS = Path(os.environ.get("YODAS_ROOT", REPO / "data" / "eval" / "yodas3"))
BANK = YODAS / "bank" / "en"
MODELS = YODAS / "models"
SILERO = Path(os.environ.get(
    "SILERO_VAD_ONNX", "/Users/redbars/stt-shootout/models/onnx-asr/istupakov--silero-vad-onnx/silero_vad.onnx"))

SET = "yodas"
SR = 16000
BUCKETS = (8, 4, 2)  # longest first: long clean stretches are the scarce resource
PER_BUCKET = 3
CAP = 3000
MIN_DBFS = -45.0
CLIP_FRAC = 0.01  # reject a clip when over 1% of its samples sit at full scale (hard distortion)
EDGE_SKIP_S = 10.0  # intros and outros often carry music or bumper voices
GUARD_S = 0.15  # stay inside the caption stretch
BAD_MARGIN_S = 1.5  # keep clear of windows either labeler put outside the main voice
CLIP_GAP_S = 0.5  # clips of one session never touch
WINDOW_S = 3.0

# Same-voice bars the bank was built with (TitaNet 0.43, CAM++ 0.47 at 3 s windows). Clips are
# checked against the video's own centroid: the whole clip at those bars for 4 s and 8 s, a bit
# looser for a 2 s clip (2 s embeddings run lower), plus every 2 s sub-window at a loose bar
# that still sits far above where strangers land (about 0.2 / 0.3).
WHOLE_BAR = {2: (0.38, 0.40), 4: (0.43, 0.47), 8: (0.43, 0.47)}
SUB_BAR = (0.33, 0.36)

MODEL_FILES = {
    "tit": "nemo_en_titanet_large.onnx",
    "cam": "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx",
}
SAFE = re.compile(r"[^A-Za-z0-9_.:-]")

# Strangers dropped as probable unlabeled twins of another speaker in the set: two independent
# models (WeSpeaker ResNet34-LM and SpeechBrain ECAPA) both score the session close to a
# differently-labeled one (mean session cosine >= 0.42), so it is probably the same person the two
# labeler models missed. Derived by scripts/voiceprint/sets/check_yodas.py (see dupe_check.json).
DROP_STRANGERS = [
    "yd3-09332e7451ba", "yd3-36707816100e", "yd3-368ccb2fcb42", "yd3-4147cdf1160b", "yd3-5fd5c2270d03",
    "yd3-6582ad3ef33c", "yd3-78de3688ff34", "yd3-bb30cb36ae5a", "yd3-e2d860332e4c", "yd3-fe4fd8b44225",
]


def safe(s: str) -> str:
    return SAFE.sub("_", s)


def log(msg: str) -> None:
    print(f"[yodas {time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------- bank loading

def load_bank() -> dict:
    rows = [json.loads(line) for line in open(BANK / "identities.jsonl")]
    by_id = {r["identity"]: r for r in rows}
    cross = json.load(open(BANK / "cross_recording_identities.json"))
    maybe = json.load(open(BANK / "maybe_same_person.json"))
    z = np.load(BANK / "centroids.npz")
    cent_index = {i: n for n, i in enumerate(z["ids"])}
    partner: dict[str, set[str]] = collections.defaultdict(set)
    for a, b, _, _ in maybe:
        partner[a].add(b)
        partner[b].add(a)
    return {
        "rows": rows, "by_id": by_id, "groups": cross["groups"], "synthetic": set(cross["likely_synthetic"]),
        "partner": partner, "cent": {k: z[k] for k in ("tit", "cam")}, "cent_index": cent_index,
        "mean": {k: np.load(BANK / f"mean_{k}.npy") for k in ("tit", "cam")},
    }


def plan_speakers(bank: dict, n_strangers: int, seed: int) -> dict:
    """Decide which identities are targets, strangers, and left over (babble candidates)."""
    by_id, syn, partner = bank["by_id"], bank["synthetic"], bank["partner"]
    unreliable = {i for i, r in by_id.items() if r.get("unreliable")}
    group_of = {m: gi for gi, g in enumerate(bank["groups"]) for m in g["members"]}

    excluded_groups: dict[int, str] = {}
    for gi, g in enumerate(bank["groups"]):
        members = g["members"]
        if any(m in syn for m in members):
            excluded_groups[gi] = "contains a likely_synthetic voice (a TTS voice reused across videos)"
        elif any(p in syn for m in members for p in partner[m] if group_of.get(p) != gi):
            excluded_groups[gi] = "voice is a near match of likely_synthetic voices and the videos are wall-to-wall speech"
        elif any(m in unreliable for m in members):
            excluded_groups[gi] = "a member was flagged unreliable by the dense check"
    target_groups = [gi for gi in range(len(bank["groups"])) if gi not in excluded_groups]

    # Unresolved maybe-same: listed in a pair, but not part of a group that resolved it.
    unresolved = {i for i in partner if i not in group_of}
    dropped_twins = set(DROP_STRANGERS)
    stranger_pool = [i for i in by_id if i not in syn and i not in unreliable and i not in group_of
                     and i not in unresolved and i not in dropped_twins]
    rng = np.random.default_rng(seed)
    if len(stranger_pool) > n_strangers:
        stranger_pool = sorted(rng.choice(stranger_pool, n_strangers, replace=False).tolist())
    used = {m for gi in target_groups for m in bank["groups"][gi]["members"]} | set(stranger_pool)
    # Babble voices: never a voice used above, never a possible twin of one, never synthetic.
    twins = {p for u in used for p in partner[u]}
    bad_groups = set(excluded_groups)
    babble_pool = [i for i in by_id
                   if i not in used and i not in twins and i not in syn and i not in unreliable and i not in dropped_twins
                   and group_of.get(i) not in bad_groups]
    return {
        "target_groups": target_groups, "excluded_groups": excluded_groups, "stranger_pool": stranger_pool,
        "unresolved": unresolved, "used": used, "babble_pool": babble_pool, "unreliable": unreliable,
    }


# ---------------------------------------------------------------- stretches

def joined(regions: list[list[float]], gap: float = 0.6) -> list[list[float]]:
    out: list[list[float]] = []
    for s, e in sorted(regions):
        if out and s - out[-1][1] < gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def subtract(spans: list[list[float]], holes: list[tuple[float, float]]) -> list[list[float]]:
    for hs, he in sorted(holes):
        nxt = []
        for s, e in spans:
            if he <= s or hs >= e:
                nxt.append([s, e])
                continue
            if hs > s:
                nxt.append([s, hs])
            if he < e:
                nxt.append([he, e])
        spans = nxt
    return spans


def stretches_for(info: dict, row: dict) -> list[list[float]]:
    """Continuous speech stretches of one video that stay clear of off-voice windows and the edges."""
    dur = info["length"]
    spans = joined(info["regions"])
    holes = [(b - BAD_MARGIN_S, b + WINDOW_S + BAD_MARGIN_S) for b in row["bad_windows"]]
    spans = subtract(spans, holes)
    out = []
    for s, e in spans:
        s, e = max(s + GUARD_S, EDGE_SKIP_S), min(e - GUARD_S, dur - EDGE_SKIP_S)
        if e - s >= 2.0:
            out.append([s, e])
    return out


# ---------------------------------------------------------------- worker

_EX = None


def _init_worker(threads: int) -> None:
    global _EX
    import sherpa_onnx

    _EX = {}
    for key, fname in MODEL_FILES.items():
        cfg = sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(MODELS / fname), num_threads=threads, provider="cpu")
        _EX[key] = sherpa_onnx.SpeakerEmbeddingExtractor(cfg)


def embed(key: str, seg: np.ndarray, mu: np.ndarray) -> np.ndarray:
    s = _EX[key].create_stream()
    s.accept_waveform(SR, seg)
    s.input_finished()
    v = np.asarray(_EX[key].compute(s), dtype=np.float32) - mu
    return v / (np.linalg.norm(v) + 1e-9)


def dbfs(seg: np.ndarray) -> float:
    return float(20 * np.log10(np.sqrt(np.mean(seg.astype(np.float64) ** 2)) + 1e-9))


def check_clip(seg: np.ndarray, bucket: int, cent: dict, mean: dict) -> str | None:
    """None when the clip is the video's main voice all the way through, else why not."""
    if dbfs(seg) < MIN_DBFS:
        return "quiet"
    if np.mean(np.abs(seg) >= 0.9995) > CLIP_FRAC:
        return "clipped"
    whole = WHOLE_BAR[bucket]
    for k, key in enumerate(("tit", "cam")):
        if float(embed(key, seg, mean[key]) @ cent[key]) < whole[k]:
            return f"whole_{key}"
    if bucket > 2:
        n2 = int(2 * SR)
        for off in range(0, len(seg) - n2 + 1, SR):
            sub = seg[off:off + n2]
            for k, key in enumerate(("tit", "cam")):
                if float(embed(key, sub, mean[key]) @ cent[key]) < SUB_BAR[k]:
                    return f"sub_{key}"
    return None


def draw(strata_lo: float, strata_hi: float, cands: list[tuple[float, float]], cum: np.ndarray, rng) -> float:
    """A clip start drawn from candidate intervals, by position in the pooled candidate mass."""
    u = rng.uniform(strata_lo, strata_hi)
    i = int(np.searchsorted(cum, u, side="right"))
    i = min(i, len(cands) - 1)
    lo, hi = cands[i]
    prev = cum[i - 1] if i > 0 else 0.0
    frac = (u - prev) / max(cum[i] - prev, 1e-9)
    return lo + min(max(frac, 0.0), 1.0) * (hi - lo)


def cut_session(job: dict) -> dict:
    """Pick, verify and write up to PER_BUCKET clips per bucket for one session."""
    out_dir = Path(job["out_dir"])
    rng = np.random.default_rng(job["seed"])
    stretches = job["stretches"]
    cent, mean = job["cent"], job["mean"]
    chosen: list[tuple[float, float]] = []  # (start, end) of every clip taken so far
    rows, why = [], collections.Counter()
    counter = 0
    try:
        f = sf.SoundFile(str(BANK / "audio16k" / f"{job['video']}.flac"))
    except Exception as exc:  # unreadable audio: no clips, reported by the caller
        return {"job": job["session"], "rows": [], "why": {"open_failed": 1}, "error": repr(exc)[:200]}
    with f:
        for bucket in BUCKETS:
            cands = [(s, e - bucket) for s, e in stretches if e - s >= bucket]
            if not cands:
                continue
            widths = np.array([max(hi - lo, 0.05) for lo, hi in cands])
            cum = np.cumsum(widths)
            total = float(cum[-1])
            k = job["per_bucket"]
            taken = 0
            for slot in range(k):
                lo_f, hi_f = slot / k * total, (slot + 1) / k * total
                for attempt in range(14):
                    if attempt < 6:
                        start = draw(lo_f, hi_f, cands, cum, rng)
                    else:
                        start = draw(0.0, total, cands, cum, rng)  # this stratum is used up: anywhere
                    a = round(start * SR) / SR
                    b = a + bucket
                    if any(a < ce + CLIP_GAP_S and b > cs - CLIP_GAP_S for cs, ce in chosen):
                        why["overlap"] += 1
                        continue
                    f.seek(int(round(a * SR)))
                    seg = f.read(bucket * SR, dtype="float32")
                    if len(seg) != bucket * SR:
                        why["short_read"] += 1
                        continue
                    seg = np.clip(seg, -1.0, 1.0)
                    bad = check_clip(seg, bucket, cent, mean)
                    if bad:
                        why[bad] += 1
                        continue
                    seg_id = f"{SET}:{job['speaker_local']}:{job['session_local']}:{counter}"
                    seg_id = safe(seg_id)
                    rel = f"clips/{SET}/clean/{seg_id}.wav"
                    sf.write(str(out_dir / f"{seg_id}.wav"), seg, SR, subtype="PCM_16")
                    rows.append({
                        "seg_id": seg_id, "set": SET, "speaker": job["speaker"], "session": job["session"],
                        "bucket": bucket, "dur": float(bucket), "clip": rel,
                        "src": {"file": job["src_file"], "start": round(a, 3), "end": round(b, 3)},
                        "label_source": "model", "stranger_only": job["stranger_only"],
                        "identity": job["identity"], "rank": taken,
                    })
                    counter += 1
                    taken += 1
                    chosen.append((a, b))
                    break
    return {"job": job["session"], "rows": rows, "why": dict(why)}


# ---------------------------------------------------------------- yodas stage

def stage_yodas(args: argparse.Namespace) -> dict:
    bank = load_bank()
    plan = plan_speakers(bank, args.strangers, args.seed)
    by_id = bank["by_id"]
    out_dir = VP / "clips" / SET / "clean"
    set_dir = VP / "sets" / SET
    for d in (out_dir, set_dir):
        assert str(d.resolve()).startswith(str((VP).resolve()) + os.sep), d
    (set_dir).mkdir(parents=True, exist_ok=True)
    (set_dir / "READY").unlink(missing_ok=True)
    (VP / "clips" / SET / "READY").unlink(missing_ok=True)
    if out_dir.exists():
        shutil.rmtree(out_dir)  # only ever this set's own folder, checked above
    out_dir.mkdir(parents=True)

    sessions_seen: set[str] = set()
    jobs = []

    def add_job(speaker_local: str, ident: str, stranger_only: bool) -> None:
        row = by_id[ident]
        info = json.load(open(BANK / "regions" / f"{row['video']}.json"))
        session_local = ident  # yd3-<first 12 hex of the video id>
        assert session_local not in sessions_seen, session_local
        sessions_seen.add(session_local)
        k = bank["cent_index"][ident]
        seed = int(hashlib.sha1(f"{args.seed}:{row['video']}".encode()).hexdigest()[:8], 16)
        jobs.append({
            "speaker_local": speaker_local, "speaker": f"{SET}:{speaker_local}",
            "session_local": session_local, "session": f"{SET}:{session_local}",
            "identity": ident, "video": row["video"], "stranger_only": stranger_only,
            "src_file": f"data/eval/yodas3/bank/en/audio16k/{row['video']}.flac",
            "stretches": stretches_for(info, row), "seed": seed, "per_bucket": PER_BUCKET,
            "cent": {key: bank["cent"][key][k] for key in ("tit", "cam")}, "mean": bank["mean"],
            "out_dir": str(out_dir),
        })

    group_names = {}
    for n, gi in enumerate(plan["target_groups"]):
        name = f"xv{n:02d}"
        group_names[gi] = name
        for ident in bank["groups"][gi]["members"]:
            add_job(name, ident, False)
    for ident in plan["stranger_pool"]:
        add_job(ident, ident, True)
    log(f"{len(jobs)} sessions to cut: {len(plan['target_groups'])} cross-video groups, "
        f"{len(plan['stranger_pool'])} strangers; excluded groups: {plan['excluded_groups']}")

    t0 = time.time()
    results = []
    ctx = mp.get_context("spawn")
    with ctx.Pool(args.workers, initializer=_init_worker, initargs=(args.threads,)) as pool:
        for i, r in enumerate(pool.imap_unordered(cut_session, jobs, chunksize=1), 1):
            results.append(r)
            if i % 25 == 0 or i == len(jobs):
                log(f"{i}/{len(jobs)} sessions, {sum(len(x['rows']) for x in results)} clips, {(time.time() - t0) / 60:.1f} min")

    rows = [row for r in results for row in r["rows"]]
    why = collections.Counter()
    for r in results:
        why.update(r["why"])
    failed = [r["job"] for r in results if r.get("error")]

    # A target needs at least two sessions with clips; otherwise it can only be a stranger.
    sess_by_speaker: dict[str, set[str]] = collections.defaultdict(set)
    for row in rows:
        sess_by_speaker[row["speaker"]].add(row["session"])
    demoted = []
    for row in rows:
        if not row["stranger_only"] and len(sess_by_speaker[row["speaker"]]) < 2:
            row["stranger_only"] = True
            demoted.append(row["speaker"])

    # Trim to the cap, dropping the highest-ranked stranger clips first (targets keep theirs).
    trimmed = 0
    if len(rows) > CAP:
        order = sorted(range(len(rows)), key=lambda i: (rows[i]["stranger_only"] is False, -rows[i]["rank"], rows[i]["seg_id"]))
        drop = set(order[: len(rows) - CAP])
        for i in drop:
            (out_dir / f"{rows[i]['seg_id']}.wav").unlink(missing_ok=True)
        rows = [r for i, r in enumerate(rows) if i not in drop]
        trimmed = len(drop)
    rows.sort(key=lambda r: (r["speaker"], r["session"], -r["bucket"], r["rank"]))
    for r in rows:
        r.pop("rank")

    with open(set_dir / "segments.jsonl", "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")

    files = {p.stem for p in out_dir.glob("*.wav")}
    assert files == {r["seg_id"] for r in rows}, "clip files and rows disagree"
    assert len({r["seg_id"] for r in rows}) == len(rows)

    stats = summarize(rows, plan, bank, group_names, why, failed, sorted(set(demoted)), trimmed, time.time() - t0)
    write_readme(set_dir / "README.md", stats)
    (out_dir / "READY").write_text(time.strftime("%Y-%m-%dT%H:%M:%S") + "\n")  # clips/<set>/clean/READY
    (set_dir / "READY").write_text(time.strftime("%Y-%m-%dT%H:%M:%S") + "\n")  # last
    log(f"yodas READY: {json.dumps({k: stats[k] for k in ('clips', 'targets', 'strangers', 'per_bucket')})}")
    return stats


def summarize(rows, plan, bank, group_names, why, failed, demoted, trimmed, seconds) -> dict:
    target_rows = [r for r in rows if not r["stranger_only"]]
    stranger_rows = [r for r in rows if r["stranger_only"]]
    target_speakers = sorted({r["speaker"] for r in target_rows})
    sessions_per_target = {s: len({r["session"] for r in target_rows if r["speaker"] == s}) for s in target_speakers}
    return {
        "clips": len(rows),
        "targets": len(target_speakers),
        "target_sessions": sum(sessions_per_target.values()),
        "target_clips": len(target_rows),
        "sessions_per_target": sessions_per_target,
        "strangers": len({r["speaker"] for r in stranger_rows}),
        "stranger_clips": len(stranger_rows),
        "per_bucket": {str(b): sum(1 for r in rows if r["bucket"] == b) for b in (2, 4, 8)},
        "reject_reasons": dict(why),
        "unreadable_sessions": failed,
        "demoted_to_stranger": demoted,
        "trimmed_for_cap": trimmed,
        "excluded_groups": {str(k): v for k, v in plan["excluded_groups"].items()},
        "excluded_synthetic": len(bank["synthetic"]),
        "excluded_unresolved_maybe_same": len(plan["unresolved"]),
        "excluded_unreliable": len(plan["unreliable"]),
        "dropped_twins": len(DROP_STRANGERS),
        "group_names": {str(k): v for k, v in group_names.items()},
        "stranger_pool": len(plan["stranger_pool"]),
        "babble_pool": len(plan["babble_pool"]),
        "build_seconds": round(seconds),
    }


README = """# yodas: YouTube in-the-wild speech (SECONDARY set, model-made labels)

> **Read this first.** Speaker labels in this set were made by two models agreeing (NVIDIA
> TitaNet-large and 3D-Speaker CAM++ common_advanced), not by people. That biases the set toward
> those two models: same-person groups are the ones both models cluster together, and any pair
> of videos both models scored as "maybe the same person" that no group resolved was dropped, so the
> hardest strangers for those two models are missing. Scores on this set flatter TitaNet and CAM++
> and are not a fair ranking of models. Every row has `"label_source": "model"`. Use it as a
> secondary check on in-the-wild audio, never as the deciding set.

## Source and license

YODAS3 English shards (YouTube videos with a Creative Commons CC BY 3.0 license), via the
existing voice bank at `data/eval/yodas3/bank/en` (see `scripts/speaker_lab/voicebank.py`). Local
evaluation only: never commit or upload these clips. Attribution belongs to the video uploaders.

## What is in it

* **Sessions are videos.** A speaker's session id is the bank identity of the video (`yd3-` plus the
  first 12 hex of the video id). `src.file` is the decoded 16 kHz FLAC of the video in the bank
  (`data/eval/yodas3/bank/en/audio16k`); start and end are seconds in the video, the same
  timeline as the original download.
* **Targets:** {targets} cross-video speakers (`yodas:xvNN`), {target_sessions} sessions,
  {target_clips} clips. Each is a group from `cross_recording_identities.json`, counting only sessions
  that produced clips. Sessions per speaker: {sessions_per_target}.
* **Strangers:** {strangers} single-video speakers (`yodas:yd3-...`), {stranger_clips} clips,
  all `"stranger_only": true`. The pool was every bank identity that is not synthetic, not
  unreliable, not in a group, not in any unresolved maybe-same pair, and not one of the
  {dropped_twins} probable twins dropped below ({stranger_pool} identities). The plan asked for about
  300 strangers; the bank has no more that pass every exclusion.
* **Clips:** {clips} total, buckets 2 s / 4 s / 8 s = {per_bucket}. Up to 3 per (speaker,
  session, bucket), from different places (stratified over the session, never touching another clip
  of the session), 16 kHz mono PCM16, RMS at least -45 dBFS.

## How the clips were cut

1. Continuous speech stretches come from the bank's caption regions (merged across pauses under
   0.6 s), minus 1.5 s around every window either labeler put outside the video's main voice,
   minus the first and last 10 s of the video (intros and outros carry music and bumper voices).
2. A clip is one continuous stretch, cut to exactly its bucket length.
3. Every clip is re-checked against its own video's voice centroid with both labeler models: the
   whole clip at the bank's same-voice bars (TitaNet 0.43, CAM++ 0.47; a little lower for 2 s
   clips), and every 2 s window inside it at a loose bar. Rejected or overlapping draws are
   redrawn. Draw outcomes: {reject_reasons}. Heavily clipped sources (over 1% of samples at
   full scale) were skipped, which is why a few sessions have fewer than nine clips.
4. Exclusions: {excluded_synthetic} identities marked likely synthetic/TTS, plus every group that
   contains one or is a near match of them ({excluded_groups}); {excluded_unreliable}
   identities the dense check flagged unreliable; {excluded_unresolved_maybe_same} identities that appear in
   `maybe_same_person.json` without a group resolving them.
5. {dropped_twins} strangers dropped as probable unlabeled twins (see the independent check below).
{extra}
<!-- indep-check:start -->
Independent check not run yet: run `scripts/voiceprint/sets/check_yodas.py`.
<!-- indep-check:end -->

## Caveats

* Single-voice means "one main voice by two models", not "no other person anywhere". A short
  interjection of another voice under about 1 s could pass the checks.
* YODAS3 IDs are encrypted, so the same uploader cannot be linked from metadata. Cross-video groups
  are mostly one uploader across several videos: same mic, room, and production chain.
  That makes cross-session trials easier than meeting-to-meeting recognition in the app.
* Audio is YouTube-compressed (Opus/AAC), decoded to 16 kHz. Some sessions carry background music.
* A target group is one person only by the two labeler models' opinion. If a group was merged
  wrongly, a good model will look like it rejects true matches: check the group (`xvNN`) before
  blaming a model for a cluster of misses.

Built by `scripts/voiceprint/sets/build_yodas.py` in {build_seconds} s. Deterministic (seeded per video).
Also builds `sets/_noise/` (music and babble for the degradation agent).
"""


def write_readme(path: Path, stats: dict) -> None:
    extra = ""
    if stats["demoted_to_stranger"]:
        extra += f"6. Groups with fewer than two sessions of clips were demoted to strangers: {stats['demoted_to_stranger']}.\n"
    if stats["trimmed_for_cap"]:
        extra += f"7. Trimmed {stats['trimmed_for_cap']} stranger clips to stay under the {CAP} cap.\n"
    if stats["unreadable_sessions"]:
        extra += f"8. Unreadable sessions: {stats['unreadable_sessions']}.\n"
    stats = dict(stats)
    stats["sessions_per_target"] = ", ".join(f"{k.split(':')[1]} {v}" for k, v in stats["sessions_per_target"].items())
    stats["per_bucket"] = ", ".join(f"{k} s: {v}" for k, v in stats["per_bucket"].items())
    stats["reject_reasons"] = ", ".join(f"{k} {v}" for k, v in sorted(stats["reject_reasons"].items(), key=lambda kv: -kv[1]))
    stats["excluded_groups"] = "; ".join(f"group {k}: {v}" for k, v in stats["excluded_groups"].items())
    text = README.format(extra=extra, **{k: stats[k] for k in (
        "targets", "target_sessions", "target_clips", "sessions_per_target", "strangers", "stranger_clips",
        "stranger_pool", "clips", "per_bucket", "reject_reasons", "excluded_synthetic", "excluded_groups",
        "excluded_unreliable", "excluded_unresolved_maybe_same", "build_seconds", "dropped_twins")})
    path.write_text(text)


# ---------------------------------------------------------------- noise stage

class Vad:
    """Silero VAD v5 (ONNX), 16 kHz, 512-sample frames."""

    def __init__(self, path: Path):
        import onnxruntime as ort

        so = ort.SessionOptions()
        so.intra_op_num_threads = 1
        self.sess = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])

    def probs(self, wav: np.ndarray) -> np.ndarray:
        state = np.zeros((2, 1, 128), dtype=np.float32)
        ctx = np.zeros((1, 64), dtype=np.float32)
        sr = np.array(SR, dtype=np.int64)
        out = []
        for i in range(0, len(wav) - 511, 512):
            x = np.concatenate([ctx, wav[i:i + 512][None].astype(np.float32)], axis=1)
            p, state = self.sess.run(None, {"input": x, "state": state, "sr": sr})
            ctx = x[:, -64:]
            out.append(float(p[0, 0]))
        return np.array(out)


def rms_scale(x: np.ndarray, target_dbfs: float) -> np.ndarray:
    return x * (10 ** (target_dbfs / 20) / (np.sqrt(np.mean(x.astype(np.float64) ** 2)) + 1e-9))


def write_wav(path: Path, wav: np.ndarray) -> None:
    sf.write(str(path), np.clip(wav, -1.0, 1.0).astype(np.float32), SR, subtype="PCM_16")


def stage_noise(args: argparse.Namespace) -> dict:
    bank = load_bank()
    plan = plan_speakers(bank, args.strangers, args.seed)
    noise = VP / "sets" / "_noise"
    assert str(noise.resolve()).startswith(str(VP.resolve()) + os.sep), noise
    noise.mkdir(parents=True, exist_ok=True)
    (noise / "READY").unlink(missing_ok=True)
    for sub in ("music", "babble"):
        if (noise / sub).exists():
            shutil.rmtree(noise / sub)
        (noise / sub).mkdir()
    rng = np.random.default_rng(args.seed + 1)
    used_videos = {bank["by_id"][i]["video"] for i in plan["used"]}
    # Prefer music from videos that never went through the yodas set, including the dropped twins.
    avoid_videos = used_videos | {bank["by_id"][i]["video"] for i in DROP_STRANGERS}
    dur = 10.0
    n_music, n_babble = args.music, args.babble

    # ---- music: caption-marked [Music] spans, no speech caption inside, then a VAD check.
    vad = Vad(SILERO) if SILERO.exists() else None
    if vad is None:
        log(f"WARNING: silero VAD not found at {SILERO}; music clips are checked by captions and level only")
    spans = [json.loads(line) for line in open(BANK / "music.jsonl")]
    spans = [s for s in spans if s["end"] - s["start"] >= dur + 1.0 and (BANK / "audio16k" / f"{s['video']}.flac").exists()]
    by_video: dict[str, list[dict]] = collections.defaultdict(list)
    for s in spans:
        by_video[s["video"]].append(s)
    # Prefer videos that are not in the yodas set, then everything else. One clip per video first.
    order_pref = sorted(by_video, key=lambda v: (v in avoid_videos, hashlib.sha1(f"{args.seed}{v}".encode()).hexdigest()))
    music_index, taken_by_video = [], collections.Counter()
    rejects = collections.Counter()
    for rnd in range(3):
        for vid in order_pref:
            if len(music_index) >= n_music:
                break
            if taken_by_video[vid] > rnd:
                continue
            cand = by_video[vid]
            for _ in range(4):
                s = cand[int(rng.integers(len(cand)))]
                a = float(rng.uniform(s["start"] + 0.5, s["end"] - 0.5 - dur))
                a = round(a * SR) / SR
                with sf.SoundFile(str(BANK / "audio16k" / f"{vid}.flac")) as f:
                    f.seek(int(round(a * SR)))
                    seg = f.read(int(dur * SR), dtype="float32")
                if len(seg) != int(dur * SR):
                    rejects["short"] += 1
                    continue
                db = dbfs(seg)
                if db < -40.0:
                    rejects["quiet"] += 1
                    continue
                if np.mean(np.abs(seg) >= 0.9995) > CLIP_FRAC:
                    rejects["clipped"] += 1
                    continue
                if vad is not None:
                    p = vad.probs(seg)
                    if float(np.mean(p > 0.5)) > 0.05 or float(p.max()) > 0.9:
                        rejects["speech_like"] += 1
                        continue
                cid = f"music{len(music_index):03d}"
                write_wav(noise / "music" / f"{cid}.wav", seg)
                music_index.append({
                    "id": cid, "path": f"sets/_noise/music/{cid}.wav", "dur": dur, "rms_dbfs": round(db, 1),
                    "src": {"file": f"data/eval/yodas3/bank/en/audio16k/{vid}.flac", "start": round(a, 3), "end": round(a + dur, 3)},
                    "video_in_yodas_set": vid in used_videos,
                })
                taken_by_video[vid] += 1
                break
    log(f"music: {len(music_index)} clips, {len({m['src']['file'] for m in music_index})} videos, rejects {dict(rejects)}")

    # ---- babble: 4 to 6 overlapping voices that are not in the yodas set.
    pool = [i for i in plan["babble_pool"] if len(bank["by_id"][i]["clean_windows"]) >= 4]
    partner = bank["partner"]
    use_count = collections.Counter()
    babble_index = []
    for n in range(n_babble):
        n_voices = 4 + n % 3
        voices: list[str] = []
        order = sorted(pool, key=lambda i: (use_count[i], rng.random()))
        for cand in order:
            if any(cand in partner[v] or v in partner[cand] for v in voices):
                continue
            voices.append(cand)
            if len(voices) == n_voices:
                break
        tracks = []
        for ident in voices:
            row = bank["by_id"][ident]
            wins = row["clean_windows"]
            picks = rng.choice(len(wins), size=min(5, len(wins)), replace=False)
            pieces = []
            with sf.SoundFile(str(BANK / "audio16k" / f"{row['video']}.flac")) as f:
                for pi in picks:
                    a = wins[int(pi)][0]
                    f.seek(int(round(a * SR)))
                    w = f.read(int(WINDOW_S * SR), dtype="float32")
                    if len(w) < int(WINDOW_S * SR):
                        continue
                    fade = int(0.01 * SR)
                    w = w.copy()
                    w[:fade] *= np.linspace(0, 1, fade)
                    w[-fade:] *= np.linspace(1, 0, fade)
                    pieces.append(w)
            track = np.concatenate(pieces) if pieces else np.zeros(0, np.float32)
            if len(track) < int(dur * SR):
                continue  # too little audio for this voice
            off = int(rng.integers(0, len(track) - int(dur * SR) + 1))
            track = track[off:off + int(dur * SR)]
            tracks.append(rms_scale(track, -26.0 + float(rng.uniform(-3, 3))))
            use_count[ident] += 1
        if len(tracks) < 4:
            log(f"babble {n}: only {len(tracks)} voices, skipped")
            continue
        mix = np.sum(tracks, axis=0)
        mix = rms_scale(mix, -24.0)
        peak = float(np.max(np.abs(mix)))
        if peak > 0.9:
            mix *= 0.9 / peak
        cid = f"babble{len(babble_index):03d}"
        write_wav(noise / "babble" / f"{cid}.wav", mix)
        babble_index.append({
            "id": cid, "path": f"sets/_noise/babble/{cid}.wav", "dur": dur, "n_voices": len(tracks),
            "rms_dbfs": round(dbfs(mix), 1), "voices": voices[:len(tracks)],
        })
    voices_used = sorted({v for b in babble_index for v in b["voices"]})
    assert not (set(voices_used) & plan["used"]), "babble voice also used in the yodas set"
    log(f"babble: {len(babble_index)} clips from {len(voices_used)} voices (pool {len(pool)})")

    index = {
        "sr": SR, "dur": dur, "made": time.strftime("%Y-%m-%d"),
        "note": ("Noise sources for scripts/voiceprint/degrade.py. All audio comes from the YODAS3 bank "
                 "(CC BY 3.0 YouTube). Music: caption-marked [Music] spans, VAD-checked to hold no speech. "
                 "Babble: 4 to 6 overlapping single-voice bank identities that are not in the yodas set and "
                 "not possible twins of one. Each file is 10 s, 16 kHz mono PCM16, RMS around -24 dBFS."),
        "music": music_index, "babble": babble_index,
    }
    (noise / "index.json").write_text(json.dumps(index, indent=1) + "\n")
    (noise / "README.md").write_text(
        "# _noise: music and babble sources for the degradation agent\n\n"
        f"* `music/`: {len(music_index)} clips, 10 s, 16 kHz mono PCM16. Real music from YODAS3 videos "
        "(caption-marked [Music], checked with Silero VAD to hold no speech).\n"
        f"* `babble/`: {len(babble_index)} clips, 10 s, 4 to 6 overlapping voices each, built from "
        f"{len(voices_used)} bank identities that are NOT in the `yodas` set (and are not possible twins of "
        "a voice in it). Voices are listed per clip in `index.json`.\n"
        "* Source: YODAS3 (YouTube, CC BY 3.0), local evaluation only. Never from an eval set.\n"
        "* `index.json` lists every clip: id, path relative to VP, dur, rms_dbfs, source.\n"
        "* Built by `scripts/voiceprint/sets/build_yodas.py --stage noise`.\n")
    (noise / "READY").write_text(time.strftime("%Y-%m-%dT%H:%M:%S") + "\n")  # last
    return {"music": len(music_index), "babble": len(babble_index), "babble_voices": len(voices_used),
            "babble_pool": len(pool), "music_videos": len({m["src"]["file"] for m in music_index}),
            "music_reject": dict(rejects)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stage", choices=("all", "yodas", "noise"), default="all")
    ap.add_argument("--strangers", type=int, default=300, help="most single-video strangers to include")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--threads", type=int, default=2, help="threads per worker process")
    ap.add_argument("--music", type=int, default=60)
    ap.add_argument("--babble", type=int, default=60)
    ap.add_argument("--seed", type=int, default=17)
    args = ap.parse_args()
    out = {}
    if args.stage in ("all", "yodas"):
        out["yodas"] = stage_yodas(args)
    if args.stage in ("all", "noise"):
        out["noise"] = stage_noise(args)
    (VP / "logs").mkdir(parents=True, exist_ok=True)
    (VP / "logs" / "build_yodas_summary.json").write_text(json.dumps(out, indent=1) + "\n")
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
