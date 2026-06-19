#!/usr/bin/env python3
"""build_voxceleb_singles.py — assemble the VoxCeleb "clean domain" ladder substrate.

Each VoxCeleb utterance becomes ONE single-speaker pseudo-meeting (the `singles` model
from scripts/build_voxceleb_sessions.py): identity-in-filename is the ground-truth
speaker, the whole clip is one RTTM SPEAKER line. Clips are emitted ROUND-ROBIN across
identities, so the lexicographically-sorted meeting order (which run_dumps.sh / the
fingerprint stage walk in) interleaves each person's clips across the run — exactly the
chronological "this person keeps showing up across meetings" recurrence the ladder needs.

Source: the LOCAL HuggingFace cache for s3prl/mini_voxceleb1 (no network, no login).
Each clip is already 16 kHz mono Int16. We SYMLINK audio (no copy) and synthesize RTTM.

Output (matches run_speaker_eval.sh voxceleb convention):
  data/voxceleb/sessions/audio/m{NNNN}_{id}.wav   (symlink to cache)
  data/voxceleb/sessions/rttm/m{NNNN}_{id}.rttm    (single SPEAKER line, speaker=<id>)

Env knobs (logged, never silent):
  VOXCELEB_IDENTITY_CAP  (default 30)  max distinct identities
  VOXCELEB_CLIPS_PER_ID  (default 20)  max clips per identity  -> meetings = cap*clips
  VOXCELEB_CACHE         (default auto-detected mini_voxceleb1 snapshot dir)
"""
import os, re, sys, wave, glob, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "voxceleb" / "sessions"
AUDIO_OUT = OUT / "audio"
RTTM_OUT = OUT / "rttm"

ID_CAP = int(os.environ.get("VOXCELEB_IDENTITY_CAP", "30"))
CLIPS_PER_ID = int(os.environ.get("VOXCELEB_CLIPS_PER_ID", "20"))

def find_cache():
    env = os.environ.get("VOXCELEB_CACHE")
    if env:
        return Path(env)
    base = Path.home() / ".cache/huggingface/hub/datasets--s3prl--mini_voxceleb1/snapshots"
    snaps = sorted(base.glob("*")) if base.exists() else []
    if not snaps:
        sys.exit(f"no mini_voxceleb1 cache under {base}; set VOXCELEB_CACHE")
    return snaps[-1]

def clip_duration(path):
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / float(w.getframerate())

def main():
    cache = find_cache()
    wavs = sorted(glob.glob(str(cache / "**" / "*.wav"), recursive=True))
    if not wavs:
        sys.exit(f"no wavs under {cache}")
    pat = re.compile(r"(id\d+)")
    by_id = {}
    for w in wavs:
        m = pat.search(os.path.basename(w))
        if not m:
            continue
        by_id.setdefault(m.group(1), []).append(w)
    ids = sorted(by_id)[:ID_CAP]
    for i in ids:
        by_id[i] = sorted(by_id[i])[:CLIPS_PER_ID]

    total_avail = sum(len(v) for v in by_id.values())
    # Round-robin interleave: meeting k draws from identity (k % len(ids)).
    queues = {i: list(by_id[i]) for i in ids}
    order = []
    while any(queues[i] for i in ids):
        for i in ids:
            if queues[i]:
                order.append((i, queues[i].pop(0)))

    AUDIO_OUT.mkdir(parents=True, exist_ok=True)
    RTTM_OUT.mkdir(parents=True, exist_ok=True)
    # clean stale outputs so re-runs are deterministic
    for p in list(AUDIO_OUT.glob("*.wav")) + list(RTTM_OUT.glob("*.rttm")):
        p.unlink()

    n = 0
    for (ident, src) in order:
        tag = f"m{n:04d}_{ident}"
        dst = AUDIO_OUT / f"{tag}.wav"
        try:
            dst.symlink_to(src)
        except FileExistsError:
            dst.unlink(); dst.symlink_to(src)
        dur = clip_duration(src)
        # RTTM: <type> <file> <chan> <start> <dur> <ortho> <stype> <name> <conf> <slat>
        (RTTM_OUT / f"{tag}.rttm").write_text(
            f"SPEAKER {tag} 1 0.000 {dur:.3f} <NA> <NA> {ident} <NA> <NA>\n")
        n += 1

    meta = {
        "corpus": "voxceleb",
        "model": "singles",
        "source_cache": str(cache),
        "identities": len(ids),
        "clips_per_id_cap": CLIPS_PER_ID,
        "identity_cap": ID_CAP,
        "meetings_emitted": n,
        "clips_available_after_cap": total_avail,
        "order": "round-robin across identities",
    }
    (OUT / "build_meta.json").write_text(json.dumps(meta, indent=2))
    print(json.dumps(meta, indent=2))
    print(f"[voxceleb-singles] wrote {n} single-speaker meetings -> {AUDIO_OUT}")

if __name__ == "__main__":
    main()
