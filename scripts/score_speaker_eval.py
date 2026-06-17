#!/usr/bin/env python3
"""Score a speaker-eval-harness replay against AMI ground-truth RTTMs.

Separates two concerns:

  * Diarizer quality   — per-file DER (pyannote.metrics, optimal per-file label
    mapping). Independent of cross-meeting naming; isolates PyAnnote+WeSpeaker+VBx.

  * Threshold quality  — fragmentation, false-merge, and the cross-meeting re-ID
    curve, derived from a global time-overlap matrix between the harness's
    persistent DB-profile labels (consistent across the whole replay) and the AMI
    global participant IDs (FEE005, MEE006, ...). These are what the 0.88
    consolidation and 0.6 match thresholds actually move.

Usage:
  score_speaker_eval.py --result <replay.json> --rttm-dir data/ami/rttm \
      [--collar 0.25] [--out-json out.json] [--out-md out.md]
"""
import argparse, json, sys
from collections import defaultdict

try:
    from pyannote.core import Annotation, Segment
    from pyannote.metrics.diarization import DiarizationErrorRate
except Exception as e:  # pragma: no cover
    print(f"error: pyannote.metrics required ({e})", file=sys.stderr); sys.exit(2)


def parse_rttm(path, meeting=None, per_file=False):
    """Return list of (start, end, speaker_global_id).

    With per_file=True the speaker label is namespaced by `meeting`
    (``meeting␟spk00``). Corpora whose RTTM labels are PER-FILE and reused
    across files (e.g. VoxConverse: every file has its own ``spk00``) MUST use
    this, or the cross-file overlap matrix conflates distinct people. Corpora
    with globally-recurring ids (AMI ``FEE005``...) leave it off so the
    cross-meeting re-ID curve still sees the same identity across meetings."""
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "SPEAKER":
                continue
            start, dur, spk = float(p[3]), float(p[4]), p[7]
            if per_file and meeting is not None:
                spk = f"{meeting}␟{spk}"
            out.append((start, start + dur, spk))
    return out


def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def build_overlap_matrix(ref, hyp):
    """seconds of ref/hyp co-occurrence, keyed [true_id][db_profile]."""
    m = defaultdict(lambda: defaultdict(float))
    # sort hyp by start for a light sweep
    hyp = sorted(hyp, key=lambda x: x[0])
    for (rs, re, tid) in ref:
        for (hs, he, pid) in hyp:
            if hs >= re:
                break
            ov = overlap(rs, re, hs, he)
            if ov > 0:
                m[tid][pid] += ov
    return m


def annotation_from(segs):
    ann = Annotation()
    for i, (s, e, lbl) in enumerate(segs):
        if e > s:
            ann[Segment(s, e), i] = lbl
    return ann


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--result", required=True)
    ap.add_argument("--rttm-dir", required=True)
    ap.add_argument("--collar", type=float, default=0.25,
                    help="DER forgiveness collar in seconds (AMI convention: 0.25)")
    ap.add_argument("--per-file-ids", action="store_true",
                    help="Namespace RTTM speaker ids by file. Required for corpora with "
                         "per-file labels reused across files (VoxConverse). Leave off for "
                         "globally-recurring ids (AMI) so cross-meeting re-ID stays meaningful.")
    ap.add_argument("--out-json")
    ap.add_argument("--out-md")
    args = ap.parse_args()

    result = json.load(open(args.result))
    consolidation = result.get("consolidationThreshold")
    match_thr = result.get("matchThreshold")

    der_metric = DiarizationErrorRate(collar=args.collar, skip_overlap=False)

    per_meeting = []
    global_ref_time = defaultdict(float)   # true_id -> total ref seconds (this run)
    global_overlap = defaultdict(lambda: defaultdict(float))  # true_id -> db_profile -> sec
    # per-(meeting,true_id) dominant profile, used for the re-ID curve
    meeting_dom = {}   # (meeting, true_id) -> (db_profile, covered_sec, ref_sec)
    meeting_order = []

    for mr in result["meetings"]:
        meeting = mr["meeting"]
        meeting_order.append(meeting)
        ref = parse_rttm(f"{args.rttm_dir}/{meeting}.rttm", meeting, args.per_file_ids)
        hyp = [(a["start"], a["end"], a["dbProfile"]) for a in mr["assignments"]]

        der = der_metric(annotation_from(ref), annotation_from(hyp), detailed=True)
        total = der["total"] or 1.0
        per_meeting.append({
            "meeting": meeting,
            "der": der["diarization error rate"],
            "miss": der["missed detection"] / total,
            "false_alarm": der["false alarm"] / total,
            "confusion": der["confusion"] / total,
            "ref_speakers": len(set(t for _, _, t in ref)),
            "hyp_profiles": len(set(p for _, _, p in hyp)),
        })

        om = build_overlap_matrix(ref, hyp)
        for tid, secs in om.items():
            ref_sec = sum(e - s for s, e, t in ref if t == tid)
            global_ref_time[tid] += ref_sec
            dom_pid, dom_sec = (max(secs.items(), key=lambda kv: kv[1]) if secs else (None, 0.0))
            meeting_dom[(meeting, tid)] = (dom_pid, dom_sec, ref_sec)
            for pid, ov in secs.items():
                global_overlap[tid][pid] += ov

    # ---- fragmentation: distinct profiles holding >=10% of a person's speech ----
    FRAG_MIN = 0.10
    fragmentation = {}
    for tid, profiles in global_overlap.items():
        tot = global_ref_time[tid] or 1.0
        frag = sum(1 for pid, ov in profiles.items() if ov / tot >= FRAG_MIN)
        fragmentation[tid] = max(1, frag)

    # ---- false-merge: profiles whose mass spans >=2 distinct true speakers ----
    profile_to_true = defaultdict(lambda: defaultdict(float))
    for tid, profiles in global_overlap.items():
        for pid, ov in profiles.items():
            profile_to_true[pid][tid] += ov
    MERGE_MIN = 0.10
    false_merge = {}
    for pid, trues in profile_to_true.items():
        tot = sum(trues.values()) or 1.0
        n = sum(1 for tid, ov in trues.items() if ov / tot >= MERGE_MIN)
        if n >= 2:
            false_merge[pid] = sorted([t for t, ov in trues.items() if ov / tot >= MERGE_MIN])

    # ---- global mapping: each true speaker -> the profile holding most of its speech
    global_dom_profile = {}
    for tid, profiles in global_overlap.items():
        if profiles:
            global_dom_profile[tid] = max(profiles.items(), key=lambda kv: kv[1])[0]

    # ---- cross-meeting re-ID curve ----
    # For each true speaker, anchor = dominant profile at their FIRST appearance.
    # re-ID accuracy at appearance k = fraction of that session's speech assigned to anchor.
    first_anchor = {}
    reid_by_appearance = defaultdict(list)   # appearance_index (1-based) -> [accuracy...]
    reid_detail = []
    appearance_counter = defaultdict(int)
    for meeting in meeting_order:
        for tid in sorted(global_ref_time.keys()):
            key = (meeting, tid)
            if key not in meeting_dom:
                continue
            dom_pid, dom_sec, ref_sec = meeting_dom[key]
            if ref_sec <= 0:
                continue
            appearance_counter[tid] += 1
            k = appearance_counter[tid]
            if k == 1:
                first_anchor[tid] = dom_pid
            anchor = first_anchor.get(tid)
            # fraction of this session's speech assigned to the anchor profile
            covered = sec_assigned(result, meeting, tid, anchor, args.rttm_dir, args.per_file_ids)
            acc = covered / ref_sec if ref_sec else 0.0
            reid_by_appearance[k].append(acc)
            reid_detail.append({"meeting": meeting, "true": tid, "appearance": k,
                                "anchor": anchor, "dominant": dom_pid,
                                "reid_accuracy": round(acc, 4)})

    reid_curve = {str(k): round(sum(v) / len(v), 4) for k, v in sorted(reid_by_appearance.items())}

    # aggregate DER: mean of per-meeting DER (each meeting weighted equally)
    tot_der = sum(p["der"] for p in per_meeting) / len(per_meeting) if per_meeting else None

    summary = {
        "config": {"consolidationThreshold": consolidation, "matchThreshold": match_thr,
                   "collar": args.collar},
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
        "reid_curve_by_appearance": reid_curve,
        "reid_detail": reid_detail,
        "profiles_at_end": result.get("profilesAtEnd"),
        "true_speakers": sorted(global_ref_time.keys()),
    }

    if args.out_json:
        json.dump(summary, open(args.out_json, "w"), indent=2)
    print(format_md(summary))
    if args.out_md:
        open(args.out_md, "w").write(format_md(summary))


def sec_assigned(result, meeting, tid, anchor_pid, rttm_dir, per_file=False):
    """Seconds of true speaker `tid`'s reference speech in `meeting` that overlap
    hypothesis segments labeled `anchor_pid`."""
    if anchor_pid is None:
        return 0.0
    ref = parse_rttm(f"{rttm_dir}/{meeting}.rttm", meeting, per_file)
    ref = [(s, e) for (s, e, t) in ref if t == tid]
    mr = next(m for m in result["meetings"] if m["meeting"] == meeting)
    hyp = sorted([(a["start"], a["end"]) for a in mr["assignments"] if a["dbProfile"] == anchor_pid])
    total = 0.0
    for (rs, re) in ref:
        for (hs, he) in hyp:
            if hs >= re:
                break
            total += overlap(rs, re, hs, he)
    return total


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
