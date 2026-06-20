#!/usr/bin/env python3
"""Materialize loose per-meeting ICSI RTTMs from the HF `diarizers-community/icsi` dataset.

GATED: requires accepting the dataset terms on HuggingFace and authenticating
(`huggingface-cli login`, or HF_TOKEN env), plus `pip install datasets`.

The diarizers-community speaker-diarization datasets expose, per row (one meeting):
  - `timestamps_start` : list[float]
  - `timestamps_end`   : list[float]
  - `speakers`         : list[str]   (global ICSI speaker ids, recurring across meetings)
plus an `audio` column (which we ignore — audio comes from the Edinburgh mirror).

We emit standard SPEAKER-line RTTMs keyed by meeting id, matching the AMI scorer's
expectations (score_speaker_eval.py reads cols 4=start, 5=dur, 8=speaker).

Usage:
  python3 scripts/icsi_rttm_from_hf.py --out-dir data/icsi/rttm --meetings "Bmr001 Bro003"
  python3 scripts/icsi_rttm_from_hf.py --out-dir data/icsi/rttm   # all meetings in the dataset
"""
import argparse, os, sys


def meeting_id_of(row):
    """Best-effort meeting id from a dataset row (id/meeting/file/audio path)."""
    for k in ("id", "meeting_id", "meeting", "file", "filename", "name"):
        v = row.get(k)
        if isinstance(v, str) and v:
            return os.path.splitext(os.path.basename(v))[0]
    a = row.get("audio")
    if isinstance(a, dict) and a.get("path"):
        return os.path.splitext(os.path.basename(a["path"]))[0]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--meetings", default="", help="space-separated meeting ids; empty = all")
    ap.add_argument("--dataset", default="diarizers-community/icsi")
    ap.add_argument("--splits", default="train,validation,test")
    args = ap.parse_args()

    try:
        from datasets import load_dataset
    except Exception as e:
        print(f"error: `datasets` not installed ({e}); pip install datasets", file=sys.stderr)
        sys.exit(2)

    wanted = set(args.meetings.split()) if args.meetings.strip() else None
    os.makedirs(args.out_dir, exist_ok=True)
    written = 0

    for split in args.splits.split(","):
        split = split.strip()
        if not split:
            continue
        try:
            ds = load_dataset(args.dataset, split=split)
        except Exception as e:
            print(f"warn: split '{split}' unavailable ({e})", file=sys.stderr)
            continue
        # Avoid decoding audio bytes — we only need the timing columns.
        try:
            ds = ds.remove_columns([c for c in ds.column_names if c == "audio"])
        except Exception:
            pass
        for row in ds:
            mid = meeting_id_of(row)
            if mid is None:
                continue
            if wanted is not None and mid not in wanted:
                continue
            starts = row.get("timestamps_start") or []
            ends = row.get("timestamps_end") or []
            spks = row.get("speakers") or []
            n = min(len(starts), len(ends), len(spks))
            if n == 0:
                continue
            path = os.path.join(args.out_dir, f"{mid}.rttm")
            with open(path, "w") as f:
                for i in range(n):
                    s, e, spk = float(starts[i]), float(ends[i]), str(spks[i])
                    if e > s:
                        f.write(f"SPEAKER {mid} 1 {s:.3f} {e - s:.3f} <NA> <NA> {spk} <NA> <NA>\n")
            written += 1
            print(f"[icsi-rttm] {mid}: {n} segments -> {path}")

    print(f"[icsi-rttm] wrote {written} RTTM file(s) to {args.out_dir}")
    if written == 0:
        print("[icsi-rttm] nothing written — check HF auth/terms and meeting ids", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
