#!/usr/bin/env python3
"""
Ground-truth recalibration of the speaker-matcher thresholds for ERes2Net.

The app's matcher thresholds (adaptive DB match 0.85/0.78/0.70, same-voice
consolidation 0.88, small-cluster absorb 0.72/0.62) were tuned for WeSpeaker's
cosine geometry. ERes2Net has different geometry, so we re-derive them — but
NOT by guessing. We use AMI RTTM ground truth to measure each model's true
same-speaker vs different-speaker cosine distributions, then map every WeSpeaker
threshold to the ERes2Net threshold that achieves the SAME false-accept rate
(FAR). This preserves the exact safety the product was tuned for while letting
ERes2Net's better separation lower the false-reject rate at that operating point.

Two regimes:
  - CROSS-CALL (per-(meeting,speaker) mean embeddings, same label across different
    meetings = same person): drives the DB-match thresholds (0.85/0.78/0.70).
  - WITHIN-MEETING (segment pairs, same/different true speaker in one meeting):
    drives consolidation (0.88) + absorption (0.72/0.62).

AMI series (ES2002a-d etc.) reuse the same speakers, so cross-meeting same-label
pairs are genuine cross-call same-person pairs.

Outputs: scripts/out/eres2net_calibration.json + a printed table.
"""
import os, json, glob
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTTM_DIR = os.path.join(ROOT, "data", "ami", "rttm")
ARMS = {"clean": "", "opus8k": "__", "g711u": "__"}  # filled below
MODELS = {"wespeaker": "data/eval/ami_clean", "eres2net": "data/eval/ami_clean__eres2net"}
# WeSpeaker thresholds currently in the app (the operating points to preserve).
WESPEAKER_MATCH = {"1seg": 0.85, "2-3seg": 0.78, "4+seg": 0.70}
WESPEAKER_WITHIN = {"consolidation": 0.88, "absorb": 0.72, "micro_absorb": 0.62, "per_seg_split": 0.62}


def norm(v):
    v = np.asarray(v, dtype=np.float64)
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def load_rttm(meeting):
    path = os.path.join(RTTM_DIR, f"{meeting}.rttm")
    if not os.path.exists(path):
        return []
    spans = []
    for line in open(path):
        p = line.split()
        if len(p) >= 8 and p[0] == "SPEAKER":
            start, dur, spk = float(p[3]), float(p[4]), p[7]
            spans.append((spk, start, start + dur))
    return spans


def true_speaker(seg_start, seg_end, spans):
    """Max-overlap RTTM speaker for a segment; None if no real overlap."""
    best, best_ov = None, 0.0
    for spk, a, b in spans:
        ov = max(0.0, min(seg_end, b) - max(seg_start, a))
        if ov > best_ov:
            best_ov, best = ov, spk
    dur = seg_end - seg_start
    return best if (dur > 0 and best_ov / dur >= 0.5) else None


def load_model(dump_dir):
    """meeting -> list of (true_spk, embedding). Skips ambiguous segments."""
    out = {}
    for fp in sorted(glob.glob(os.path.join(ROOT, dump_dir, "dumps", "*.json"))):
        meeting = os.path.splitext(os.path.basename(fp))[0]
        spans = load_rttm(meeting)
        if not spans:
            continue
        segs = []
        for s in json.load(open(fp)).get("segments", []):
            emb = s.get("embedding")
            if not emb:
                continue
            ts = true_speaker(float(s["start"]), float(s["end"]), spans)
            if ts is not None:
                segs.append((ts, norm(emb)))
        if segs:
            out[meeting] = segs
    return out


def far_frr(same, diff, thr):
    same, diff = np.asarray(same), np.asarray(diff)
    frr = float((same < thr).mean()) if len(same) else float("nan")   # same-speaker rejected
    far = float((diff >= thr).mean()) if len(diff) else float("nan")  # diff-speaker accepted
    return far, frr


def thr_at_far(same, diff, target_far):
    """Lowest threshold whose FAR <= target_far (preserve safety, maximize recall)."""
    diff = np.sort(np.asarray(diff))
    if len(diff) == 0:
        return float("nan")
    # FAR(thr) = fraction of diff >= thr. Want smallest thr with FAR <= target.
    for thr in np.linspace(0.0, 1.0, 1001):
        if (diff >= thr).mean() <= target_far:
            return round(float(thr), 3)
    return 1.0


def eer(same, diff):
    same, diff = np.asarray(same), np.asarray(diff)
    best = (1.0, 0.5)
    for thr in np.linspace(0.0, 1.0, 1001):
        far, frr = far_frr(same, diff, thr)
        if abs(far - frr) < best[0]:
            best = (abs(far - frr), thr)
    far, frr = far_frr(same, diff, best[1])
    return round(best[1], 3), round((far + frr) / 2, 4)


def cross_call_pairs(model):
    """Per-(meeting,speaker) means; same = same label across DIFFERENT meetings."""
    means = {}  # (meeting, spk) -> mean
    for meeting, segs in model.items():
        by = {}
        for spk, e in segs:
            by.setdefault(spk, []).append(e)
        for spk, es in by.items():
            if len(es) >= 2:
                means[(meeting, spk)] = norm(np.mean(es, axis=0))
    keys = list(means.keys())
    same, diff = [], []
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            (m1, s1), (m2, s2) = keys[i], keys[j]
            if m1 == m2:
                continue  # same meeting handled by within-meeting regime
            c = float(np.dot(means[keys[i]], means[keys[j]]))
            (same if s1 == s2 else diff).append(c)
    return same, diff


def within_meeting_pairs(model):
    same, diff = [], []
    for meeting, segs in model.items():
        for i in range(min(len(segs), 60)):
            for j in range(i + 1, min(len(segs), 60)):
                c = float(np.dot(segs[i][1], segs[j][1]))
                (same if segs[i][0] == segs[j][0] else diff).append(c)
    return same, diff


def main():
    data = {m: load_model(d) for m, d in MODELS.items()}
    for m in MODELS:
        nseg = sum(len(v) for v in data[m].values())
        print(f"[load] {m}: {len(data[m])} meetings, {nseg} labeled segments")

    result = {"cross_call": {}, "within_meeting": {}, "recommended_eres2net": {}}

    # ---- CROSS-CALL: preserve each WeSpeaker match threshold's FAR ----
    cc = {m: cross_call_pairs(data[m]) for m in MODELS}
    print("\n=== CROSS-CALL (DB match thresholds) ===")
    for m in MODELS:
        s, d = cc[m]
        e_thr, e_val = eer(s, d)
        print(f"  {m}: same n={len(s)} diff n={len(d)} | EER={e_val} @ thr {e_thr} | "
              f"same med={np.median(s):.3f} diff p95={np.percentile(d,95):.3f}")
        result["cross_call"][m] = {"eer": e_val, "eer_thr": e_thr,
                                   "same_median": round(float(np.median(s)), 3),
                                   "diff_p95": round(float(np.percentile(d, 95)), 3)}
    we_s, we_d = cc["wespeaker"]
    er_s, er_d = cc["eres2net"]
    match_rec = {}
    for name, wethr in WESPEAKER_MATCH.items():
        far, frr = far_frr(we_s, we_d, wethr)
        er_thr = thr_at_far(er_s, er_d, max(far, 1e-4))
        er_far, er_frr = far_frr(er_s, er_d, er_thr)
        match_rec[name] = round(er_thr, 2)
        print(f"  WeSpeaker {name}={wethr} (FAR={far:.3f} FRR={frr:.3f}) "
              f"-> ERes2Net {er_thr:.3f} (FAR={er_far:.3f} FRR={er_frr:.3f})")
    result["recommended_eres2net"]["match"] = match_rec

    # ---- WITHIN-MEETING: preserve consolidation/absorption FARs ----
    wm = {m: within_meeting_pairs(data[m]) for m in MODELS}
    print("\n=== WITHIN-MEETING (consolidation / absorption) ===")
    for m in MODELS:
        s, d = wm[m]
        print(f"  {m}: same n={len(s)} diff n={len(d)} | same med={np.median(s):.3f} "
              f"diff p95={np.percentile(d,95):.3f} p99={np.percentile(d,99):.3f}")
    we_s2, we_d2 = wm["wespeaker"]
    er_s2, er_d2 = wm["eres2net"]
    within_rec = {}
    for name, wethr in WESPEAKER_WITHIN.items():
        far, frr = far_frr(we_s2, we_d2, wethr)
        er_thr = thr_at_far(er_s2, er_d2, max(far, 1e-4))
        within_rec[name] = round(er_thr, 2)
        er_far, er_frr = far_frr(er_s2, er_d2, er_thr)
        print(f"  WeSpeaker {name}={wethr} (FAR={far:.3f}) -> ERes2Net {er_thr:.3f} (FAR={er_far:.3f})")
    result["recommended_eres2net"]["within"] = within_rec

    # ---- ERes2Net operating-point grids (to pick safe final values) ----
    print("\n=== ERes2Net operating points (thr: FAR / FRR) ===")
    print("  CROSS-CALL:  ", "  ".join(
        f"{t:.2f}:{far_frr(er_s, er_d, t)[0]:.3f}/{far_frr(er_s, er_d, t)[1]:.3f}"
        for t in [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]))
    print("  WITHIN-MTG:  ", "  ".join(
        f"{t:.2f}:{far_frr(er_s2, er_d2, t)[0]:.3f}/{far_frr(er_s2, er_d2, t)[1]:.3f}"
        for t in [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]))
    result["eres2net_within_diff_p95"] = round(float(np.percentile(er_d2, 95)), 3)
    result["eres2net_within_same_median"] = round(float(np.median(er_s2)), 3)

    out = os.path.join(ROOT, "scripts", "out", "eres2net_calibration.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(result, open(out, "w"), indent=2)
    print(f"\n[ok] wrote {out}")
    print("\n=== RECOMMENDED ERes2Net thresholds (equal-FAR to WeSpeaker) ===")
    print("  match:", match_rec)
    print("  within:", within_rec)


if __name__ == "__main__":
    main()
