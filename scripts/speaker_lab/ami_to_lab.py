#!/usr/bin/env python3
"""Turn downloaded AMI meetings (scripts/download_ami.sh) into a speaker-lab set.

Real recorded meetings with a human-labeled answer key: each AMI Mix-Headset
recording becomes a meeting's call channel (system.wav), with a near-silent mic
track, the RTTM as truth.json, and a calendar invite listing the meeting's people.
Meetings are ordered series by series (sessions a-d), one shared speaker database,
so the same 4 people recur across their 4 sessions: real cross-session voice change
for the naming tests. AMI is research-use only: the set stays under data/ (gitignored).

  data/eval/yodas3/venv/bin/python scripts/speaker_lab/ami_to_lab.py --set ami-lab
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from collections import defaultdict
from pathlib import Path

import numpy as np
import soundfile as sf

REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get("YODAS_ROOT", REPO_ROOT / "data" / "eval" / "yodas3"))
AMI = REPO_ROOT / "data" / "ami"
FIRST = ["Alex", "Blair", "Casey", "Drew", "Emery", "Finley", "Gray", "Harper", "Indy", "Jules", "Kai", "Lane",
         "Morgan", "Noel", "Oakley", "Parker", "Quinn", "Reese", "Sage", "Tatum", "Val", "Wren", "Yael", "Zion"]
LAST = ["Abbott", "Brooks", "Carver", "Dalton", "Ellis", "Frost", "Garner", "Hayes", "Irving", "Jensen", "Keller",
        "Lowe", "Mercer", "Nash", "Ortega", "Pryor", "Quill", "Ramsey", "Sutton", "Talbot", "Underwood", "Vance"]


def fake_name(speaker: str) -> str:
    h = int(hashlib.sha256(speaker.encode()).hexdigest(), 16)
    return f"{FIRST[h % len(FIRST)]} {LAST[(h // 97) % len(LAST)]}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", default="ami-lab")
    args = ap.parse_args()
    out = ROOT / "sim" / args.set
    out.mkdir(parents=True, exist_ok=True)
    meetings = sorted(p.name.split(".")[0] for p in (AMI / "audio").glob("*.Mix-Headset.wav"))
    series = {"set": args.set, "meetings": [], "source": "AMI Meeting Corpus (research use), pyannote only_words RTTMs"}
    names_used: dict[str, str] = {}
    for m in meetings:
        rttm = AMI / "rttm" / f"{m}.rttm"
        wav = AMI / "audio" / f"{m}.Mix-Headset.wav"
        if not rttm.exists() or wav.stat().st_size < 1000:
            continue
        segs = []
        for line in open(rttm):
            f = line.split()
            if len(f) >= 8 and f[0] == "SPEAKER":
                start, dur, spk = float(f[3]), float(f[4]), f[7]
                segs.append({"pid": spk, "start": round(start, 3), "end": round(start + dur, 3), "kind": "turn"})
        if not segs:
            continue
        info = sf.info(str(wav))
        d = out / m
        d.mkdir(exist_ok=True)
        system = d / "system.wav"
        if not system.exists():
            os.symlink(wav.resolve(), system)
        mic = d / "mic.wav"
        if not mic.exists():
            n = int(info.duration * 16000)
            rng = np.random.default_rng(len(m))
            sf.write(mic, (rng.standard_normal(n) * 10 ** (-70 / 20)).astype(np.float32), 16000, subtype="PCM_16")
        talk = defaultdict(float)
        for s in segs:
            talk[s["pid"]] += s["end"] - s["start"]
        people = sorted(talk)
        for p in people:
            names_used.setdefault(p, fake_name(p))
        truth = {
            "meeting": m, "family": "AMI", "duration_s": round(info.duration, 2), "split_local_speakers": False,
            "participants": [{"pid": "you", "identity": "you", "name": "You", "role": "you", "channel": "mic",
                              "talk_s": 0.0}]
            + [{"pid": p, "identity": p, "name": names_used[p], "role": "remote", "channel": "system",
                "talk_s": round(talk[p], 1)} for p in people],
            "segments": sorted(segs, key=lambda s: s["start"]),
            "words": [],
        }
        json.dump(truth, open(d / "truth.json", "w"), indent=1)
        invitees = [{"name": names_used[p], "email": names_used[p].lower().replace(" ", ".") + "@example.com",
                     "is_person": True, "pid": p} for p in people]
        json.dump({"invitees": invitees, "crasher_pid": None, "note": "every AMI attendee invited"},
                  open(d / "calendar.json", "w"), indent=1)
        series["meetings"].append({"id": m, "family": "AMI", "split_local_speakers": False, "fresh_db": False,
                                   "title": m})
    series["cast"] = sorted(names_used)
    json.dump(series, open(out / "series.json", "w"), indent=1)
    print(f"[ami] {len(series['meetings'])} meetings, {len(names_used)} people -> {out}")


if __name__ == "__main__":
    main()
