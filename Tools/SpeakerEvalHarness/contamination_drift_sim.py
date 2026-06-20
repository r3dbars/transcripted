#!/usr/bin/env python3
"""Contamination-drift simulation for the speaker-profile EMA write-back.

Models what the production write-back actually does on every cross-meeting match:

    SpeakerDatabase.addOrUpdateSpeakerImpl (SpeakerDatabase.swift:252)
        alpha = 0.15
        v' = l2normalize( (1 - alpha) * v_old + alpha * e_new )

This is a fixed-weight EMA (recent samples weighted more), NOT a 1/n running mean.
Match gate is cosine >= 0.6 (SpeakerDatabase.matchSpeaker, the production value).

Question (roadmap #6, the write-time contamination gate):
    How much does a profile's stored voiceprint drift when it absorbs a
    low-margin / under-segmented match (a sample that is actually a DIFFERENT
    person, or a correct-but-near-threshold sample) versus a clean same-person
    match?

No corpus or Swift toolchain is needed: this is a closed pure-Python numeric
model parameterized by the cosine bands MEASURED on real audio by the harness
(BASELINE_REPORT.md S4, AB_DOT_VS_CLOUD.md), so the inputs are grounded even
though the recurrence is synthetic. 256-dim to match WeSpeaker.

Deterministic (seeded). Pure stdlib; no numpy.
"""
import math, random

DIM = 256
ALPHA = 0.15          # production EMA new-sample weight (SpeakerDatabase.swift:252)
MATCH_THR = 0.6       # production cross-meeting match gate
SEED = 1729

# --- measured cosine bands (from the harness reports) ---
# Same-speaker (within) mean: AMI clean cluster pairs ~0.53; VoxCeleb within ~0.49 -> use 0.50.
# Different-speaker mean: AMI clean ~0.33; AMI VoIP ~0.36 (bands nearly collapse on VoIP).
W_CLEAN = 0.50        # within-speaker cosine, clean
D_CLEAN = 0.33        # between-speaker cosine, clean headset
D_VOIP = 0.36         # between-speaker cosine, compressed/VoIP (collapses toward within)


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def norm(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def rand_unit(rng):
    v = [rng.gauss(0, 1) for _ in range(DIM)]
    return norm(v)


def orthogonal_unit(rng, base):
    """Random unit vector orthogonal to `base`."""
    v = rand_unit(rng)
    p = dot(v, base)
    v = [x - p * b for x, b in zip(v, base)]
    return norm(v)


def at_cosine(rng, base, target_cos):
    """A unit vector whose cosine with `base` is exactly target_cos (random in the rest)."""
    o = orthogonal_unit(rng, base)
    s = max(-0.999, min(0.999, target_cos))
    v = [s * b + math.sqrt(1 - s * s) * x for b, x in zip(base, o)]
    return norm(v)


def speaker_sample(rng, centroid, within_cos):
    """A noisy sample of `centroid` whose expected cosine to the centroid ~ within_cos.

    Jitter direction is random in the subspace orthogonal to the centroid; the
    exact realized cosine wiggles around within_cos, like real per-utterance embeddings."""
    jitter = within_cos + rng.gauss(0, 0.07)
    return at_cosine(rng, centroid, jitter)


def ema_update(v, e):
    """Exact production write-back."""
    blended = [(1 - ALPHA) * o + ALPHA * n for o, n in zip(v, e)]
    return norm(blended)


def run_stream(rng, A, B, n_writes, contam_rate, contam_is_B, near_thr=False):
    """Start a profile at a clean A sample, absorb n_writes matched samples.

    contam_rate    : fraction of writes that are 'bad'
    contam_is_B    : if True, a bad write is actually speaker B (wrong person, under-seg);
                     if False, a bad write is a correct-A sample but near the 0.6 margin.
    near_thr       : clean (good) writes are drawn near the match threshold too.
    Returns (cos_to_A, cos_to_B, margin) of the final voiceprint.
    """
    v = speaker_sample(rng, A, W_CLEAN)        # profile created from first A sighting
    for _ in range(n_writes):
        bad = rng.random() < contam_rate
        if bad and contam_is_B:
            # a B utterance that slipped past the gate (fused cluster / false match);
            # draw it just above threshold so it is a plausible match, not an obvious one
            e = at_cosine(rng, B, max(W_CLEAN, MATCH_THR))
        elif bad and not contam_is_B:
            e = at_cosine(rng, A, MATCH_THR + 0.02)   # correct person, low margin
        else:
            e = speaker_sample(rng, A, MATCH_THR + 0.05 if near_thr else W_CLEAN)
        v = ema_update(v, e)
    cA, cB = dot(v, A), dot(v, B)
    return cA, cB, cA - cB


def writes_to_flip(rng, A, B, max_writes=200):
    """How many consecutive all-B (under-segmented) absorptions flip the profile's
    nearest identity from A to B (margin cos(v,A)-cos(v,B) crosses 0)."""
    v = speaker_sample(rng, A, W_CLEAN)
    for k in range(1, max_writes + 1):
        e = at_cosine(rng, B, max(W_CLEAN, MATCH_THR))
        v = ema_update(v, e)
        if dot(v, B) > dot(v, A):
            return k
    return None


def avg(xs):
    return sum(xs) / len(xs)


def closed_form_single_write(s):
    """cos(v, v') after one EMA write absorbing a sample at cosine s to v."""
    num = (1 - ALPHA) + ALPHA * s
    den = math.sqrt((1 - ALPHA) ** 2 + ALPHA ** 2 + 2 * ALPHA * (1 - ALPHA) * s)
    c = num / den
    return c, math.degrees(math.acos(min(1.0, c)))


def main():
    rng = random.Random(SEED)
    TRIALS = 400

    print(f"# Contamination-drift simulation  (alpha={ALPHA}, match_thr={MATCH_THR}, dim={DIM})")
    print(f"# measured bands: within={W_CLEAN}, between_clean={D_CLEAN}, between_voip={D_VOIP}")
    print(f"# trials={TRIALS}, seed={SEED}\n")

    print("## 1. Single-write drift (closed form): angle the voiceprint moves per write")
    print("| incoming sample cosine to voiceprint | cos(v,v') | drift angle |")
    print("|---|---|---|")
    for s in [1.0, 0.9, 0.7, 0.6, 0.5, 0.4, 0.3]:
        c, deg = closed_form_single_write(s)
        print(f"| {s:.2f} | {c:.4f} | {deg:.2f}deg |")
    print()

    for label, D in [("clean headset (between=0.33)", D_CLEAN),
                     ("compressed/VoIP (between=0.36)", D_VOIP)]:
        print(f"## 2. Cumulative drift after 10 writes -- {label}")
        print("| stream | cos(v,A_true) | cos(v,B) | margin A-B |")
        print("|---|---|---|---|")
        scenarios = [
            ("clean (all correct A)",            0.0, True,  False),
            ("low-margin but correct (all A@~0.6)", 1.0, False, False),
            ("under-seg 1-in-3 (B fused in)",    1.0 / 3, True, False),
            ("under-seg 1-in-2 (B fused in)",    0.5, True,  False),
            ("under-seg every write (B)",        1.0, True,  False),
        ]
        for name, rate, isB, nt in scenarios:
            cA = cB = mg = 0.0
            for t in range(TRIALS):
                r = random.Random(SEED * 7 + t)
                A = rand_unit(r)
                B = at_cosine(r, A, D)
                a, b, m = run_stream(r, A, B, 10, rate, isB, nt)
                cA += a; cB += b; mg += m
            print(f"| {name} | {cA/TRIALS:.3f} | {cB/TRIALS:.3f} | {mg/TRIALS:+.3f} |")
        print()

    print("## 3. Under-segmentation runaway: consecutive all-B absorptions to flip identity A->B")
    for label, D in [("clean headset", D_CLEAN), ("compressed/VoIP", D_VOIP)]:
        flips = []
        for t in range(TRIALS):
            r = random.Random(SEED * 13 + t)
            A = rand_unit(r)
            B = at_cosine(r, A, D)
            k = writes_to_flip(r, A, B)
            if k is not None:
                flips.append(k)
        if flips:
            print(f"- {label}: median {sorted(flips)[len(flips)//2]} writes, "
                  f"mean {avg(flips):.1f}, min {min(flips)}, max {max(flips)} "
                  f"({len(flips)}/{TRIALS} flipped within cap)")
        else:
            print(f"- {label}: never flipped within cap")
    print()


if __name__ == "__main__":
    main()
