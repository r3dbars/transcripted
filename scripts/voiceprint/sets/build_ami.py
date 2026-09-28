#!/usr/bin/env python3
"""Build the `ami` voiceprint set from the AMI Meeting Corpus (Mix-Headset audio).

AMI is the closest public thing to the product: real meetings where the same four people meet again
in sessions a-d of one scenario series. speaker = AMI global participant id (FEE005, MIO016,
MTD009PM, ...), session = AMI meeting id (ES2002a). Group = scenario series (ES2002); the same four
people recur across its sessions, and nobody appears in two groups.

Speaker identity. AMI's official meetings.xml (ami_public_manual_1.6.2, corpusResources/) maps every
meeting's per-meeting agent (A-D) to a `global_name`. The pyannote `only_words` RTTMs already use
those global names as speaker labels. This script does not trust that: for every meeting it checks
that every RTTM label is one of the meeting's global names in meetings.xml (or maps a per-meeting
label through it), that each group has a stable set of people across a-d, that no person appears in
two groups, and that the gender letter of the id agrees with participants.xml (where it has the person). A failure stops the
build. With --verify it also embeds a few clips per (speaker, session) with the baseline
WeSpeaker model and checks that a clip is closest to its own speaker's other-session voiceprint
(catches a label swapped inside a meeting).

Clips are cut from single-speaker stretches: no other RTTM speaker is active inside the clip or
within 0.3 s of it, the speaker's own RTTM covers most of it, raw RMS >= -60 dBFS. AMI mixes are quiet
(speech -18..-52 dBFS), so by the coordinator's call this set gates at -60 dBFS instead of the contract's
-45 and rescales every clean clip to -26 dBFS RMS, recording the gain in src.gain_db. Buckets 2/4/8 s, up to
3 clips per (speaker, session, bucket) from different places, no audio shared between clips of the
same (speaker, session). At most ~3,000 clips; over that, the busiest speakers lose their last
clips first so more speakers survive. Speakers left with one session are `stranger_only`.

License: AMI is CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Local eval only.

Deterministic (fixed seed, sorted inputs) and re-runnable. Writes only VP/clips/ami/clean/,
VP/sets/ami/ and VP/logs/ami_build.log. Reads data/ami.

Usage:
    VP/venv/bin/python scripts/voiceprint/sets/build_ami.py [--cap 3000] [--dry-run] [--verify]
                                                             [--require-all]
"""
from __future__ import annotations

import argparse
import bisect
import collections
import json
import math
import random
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import soundfile as sf

SET = "ami"
SEED = "ami-v1"
SR = 16000
BUCKETS = (2, 4, 8)
MAX_PER_SESSION_BUCKET = 3
MIN_RMS_DBFS = -60.0   # "not silent" gate on the raw clip. The contract says -45, but AMI mixes are quiet (speech -18..-52 dBFS)
TARGET_CLIP_DBFS = -26.0   # every clean clip is rescaled to this RMS (typical call playback level); gain goes in src.gain_db
MAX_PEAK = 0.99        # after rescale; a clip with a pop that would clip is skipped
CLIP_LEVEL = 0.999     # source samples at or above this are clipped
MAX_CLIPPED_FRAC = 0.0002   # some IS meetings clip in the source; skip windows that do
GUARD = 0.31           # seconds clear of every other RTTM speaker (contract: 0.3; 10 ms slack so rounding cannot erode it)
JOIN_GAP = 0.5         # pauses up to this long inside one speaker's talk still count as one stretch
MIN_COVER = 0.80       # share of the clip that must be the speaker's own RTTM speech
MIN_ACTIVE_FRAC = 0.5  # frames within 35 dB of the clip's loudest frame
USED_PAD = 0.5         # audio of two clips from one (speaker, session) never touches closer than this
GRID = 0.25            # candidate start step inside a stretch
CAP_DEFAULT = 3000

# The downloader's `lab` list: 12 Edinburgh (ES), 6 Idiap (IS), 6 TNO (TS) series, sessions a-d.
LAB_SERIES = (
    "ES2002 ES2003 ES2004 ES2005 ES2006 ES2007 ES2008 ES2009 ES2010 ES2011 ES2012 ES2013 "
    "IS1000 IS1001 IS1003 IS1004 IS1006 IS1007 TS3003 TS3004 TS3005 TS3006 TS3007 TS3008"
).split()
LAB_MEETINGS = [f"{s}{x}" for s in LAB_SERIES for x in "abcd"]
SITE = {"ES": "Edinburgh", "IS": "Idiap", "TS": "TNO"}

REPO = Path(__file__).resolve().parents[3]
AMI = REPO / "data" / "ami"
VP = REPO / "data" / "eval" / "voiceprint"
META = AMI / "meta" / "corpusResources"
OUT = VP
SET_DIR = OUT / "sets" / SET
CLIP_DIR = OUT / "clips" / SET / "clean"
LOG = VP / "logs" / "ami_build.log"
NS = "{http://nite.sourceforge.net/}"


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


# ---------------------------------------------------------------- AMI metadata
def load_meetings():
    """meeting id -> {type, date, time, spk: {agent: (global_name, role)}}"""
    root = ET.parse(META / "meetings.xml").getroot()
    out = {}
    for m in root.iter("meeting"):
        out[m.get("observation")] = {
            "type": m.get("type"),
            "date": m.get("dateOnly"),
            "time": m.get("startTime"),
            "spk": {s.get("nxt_agent"): (s.get("global_name"), s.get("role"), s.get(NS + "id"))
                    for s in m.iter("speaker")},
        }
    return out


def load_participants():
    root = ET.parse(META / "participants.xml").getroot()
    return {p.get(NS + "id"): {"sex": p.get("sex"), "meeting": p.get("meeting"),
                               "native_language": p.get("native_language")}
            for p in root.iter("participant")}


def iso_time(date: str, hm: str) -> str:
    d, m, y = date.split("-")
    h, mi = (hm or "00h00").replace("h", ":").split(":")[:2]
    return f"{y}-{m}-{d}T{int(h):02d}:{int(mi):02d}"


def read_rttm(path: Path):
    """[(start, end, label)]"""
    rows = []
    for line in path.read_text().splitlines():
        p = line.split()
        if len(p) < 8 or p[0] != "SPEAKER":
            continue
        s, d = float(p[3]), float(p[4])
        if d > 0:
            rows.append((s, s + d, p[7]))
    return rows


def resolve_label(label: str, spk_map: dict):
    """RTTM label -> global participant id via meetings.xml, or None."""
    names = {v[0] for v in spk_map.values()}
    if label in names:
        return label
    if label in spk_map:                                   # per-meeting agent letter
        return spk_map[label][0]
    for v in spk_map.values():                             # per-meeting nite id (ES2002a_1)
        if label == v[2]:
            return v[0]
    return None


def audio_complete(path: Path) -> bool:
    try:
        info = sf.info(str(path))
    except Exception:
        return False
    if info.samplerate != SR or info.channels not in (1, 2):
        return False
    return path.stat().st_size >= info.frames * 2 * info.channels + 44


def load_audio(path: Path) -> np.ndarray:
    """Float32 mono. ES2010d's Mix-Headset is dual-mono stereo (L == R); downmixing is exact."""
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    assert sr == SR
    return x[:, 0] if x.shape[1] == 1 else x.mean(axis=1, dtype=np.float32)


# ---------------------------------------------------------------- audio helpers
def frame_db(x: np.ndarray, frame: int = 400, hop: int = 160) -> np.ndarray:
    if len(x) < frame:
        x = np.pad(x, (0, frame - len(x)))
    n = 1 + (len(x) - frame) // hop
    idx = np.arange(frame)[None, :] + hop * np.arange(n)[:, None]
    ms = np.mean(x[idx].astype(np.float64) ** 2, axis=1)
    return 10 * np.log10(np.maximum(ms, 1e-12))


def rms_db(x: np.ndarray) -> float:
    return 20 * np.log10(max(float(np.sqrt(np.mean(x.astype(np.float64) ** 2))), 1e-9))


def clip_gain_db(x: np.ndarray) -> float:
    """Gain (dB, 2 decimals) that takes the raw window to TARGET_CLIP_DBFS RMS."""
    return round(TARGET_CLIP_DBFS - rms_db(x), 2)


def clip_ok(x: np.ndarray, why: collections.Counter | None = None) -> bool:
    """x is the raw (unscaled) window."""
    def no(reason):
        if why is not None:
            why[reason] += 1
        return False
    if rms_db(x) < MIN_RMS_DBFS:
        return no("quiet")
    if float(np.mean(np.abs(x) >= CLIP_LEVEL)) > MAX_CLIPPED_FRAC:
        return no("source_clipped")
    if float(np.abs(x).max()) * 10 ** (clip_gain_db(x) / 20) > MAX_PEAK:
        return no("peak_after_rescale")
    fdb = frame_db(x)
    if float(np.mean(fdb > fdb.max() - 35.0)) < MIN_ACTIVE_FRAC:
        return no("not_active")
    return True


def free_stretches(own_raw, others):
    """Where the speaker talks and nobody else does (0.3 s guard). own_raw: merged raw intervals."""
    own = merge(own_raw, gap=JOIN_GAP)
    others_pad = merge([(s - GUARD, e + GUARD) for s, e in others])
    return subtract(own, others_pad)


def gap_between(a, b) -> float:
    return max(0.0, max(a[0], b[0]) - min(a[1], b[1]))


def pick_windows(spk, ses, free, own_raw, own_starts, audio, rng, why):
    """Pick up to MAX_PER_SESSION_BUCKET windows per bucket. Returns {bucket: [start,...]}.

    Longest bucket first, since long single-speaker stretches are the scarce resource. Windows of one
    (speaker, session) never share audio, across buckets too.
    """
    used = []   # merged, padded
    result = {}
    for bucket in sorted(BUCKETS, reverse=True):
        picks = []
        bad = set()   # stretches (as tuples) with no valid window
        for _ in range(MAX_PER_SESSION_BUCKET):
            remaining = subtract(free, used)
            cands = [s for s in remaining if s[1] - s[0] >= bucket and s not in bad]
            if not cands:
                break
            if not picks:
                order = [cands[rng.randrange(len(cands))]]
                order += [c for c in cands if c != order[0]]
            else:
                # farthest from what is already picked for this bucket: spreads clips across the session
                pk = [(p, p + bucket) for p in picks]
                jitter = {c: rng.random() for c in cands}
                order = sorted(cands, key=lambda c: (-min(gap_between(c, q) for q in pk), jitter[c]))
            chosen = None
            for st in order:
                lo, hi = math.ceil(st[0] * 1000) / 1000, st[1]     # start on a whole millisecond
                n = int((hi - lo - bucket) / GRID) + 1
                starts = [lo + i * GRID for i in range(max(n, 1))]
                if starts[-1] + bucket > hi + 1e-9:
                    starts = [s for s in starts if s + bucket <= hi + 1e-9]
                rng.shuffle(starts)
                tries = 0
                for t in starts:
                    if overlap_len(own_raw, own_starts, t, t + bucket) / bucket < MIN_COVER:
                        why["low_cover"] += 1
                        continue
                    a = int(round(t * SR))
                    x = audio[a:a + bucket * SR]
                    if len(x) != bucket * SR:
                        continue
                    tries += 1
                    if clip_ok(x, why):
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
def check_identity(meetings_xml, participants, avail):
    """Verify global speaker ids. Returns (mapping, groups, problems)."""
    problems = []
    mapping = {}           # meeting -> {rttm label -> participant}
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    person_groups = collections.defaultdict(set)
    no_participant_row = set()
    for mid in avail:
        spk_map = meetings_xml[mid]["spk"]
        labels = sorted({l for _, _, l in read_rttm(AMI / "rttm" / f"{mid}.rttm")})
        mapping[mid] = {}
        for l in labels:
            g = resolve_label(l, spk_map)
            if g is None:
                problems.append(f"{mid}: RTTM label {l!r} not found in meetings.xml speakers "
                                f"{sorted(v[0] for v in spk_map.values())}")
            else:
                mapping[mid][l] = g
        for v in spk_map.values():
            groups[mid[:-1]][v[0]].append(mid[-1])
            person_groups[v[0]].add(mid[:-1])
            info = participants.get(v[0])
            if info is None:
                no_participant_row.add(v[0])       # participants.xml (2006) covers only the EN/ES series
            else:
                if info["sex"] != v[0][0]:
                    problems.append(f"{v[0]}: id says {v[0][0]} but participants.xml says {info['sex']}")
                if info["meeting"] and info["meeting"] != mid[:-1]:
                    problems.append(f"{v[0]}: participants.xml lists series {info['meeting']}, seen in {mid}")
    for p, gs in person_groups.items():
        if len(gs) > 1:
            problems.append(f"{p} appears in more than one group: {sorted(gs)}")
    return mapping, groups, problems, no_participant_row


# ---------------------------------------------------------------- README
def readme_info(rows, cap, verify, full_groups, n_series):
    ses_of = collections.defaultdict(set)
    sites_m, sites_spk = collections.defaultdict(set), collections.defaultdict(set)
    for r in rows:
        ses_of[r["speaker"]].add(r["session"])
        m = r["session"].split(":", 1)[1]
        sites_m[SITE[m[:2]]].add(m)
        sites_spk[SITE[m[:2]]].add(r["speaker"])
    info = {
        "speakers": len(ses_of), "sessions": len({r["session"] for r in rows}),
        "groups": len({r["group"] for r in rows}),
        "multi": sum(1 for v in ses_of.values() if len(v) >= 2),
        "stranger_only": len({r["speaker"] for r in rows if r.get("stranger_only")}),
        "clips": len(rows), "per_bucket": collections.Counter(r["bucket"] for r in rows), "cap": cap,
        "sites_line": ", ".join(f"{k} {len(sites_m[k])} meetings / {len(sites_spk[k])} speakers" for k in sorted(sites_m)),
        "groups_line": f"{full_groups} of {n_series} series have all four people in all four sessions",
        "verify_line": "an embedding check with the baseline model is available with `--verify`.",
    }
    if verify and "group" in verify:
        g, a = verify["group"], verify["all"]
        sg, sa = verify["session_group"], verify["session_all"]
        info["verify_line"] = (
            f"embedding check with the baseline WeSpeaker ResNet34-LM (up to 2 clips per speaker-session, {verify['clips']} clips): "
            f"one voiceprint per speaker-session matched the labeled person's other-session voiceprint best in "
            f"{sg['top1_correct']}/{sg['queries']} cases within the group and {sa['top1_correct']}/{sa['queries']} against all "
            f"{len(ses_of)} speakers; single clips {g['top1_acc'] * 100:.1f}% / {a['top1_acc'] * 100:.1f}%. "
            f"Misses are listed in `identity_check.json`.")
    return info


def write_readme(path: Path, info: dict) -> None:
    b = info["per_bucket"]
    lines = [
        "# ami: AMI Meeting Corpus, recurring meetings",
        "",
        "Real project meetings where the same four people meet again in sessions a-d of one scenario series.",
        "The closest public stand-in for Transcripted's returning-speaker case.",
        "",
        "- Source: AMI Meeting Corpus (Mix-Headset, 16 kHz mono), https://groups.inf.ed.ac.uk/ami/corpus/",
        "- Speech labels: pyannote/AMI-diarization-setup `only_words` RTTMs (MIT tooling over the AMI word annotations).",
        "- Speaker identity: AMI `meetings.xml` + `participants.xml` (ami_public_manual_1.6.2, `data/ami/meta/corpusResources/`).",
        "- License: AMI Meeting Corpus and annotations are CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). "
        "Attribution: the AMI Consortium, McCowan et al., \"The AMI Meeting Corpus\", 2005. "
        "Used here for local evaluation only; nothing is redistributed, committed, or uploaded.",
        "",
        "## Global speaker ids",
        "",
        "`speaker` is `ami:<participant>` using AMI's global participant id (FEE005, MIO016, MTD009PM, ...), "
        "`session` is `ami:<meeting>` (ami:ES2002a). The RTTM labels are already those global ids, and the build checks that "
        "rather than assuming it:",
        "",
        "- every RTTM label is one of the meeting's `global_name` values in meetings.xml (per-meeting agent letters would be mapped through it);",
        "- each series has the same four people in sessions a-d (%s);" % info["groups_line"],
        "- nobody appears in two series, so a `group` is a closed set of recurring people;",
        "- where participants.xml has the person (the EN/ES series; its 2006 snapshot has no IS or TS rows), the id's gender letter and series agree with it;",
        "- %s" % info["verify_line"],
        "",
        "## What is in it",
        "",
        f"- {info['speakers']} speakers, {info['sessions']} sessions (meetings), {info['groups']} groups (scenario series), "
        f"{info['multi']} speakers with clips in 2+ sessions, {info['stranger_only']} stranger-only.",
        f"- {info['clips']} clean clips: 2 s = {b[2]}, 4 s = {b[4]}, 8 s = {b[8]}.",
        f"- Sites: {info['sites_line']}.",
        "",
        "## How clips were cut",
        "",
        "1. Per meeting, per speaker: take that speaker's RTTM speech, join pauses up to 0.5 s, then remove everything within "
        "0.3 s of any other RTTM speaker. What is left are single-speaker stretches.",
        "2. Slide a window of exactly 2, 4, or 8 s along each stretch. The speaker's own RTTM must cover at least 80% of the window, "
        "raw RMS must be at least -60 dBFS, at least half the frames must be within 35 dB of the loudest frame, "
        "and the source must not be clipped (some Idiap meetings clip; windows with more than 0.02% samples at full scale are skipped).",
        "3. Up to 3 windows per (speaker, session, bucket), preferring stretches far from windows already picked. "
        "Longest bucket first. No two clips of one (speaker, session) share audio, across buckets too.",
        f"4. Cap {info['cap']}: over the cap, the speaker with the most clips gives up its last-ranked clip first, "
        "so more speakers survive. Speakers left with clips in one session are marked `\"stranger_only\": true`.",
        "",
        "Deterministic (seed `%s`): `VP/venv/bin/python scripts/voiceprint/sets/build_ami.py`." % SEED,
        "",
        "## Extra fields beyond the contract",
        "",
        "- `group`: `ami:<series>` (`ami:ES2002`). The four people who meet again in that series. Naming simulation can treat one group as one user's recurring meetings.",
        "- `session_order`: 0-3, chronological rank of the meeting within its group (from meetings.xml date and time; usually the a-d order).",
        "- `gender`: `F` or `M`.",
        "",
        "## Caveats",
        "",
        "- Audio is the headset mix, so every participant's mic is in it. RTTM only marks words: laughter, coughs and breaths of other "
        "people are not labeled, so a few clips have faint non-speech from someone else.",
        "- Scenario meetings are role-played design meetings; the same person keeps a role (PM, ME, ID, UI) across a-d.",
        "- Levels. The raw mixes are all over the place: labeled speech averages -18 dBFS in the Idiap meetings and down to -52 dBFS in some "
        "Edinburgh and TNO ones. That is a recording artifact, not something this set should test, and some models do not normalize level. "
        "So this set departs from the contract in two ways (coordinator's call): the \"not silent\" gate is -60 dBFS on the raw clip "
        "instead of -45, and every clean clip is rescaled to -26 dBFS RMS (typical call playback level). The gain applied to each clip is in "
        "`src.gain_db` (dB, 2 decimals; clean clip = source * 10^(gain_db/20)). A clip that would peak above 0.99 after rescaling is skipped. "
        "Otherwise clips are 16 kHz mono PCM16 as recorded. Degraded copies inherit the rescaled level.",
        "- Speakers with too little clean single-speaker speech get few clips or none (listeners who mostly back-channel).",
        "- ES2010d's Mix-Headset file is dual-mono stereo (L equals R); it is downmixed exactly. The rest are mono.",
        "- Everyone here sits in four meetings, so no speaker is `stranger_only`. For stranger (impostor) tests, use people from other groups: no one appears in two.",
        "- Audio came from `scripts/download_ami.sh lab` (downloads live in `data/ami`; `VP/raw/ami` is a symlink to it). The downloader had been interrupted; "
        "the one truncated file (TS3004b) was removed and fetched again, and every wav is checked against its header length before use.",
        "",
    ]
    path.write_text("\n".join(lines))


# ---------------------------------------------------------------- embedding verification
def verify_embeddings(rows, per_pair: int = 2):
    """Nearest-voiceprint check with the baseline model. Returns a dict of results."""
    sys.path.insert(0, str(REPO / "scripts" / "voiceprint" / "runtimes"))
    import importlib
    mdir = VP / "models" / "wespeaker-resnet34-lm"
    if not (mdir / "model.json").is_file():
        return {"skipped": "baseline model not found"}
    meta = json.loads((mdir / "model.json").read_text())
    rt = importlib.import_module(meta["runtime"])
    emb = rt.Embedder(mdir, meta, threads=3)
    # pick up to `per_pair` clips per (speaker, session), longest buckets first
    by_pair = collections.defaultdict(list)
    for r in rows:
        by_pair[(r["speaker"], r["session"])].append(r)
    chosen = []
    for k in sorted(by_pair):
        rs = sorted(by_pair[k], key=lambda r: (-r["bucket"], r["seg_id"]))[:per_pair]
        chosen += rs
    log(f"verify: embedding {len(chosen)} clips with {meta['model_id']}")
    E = []
    for r in chosen:
        x, sr = sf.read(str(OUT / r["clip"]), dtype="float32")
        v = emb.embed(x)
        E.append(v / (np.linalg.norm(v) + 1e-9))
    E = np.array(E)
    spk = np.array([r["speaker"] for r in chosen])
    ses = np.array([r["session"] for r in chosen])
    grp = np.array([r["group"] for r in chosen])
    out = {"model": meta["model_id"], "clips": len(chosen)}
    for scope in ("group", "all"):
        correct = total = 0
        wrong = []
        for i in range(len(chosen)):
            cand = {}
            for s in sorted(set(spk)):
                m = (spk == s) & (ses != ses[i])       # leave the query's session out of every voiceprint
                if scope == "group":
                    if grp[np.argmax(spk == s)] != grp[i]:
                        continue
                if m.any():
                    c = E[m].mean(0)
                    cand[s] = float(E[i] @ (c / (np.linalg.norm(c) + 1e-9)))
            if spk[i] not in cand or len(cand) < 2:
                continue
            total += 1
            best = max(cand, key=cand.get)
            if best == spk[i]:
                correct += 1
            else:
                wrong.append({"clip": chosen[i]["seg_id"], "true": spk[i], "pred": best})
        out[scope] = {"queries": total, "top1_correct": correct,
                      "top1_acc": round(correct / max(total, 1), 4), "wrong": wrong[:40]}
        log(f"verify[{scope}]: {correct}/{total} = {correct / max(total, 1):.3f} nearest other-session voiceprint is the labeled speaker")
    # session level: each (speaker, session) gets one voiceprint from its clips; a person whose whole session
    # was labeled wrong (or a swapped pair) fails here even when single clips are noisy
    pairs = sorted({(a, b) for a, b in zip(spk, ses)})
    cent = {}
    for (a, b) in pairs:
        m = (spk == a) & (ses == b)
        c = E[m].mean(0)
        cent[(a, b)] = c / (np.linalg.norm(c) + 1e-9)
    grp_of = {a: grp[np.argmax(spk == a)] for a in set(spk)}
    for scope in ("group", "all"):
        correct = total = 0
        wrong = []
        for (a, b) in pairs:
            cand = {}
            for other in sorted(set(spk)):
                if scope == "group" and grp_of[other] != grp_of[a]:
                    continue
                cs = [cent[(o, t)] for (o, t) in pairs if o == other and t != b]
                if cs:
                    c = np.mean(cs, axis=0)
                    cand[other] = float(cent[(a, b)] @ (c / (np.linalg.norm(c) + 1e-9)))
            if a not in cand or len(cand) < 2:
                continue
            total += 1
            best = max(cand, key=cand.get)
            if best == a:
                correct += 1
            else:
                wrong.append({"session": b, "true": a, "pred": best,
                              "cos_true": round(cand[a], 3), "cos_pred": round(cand[best], 3)})
        out["session_" + scope] = {"queries": total, "top1_correct": correct,
                                   "top1_acc": round(correct / max(total, 1), 4), "wrong": wrong}
        log(f"verify[session_{scope}]: {correct}/{total} = {correct / max(total, 1):.3f} "
            f"(one voiceprint per speaker-session vs other-session voiceprints)")
    return out


# ---------------------------------------------------------------- main
def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cap", type=int, default=CAP_DEFAULT)
    ap.add_argument("--dry-run", action="store_true", help="select clips and print counts; write nothing")
    ap.add_argument("--verify", action="store_true", help="also run the embedding identity check (after writing)")
    ap.add_argument("--require-all", action="store_true", help="fail unless all 96 lab meetings are present")
    ap.add_argument("--readme-only", action="store_true", help="rewrite README.md from the existing segments.jsonl and identity_check.json; touches no clips")
    ap.add_argument("--meetings", nargs="*", help="limit to these meetings (testing)")
    ap.add_argument("--out-root", help="write clips/sets under this folder instead of VP (testing)")
    args = ap.parse_args()
    global SET_DIR, CLIP_DIR, OUT
    if args.out_root:
        OUT = Path(args.out_root).resolve()
        SET_DIR, CLIP_DIR = OUT / "sets" / SET, OUT / "clips" / SET / "clean"

    meetings_xml = load_meetings()
    participants = load_participants()

    avail, skipped = [], []
    for mid in LAB_MEETINGS:
        if args.meetings and mid not in args.meetings:
            continue
        wav, rttm = AMI / "audio" / f"{mid}.Mix-Headset.wav", AMI / "rttm" / f"{mid}.rttm"
        if wav.is_file() and rttm.is_file() and audio_complete(wav) and mid in meetings_xml:
            avail.append(mid)
        else:
            skipped.append(mid)
    log(f"meetings: {len(avail)} usable, {len(skipped)} skipped {skipped}")
    if args.require_all and skipped:
        log("--require-all: some lab meetings are missing or incomplete; stopping")
        return 2

    mapping, groups, problems, no_row = check_identity(meetings_xml, participants, avail)
    for p in problems:
        log(f"IDENTITY PROBLEM: {p}")
    if problems:
        return 3
    log(f"participants.xml has a row for {len({p for d in groups.values() for p in d} - no_row)} people; "
        f"{len(no_row)} (IS/TS series) have none, so their gender comes from the id's first letter")
    unstable = {g: {p: "".join(v) for p, v in d.items()} for g, d in groups.items()
                if len({tuple(sorted(v)) for v in d.values()}) != 1}
    full_groups = sum(1 for g, d in groups.items() if len(d) == 4 and all(len(v) == 4 for v in d.values()))
    log(f"identity ok: {len(avail)} meetings, {len(groups)} groups ({full_groups} with the same 4 people in a-d), "
        f"{len({p for d in groups.values() for p in d})} participants; unstable groups: {unstable or 'none'}")
    for g in sorted(groups):
        log(f"  group {g}: " + " ".join(f"{p}[{''.join(sorted(v))}]" for p, v in sorted(groups[g].items())))

    if args.readme_only:
        rows_in = [json.loads(l) for l in (SET_DIR / "segments.jsonl").read_text().splitlines()]
        idc = SET_DIR / "identity_check.json"
        write_readme(SET_DIR / "README.md",
                     readme_info(rows_in, args.cap, json.loads(idc.read_text()) if idc.is_file() else None,
                                 full_groups, len(groups)))
        log(f"rewrote README.md under {SET_DIR}")
        return 0

    # session order within group, from meetings.xml date/time
    order = {}
    for g in groups:
        ms = sorted((iso_time(meetings_xml[m]["date"], meetings_xml[m]["time"]), m) for m in avail if m[:-1] == g)
        for i, (_, m) in enumerate(ms):
            order[m] = i

    # ---- pass 1: choose windows per meeting
    selected = []   # dicts: speaker, session, bucket, start, meeting
    why = collections.Counter()      # window rejections by reason
    for mid in avail:
        rows = read_rttm(AMI / "rttm" / f"{mid}.rttm")
        by = collections.defaultdict(list)
        for s, e, l in rows:
            by[mapping[mid][l]].append((s, e))
        merged = {p: merge(v) for p, v in by.items()}
        audio = load_audio(AMI / "audio" / f"{mid}.Mix-Headset.wav")
        n0 = len(selected)
        for p in sorted(merged):
            others = merge([iv for q, v in merged.items() if q != p for iv in v])
            free = free_stretches(merged[p], others)
            own_starts = [iv[0] for iv in merged[p]]
            rng = random.Random(f"{SEED}|{p}|{mid}")
            picks = pick_windows(p, mid, free, merged[p], own_starts, audio, rng, why)
            for b, starts in picks.items():
                for t in starts:
                    selected.append({"speaker": p, "meeting": mid, "bucket": b, "start": t})
        log(f"{mid}: {len(selected) - n0} candidate clips from {len(merged)} speakers, audio {len(audio) / SR / 60:.1f} min")
        del audio

    log(f"selected before cap: {len(selected)}; window rejections {dict(why)}")

    # ---- cap: busiest speaker gives up its last-ranked clip in its fullest (session, bucket) first
    def key(c):
        return (c["speaker"], c["meeting"], c["bucket"])
    trip = collections.defaultdict(list)
    for c in selected:
        trip[key(c)].append(c)
    per_spk = collections.Counter(c["speaker"] for c in selected)
    bucket_n = collections.Counter(c["bucket"] for c in selected)
    total = len(selected)
    dropped = 0
    while total > args.cap:
        spk = max(sorted(per_spk), key=lambda s: per_spk[s])
        ks = [k for k in trip if k[0] == spk and len(trip[k]) > 1]
        if not ks:                       # nothing left to thin without losing a (session, bucket)
            ks = [k for k in trip if k[0] == spk and trip[k]]
            if not ks:
                break
        # thin the fullest (session, bucket); tie -> the bucket that has the most clips overall, so buckets stay balanced
        k = max(sorted(ks, key=lambda k: (k[1], k[2])), key=lambda k: (len(trip[k]), bucket_n[k[2]]))
        trip[k].pop()
        bucket_n[k[2]] -= 1
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
    n_sessions = len({c["meeting"] for c in kept})
    multi = sum(1 for v in ses_of.values() if len(v) >= 2)
    kept_groups = {c["meeting"][:-1] for c in kept}
    log(f"clips={len(kept)} speakers={len(ses_of)} sessions={n_sessions} groups={len(kept_groups)} "
        f"speakers_with_2plus_sessions={multi} stranger_only={len(stranger)} per_bucket={dict(sorted(per_bucket.items()))}")
    sess_hist = collections.Counter(len(v) for v in ses_of.values())
    log(f"sessions-per-speaker histogram: {dict(sorted(sess_hist.items()))}")
    if args.dry_run:
        return 0

    # ---- write clips, segments.jsonl, README, READY
    for d in (SET_DIR, CLIP_DIR):
        assert OUT.resolve() in d.resolve().parents, d
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
        audio = load_audio(AMI / "audio" / f"{mid}.Mix-Headset.wav")
        for c in sorted(by_meeting[mid], key=lambda c: (c["speaker"], c["bucket"], c["start"])):
            n = counter
            counter += 1
            spk, b, t = c["speaker"], c["bucket"], c["start"]
            seg_id = safe(f"{SET}:{spk}:{mid}:{n}")
            a = int(round(t * SR))
            x = audio[a:a + b * SR]
            assert len(x) == b * SR
            gdb = clip_gain_db(x)
            pcm = np.clip(np.round(x * 10 ** (gdb / 20) * 32768.0), -32768, 32767).astype("<i2")
            sf.write(str(CLIP_DIR / f"{seg_id}.wav"), pcm, SR, subtype="PCM_16", format="WAV")
            row = {
                "seg_id": seg_id, "set": SET, "speaker": f"{SET}:{safe(spk)}",
                "session": f"{SET}:{safe(mid)}", "bucket": b, "dur": b,
                "clip": f"clips/{SET}/clean/{seg_id}.wav",
                "src": {"file": f"data/ami/audio/{mid}.Mix-Headset.wav", "start": round(t, 3), "end": round(t + b, 3),
                        "gain_db": gdb},
                "gender": participants[spk]["sex"] if spk in participants else spk[0],
                "group": f"{SET}:{safe(mid[:-1])}",
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

    verify = None
    if args.verify:
        verify = verify_embeddings(rows_out)
        (SET_DIR / "identity_check.json").write_text(json.dumps(verify, indent=1))
    write_readme(SET_DIR / "README.md", readme_info(rows_out, args.cap, verify, full_groups, len(groups)))

    ready = {"set": SET, "clips": len(rows_out), "speakers": len(ses_of), "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    (SET_DIR / "READY").write_text(json.dumps(ready) + "\n")
    log(f"wrote {len(rows_out)} clips, segments.jsonl, README.md, READY under {SET_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
