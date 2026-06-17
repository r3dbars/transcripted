#!/usr/bin/env python3
"""Mean-center the embeddings in a set of cached dumps, then write new dumps the harness
can replay through the REAL matcher (measurement only — no app code touched).

The codec-coloration finding (AMI_CODEC_REID_REPORT §3) showed compression injects a single
shared bias direction into every embedding, inflating all cosines and collapsing the
matcher's ability to separate strangers. Subtracting that shared direction restored the
embedding-band separation. This script applies the subtraction to the per-segment
embeddings in the dump so we can measure whether it fixes the DOWNSTREAM matcher metrics
(profiles_end, false-merge, re-ID) — not just the bands.

Modes (what centroid is subtracted from each segment):
  normonly     control: just L2-normalize each segment, subtract nothing. Isolates the
               effect of unit-normalizing from the effect of centering.
  global       subtract the mean of ALL normalized segment embeddings in the arm (oracle:
               needs all the audio; an upper bound).
  per_meeting  subtract each meeting's own mean (per-session centering).
  running      subtract a causal EMA of normalized embeddings seen so far, in replay order
               (online / production-deployable; estimates the bias without future audio).
  frozen       estimate the centroid from the FIRST meeting's segments ONLY, then freeze it
               and subtract it from every meeting (including the first). A causal one-time
               per-source calibration: deployable as "warm up on the opening minutes, then
               hold the codec-bias estimate fixed". Uses no future audio beyond meeting 1.

All output embeddings are L2-normalized. Every other dump field is preserved verbatim, so
the only thing that changes in the replay is the embeddings.
"""
import argparse, glob, json, os


def l2(v):
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v] if n else list(v)


def sub_norm(e, c):
    return l2([a - b for a, b in zip(e, c)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-dumps", required=True)
    ap.add_argument("--out-dumps", required=True)
    ap.add_argument("--mode", required=True, choices=["normonly", "global", "per_meeting", "running", "frozen"])
    ap.add_argument("--alpha", type=float, default=0.05, help="running-EMA rate")
    args = ap.parse_args()
    os.makedirs(args.out_dumps, exist_ok=True)

    files = sorted(glob.glob(os.path.join(args.in_dumps, "*.json")))  # sorted = replay order
    dim = None
    # global centroid (mean of all normalized segment embeddings)
    if args.mode == "global":
        acc = None; n = 0
        for f in files:
            for s in json.load(open(f))["segments"]:
                e = l2(s["embedding"]); dim = len(e)
                acc = e if acc is None else [a + b for a, b in zip(acc, e)]
                n += 1
        gcent = [a / n for a in acc] if n else None

    # frozen centroid: mean of ONLY the first meeting's normalized segment embeddings
    if args.mode == "frozen":
        acc = None; n = 0
        if files:
            for s in json.load(open(files[0]))["segments"]:
                e = l2(s["embedding"]); dim = len(e)
                acc = e if acc is None else [a + b for a, b in zip(acc, e)]
                n += 1
        fcent = [a / n for a in acc] if n else None

    run = None  # running EMA state
    for f in files:
        d = json.load(open(f))
        segs = sorted(d["segments"], key=lambda s: s["start"])
        if args.mode == "per_meeting":
            acc = None; n = 0
            for s in segs:
                e = l2(s["embedding"]); acc = e if acc is None else [a + b for a, b in zip(acc, e)]; n += 1
            cent = [a / n for a in acc] if n else None
        out = []
        for s in segs:
            e = l2(s["embedding"])
            if args.mode == "normonly":
                ec = e
            elif args.mode == "global":
                ec = sub_norm(e, gcent)
            elif args.mode == "per_meeting":
                ec = sub_norm(e, cent)
            elif args.mode == "frozen":
                ec = sub_norm(e, fcent) if fcent else e
            else:  # running
                if run is None:
                    run = list(e)            # warm-start
                    ec = e                    # nothing to subtract yet
                else:
                    ec = sub_norm(e, run)
                run = [(1 - args.alpha) * r + args.alpha * x for r, x in zip(run, e)]
            ns = dict(s); ns["embedding"] = ec
            out.append(ns)
        d["segments"] = out
        json.dump(d, open(os.path.join(args.out_dumps, os.path.basename(f)), "w"))
    print(f"[center] {args.mode}: wrote {len(files)} dumps -> {args.out_dumps}")


if __name__ == "__main__":
    main()
