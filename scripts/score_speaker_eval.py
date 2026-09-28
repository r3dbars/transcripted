#!/usr/bin/env python3
"""Score a speaker-eval-harness replay against AMI ground-truth RTTMs.

Separates two concerns:

  * Diarizer quality   — per-file DER (optimal per-file label mapping, pyannote.metrics
    conventions; computed by speaker_eval_common.diarization_error, which matches
    pyannote.metrics' DiarizationErrorRate to float precision without needing it
    installed). Independent of cross-meeting naming.

  * Threshold quality  — fragmentation, false-merge, and the cross-meeting re-ID
    curve, derived from a global time-overlap matrix between the harness's
    persistent DB-profile labels (consistent across the whole replay) and the AMI
    global participant IDs (FEE005, MEE006, ...). These are what the 0.88
    consolidation and 0.6 match thresholds actually move.

The shared math lives in scripts/speaker_eval_common.py; scripts/score_speaker_lab.py
builds the diarizer bake-off (raw vs pipeline DER, returning-speaker recognition) on
the same helpers.

Usage:
  score_speaker_eval.py --result <replay.json> --rttm-dir data/ami/rttm \
      [--collar 0.25] [--out-json out.json] [--out-md out.md]
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from speaker_eval_common import (  # noqa: E402
    build_overlap_matrix,
    diarization_error,
    identity_metrics,
    overlap,
    parse_rttm,
)

__all__ = ["parse_rttm", "overlap", "build_overlap_matrix", "score_result", "format_md"]


def score_result(result, rttm_dir, collar=0.25):
    """Score one replay result dict. Returns the summary dict written by --out-json."""
    per_meeting = []
    meetings = []
    for mr in result["meetings"]:
        meeting = mr["meeting"]
        ref = parse_rttm(f"{rttm_dir}/{meeting}.rttm")
        hyp = [(a["start"], a["end"], a["dbProfile"]) for a in mr["assignments"]]
        meetings.append((meeting, ref, hyp))

        der = diarization_error(ref, hyp, collar=collar)
        per_meeting.append({
            "meeting": meeting,
            "der": der["der"],
            "miss": der["miss_rate"],
            "false_alarm": der["false_alarm_rate"],
            "confusion": der["confusion_rate"],
            "ref_speakers": len(set(t for _, _, t in ref)),
            "hyp_profiles": len(set(p for _, _, p in hyp)),
        })

    ident = identity_metrics(meetings)
    fragmentation = ident["fragmentation"]
    false_merge = ident["false_merge"]

    # aggregate DER: mean of per-meeting DER (each meeting weighted equally)
    tot_der = sum(p["der"] for p in per_meeting) / len(per_meeting) if per_meeting else None

    return {
        "config": {"consolidationThreshold": result.get("consolidationThreshold"),
                   "matchThreshold": result.get("matchThreshold"),
                   "collar": collar},
        "der": {"per_meeting": per_meeting, "mean_der": round(tot_der, 4) if tot_der is not None else None},
        "fragmentation": {
            "per_true_speaker": fragmentation,
            "mean_profiles_per_person": round(sum(fragmentation.values()) / len(fragmentation), 3) if fragmentation else None,
            "max_profiles_per_person": max(fragmentation.values()) if fragmentation else None,
        },
        "false_merge": {
            "count": len(false_merge),
            "profiles": false_merge,
        },
        "reid_curve_by_appearance": ident["reid_curve"],
        "reid_detail": ident["reid_detail"],
        "profiles_at_end": result.get("profilesAtEnd"),
        "true_speakers": ident["true_speakers"],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--result", required=True)
    ap.add_argument("--rttm-dir", required=True)
    ap.add_argument("--collar", type=float, default=0.25,
                    help="DER forgiveness collar in seconds (AMI convention: 0.25)")
    ap.add_argument("--out-json")
    ap.add_argument("--out-md")
    args = ap.parse_args()

    with open(args.result) as f:
        result = json.load(f)
    summary = score_result(result, args.rttm_dir, collar=args.collar)

    if args.out_json:
        with open(args.out_json, "w") as f:
            json.dump(summary, f, indent=2)
    print(format_md(summary))
    if args.out_md:
        with open(args.out_md, "w") as f:
            f.write(format_md(summary))


def format_md(s):
    c = s["config"]
    lines = []
    lines.append(f"### consolidation={c['consolidationThreshold']}  match={c['matchThreshold']}  (DER collar={c['collar']}s)")
    lines.append("")
    lines.append("| meeting | DER | miss | FA | conf | ref spk | hyp prof |")
    lines.append("|---|---|---|---|---|---|---|")
    for p in s["der"]["per_meeting"]:
        lines.append(f"| {p['meeting']} | {p['der']:.3f} | {p['miss']:.3f} | {p['false_alarm']:.3f} | "
                     f"{p['confusion']:.3f} | {p['ref_speakers']} | {p['hyp_profiles']} |")
    lines.append(f"| **mean** | **{s['der']['mean_der']}** | | | | | |")
    lines.append("")
    f = s["fragmentation"]
    lines.append(f"**Fragmentation** (distinct DB profiles ≥10% of a person's speech): "
                 f"mean {f['mean_profiles_per_person']} / person, max {f['max_profiles_per_person']}.")
    lines.append(f"  per-speaker: {f['per_true_speaker']}")
    lines.append("")
    fm = s["false_merge"]
    lines.append(f"**False-merge**: {fm['count']} DB profile(s) span ≥2 distinct people.")
    if fm["profiles"]:
        for pid, trues in fm["profiles"].items():
            lines.append(f"  {pid[:8]}…: {trues}")
    lines.append("")
    lines.append(f"**Cross-meeting re-ID curve** (fraction of a person's speech re-identified "
                 f"to their first-appearance profile, by appearance #): {s['reid_curve_by_appearance']}")
    lines.append(f"**Profiles at end of run**: {s['profiles_at_end']} (ideal = {len(s['true_speakers'])} for one series).")
    return "\n".join(lines)


if __name__ == "__main__":
    main()
