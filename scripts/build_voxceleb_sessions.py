#!/usr/bin/env python3
"""Build synthetic multi-identity "sessions" (WAV + ground-truth RTTM) from sampled
VoxCeleb identities, for the cross-recording re-ID / false-positive test.

Why synthetic sessions: VoxCeleb gives many short single-speaker clips per identity but no
multi-speaker recordings. We stitch clips from several identities into conversational
sessions and emit an exact RTTM (we know who speaks when). Sessions are constructed so that:

  * the SAME identities RECUR across sessions, using DIFFERENT clips each time
    -> measures cross-recording re-ID (does the DB re-identify a person from new audio?).
  * MANY distinct identities appear overall, and within a session each identity is a
    different person -> measures false-merge / false-positive (does the DB wrongly fuse
    two different people into one profile?).

Deterministic (no RNG): identity pools slide over the sorted id list with overlap; clip
choice is round-robin per identity, so re-appearances use fresh audio.

Output:
  data/voxceleb/sessions/audio/sess000.wav ...
  data/voxceleb/sessions/rttm/sess000.rttm ...

Requires ffmpeg + ffprobe (audio concat + duration probing).

Usage:
  python3 scripts/build_voxceleb_sessions.py --raw-dir data/voxceleb/raw \
      --out-dir data/voxceleb/sessions \
      --num-sessions 20 --speakers-per-session 4 --clips-per-speaker 3 --gap 0.3
"""
import argparse, json, os, shutil, subprocess, sys, tempfile


def ffprobe_duration(path):
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path], text=True).strip()
    return float(out)


def normalize(src, dst, sr):
    subprocess.check_call(
        ["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", str(sr),
         "-c:a", "pcm_s16le", dst])


def make_silence(path, sr, dur):
    subprocess.check_call(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-t", f"{dur}",
         "-i", f"anullsrc=r={sr}:cl=mono", "-c:a", "pcm_s16le", path])


def build_singles(ids, clips, raw_dir, out_dir, sr):
    """One clip = one single-speaker 'meeting'. The diarizer trivially sees one clean
    voice (no within-session mixing to confound it), so the eval isolates the DB matcher:
    does it keep N people as N profiles, re-identify each across their clips, and never
    fuse two different people? This is the clean cross-recording re-ID / false-positive
    test. Meetings are emitted round-robin across identities so sorted replay order
    interleaves them (each identity's appearances spread across the run)."""
    audio_dir = os.path.join(out_dir, "audio")
    rttm_dir = os.path.join(out_dir, "rttm")
    os.makedirs(audio_dir, exist_ok=True)
    os.makedirs(rttm_dir, exist_ok=True)
    cursor = {s: 0 for s in ids}
    remaining = sum(len(clips[s]) for s in ids)
    n = 0
    appear = {}
    while remaining > 0:
        for spk in ids:
            i = cursor[spk]
            if i >= len(clips[spk]):
                continue
            cursor[spk] += 1
            remaining -= 1
            src = os.path.join(raw_dir, spk, clips[spk][i])
            mid = f"m{n:04d}_{spk}"
            dst = os.path.join(audio_dir, f"{mid}.wav")
            try:
                normalize(src, dst, sr)
                dur = ffprobe_duration(dst)
            except subprocess.CalledProcessError:
                continue
            with open(os.path.join(rttm_dir, f"{mid}.rttm"), "w") as f:
                f.write(f"SPEAKER {mid} 1 0.000 {dur:.3f} <NA> <NA> {spk} <NA> <NA>\n")
            appear[spk] = appear.get(spk, 0) + 1
            n += 1
    print(json.dumps({"mode": "singles", "meetings": n, "distinct_identities": len(appear),
                      "clips_per_identity": appear}, indent=2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw-dir", required=True, help="data/voxceleb/raw/<spk>/*.wav")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--mode", choices=["sessions", "singles"], default="sessions",
                    help="sessions = stitched multi-speaker (stresses diarizer too); "
                         "singles = one clip/meeting (isolates the DB matcher — clean re-ID/false-positive)")
    ap.add_argument("--num-sessions", type=int, default=20)
    ap.add_argument("--speakers-per-session", type=int, default=4)
    ap.add_argument("--clips-per-speaker", type=int, default=3)
    ap.add_argument("--gap", type=float, default=0.3, help="silence (s) between turns")
    ap.add_argument("--sr", type=int, default=16000)
    args = ap.parse_args()

    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        print("error: ffmpeg + ffprobe required", file=sys.stderr); sys.exit(2)

    ids = sorted(d for d in os.listdir(args.raw_dir)
                 if os.path.isdir(os.path.join(args.raw_dir, d)))
    clips = {s: sorted(f for f in os.listdir(os.path.join(args.raw_dir, s))
                       if f.lower().endswith(".wav")) for s in ids}
    ids = [s for s in ids if clips[s]]

    if args.mode == "singles":
        if len(ids) < 2:
            print(f"error: only {len(ids)} identities; need >= 2", file=sys.stderr); sys.exit(1)
        build_singles(ids, clips, args.raw_dir, args.out_dir, args.sr)
        return

    spk_n = args.speakers_per_session
    if len(ids) < spk_n:
        print(f"error: only {len(ids)} identities; need >= {spk_n}", file=sys.stderr); sys.exit(1)

    audio_dir = os.path.join(args.out_dir, "audio")
    rttm_dir = os.path.join(args.out_dir, "rttm")
    os.makedirs(audio_dir, exist_ok=True)
    os.makedirs(rttm_dir, exist_ok=True)

    overlap = max(1, spk_n // 2)         # consecutive sessions share `overlap` identities
    stride = max(1, spk_n - overlap)
    clip_cursor = {s: 0 for s in ids}    # round-robin clip pointer per identity

    for si in range(args.num_sessions):
        start = (si * stride) % len(ids)
        session_ids = [ids[(start + j) % len(ids)] for j in range(spk_n)]
        mid = f"sess{si:03d}"
        tmp = tempfile.mkdtemp(prefix=f"voxsess_{mid}_")
        sil = os.path.join(tmp, "sil.wav")
        make_silence(sil, args.sr, args.gap)

        concat_lines, rttm_lines = [], []
        t = 0.0
        # interleave: round-robin one clip per speaker per turn
        for turn in range(args.clips_per_speaker):
            for spk in session_ids:
                cl = clips[spk]
                c = cl[clip_cursor[spk] % len(cl)]
                clip_cursor[spk] += 1
                src = os.path.join(args.raw_dir, spk, c)
                norm = os.path.join(tmp, f"{spk}_{turn}.wav")
                try:
                    normalize(src, norm, args.sr)
                    dur = ffprobe_duration(norm)
                except subprocess.CalledProcessError:
                    continue
                concat_lines.append(f"file '{norm}'")
                rttm_lines.append(
                    f"SPEAKER {mid} 1 {t:.3f} {dur:.3f} <NA> <NA> {spk} <NA> <NA>")
                t += dur
                concat_lines.append(f"file '{sil}'")
                t += args.gap

        listing = os.path.join(tmp, "list.txt")
        with open(listing, "w") as f:
            f.write("\n".join(concat_lines) + "\n")
        out_wav = os.path.join(audio_dir, f"{mid}.wav")
        subprocess.check_call(
            ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0",
             "-i", listing, "-c:a", "pcm_s16le", out_wav])
        with open(os.path.join(rttm_dir, f"{mid}.rttm"), "w") as f:
            f.write("\n".join(rttm_lines) + "\n")
        shutil.rmtree(tmp, ignore_errors=True)
        print(f"[voxsess] {mid}: {spk_n} ids {session_ids} -> {t:.1f}s")

    # recurrence summary
    appear = {}
    for si in range(args.num_sessions):
        start = (si * stride) % len(ids)
        for j in range(spk_n):
            s = ids[(start + j) % len(ids)]
            appear[s] = appear.get(s, 0) + 1
    recurring = sum(1 for v in appear.values() if v >= 2)
    print(json.dumps({
        "sessions": args.num_sessions, "distinct_identities": len(appear),
        "recurring_identities(>=2 sessions)": recurring,
        "max_appearances": max(appear.values()) if appear else 0,
    }, indent=2))


if __name__ == "__main__":
    main()
