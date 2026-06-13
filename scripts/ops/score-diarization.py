#!/usr/bin/env python3
"""Score diarization accuracy and emit score-diarization.json for the scorecard.

Input is a segments JSON describing reference (ground-truth) speaker turns and
the hypothesis (Transcripted) turns on the same timeline:

  {
    "reference":  [{"speaker": "A",  "start": 0.0, "end": 2.4}, ...],
    "hypothesis": [{"speaker": "S1", "start": 0.1, "end": 2.3}, ...]
  }

It computes a frame-based Diarization Error Rate (DER) — missed speech + false
alarm + speaker confusion over total reference speech — after a greedy optimal
mapping of hypothesis labels to reference speakers. DER is the standard metric;
the greedy mapping is a documented approximation of the Hungarian assignment and
is exact whenever the best mapping is unambiguous (the common case for a handful
of speakers).

score = 100 * (1 - DER), clamped to 0-100. No transcript text is read; only
timestamps and opaque speaker labels.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_segments(payload: dict[str, Any], key: str) -> list[tuple[str, float, float]]:
    segs = []
    for item in payload.get(key, []):
        start = float(item["start"])
        end = float(item["end"])
        if end > start:
            segs.append((str(item["speaker"]), start, end))
    return segs


def overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def speaker_overlaps(
    reference: list[tuple[str, float, float]],
    hypothesis: list[tuple[str, float, float]],
) -> dict[tuple[str, str], float]:
    """Total overlap duration between each (ref speaker, hyp label) pair."""
    overlaps: dict[tuple[str, str], float] = {}
    for r_spk, r_s, r_e in reference:
        for h_spk, h_s, h_e in hypothesis:
            ov = overlap(r_s, r_e, h_s, h_e)
            if ov > 0:
                overlaps[(r_spk, h_spk)] = overlaps.get((r_spk, h_spk), 0.0) + ov
    return overlaps


def greedy_mapping(overlaps: dict[tuple[str, str], float]) -> dict[str, str]:
    """Greedy one-to-one hyp-label -> ref-speaker mapping by descending overlap."""
    mapping: dict[str, str] = {}
    used_ref: set[str] = set()
    for (r_spk, h_spk), _ in sorted(overlaps.items(), key=lambda kv: kv[1], reverse=True):
        if h_spk in mapping or r_spk in used_ref:
            continue
        mapping[h_spk] = r_spk
        used_ref.add(r_spk)
    return mapping


def compute_der(
    reference: list[tuple[str, float, float]],
    hypothesis: list[tuple[str, float, float]],
    resolution: float,
) -> dict[str, Any]:
    if not reference:
        return {"der": None, "detail": "no reference segments"}

    mapping = greedy_mapping(speaker_overlaps(reference, hypothesis))

    start = min(s for _, s, _ in reference + hypothesis) if hypothesis else min(s for _, s, _ in reference)
    end = max(e for _, _, e in reference + hypothesis) if hypothesis else max(e for _, _, e in reference)

    total_ref = 0.0
    missed = 0.0
    false_alarm = 0.0
    confusion = 0.0

    t = start
    while t < end:
        mid = t + resolution / 2
        ref_spk = next((spk for spk, s, e in reference if s <= mid < e), None)
        hyp_spk = next((spk for spk, s, e in hypothesis if s <= mid < e), None)
        frame = resolution
        if ref_spk is not None:
            total_ref += frame
            if hyp_spk is None:
                missed += frame
            elif mapping.get(hyp_spk) != ref_spk:
                confusion += frame
        elif hyp_spk is not None:
            false_alarm += frame
        t += resolution

    if total_ref <= 0:
        return {"der": None, "detail": "reference has no speech time"}

    der = (missed + false_alarm + confusion) / total_ref
    return {
        "der": round(der, 4),
        "missedRate": round(missed / total_ref, 4),
        "falseAlarmRate": round(false_alarm / total_ref, 4),
        "confusionRate": round(confusion / total_ref, 4),
        "refSpeakers": len({spk for spk, _, _ in reference}),
        "hypSpeakers": len({spk for spk, _, _ in hypothesis}),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--segments", required=True, help="Segments JSON with reference + hypothesis turns.")
    parser.add_argument("--out", required=True, help="Where to write score-diarization.json.")
    parser.add_argument("--resolution", type=float, default=0.1, help="Frame size in seconds (default 0.1).")
    args = parser.parse_args()

    seg_path = Path(args.segments).expanduser()
    out_path = Path(args.out).expanduser()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if not seg_path.is_file():
        out_path.write_text(json.dumps({"board": "diarization", "metric": "der", "present": False, "score": None, "detail": f"missing {seg_path.name}"}, indent=2), encoding="utf-8")
        print(f"INCOMPLETE: no segments at {seg_path}")
        return 3

    payload = json.loads(seg_path.read_text(encoding="utf-8"))
    reference = load_segments(payload, "reference")
    hypothesis = load_segments(payload, "hypothesis")
    result = compute_der(reference, hypothesis, args.resolution)

    der = result.get("der")
    if der is None:
        score = None
        present = False
    else:
        score = max(0.0, min(100.0, 100.0 * (1.0 - der)))
        present = True

    detail = "" if der is None else (
        f"DER {der:.1%} (miss {result['missedRate']:.0%}, fa {result['falseAlarmRate']:.0%}, "
        f"conf {result['confusionRate']:.0%}); {result['hypSpeakers']} vs {result['refSpeakers']} speakers"
    )
    out_path.write_text(json.dumps({
        "board": "diarization",
        "metric": "der",
        "present": present,
        "score": None if score is None else round(score, 1),
        "detail": detail or result.get("detail", ""),
        "subscores": result,
    }, indent=2, sort_keys=True), encoding="utf-8")

    print(f"diarization: {detail or result.get('detail', 'no score')}")
    return 0 if present else 3


if __name__ == "__main__":
    raise SystemExit(main())
