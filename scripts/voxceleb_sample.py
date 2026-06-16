#!/usr/bin/env python3
"""SAMPLE-ONLY VoxCeleb1 identity sampler with a HARD CAP.

VoxCeleb1 (CC-BY-SA 4.0, https://www.robots.ox.ac.uk/~vgg/data/voxceleb/) is huge
(~1200 identities / ~150k clips / ~30 GB). We NEVER pull all of it. Instead we STREAM a
HuggingFace VoxCeleb1 mirror and stop as soon as we have `--identity-cap` distinct
speakers, each with up to `--clips-per-id` clips. Streaming means the wire footprint is
bounded by (cap × clips × ~clip-size), not the full corpus.

GATED: VoxCeleb on HF is usually access-gated — needs `huggingface-cli login` (or HF_TOKEN)
and accepting the dataset terms, plus `pip install datasets soundfile`.

Output layout (16 kHz mono WAV, the app's target rate):
  data/voxceleb/raw/<speaker_id>/<clip_index>.wav

Usage:
  python3 scripts/voxceleb_sample.py --out-dir data/voxceleb/raw \
      --identity-cap 300 --clips-per-id 10
"""
import argparse, os, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--identity-cap", type=int, default=300,
                    help="HARD CAP on distinct identities (default 300). Never pull all of VoxCeleb.")
    ap.add_argument("--clips-per-id", type=int, default=10, help="max clips kept per identity")
    ap.add_argument("--dataset", default="confit/voxceleb1",
                    help="HF VoxCeleb1 mirror exposing per-clip audio + speaker label")
    ap.add_argument("--split", default="train")
    ap.add_argument("--sr", type=int, default=16000)
    args = ap.parse_args()

    if args.identity_cap <= 0 or args.identity_cap > 1211:
        print(f"refusing identity-cap={args.identity_cap}: must be 1..1211 (VoxCeleb1 size). "
              "This is a SAMPLE-only tool.", file=sys.stderr)
        sys.exit(2)

    try:
        from datasets import load_dataset
        import soundfile as sf
        import numpy as np
    except Exception as e:
        print(f"error: needs `datasets` + `soundfile` ({e}); pip install datasets soundfile",
              file=sys.stderr)
        sys.exit(2)

    print(f"[voxceleb] STREAMING {args.dataset}:{args.split} — cap {args.identity_cap} ids "
          f"× {args.clips_per_id} clips (hard cap; not pulling the full corpus)")
    ds = load_dataset(args.dataset, split=args.split, streaming=True)

    def speaker_of(row):
        for k in ("speaker", "speaker_id", "label", "id", "client_id"):
            v = row.get(k)
            if v is not None:
                return str(v)
        return None

    kept = {}            # speaker -> count kept
    os.makedirs(args.out_dir, exist_ok=True)
    total = 0
    for row in ds:
        spk = speaker_of(row)
        if spk is None:
            continue
        if spk not in kept and len(kept) >= args.identity_cap:
            # cap reached for new identities; only top up identities we already have
            if all(c >= args.clips_per_id for c in kept.values()):
                break
            continue
        if kept.get(spk, 0) >= args.clips_per_id:
            continue
        audio = row.get("audio")
        if not isinstance(audio, dict) or "array" not in audio:
            continue
        arr = np.asarray(audio["array"], dtype="float32")
        sr = int(audio.get("sampling_rate", args.sr))
        d = os.path.join(args.out_dir, spk)
        os.makedirs(d, exist_ok=True)
        idx = kept.get(spk, 0)
        sf.write(os.path.join(d, f"{idx:03d}.wav"), arr, sr)
        kept[spk] = idx + 1
        total += 1
        if total % 100 == 0:
            print(f"[voxceleb] {len(kept)} ids, {total} clips...")

    print(f"[voxceleb] done: {len(kept)} identities, {total} clips -> {args.out_dir}")
    if not kept:
        print("[voxceleb] nothing sampled — check HF auth/terms and dataset schema", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
