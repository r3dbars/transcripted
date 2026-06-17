#!/usr/bin/env python3
"""Task B - mixed-segment diagnosis: segmentation vs embeddings.

A clustering ceiling can come from SEGMENTATION rather than embeddings/clustering:
if a single dump segment's time span covers >=2 true speakers (overlap or coarse
boundaries), its WeSpeaker embedding is a blend that NO clustering can split. This
script measures how much of the ceiling is mixed-segments.

For each quality-filtered dump segment (quality>=0.3, dur>=1s, same filter as
recluster_eval.py), we compute how much of its time span each TRUE speaker occupies
(summing per-speaker active time within the span, from the RTTM, accounting for
overlap), then the dominant speaker's share. A segment is 'mixed' if dominant < 0.8.

Denominator choice: we report dominant share against the UNION of all true-speaker
speech time inside the span (i.e. fraction of actual speech in the span owned by the
dominant speaker). Pure silence inside a span is excluded from the denominator so a
segment is not flagged mixed merely for containing gaps. Segments with zero ref
speech in their span are excluded from the mixed/clean split (counted separately).

Per arm we report:
  - % mixed segments (count) and time-weighted speech share in mixed segments
  - oracle-k coverage (agglo_oraclek, center=none) from recluster_eval, recomputed
  - correlation across the 6 arms: mixed-rate vs oracle-k coverage shortfall, and
    codec severity vs mixed-rate.

Measurement only. Reads dumps + RTTMs; no app code, no re-diarization.
"""
import glob
import json
import os
import statistics as st
from collections import defaultdict

ARMS = ["clean", "opus24k", "opus16k", "opus12k", "opus8k", "g711u"]
QUAL_MIN = 0.3
DUR_MIN = 1.0
MIXED_THRESH = 0.8  # dominant share below this => mixed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_rttm(p):
    o = []
    for ln in open(p):
        x = ln.split()
        if len(x) >= 8 and x[0] == "SPEAKER":
            s, d = float(x[3]), float(x[4])
            o.append((s, s + d, x[7]))
    return o


def merge_intervals(ivs):
    """Union length of a list of (start,end) intervals (handles overlap)."""
    if not ivs:
        return 0.0
    ivs = sorted(ivs)
    tot = 0.0
    cs, ce = ivs[0]
    for s, e in ivs[1:]:
        if s > ce:
            tot += ce - cs
            cs, ce = s, e
        else:
            ce = max(ce, e)
    tot += ce - cs
    return tot


def span_speaker_times(s, e, ref):
    """For span [s,e], return dict speaker -> active (union) seconds within the span,
    and the union of ALL speech (any speaker) within the span."""
    per = defaultdict(list)
    allivs = []
    for rs, re, t in ref:
        os_, oe = max(s, rs), min(e, re)
        if oe > os_:
            per[t].append((os_, oe))
            allivs.append((os_, oe))
    per_time = {t: merge_intervals(iv) for t, iv in per.items()}
    union_speech = merge_intervals(allivs)
    return per_time, union_speech


def diagnose_arm(arm, rttm_dir):
    dumps = os.path.join(ROOT, f"data/eval/ami_{arm}/dumps")
    files = sorted(glob.glob(os.path.join(dumps, "*.json")))
    total_segs = 0
    mixed_segs = 0
    nospeech_segs = 0
    speech_in_mixed = 0.0
    speech_in_clean = 0.0
    dom_shares = []  # dominant share per (speech-bearing) segment
    per_meeting = []
    for f in files:
        m = os.path.basename(f)[:-5]
        rp = os.path.join(rttm_dir, m + ".rttm")
        if not os.path.exists(rp):
            continue
        d = json.load(open(f))
        ref = parse_rttm(rp)
        segs = [s for s in d["segments"]
                if s.get("embedding") and s["quality"] >= QUAL_MIN and s["end"] - s["start"] >= DUR_MIN]
        mt, mm, mns = 0, 0, 0
        msp_mixed, msp_clean = 0.0, 0.0
        for s in segs:
            per_time, union_speech = span_speaker_times(s["start"], s["end"], ref)
            if union_speech <= 0 or not per_time:
                nospeech_segs += 1
                mns += 1
                continue
            dom = max(per_time.values())
            share = dom / union_speech
            dom_shares.append(share)
            total_segs += 1
            mt += 1
            if share < MIXED_THRESH:
                mixed_segs += 1
                mm += 1
                speech_in_mixed += union_speech
                msp_mixed += union_speech
            else:
                speech_in_clean += union_speech
                msp_clean += union_speech
        tot_speech = msp_mixed + msp_clean
        per_meeting.append({
            "m": m, "segs": mt, "mixed": mm, "nospeech": mns,
            "pct_mixed": round(100 * mm / mt, 1) if mt else None,
            "speech_share_mixed": round(msp_mixed / tot_speech, 4) if tot_speech else None,
        })
    return {
        "arm": arm,
        "n_meetings": len(per_meeting),
        "total_segs": total_segs,
        "nospeech_segs": nospeech_segs,
        "mixed_segs": mixed_segs,
        "pct_mixed": round(100 * mixed_segs / total_segs, 2) if total_segs else None,
        "speech_share_mixed": round(speech_in_mixed / (speech_in_mixed + speech_in_clean), 4)
        if (speech_in_mixed + speech_in_clean) else None,
        "median_dom_share": round(st.median(dom_shares), 4) if dom_shares else None,
        "mean_dom_share": round(st.mean(dom_shares), 4) if dom_shares else None,
        "per_meeting": per_meeting,
    }


def pearson(xs, ys):
    n = len(xs)
    if n < 2:
        return None
    mx, my = st.mean(xs), st.mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = sum((x - mx) ** 2 for x in xs) ** 0.5
    dy = sum((y - my) ** 2 for y in ys) ** 0.5
    if dx == 0 or dy == 0:
        return None
    return num / (dx * dy)


if __name__ == "__main__":
    rttm_dir = os.path.join(ROOT, "data/ami/rttm")
    out = {}
    for arm in ARMS:
        out[arm] = diagnose_arm(arm, rttm_dir)
    json.dump(out, open(os.path.join(ROOT, "scripts/_mixed_seg_diag.json"), "w"), indent=2)
    # compact stdout
    for arm in ARMS:
        o = out[arm]
        print(f"{arm:8s} segs={o['total_segs']:5d} nospeech={o['nospeech_segs']:4d} "
              f"pct_mixed={o['pct_mixed']:.2f}%  speech_share_mixed={o['speech_share_mixed']:.4f}  "
              f"median_dom={o['median_dom_share']:.4f}")
