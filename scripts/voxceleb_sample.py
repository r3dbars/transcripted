#!/usr/bin/env python3
"""SAMPLE-ONLY VoxCeleb1 identity sampler with a HARD CAP.

VoxCeleb1 (CC-BY-SA 4.0, https://www.robots.ox.ac.uk/~vgg/data/voxceleb/) is huge
(~1200 identities / ~150k clips / ~30 GB). We NEVER pull all of it. Instead we STREAM a
HuggingFace VoxCeleb1 mirror and stop as soon as we have `--identity-cap` distinct
speakers, each with up to `--clips-per-id` clips. Streaming means the wire footprint is
bounded by (cap × clips × ~clip-size), not the full corpus.

Needs `pip install datasets` + `ffmpeg` on PATH (audio is read via fsspec and transcoded
by ffmpeg — no torch/soundfile/torchcodec needed). The default mirror `s3prl/mini_voxceleb1`
is PUBLIC (no HF login). Larger mirrors may be access-gated (`huggingface-cli login` /
HF_TOKEN + accept terms); point `--dataset` at one to scale past mini's identity count.

Speaker id comes from the dataset's speaker column if populated, else from the VoxCeleb
filename convention (`id10012-<video>-00001.wav` -> `id10012`).

Output layout (16 kHz mono WAV, the app's target rate):
  data/voxceleb/raw/<speaker_id>/<clip_index>.wav

Usage:
  python3 scripts/voxceleb_sample.py --out-dir data/voxceleb/raw \
      --identity-cap 300 --clips-per-id 10 --dataset s3prl/mini_voxceleb1
"""
import argparse, os, sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--identity-cap", type=int, default=300,
                    help="HARD CAP on distinct identities (default 300). Never pull all of VoxCeleb.")
    ap.add_argument("--clips-per-id", type=int, default=10, help="max clips kept per identity")
    ap.add_argument("--dataset", default="s3prl/mini_voxceleb1",
                    help="HF VoxCeleb1 mirror exposing per-clip audio (public default; "
                         "swap for a larger/gated mirror to exceed mini's identity count)")
    ap.add_argument("--split", default="train")
    ap.add_argument("--sr", type=int, default=16000)
    args = ap.parse_args()

    if args.identity_cap <= 0 or args.identity_cap > 1211:
        print(f"refusing identity-cap={args.identity_cap}: must be 1..1211 (VoxCeleb1 size). "
              "This is a SAMPLE-only tool.", file=sys.stderr)
        sys.exit(2)

    try:
        from datasets import load_dataset, Audio
    except Exception as e:
        print(f"error: needs `datasets` ({e}); pip install datasets", file=sys.stderr)
        sys.exit(2)
    import shutil, subprocess, tempfile
    if not shutil.which("ffmpeg"):
        print("error: ffmpeg required to transcode clips", file=sys.stderr)
        sys.exit(2)

    print(f"[voxceleb] STREAMING {args.dataset}:{args.split} — cap {args.identity_cap} ids "
          f"× {args.clips_per_id} clips (hard cap; not pulling the full corpus)")
    ds = load_dataset(args.dataset, split=args.split, streaming=True)
    # Disable HF audio decoding (datasets 4.x needs torchcodec to decode arrays). We grab
    # the raw encoded bytes/path instead and let ffmpeg transcode to 16 kHz mono — no
    # torch/soundfile dependency, and robust across mirrors.
    audio_col = "audio" if "audio" in (ds.column_names or []) else None
    if audio_col:
        ds = ds.cast_column(audio_col, Audio(decode=False))

    import re
    try:
        import fsspec
    except Exception:
        fsspec = None

    def speaker_of(row, audio):
        # 1) an explicit speaker column, if populated
        for k in ("speaker", "speaker_id", "client_id", "speaker_label", "label", "id"):
            v = row.get(k)
            if v is not None and str(v) != "":
                return str(v)
        # 2) VoxCeleb encodes the speaker in the filename: id10012-<video>-00001.wav
        path = audio.get("path") if isinstance(audio, dict) else None
        if path:
            base = os.path.basename(path)
            m = re.match(r"(id\d+)", base)
            if m:
                return m.group(1)
            # else fall back to the leading path segment
            parts = base.split("-")
            if parts:
                return parts[0]
        return None

    def write_clip(audio, dst, sr):
        """audio is {'bytes':..,'path':..} (decode=False). Read bytes (local, or hf://
        via fsspec) and transcode to 16 kHz mono WAV with ffmpeg."""
        src, tmp = None, None
        if isinstance(audio, dict):
            data = audio.get("bytes")
            path = audio.get("path")
            if not data and path and "://" in path and fsspec is not None:
                try:
                    with fsspec.open(path, "rb") as f:
                        data = f.read()
                except Exception:
                    data = None
            if data:
                tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".bin")
                tmp.write(data); tmp.close(); src = tmp.name
            elif path and "://" not in path:
                src = path
        if not src:
            return False
        try:
            subprocess.check_call(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1",
                                   "-ar", str(sr), "-c:a", "pcm_s16le", dst],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except subprocess.CalledProcessError:
            return False
        finally:
            if tmp:
                os.unlink(tmp.name)

    kept = {}            # speaker -> count kept
    os.makedirs(args.out_dir, exist_ok=True)
    total = 0
    for row in ds:
        audio = row.get(audio_col) if audio_col else None
        spk = speaker_of(row, audio)
        if spk is None:
            continue
        if spk not in kept and len(kept) >= args.identity_cap:
            # cap reached for new identities; only top up identities we already have
            if all(c >= args.clips_per_id for c in kept.values()):
                break
            continue
        if kept.get(spk, 0) >= args.clips_per_id:
            continue
        d = os.path.join(args.out_dir, spk)
        os.makedirs(d, exist_ok=True)
        idx = kept.get(spk, 0)
        if not write_clip(row.get(audio_col), os.path.join(d, f"{idx:03d}.wav"), args.sr):
            continue
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
