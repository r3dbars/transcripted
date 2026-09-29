#!/usr/bin/env python3
"""Build the `icsi` voiceprint set from the ICSI Meeting Corpus (interaction = headset mix audio).

ICSI is the most product-like public data for "the same people meet again": 75 real research-group
meetings recorded 2000-2002 at Berkeley (groups Bmr, Bro, Bed, Bns, Bdb, Bsr, Btr, Buw), where
the same 60 people recur week after week (one person attends 49 of the 75). speaker = ICSI global
participant id (me013, fe008, ...), session = ICSI meeting id (Bmr001).

Speaker identity. The NXT segment annotations (ICSI_core_NXT.zip, Segments/<meeting>.<channel>.segs.xml)
carry a `participant` attribute per segment, and those ids are global across meetings. This script
checks them against the original MRT preambles (each meeting's Participants list, ICSI_original_transcripts)
and speakers.xml: every participant in a segment file must be listed in that meeting's preamble, each
channel file must belong to exactly one participant, and the id must exist in speakers.xml. A failure
stops the build. A cheap audio/annotation alignment check (energy of the mix vs. annotated speech, at
lags of +-3 s, first and last third of each meeting) drops a meeting whose annotation timeline does not
line up with the mix.

Clips are cut from single-speaker stretches: no other annotated segment (words or vocal sounds such as
laughs) is active inside the clip or within 0.3 s of it, the speaker's own word segments cover most of
it, RMS >= -45 dBFS. Buckets 2/4/8 s, up to 3 clips per (speaker, session, bucket) from different
places, no audio shared between clips of the same (speaker, session). At most ~3,000 clips; over that,
the busiest speakers lose their last clips first so more speakers survive. Speakers left with one
session are `stranger_only`.

License: ICSI signals and annotations are CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/),
released via the University of Edinburgh (https://groups.inf.ed.ac.uk/ami/icsi/). Local eval only.

Deterministic (fixed seed, sorted inputs) and re-runnable. Writes only VP/clips/icsi/clean/,
VP/sets/icsi/ and VP/logs/icsi_build.log. Reads VP/raw/icsi.

Usage:
    VP/venv/bin/python scripts/voiceprint/sets/build_icsi.py [--cap 3000] [--dry-run] [--qc-only]
                                                             [--verify] [--meetings Bmr001 ...]
"""
from __future__ import annotations

import argparse
import bisect
import collections
import json
import random
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import soundfile as sf

SET = "icsi"
SEED = "icsi-v1"
SR = 16000
BUCKETS = (2, 4, 8)
MAX_PER_SESSION_BUCKET = 3
MIN_RMS_DBFS = -45.0
GUARD = 0.3            # seconds clear of every other annotated segment
JOIN_GAP = 0.5         # pauses up to this long inside one speaker's talk still count as one stretch
MIN_COVER = 0.80       # share of the clip that must be the speaker's own word segments
MIN_ACTIVE_FRAC = 0.5  # frames within 35 dB of the clip's loudest frame
USED_PAD = 0.5         # audio of two clips from one (speaker, session) never touches closer than this
GRID = 0.25            # candidate start step inside a stretch
CAP_DEFAULT = 3000
MAX_LAG_OK = 0.25      # seconds: annotation vs mix alignment tolerance

REPO = Path(__file__).resolve().parents[3]
VP = REPO / "data" / "eval" / "voiceprint"
RAW = VP / "raw" / "icsi"
AUDIO = RAW / "audio"
NXT = RAW / "annot" / "nxt" / "ICSI"
MRT = RAW / "annot" / "mrt" / "transcripts"
SET_DIR = VP / "sets" / SET
CLIP_DIR = VP / "clips" / SET / "clean"
LOG = VP / "logs" / "icsi_build.log"
NS = "{http://nite.sourceforge.net/}"

GROUP_NAMES = {
    "Bmr": "Meeting Recorder", "Bed": "Even Deeper Understanding", "Bro": "Robustness",
    "Bns": "Network Services", "Bdb": "Database", "Bsr": "Speech Recognition (Sr)",
    "Btr": "Transcription", "Buw": "UW visitors",
}


def safe(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.:-]", "_", s)


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------- intervals
def merge(iv, gap: float = 0.0):
    out = []
    for s, e in sorted(iv):
        if out and s <= out[-1][1] + gap:
            if e > out[-1][1]:
                out[-1][1] = e
        else:
            out.append([s, e])
    return [(s, e) for s, e in out]


def subtract(a, b):
    """a, b: merged sorted interval lists. Parts of a not covered by b."""
    out = []
    j = 0
    for s, e in a:
        cur = s
        while j < len(b) and b[j][1] <= cur:
            j += 1
        k = j
        while k < len(b) and b[k][0] < e:
            if b[k][0] > cur:
                out.append((cur, b[k][0]))
            cur = max(cur, b[k][1])
            k += 1
        if cur < e:
            out.append((cur, e))
    return out


def overlap_len(iv, starts, s, e) -> float:
    """Length of [s,e] covered by merged sorted iv (starts = [i[0] for i in iv])."""
    i = max(0, bisect.bisect_right(starts, s) - 1)
    tot = 0.0
    while i < len(iv) and iv[i][0] < e:
        lo, hi = max(iv[i][0], s), min(iv[i][1], e)
        if hi > lo:
            tot += hi - lo
        i += 1
    return tot


# ---------------------------------------------------------------- ICSI metadata
def load_speakers():
    """speakers.xml -> {tag: gender letter}"""
    root = ET.parse(NXT / "speakers.xml").getroot()
    return {s.get("tag"): ("F" if s.get("gender") == "Female" else "M") for s in root.iter("speaker")}


def load_preambles():
    """original MRT preambles -> {meeting: {"date": iso, "participants": {name: channel}}}"""
    txt = (MRT / "preambles.mrt").read_text(encoding="latin-1")
    out = {}
    for m in re.finditer(r'<Meeting Session="(\w+)" DateTimeStamp="([\d-]+)"(.*?)</Meeting>', txt, flags=re.S):
        mid, stamp, body = m.group(1), m.group(2), m.group(3)
        y, mo, d, hm = stamp.split("-")
        # miked participants have a Channel; an unmiked one (heard faintly, e.g. the person who set up
        # the recording) has none. Unmiked speakers still count as "someone else talking" but are never
        # used as clip speakers.
        parts = {n: (c or None) for n, c in re.findall(r'<Participant Name="(\w+)"(?: Channel="(\w+)")?', body)}
        out[mid] = {"date": f"{y}-{mo}-{d}T{hm[:2]}:{hm[2:]}", "participants": parts}
    return out


def load_segments(mid: str):
    """[(start, end, participant, channel_letter, has_word, has_vocal)] for one meeting."""
    rows = []
    for f in sorted(NXT.glob(f"Segments/{mid}.*.segs.xml")):
        ch = f.name.split(".")[1]
        root = ET.parse(f).getroot()
        for seg in root.iter("segment"):
            s, e = seg.get("starttime"), seg.get("endtime")
            if not s or not e:
                continue
            s, e = float(s), float(e)
            if e <= s:
                continue
            hrefs = " ".join(c.get("href", "") for c in seg.iter(NS + "child"))
            rows.append((s, e, seg.get("participant"), ch, ".w." in hrefs, ".vocalsound." in hrefs))
    return rows


def audio_complete(path: Path) -> bool:
    try:
        info = sf.info(str(path))
    except Exception:
        return False
    if info.samplerate != SR or info.channels != 1:
        return False
    return path.stat().st_size >= info.frames * 2 + 44


# ---------------------------------------------------------------- audio helpers
def frame_db(x: np.ndarray, frame: int = 400, hop: int = 160) -> np.ndarray:
    if len(x) < frame:
        x = np.pad(x, (0, frame - len(x)))
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    ms = np.mean(x[idx].astype(np.float64) ** 2, axis=1)
    return 10 * np.log10(np.maximum(ms, 1e-12))


def clip_ok(x: np.ndarray) -> bool:
    rms = float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))
    if 20 * np.log10(max(rms, 1e-9)) < MIN_RMS_DBFS:
        return False
    fdb = frame_db(x)
    return float(np.mean(fdb > fdb.max() - 35.0)) >= MIN_ACTIVE_FRAC


# ---------------------------------------------------------------- alignment QC
def best_lag(env: np.ndarray, ind: np.ndarray, hop: float, max_lag: float = 3.0):
    """Lag (s) at which mix energy best matches the annotated-speech indicator. Positive: the mix
    lags the annotation, i.e. speech appears in the audio later than the labels say."""
    def z(v):
        v = v - v.mean()
        s = v.std()
        return v / s if s > 0 else v
    n = min(len(env), len(ind))
    env, ind = z(env[:n]), z(ind[:n])
    L = int(round(max_lag / hop))
    best = (-9, 0)
    for k in range(-L, L + 1):
        if k >= 0:
            c = float(np.mean(env[k:] * ind[:n - k]))
        else:
            c = float(np.mean(env[:n + k] * ind[-k:]))
        if c > best[0]:
            best = (c, k)
    return best[1] * hop, best[0]


def alignment_qc(audio: np.ndarray, segs) -> dict:
    hop = 0.1
    step = int(SR * hop)
    n = len(audio) // step
    env = 10 * np.log10(np.maximum(np.mean(audio[:n * step].astype(np.float64).reshape(n, step) ** 2, axis=1), 1e-12))
    ind = np.zeros(n)
    for s, e, _p, _c, has_w, _v in segs:
        if has_w:
            ind[int(s / hop):min(n, int(np.ceil(e / hop)))] = 1.0
    out = {}
    thirds = {"all": (0, n), "first": (0, n // 3), "last": (2 * n // 3, n)}
    for k, (a, b) in thirds.items():
        lag, c = best_lag(env[a:b], ind[a:b], hop)
        out[k] = {"lag": round(lag, 2), "corr": round(c, 3)}
    return out


# ---------------------------------------------------------------- selection
def free_stretches(own_raw, others):
    """Where the speaker talks and nobody else does (0.3 s guard). own_raw: merged raw intervals."""
    own = merge(own_raw, gap=JOIN_GAP)
    others_pad = merge([(s - GUARD, e + GUARD) for s, e in others])
    return subtract(own, others_pad)


def gap_between(a, b) -> float:
    return max(0.0, max(a[0], b[0]) - min(a[1], b[1]))


def pick_windows(free, cover_iv, cover_starts, audio, rng):
    """Pick up to MAX_PER_SESSION_BUCKET windows per bucket. Returns {bucket: [start,...]}.

    Longest bucket first, since long single-speaker stretches are the scarce resource. Windows of one
    (speaker, session) never share audio, across buckets too.
    """
    used = []   # merged, padded
    result = {}
    dur = len(audio) / SR
    for bucket in sorted(BUCKETS, reverse=True):
        picks = []
        bad = set()
        for _ in range(MAX_PER_SESSION_BUCKET):
            remaining = subtract(free, used)
            cands = [s for s in remaining if s[1] - s[0] >= bucket and s not in bad]
            if not cands:
                break
            if not picks:
                order = [cands[rng.randrange(len(cands))]]
                order += [c for c in cands if c != order[0]]
            else:
                pk = [(p, p + bucket) for p in picks]
                jitter = {c: rng.random() for c in cands}
                order = sorted(cands, key=lambda c: (-min(gap_between(c, q) for q in pk), jitter[c]))
            chosen = None
            for st in order:
                lo, hi = st
                n = int((hi - lo - bucket) / GRID) + 1
                starts = [lo + i * GRID for i in range(max(n, 1))]
                starts = [s for s in starts if s + bucket <= hi + 1e-9 and s >= 0 and s + bucket <= dur]
                rng.shuffle(starts)
                tries = 0
                for t in starts:
                    if overlap_len(cover_iv, cover_starts, t, t + bucket) / bucket < MIN_COVER:
                        continue
                    a = int(round(t * SR))
                    x = audio[a:a + bucket * SR]
                    if len(x) != bucket * SR:
                        continue
                    tries += 1
                    if clip_ok(x):
                        chosen = t
                        break
                    if tries >= 12:
                        break
                if chosen is not None:
                    break
                bad.add(st)
            if chosen is None:
                break
            picks.append(round(chosen, 3))
            used = merge(used + [(chosen - USED_PAD, chosen + bucket + USED_PAD)])
        result[bucket] = sorted(picks)
    return result


# ---------------------------------------------------------------- identity checks
def check_identity(mids, speakers, preambles):
    problems = []
    for mid in mids:
        if mid not in preambles:
            problems.append(f"{mid}: no preamble in ICSI_original_transcripts")
            continue
        listed = preambles[mid]["participants"]
        chan_owner = collections.defaultdict(set)
        for s, e, p, ch, hw, hv in load_segments(mid):
            chan_owner[ch].add(p)
        for ch, ps in chan_owner.items():
            if len(ps) != 1:
                problems.append(f"{mid}: channel file {ch} has more than one participant {sorted(ps)}")
            for p in ps:
                if p not in listed:
                    problems.append(f"{mid}: {p} is not in the meeting's preamble participants {sorted(listed)}")
                if p not in speakers:
                    problems.append(f"{mid}: {p} is missing from speakers.xml")
    return problems


# ---------------------------------------------------------------- README
def write_readme(path: Path, info: dict) -> None:
    b = info["per_bucket"]
    lines = [
        "# icsi: ICSI Meeting Corpus, the same people meeting week after week",
        "",
        "Real research-group meetings recorded at Berkeley in 2000-2002. The same people recur across many meetings "
        "over months, so this is the most product-like public stand-in for Transcripted's returning-speaker case.",
        "",
        "- Source: ICSI Meeting Corpus, headset mix (`<meeting>.interaction.wav`, 16 kHz mono PCM16, sum of all participants' "
        "close-talk headset mics), https://groups.inf.ed.ac.uk/ami/icsi/",
        "- Labels: ICSI NXT core annotations v1.0 (`ICSI_core_NXT.zip`): per-channel `Segments/*.segs.xml` with a global "
        "`participant` id and start/end times, word-level `Words/`. Original MRT transcripts (`ICSI_original_transcripts.zip`) "
        "are used for meeting dates and to cross-check who was in each meeting.",
        "- License: ICSI signals and annotations are CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/), released via "
        "the University of Edinburgh. Original recording by the ICSI Meeting Recorder Project (Janin et al., ICASSP 2003). "
        "Used here for local evaluation only; nothing is redistributed, committed, or uploaded.",
        "",
        "## Global speaker ids",
        "",
        "`speaker` is `icsi:<participant>` (me013, fe008, mn007, ...), `session` is `icsi:<meeting>` (icsi:Bmr001). "
        "ICSI participant ids are global across all 75 meetings and across groups (one person attends up to 49 meetings and "
        "meetings of four different groups). The build checks the ids rather than trusting them:",
        "",
        "- each segment file (one per headset channel) has exactly one participant;",
        "- that participant is listed in the meeting's MRT preamble and exists in speakers.xml;",
        f"- alignment check: for each meeting the energy of the mix is correlated against the annotated speech at lags of +-3 s "
        f"(whole meeting, first third, last third); meetings whose best lag is over {MAX_LAG_OK} s are dropped ({info['qc_line']});",
        f"- {info['verify_line']}",
        "",
        "## What is in it",
        "",
        f"- {info['speakers']} speakers, {info['sessions']} sessions (meetings) from {info['groups']} groups, "
        f"{info['multi']} speakers with clips in 2+ sessions, {info['five']} with clips in 5+ sessions, "
        f"{info['stranger_only']} stranger-only.",
        f"- {info['clips']} clean clips: 2 s = {b[2]}, 4 s = {b[4]}, 8 s = {b[8]}.",
        f"- Meetings per group: {info['groups_line']}.",
        f"- Sessions per speaker: {info['hist_line']}.",
        "",
        "## How clips were cut",
        "",
        "1. Per meeting, per speaker: take that speaker's own segments (words or vocal sounds), join pauses up to 0.5 s, then remove "
        "everything within 0.3 s of any other participant's segment (words or vocal sounds such as laughs; mic-noise-only "
        "segments are ignored). What is left are single-speaker stretches.",
        "2. Slide a window of exactly 2, 4, or 8 s along each stretch. The speaker's own word segments must cover at least 80% of "
        "the window, RMS must be at least -45 dBFS, and at least half the frames must be within 35 dB of the loudest frame.",
        "3. Up to 3 windows per (speaker, session, bucket), preferring stretches far from windows already picked. "
        "Longest bucket first. No two clips of one (speaker, session) share audio, across buckets too.",
        f"4. Cap {info['cap']}: over the cap, the speaker with the most clips gives up its last-ranked clip first, "
        "so more speakers survive and busy speakers keep many sessions. Speakers left with clips in one session are marked "
        "`\"stranger_only\": true`.",
        "",
        "Deterministic (seed `%s`): `VP/venv/bin/python scripts/voiceprint/sets/build_icsi.py`." % SEED,
        "",
        "## Extra fields beyond the contract",
        "",
        "- `group`: `icsi:<series>` (`icsi:Bmr`), the ICSI group the meeting belongs to. Unlike a closed friend group, people cross "
        "groups (me013 and me011 appear in four or more), so use `date` for a chronological view of one person's meetings.",
        "- `date`: meeting start, `YYYY-MM-DDTHH:MM` (from the MRT preambles).",
        "- `session_order`: 0-based chronological rank of the meeting among all meetings in this set.",
        "- `gender`: `F` or `M` (speakers.xml).",
        "",
        "## Caveats",
        "",
        "- Audio is the headset mix, so every participant's mic is summed into it. A close-talk mic hears the room, so the mix "
        "has comb-filtering and room reverberation from the other headsets, and rooms/mics are 2000-era (16 kHz, noisy, some "
        "mics with hum). Harder than a clean one-mic-per-person recording, and closer to a laptop mic in a room.",
        "- Segment times come from dialogue-act annotation and forced alignment; they are not sample-exact, which is why the "
        "0.3 s guard exists. Unlabeled non-speech from other people (mic bumps, unmarked laughs) can still be in a few clips.",
        "- Speakers are researchers and students, native and non-native English speakers, mostly men (ICSI's population); female speakers "
        f"are {info['female_speakers']} of {info['speakers']}.",
        "- Bro008 is dropped: its annotation timeline has no coherent alignment with the mix (correlation near zero, lag "
        "jumping between 4 and 6 s across the meeting), so labels cannot be trusted there.",
        "- Unmiked participants (heard faintly, no headset channel; e.g. the person who set up the recording) count as "
        "\"someone else talking\" for the 0.3 s guard but are never a clip speaker.",
        "- Clips are 16 kHz mono PCM16 exactly as recorded; nothing is normalized.",
        "- Speakers with too little clean single-speaker speech get few clips or none (listeners who mostly back-channel).",
        "",
    ]
    path.write_text("\n".join(lines))


# ---------------------------------------------------------------- embedding verification
def verify_embeddings(rows, per_pair: int = 2):
    """Nearest-voiceprint check with the baseline model. Also reports each meeting's hit rate, which is
    what catches a meeting whose labels are shifted or swapped. Returns a dict of results."""
    sys.path.insert(0, str(REPO / "scripts" / "voiceprint" / "runtimes"))
    import importlib
    mdir = VP / "models" / "wespeaker-resnet34-lm"
    if not (mdir / "model.json").is_file():
        return {"skipped": "baseline model not found"}
    meta = json.loads((mdir / "model.json").read_text())
    rt = importlib.import_module(meta["runtime"])
    emb = rt.Embedder(mdir, meta, threads=3)
    by_pair = collections.defaultdict(list)
    for r in rows:
        by_pair[(r["speaker"], r["session"])].append(r)
    chosen = []
    for k in sorted(by_pair):
        chosen += sorted(by_pair[k], key=lambda r: (-r["bucket"], r["seg_id"]))[:per_pair]
    log(f"verify: embedding {len(chosen)} clips with {meta['model_id']}")
    E = []
    for r in chosen:
        x, sr = sf.read(str(VP / r["clip"]), dtype="float32")
        v = emb.embed(x)
        E.append(v / (np.linalg.norm(v) + 1e-9))
    E = np.array(E)
    spk = np.array([r["speaker"] for r in chosen])
    ses = np.array([r["session"] for r in chosen])
    out = {"model": meta["model_id"], "clips": len(chosen)}
    # a clip is a hit when its nearest OTHER-session voiceprint (mean per speaker) is its labeled speaker
    per_ses = collections.defaultdict(lambda: [0, 0])
    correct = total = 0
    wrong = []
    speakers = sorted(set(spk))
    for i in range(len(chosen)):
        cand = {}
        for s in speakers:
            m = (spk == s) & (ses != ses[i])
            if m.any():
                c = E[m].mean(0)
                cand[s] = float(E[i] @ (c / (np.linalg.norm(c) + 1e-9)))
        if spk[i] not in cand or len(cand) < 2:
            continue
        total += 1
        best = max(cand, key=cand.get)
        ok = best == spk[i]
        per_ses[ses[i]][0] += int(ok)
        per_ses[ses[i]][1] += 1
        if ok:
            correct += 1
        else:
            wrong.append({"clip": chosen[i]["seg_id"], "true": spk[i], "pred": best})
    out["queries"] = total
    out["top1_correct"] = correct
    out["top1_acc"] = round(correct / max(total, 1), 4)
    out["per_session"] = {k: {"hits": v[0], "queries": v[1], "acc": round(v[0] / max(v[1], 1), 3)}
                          for k, v in sorted(per_ses.items())}
    out["wrong"] = wrong[:60]
    log(f"verify: {correct}/{total} = {correct / max(total, 1):.3f} nearest other-session voiceprint (all {len(speakers)} speakers) is the labeled speaker")
    weak = {k: v for k, v in out["per_session"].items() if v["queries"] >= 4 and v["acc"] < 0.5}
    if weak:
        log(f"verify: sessions with hit rate < 0.5: {weak}")
    out["weak_sessions"] = weak
    return out


# ---------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cap", type=int, default=CAP_DEFAULT)
    ap.add_argument("--dry-run", action="store_true", help="select clips and print counts; write nothing")
    ap.add_argument("--qc-only", action="store_true", help="only run the identity + alignment checks")
    ap.add_argument("--verify", action="store_true", help="also run the embedding identity check (after writing)")
    ap.add_argument("--meetings", nargs="*", help="limit to these meetings (testing)")
    ap.add_argument("--scratch", action="store_true", help="write to VP/sets/_icsi_test and VP/clips/_icsi_test instead (testing)")
    ap.add_argument("--exclude", nargs="*", default=[], help="meetings to drop (e.g. after --verify flags one)")
    args = ap.parse_args()

    global SET_DIR, CLIP_DIR
    out_name = "_icsi_test" if args.scratch else SET
    SET_DIR = VP / "sets" / out_name
    CLIP_DIR = VP / "clips" / out_name / "clean"
    speakers = load_speakers()
    preambles = load_preambles()
    all_ids = [l.strip() for l in (RAW / "meetings.txt").read_text().split() if l.strip()]
    avail, skipped = [], []
    for mid in sorted(all_ids):
        if args.meetings and mid not in args.meetings:
            continue
        wav = AUDIO / f"{mid}.wav"
        if mid not in args.exclude and wav.is_file() and audio_complete(wav):
            avail.append(mid)
        else:
            skipped.append(mid)
    log(f"meetings: {len(avail)} usable, {len(skipped)} skipped {skipped}")

    problems = check_identity(avail, speakers, preambles)
    for p in problems:
        log(f"IDENTITY PROBLEM: {p}")
    if problems:
        return 3
    log("identity ok: every channel file has one participant listed in its preamble and in speakers.xml")

    # ---- alignment QC + pass 1: choose windows per meeting
    qc = {}
    dropped_qc = []
    selected = []   # dicts: speaker, meeting, bucket, start
    for mid in avail:
        segs = load_segments(mid)
        audio, sr = sf.read(str(AUDIO / f"{mid}.wav"), dtype="float32")
        assert sr == SR
        q = alignment_qc(audio, segs)
        qc[mid] = q
        good = all(abs(q[k]["lag"]) <= MAX_LAG_OK for k in q)
        log(f"{mid}: audio {len(audio) / SR / 60:.1f} min, {len(segs)} segments, alignment lag all={q['all']['lag']} "
            f"first={q['first']['lag']} last={q['last']['lag']} corr={q['all']['corr']} {'OK' if good else 'DROPPED'}")
        if not good:
            dropped_qc.append(mid)
            del audio
            continue
        if args.qc_only:
            del audio
            continue
        n0 = len(selected)
        by_all = collections.defaultdict(list)     # speaker -> [(s,e)] for any segment (words or vocal)
        by_words = collections.defaultdict(list)   # speaker -> [(s,e)] word segments only
        for s, e, p, ch, hw, hv in segs:
            if hw or hv:
                by_all[p].append((s, e))
            if hw:
                by_words[p].append((s, e))
        merged_all = {p: merge(v) for p, v in by_all.items()}
        merged_words = {p: merge(v) for p, v in by_words.items()}
        miked = {n for n, c in preambles[mid]["participants"].items() if c}
        for p in sorted(merged_all):
            if p not in miked:
                continue     # unmiked person: counted as overlap for others, never a clip speaker
            others = merge([iv for q_, v in merged_all.items() if q_ != p for iv in v])
            free = free_stretches(merged_all[p], others)
            cov = merged_words.get(p, [])
            cov_starts = [iv[0] for iv in cov]
            rng = random.Random(f"{SEED}|{p}|{mid}")
            picks = pick_windows(free, cov, cov_starts, audio, rng)
            for b, starts in picks.items():
                for t in starts:
                    selected.append({"speaker": p, "meeting": mid, "bucket": b, "start": t})
        log(f"{mid}: {len(selected) - n0} candidate clips from {len(merged_all)} speakers")
        del audio

    (VP / "logs" / "icsi_alignment_qc.json").write_text(json.dumps(qc, indent=1))
    if dropped_qc:
        log(f"alignment-dropped meetings: {dropped_qc}")
    if args.qc_only:
        return 0
    log(f"selected before cap: {len(selected)}")

    # ---- cap: busiest speaker gives up its last-ranked clip in its fullest (session, bucket) first
    def key(c):
        return (c["speaker"], c["meeting"], c["bucket"])
    trip = collections.defaultdict(list)
    for c in selected:
        trip[key(c)].append(c)
    per_spk = collections.Counter(c["speaker"] for c in selected)
    total = len(selected)
    dropped = 0
    while total > args.cap:
        spk = max(sorted(per_spk), key=lambda s: per_spk[s])
        ks = [k for k in trip if k[0] == spk and len(trip[k]) > 1]
        if not ks:
            ks = [k for k in trip if k[0] == spk and trip[k]]
            if not ks:
                break
        k = max(sorted(ks, key=lambda k: (k[1], k[2])), key=lambda k: (len(trip[k]), -k[2]))
        trip[k].pop()
        per_spk[spk] -= 1
        total -= 1
        dropped += 1
    kept = [c for k in sorted(trip) for c in sorted(trip[k], key=lambda c: c["start"])]
    log(f"cap {args.cap}: dropped {dropped}, kept {len(kept)}")

    # ---- speakers, stranger_only
    ses_of = collections.defaultdict(set)
    for c in kept:
        ses_of[c["speaker"]].add(c["meeting"])
    stranger = {s for s, v in ses_of.items() if len(v) < 2}
    per_bucket = collections.Counter(c["bucket"] for c in kept)
    kept_meetings = sorted({c["meeting"] for c in kept})
    multi = sum(1 for v in ses_of.values() if len(v) >= 2)
    five = sum(1 for v in ses_of.values() if len(v) >= 5)
    groups = collections.Counter(m[:3] for m in kept_meetings)
    log(f"clips={len(kept)} speakers={len(ses_of)} sessions={len(kept_meetings)} groups={dict(groups)} "
        f"speakers_with_2plus_sessions={multi} 5plus={five} stranger_only={len(stranger)} per_bucket={dict(sorted(per_bucket.items()))}")
    sess_hist = collections.Counter(len(v) for v in ses_of.values())
    log(f"sessions-per-speaker histogram: {dict(sorted(sess_hist.items()))}")
    if args.dry_run:
        return 0

    order = {m: i for i, (_d, m) in enumerate(sorted((preambles[m]["date"], m) for m in kept_meetings))}

    # ---- write clips, segments.jsonl, README, READY
    for d in (SET_DIR, CLIP_DIR):
        assert VP.resolve() in d.resolve().parents, d
    (SET_DIR / "READY").unlink(missing_ok=True)
    SET_DIR.mkdir(parents=True, exist_ok=True)
    CLIP_DIR.mkdir(parents=True, exist_ok=True)
    for f in CLIP_DIR.glob("*.wav"):        # only our own clip folder, only wavs
        f.unlink()

    rows_out = []
    counter = 0
    by_meeting = collections.defaultdict(list)
    for c in kept:
        by_meeting[c["meeting"]].append(c)
    for mid in sorted(by_meeting):
        audio, sr = sf.read(str(AUDIO / f"{mid}.wav"), dtype="float32")
        for c in sorted(by_meeting[mid], key=lambda c: (c["speaker"], c["bucket"], c["start"])):
            n = counter
            counter += 1
            spk, b, t = c["speaker"], c["bucket"], c["start"]
            seg_id = safe(f"{SET}:{spk}:{mid}:{n}")
            a = int(round(t * SR))
            x = audio[a:a + b * SR]
            assert len(x) == b * SR
            pcm = np.clip(np.round(x * 32768.0), -32768, 32767).astype("<i2")
            sf.write(str(CLIP_DIR / f"{seg_id}.wav"), pcm, SR, subtype="PCM_16", format="WAV")
            row = {
                "seg_id": seg_id, "set": SET, "speaker": f"{SET}:{safe(spk)}",
                "session": f"{SET}:{safe(mid)}", "bucket": b, "dur": b,
                "clip": f"clips/{out_name}/clean/{seg_id}.wav",
                "src": {"file": f"data/eval/voiceprint/raw/icsi/audio/{mid}.wav", "start": round(t, 3), "end": round(t + b, 3)},
                "gender": speakers[spk],
                "group": f"{SET}:{safe(mid[:3])}",
                "date": preambles[mid]["date"],
                "session_order": order[mid],
            }
            if spk in stranger:
                row["stranger_only"] = True
            rows_out.append(row)
        del audio
    rows_out.sort(key=lambda r: (r["speaker"], r["session"], r["bucket"], r["seg_id"]))
    tmp = SET_DIR / "segments.jsonl.tmp"
    with tmp.open("w") as f:
        for r in rows_out:
            f.write(json.dumps(r) + "\n")
    tmp.replace(SET_DIR / "segments.jsonl")

    info = {
        "speakers": len(ses_of), "sessions": len(kept_meetings), "groups": len(groups), "multi": multi, "five": five,
        "stranger_only": len(stranger), "clips": len(rows_out), "per_bucket": per_bucket, "cap": args.cap,
        "groups_line": ", ".join(f"{g} {n}" for g, n in sorted(groups.items())),
        "hist_line": ", ".join(f"{k}: {v}" for k, v in sorted(sess_hist.items())),
        "female_speakers": sum(1 for s in ses_of if speakers[s] == "F"),
        "qc_line": (f"{len(avail) - len(dropped_qc)} of {len(avail)} passed" +
                    (f"; dropped {', '.join(dropped_qc)}" if dropped_qc else "")),
        "verify_line": "an embedding check with the baseline model is available with `--verify`.",
    }
    verify = None
    if args.verify:
        verify = verify_embeddings(rows_out)
        (SET_DIR / "identity_check.json").write_text(json.dumps(verify, indent=1))
        if "top1_acc" in verify:
            info["verify_line"] = (
                f"embedding check with the baseline WeSpeaker ResNet34-LM: for {verify['queries']} clips, the nearest "
                f"other-session voiceprint among all {len(ses_of)} speakers was the labeled person "
                f"{verify['top1_acc'] * 100:.1f}% of the time; weak sessions (<50% hits): "
                f"{', '.join(verify['weak_sessions']) or 'none'}. Details in `identity_check.json`.")
    write_readme(SET_DIR / "README.md", info)

    ready = {"set": SET, "clips": len(rows_out), "speakers": len(ses_of), "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    (SET_DIR / "READY").write_text(json.dumps(ready) + "\n")
    log(f"wrote {len(rows_out)} clips, segments.jsonl, README.md, READY under {SET_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
