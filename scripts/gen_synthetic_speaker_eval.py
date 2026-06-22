#!/usr/bin/env python3
"""Generate deterministic synthetic dumps + RTTMs for the SpeakerEvalHarness.

The real corpora (AMI/VoxCeleb) need multi-GB downloads + HuggingFace models, which aren't
available in every environment. The harness `replay` stage, however, only consumes per-segment
EMBEDDINGS (the expensive `dump` stage is already baked into the JSON) plus ground-truth RTTMs.

This script fabricates embeddings with *controlled cosine geometry* so the write-path fixes can be
A/B'd with `--write-path-fixes off|on` and scored on the real metrics (DER / fragmentation /
false-merge / cross-meeting re-ID). It is NOT a substitute for an AMI sweep — it is a reproducible,
network-free probe of the exact failure modes #6 and #8 target, plus a no-regression control.

Corpora produced under data/eval/synthetic/<name>/{dumps,rttm}:

  normal         — 5 well-separated speakers across 8 meetings, each voice drifting slightly
                   meeting-to-meeting. Control: the gate must NOT hurt DER/fragmentation/re-ID here
                   (proves no under-adaptation regression).
  twopeople      — profile P learned in M1; M2 has two DISTINCT people (B,C) who each resemble P
                   (~0.74) but not each other (~0.1). #8 should keep them apart (false-merge → 0).
  contamination  — target T (M1), attacker A (~0.71 to T) appears alone across M2..M8 repeatedly
                   blending into T's stored profile, then a third party D (0.66 to T, ~0.85 to A)
                   arrives in M9. Without #6 the drifted T-profile wrongly swallows D.

Embeddings are 256-D (matching the app) with the controlled geometry in the leading dims plus a
small deterministic orthogonal jitter per segment so a cluster mean lands back on its base vector.
"""
import argparse, json, math, os
import numpy as np

DIM = 256
RNG = np.random.default_rng(20260620)


def base_vector(coords):
    """Unit 256-D vector with `coords` in the leading dims, zeros elsewhere."""
    v = np.zeros(DIM, dtype=np.float64)
    v[: len(coords)] = coords
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def jitter(vec, scale=0.008):
    """Add small per-segment noise (deterministic via global RNG) and renormalize. Kept small so a
    cluster mean lands back on its base vector and the controlled cosine geometry is stable
    (std 0.008 over 256 dims ≈ 0.13 norm → per-segment cos≈0.99, cluster-mean cos≈0.999)."""
    noise = RNG.normal(0, scale, size=DIM)
    out = vec + noise
    return out / np.linalg.norm(out)


def vec_at_cos(theta_deg):
    """2-D plane unit vector at angle theta to the x-axis."""
    t = math.radians(theta_deg)
    return base_vector([math.cos(t), math.sin(t)])


def seg(speaker_local_id, start, dur, embedding, quality=0.75):
    return {
        "speakerId": speaker_local_id,
        "start": round(start, 3),
        "end": round(start + dur, 3),
        "quality": quality,
        "embedding": [float(x) for x in embedding],
    }


def write_meeting(out_dir, name, segments, rttm_rows):
    dumps = os.path.join(out_dir, "dumps")
    rttm = os.path.join(out_dir, "rttm")
    os.makedirs(dumps, exist_ok=True)
    os.makedirs(rttm, exist_ok=True)
    dur = max((s["end"] for s in segments), default=0.0)
    raw = {
        "meeting": name,
        "audioPath": f"synthetic://{name}",
        "durationSeconds": dur,
        "diarizerSpeakerCount": len({s["speakerId"] for s in segments}),
        "segments": segments,
    }
    with open(os.path.join(dumps, f"{name}.json"), "w") as f:
        json.dump(raw, f)
    with open(os.path.join(rttm, f"{name}.rttm"), "w") as f:
        for (start, dur_, label) in rttm_rows:
            f.write(f"SPEAKER {name} 1 {start:.3f} {dur_:.3f} <NA> <NA> {label} <NA> <NA>\n")


def build_speaker_block(local_id, global_label, base_vec, start, n_segs=4, seg_dur=3.0, gap=0.0):
    """A contiguous block of `n_segs` segments for one speaker; returns (segments, rttm_rows, end)."""
    segs, rows = [], []
    t = start
    for _ in range(n_segs):
        e = jitter(base_vec)
        segs.append(seg(local_id, t, seg_dur, e))
        rows.append((t, seg_dur, global_label))
        t += seg_dur + gap
    return segs, rows, t


def meeting_from(out_dir, name, present):
    """present: list of (global_label, base_vec) or (global_label, base_vec, n_segs).
    Each entry gets its own local diarizer id + a contiguous time block."""
    all_segs, all_rows, t = [], [], 0.0
    for local_id, entry in enumerate(present):
        label, vec = entry[0], entry[1]
        n_segs = entry[2] if len(entry) > 2 else 4
        segs, rows, t = build_speaker_block(local_id, label, vec, t, n_segs=n_segs)
        all_segs += segs
        all_rows += rows
        t += 2.0  # silence gap between speakers
    write_meeting(out_dir, name, all_segs, all_rows)


def gen_normal(root):
    out = os.path.join(root, "normal")
    # 5 speakers spread 72° apart in the plane (adjacent cos≈0.31 — well separated).
    speakers = {f"S{i}": vec_at_cos(i * 72.0) for i in range(5)}
    # 8 meetings; each meeting 2-3 speakers; voices drift a few degrees per meeting.
    schedule = [
        ["S0", "S1"], ["S1", "S2", "S3"], ["S0", "S2"], ["S3", "S4"],
        ["S0", "S1", "S4"], ["S2", "S4"], ["S0", "S3"], ["S1", "S2", "S4"],
    ]
    for mi, present in enumerate(schedule):
        drift = []
        for label in present:
            ang = (list("S0 S1 S2 S3 S4".split()).index(label)) * 72.0 + (mi * 1.5)
            drift.append((label, vec_at_cos(ang)))
        meeting_from(out, f"normal_M{mi+1:02d}", drift)
    return out


def gen_twopeople(root):
    out = os.path.join(root, "twopeople")
    # Realistic two-people-one-profile bug: X is learned in M1; in M2 X returns (dominant) AND a
    # distinct intruder Y also resembles X (~0.74) but is nothing like X's session… they're the same
    # *profile match*, different people. Y must NOT be silently fused into X's row.
    X = vec_at_cos(0.0)
    Y = vec_at_cos(42.3)                       # cos(Y,X)=0.74 (above the 0.70 attach floor)
    meeting_from(out, "twopeople_M01", [("X", X, 5)])                  # learn X
    meeting_from(out, "twopeople_M02", [("X", X, 5), ("Y", Y, 3)])     # X returns + intruder Y
    return out


def gen_contamination(root):
    out = os.path.join(root, "contamination")
    T = base_vector([1, 0, 0])
    A = base_vector([0.71, 0.7042, 0.0])                 # cos(A,T)=0.71
    # D: cos(D,T)=0.66, cos(D,A)=0.85 — a distinct 3rd party close to A, not to clean T.
    d0 = 0.66
    d1 = (0.85 - 0.71 * d0) / 0.7042
    d2 = math.sqrt(max(0.0, 1 - d0 * d0 - d1 * d1))
    D = base_vector([d0, d1, d2])
    meeting_from(out, "contam_M01", [("T", T)])               # learn T
    for k in range(2, 9):                                     # M2..M8: attacker A alone, repeatedly
        meeting_from(out, f"contam_M{k:02d}", [("A", A)])
    meeting_from(out, "contam_M09", [("D", D)])               # 3rd party arrives
    meeting_from(out, "contam_M10", [("T", T)])               # target returns
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="data/eval/synthetic")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    for fn in (gen_normal, gen_twopeople, gen_contamination):
        path = fn(args.out)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
