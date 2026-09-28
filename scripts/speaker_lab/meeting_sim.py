#!/usr/bin/env python3
"""Simulate Transcripted meetings from the YODAS3 voice bank, with an answer key.

Each meeting is two files, shaped like a real Transcripted capture:
  mic.wav     you (and anyone sharing your room), through a simulated room
  system.wav  everyone on the call, each through their own simulated device
              (band limit + real Opus encode/decode at call bitrates)
plus
  truth.json     who spoke when, on which channel, with which words
  calendar.json  a fake invite: the truth with realistic noise (no-shows,
                 uninvited guests, nicknames, email-only invitees)

Scenario families (see Tools/SpeakerEvalHarness/YODAS_LAB_PLAN.md):
  A  1:1 remote call              B  3-4 remote             C  6-8 remote
  D  2-3 sharing your mic + 2-4 remote (local speaker split on)
  E  stress: sound-alikes, heavy overlap, device switch mid-call, long monologues

  data/eval/yodas3/venv/bin/python scripts/speaker_lab/meeting_sim.py \
      --family A --count 20 --set p0-A

Output: data/eval/yodas3/sim/<set>/<meeting>/..., plus <set>/series.json.
"""
from __future__ import annotations

import argparse
import io
import json
import os
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import soundfile as sf

REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get("YODAS_ROOT", REPO_ROOT / "data" / "eval" / "yodas3"))
SR = 16000
BACKCHANNELS = {"yeah", "yes", "right", "okay", "ok", "mhm", "mm", "sure", "exactly", "wow",
                "no", "yep", "totally", "true", "absolutely", "cool", "nice", "uh-huh", "hmm"}

FIRST = ["Taylor", "Jordan", "Priya", "Marcus", "Elena", "Kenji", "Aisha", "Diego", "Hannah", "Omar",
         "Grace", "Mateo", "Leah", "Ravi", "Chloe", "Samuel", "Nina", "Tomas", "Ava", "Kwame",
         "Sofia", "Ethan", "Mei", "Lucas", "Zara", "Noah", "Fatima", "Oliver", "Ines", "Caleb",
         "Yuki", "Isaac", "Maya", "Andre", "Lena", "Victor", "Amara", "Felix", "Rosa", "Julian",
         "Robert", "William", "Katherine", "Alexander", "Elizabeth", "Michael", "Samantha", "Daniel"]
LAST = ["Lee", "Patel", "Nguyen", "Garcia", "Okafor", "Smith", "Kim", "Rossi", "Cohen", "Silva",
        "Brown", "Tanaka", "Muller", "Haddad", "Johnson", "Novak", "Martin", "Chen", "Walker", "Diaz",
        "Singh", "Andersen", "Moreau", "Kowalski", "Reyes", "Ibrahim", "Clarke", "Yamamoto", "Hughes", "Costa"]
NICKNAMES = {"Robert": "Bob", "William": "Will", "Katherine": "Kate", "Alexander": "Alex",
             "Elizabeth": "Liz", "Michael": "Mike", "Samantha": "Sam", "Daniel": "Dan", "Samuel": "Sam"}


# ---------------------------------------------------------------- voice bank

def joined(regions: list[list[float]], gap: float) -> list[list[float]]:
    out: list[list[float]] = []
    for s, e in sorted(regions):
        if out and s - out[-1][1] < gap:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def subtract(spans: list[list[float]], holes: list[tuple[float, float]]) -> list[list[float]]:
    out = []
    holes = sorted(holes)
    for s, e in spans:
        cur = s
        for hs, he in holes:
            if he <= cur or hs >= e:
                continue
            if hs > cur:
                out.append([cur, hs])
            cur = max(cur, he)
        if cur < e:
            out.append([cur, e])
    return out


@dataclass
class Voice:
    identity: str
    video: str
    clean_s: float
    spans: list[list[float]]          # usable single-voice speech, source seconds
    words: list[list]                 # [start, end, word] inside usable spans
    backchannels: list[list]          # short single words usable as "yeah"/"right"

    @property
    def usable_s(self) -> float:
        return sum(e - s for s, e in self.spans)


class Bank:
    def __init__(self, lang: str):
        self.dir = ROOT / "bank" / lang
        self.voices: dict[str, Voice] = {}
        xr = self.dir / "cross_recording_identities.json"
        self.cross = json.load(open(xr)) if xr.exists() else {"groups": [], "likely_synthetic": []}
        synthetic = set(self.cross["likely_synthetic"])
        for line in open(self.dir / "identities.jsonl"):
            r = json.loads(line)
            if r.get("unreliable"):
                continue  # dense check found too much speech off this voice (voicebank.py verify)
            if r["identity"] in synthetic:
                continue  # same voice at 0.95+ across different videos: likely TTS narration
            info = json.load(open(self.dir / "regions" / f"{r['video']}.json"))
            # Captions can overhang the audio; never point past the end of the file.
            audio_s = sf.info(str(self.dir / "audio16k" / f"{r['video']}.flac")).duration - 0.05
            regions = [[a, min(b, audio_s)] for a, b in joined(info["regions"], 0.6) if a < audio_s]
            holes = [(b - 1.5, b + 3.0 + 1.5) for b in r["bad_windows"]]
            spans = [sp for sp in subtract(regions, holes) if sp[1] - sp[0] >= 1.0]
            inside = lambda t: any(s <= t < e for s, e in spans)  # noqa: E731
            words = [w for w in info["words"] if inside(w[0])]
            bcs = [w for w in words if w[2].lower().strip(".,!?") in BACKCHANNELS and w[1] - w[0] <= 0.9]
            v = Voice(r["identity"], r["video"], r["clean_s"], spans, words, bcs)
            if v.usable_s >= 30:
                self.voices[v.identity] = v
        z = np.load(self.dir / "centroids.npz")
        self.ids = list(z["ids"])
        self.index = {i: k for k, i in enumerate(self.ids)}
        self.soundalike = z["soundalike"]
        self.conflicts: set[frozenset] = set()
        for a, b, *_ in json.load(open(self.dir / "maybe_same_person.json")):
            self.conflicts.add(frozenset((a, b)))
        self._files: dict[str, sf.SoundFile] = {}
        music_path = self.dir / "music.jsonl"
        self.music = [json.loads(line) for line in open(music_path)] if music_path.exists() else []

    def music_clip(self, rng: np.random.Generator, seconds: float) -> np.ndarray:
        """Real music (caption `[Music]` spans) for `seconds`, chaining clips as needed."""
        out: list[np.ndarray] = []
        need = int(seconds * SR)
        while need > 0 and self.music:
            m = self.music[int(rng.integers(len(self.music)))]
            x = self.audio(m["video"], m["start"], m["end"])[:need]
            out.append(x)
            need -= len(x)
        return np.concatenate(out) if out else np.zeros(int(seconds * SR), np.float32)

    def audio(self, video: str, start: float, end: float) -> np.ndarray:
        f = self._files.get(video)
        if f is None:
            f = sf.SoundFile(str(self.dir / "audio16k" / f"{video}.flac"))
            self._files[video] = f
        f.seek(max(0, int(start * SR)))
        return f.read(max(0, int((end - start) * SR)), dtype="float32")

    def compatible(self, identity: str, cast: list[str]) -> bool:
        return all(frozenset((identity, c)) not in self.conflicts for c in cast)

    def similarity(self, a: str, b: str) -> float:
        return float(self.soundalike[self.index[a], self.index[b]])


# ---------------------------------------------------------------- devices

def butter(x: np.ndarray, low: float | None, high: float | None) -> np.ndarray:
    from scipy.signal import butter as _b, sosfiltfilt

    if low:
        x = sosfiltfilt(_b(4, low, "highpass", fs=SR, output="sos"), x)
    if high and high < SR / 2 - 100:
        x = sosfiltfilt(_b(6, high, "lowpass", fs=SR, output="sos"), x)
    return x.astype(np.float32)


def opus_roundtrip(x: np.ndarray, kbps: int) -> np.ndarray:
    import av

    buf = io.BytesIO()
    out = av.open(buf, "w", format="ogg")
    st = out.add_stream("libopus", rate=48000)
    st.bit_rate = kbps * 1000
    st.layout = "mono"
    rs = av.AudioResampler(format="flt", layout="mono", rate=48000)
    fr = av.AudioFrame.from_ndarray(x.reshape(1, -1).astype(np.float32), format="flt", layout="mono")
    fr.sample_rate = SR
    for f in rs.resample(fr):
        for p in st.encode(f):
            out.mux(p)
    for p in st.encode(None):
        out.mux(p)
    out.close()
    buf.seek(0)
    with av.open(buf) as c:
        r2 = av.AudioResampler(format="flt", layout="mono", rate=SR)
        ch = [f.to_ndarray().reshape(-1) for pk in c.decode(c.streams.audio[0]) for f in r2.resample(pk)]
        ch += [f.to_ndarray().reshape(-1) for f in r2.resample(None)]
    y = np.concatenate(ch) if ch else np.zeros(0, np.float32)
    y = y[: len(x)]
    return np.pad(y, (0, len(x) - len(y))).astype(np.float32)


@dataclass
class Device:
    kind: str
    highpass: float | None
    lowpass: float | None
    kbps: int | None
    gain_db: float

    def apply(self, x: np.ndarray) -> np.ndarray:
        y = butter(x, self.highpass, self.lowpass)
        if self.kbps:
            y = opus_roundtrip(y, self.kbps)
        return y * (10 ** (self.gain_db / 20))

    def to_json(self) -> dict:
        return self.__dict__.copy()


def remote_device(rng: np.random.Generator) -> Device:
    kind = rng.choice(["wideband", "fullband", "telephone"], p=[0.6, 0.28, 0.12])
    if kind == "telephone":
        return Device("telephone", 300.0, 3400.0, int(rng.choice([8, 12])), float(rng.uniform(-6, 2)))
    if kind == "wideband":
        return Device("wideband", 100.0, 7000.0, int(rng.choice([12, 16, 20, 24])), float(rng.uniform(-6, 2)))
    return Device("fullband", 60.0, None, int(rng.choice([24, 32])), float(rng.uniform(-6, 2)))


@dataclass
class Room:
    rirs: dict[str, np.ndarray] = field(default_factory=dict)
    description: dict = field(default_factory=dict)


def make_room(rng: np.random.Generator, local_pids: list[str], you_pid: str) -> Room:
    import pyroomacoustics as pra

    dims = [float(rng.uniform(3.5, 8)), float(rng.uniform(3, 6)), float(rng.uniform(2.5, 3.3))]
    absorption = float(rng.uniform(0.15, 0.5))
    mic = [dims[0] / 2, dims[1] / 2, 0.8]
    room = pra.ShoeBox(dims, fs=SR, materials=pra.Material(absorption), max_order=12)
    positions = {}
    for pid in local_pids:
        dist = float(rng.uniform(0.35, 0.7)) if pid == you_pid else float(rng.uniform(1.0, 2.6))
        ang = float(rng.uniform(0, 2 * np.pi))
        pos = [min(max(mic[0] + dist * np.cos(ang), 0.3), dims[0] - 0.3),
               min(max(mic[1] + dist * np.sin(ang), 0.3), dims[1] - 0.3), 1.2]
        room.add_source(pos)
        positions[pid] = [round(p, 2) for p in pos]
    room.add_microphone(mic)
    room.compute_rir()
    rirs = {pid: np.asarray(room.rir[0][i], dtype=np.float32) for i, pid in enumerate(local_pids)}
    return Room(rirs, {"dims": [round(d, 2) for d in dims], "absorption": round(absorption, 2),
                       "mic": [round(m, 2) for m in mic], "positions": positions})


# ---------------------------------------------------------------- people

@dataclass
class Person:
    pid: str
    identity: str
    name: str
    role: str                     # you | local | remote
    dominance: float
    device: Device | None = None
    device_after_switch: Device | None = None
    cursor: int = 0               # index into voice spans
    offset: float = 0.0           # seconds into current span
    budget_s: float = 0.0
    talk_s: float = 0.0
    voice: str = ""               # audio source when it differs from identity (family X)

    @property
    def vid(self) -> str:
        return self.voice or self.identity

    @property
    def channel(self) -> str:
        return "system" if self.role == "remote" else "mic"


def take(voice: Voice, p: Person, want: float) -> tuple[float, float] | None:
    """Next contiguous source span of up to `want` seconds, walking the voice's spans in order."""
    for _ in range(len(voice.spans) + 1):
        if p.cursor >= len(voice.spans):
            p.cursor, p.offset = 0, 0.0          # wrap: reuse audio only after the whole bank is used
        s, e = voice.spans[p.cursor]
        start = s + p.offset
        remaining = e - start
        if remaining >= 1.0:
            dur = min(want, remaining)
            p.offset += dur
            if e - (s + p.offset) < 1.0:
                p.cursor, p.offset = p.cursor + 1, 0.0
            return start, start + dur
        p.cursor, p.offset = p.cursor + 1, 0.0
    return None


def fake_names(rng: np.random.Generator, n: int) -> list[str]:
    names: set[str] = set()
    while len(names) < n:
        names.add(f"{rng.choice(FIRST)} {rng.choice(LAST)}")
    return list(names)


# ---------------------------------------------------------------- meeting

FAMILIES = {
    "A": dict(remote=(1, 1), local=(0, 0), minutes=(10, 45), split=False),
    "B": dict(remote=(3, 4), local=(0, 0), minutes=(15, 30), split=False),
    "C": dict(remote=(6, 8), local=(0, 0), minutes=(20, 40), split=False),
    "D": dict(remote=(2, 4), local=(1, 2), minutes=(20, 30), split=True),
    "E": dict(remote=(3, 6), local=(0, 0), minutes=(20, 35), split=False),
    # Stress-test families (plan phase 3): right at and past Nemotron's 8-speaker limit,
    # hour-plus meetings, very short calls, and noisy calls.
    "G8": dict(remote=(8, 8), local=(0, 0), minutes=(25, 40), split=False),
    "G10": dict(remote=(9, 10), local=(0, 0), minutes=(25, 40), split=False),
    "L": dict(remote=(3, 5), local=(0, 0), minutes=(60, 90), split=False),
    "S": dict(remote=(1, 4), local=(0, 0), minutes=(1, 3), split=False),
    "N": dict(remote=(3, 6), local=(0, 0), minutes=(15, 30), split=False),
}


def cast(bank: Bank, rng: np.random.Generator, n: int, need_s: list[float], soundalike: bool) -> list[str]:
    """Pick n compatible identities, each with enough usable speech for its share."""
    pool = sorted(bank.voices.values(), key=lambda v: -v.usable_s)
    chosen: list[str] = []
    order = np.argsort(need_s)[::-1]           # hardest (most talk) first
    picks: dict[int, str] = {}
    for slot in order:
        cands = [v.identity for v in pool if v.usable_s >= need_s[slot] * 1.1
                 and v.identity not in chosen and bank.compatible(v.identity, chosen)]
        if not cands:
            cands = [v.identity for v in pool[:40] if v.identity not in chosen and bank.compatible(v.identity, chosen)]
        if soundalike and chosen:
            # Hard negatives: prefer whoever sounds most like someone already cast.
            sims = [max(bank.similarity(c, x) for x in chosen) for c in cands]
            top = np.argsort(sims)[::-1][: max(1, len(cands) // 20)]
            pick = cands[int(rng.choice(top))]
        else:
            pick = cands[int(rng.integers(len(cands)))]
        picks[int(slot)] = pick
        chosen.append(pick)
    return [picks[i] for i in range(n)]


@dataclass
class Plan:
    """Who is in one meeting and how it runs. p0 is always you."""
    people: list[Person]
    total_s: float
    stress: bool
    overlap_p: float
    split: bool
    title: str = ""


def plan_family(bank: Bank, family: str, rng: np.random.Generator) -> Plan:
    spec = FAMILIES[family]
    n_remote = int(rng.integers(spec["remote"][0], spec["remote"][1] + 1))
    n_local = int(rng.integers(spec["local"][0], spec["local"][1] + 1))
    total_s = float(rng.uniform(*spec["minutes"])) * 60
    stress = family == "E"
    n = 1 + n_local + n_remote
    dom = rng.dirichlet(np.full(n, 1.3))
    if family == "A":
        dom = np.array([0.45, 0.55])
    ids = cast(bank, rng, n, list(dom * total_s * 1.15), soundalike=stress)
    names = fake_names(rng, n)
    people: list[Person] = []
    for i, ident in enumerate(ids):
        role = "you" if i == 0 else ("local" if i <= n_local else "remote")
        p = Person(pid=f"p{i}", identity=ident, name="You" if role == "you" else names[i], role=role,
                   dominance=float(dom[i]))
        if role == "remote":
            p.device = remote_device(rng)
        p.cursor = int(rng.integers(0, max(1, len(bank.voices[ident].spans) // 3)))
        p.budget_s = min(bank.voices[ident].usable_s * 0.95, float(dom[i]) * total_s * 1.6 + 30)
        people.append(p)
    if stress:
        for p in rng.permutation([p for p in people if p.role == "remote"])[: 2]:
            p.device_after_switch = remote_device(rng)
    return Plan(people, total_s, stress, 0.22 if stress else 0.08, spec["split"])


def add_noise_layer(bank: Bank, rng: np.random.Generator, people: list, system: np.ndarray, duration: float) -> list:
    """Family N: the things that make real calls hard, none of them a participant.
      music     a 20-40 s music intro (waiting room / screen share), and a quieter
                15-30 s music bed under speech mid-call
      babble    other people talking in the background of one remote participant's
                open mic, through that participant's device
      keyboard  typing clicks on another remote participant's open mic
    Returns a description of what was added (for the answer key)."""
    events = []
    level = lambda x, db: x * (10 ** (db / 20) / (np.sqrt(np.mean(x * x)) + 1e-9))  # noqa: E731
    def put(x, t0):
        i0 = int(t0 * SR)
        n = max(0, min(len(x), len(system) - i0))
        system[i0:i0 + n] += x[:n]
    intro = float(rng.uniform(20, 40))
    put(level(bank.music_clip(rng, intro), float(rng.uniform(-22, -16))), 0.0)
    events.append({"kind": "music_intro", "start": 0.0, "end": round(intro, 1)})
    bed_t = float(rng.uniform(0.3, 0.7)) * duration
    bed = float(rng.uniform(15, 30))
    put(level(bank.music_clip(rng, bed), float(rng.uniform(-34, -28))), bed_t)
    events.append({"kind": "music_bed", "start": round(bed_t, 1), "end": round(bed_t + bed, 1)})
    remotes = [p for p in people if p.role == "remote"]
    in_meeting = {p.identity for p in people}
    others = [v for v in bank.voices.values() if v.identity not in in_meeting]
    if remotes and len(others) >= 2:
        host = remotes[int(rng.integers(len(remotes)))]
        # Background talkers: two strangers' speech, continuous, well under the speaker.
        chunks = []
        for v in [others[int(i)] for i in rng.choice(len(others), 2, replace=False)]:
            s0, e0 = v.spans[int(rng.integers(len(v.spans)))]
            chunks.append(bank.audio(v.video, s0, min(e0, s0 + duration)))
        n = int(duration * SR)
        babble = np.zeros(n, np.float32)
        for c in chunks:
            reps = int(np.ceil(n / max(1, len(c))))
            babble += np.tile(c, reps)[:n]
        babble = level(babble, float(rng.uniform(-40, -34)))
        # Through the host's device in 30 s pieces (open mic all meeting).
        dev = host.device or remote_device(rng)
        step = 30 * SR
        for i in range(0, n, step):
            put(dev.apply(babble[i:i + step]), i / SR)
        events.append({"kind": "babble", "on": host.pid})
        if len(remotes) >= 2:
            typist = [p for p in remotes if p.pid != host.pid][0]
            clicks = np.zeros(n, np.float32)
            for _ in range(int(duration / 60 * 3)):  # ~3 typing bursts per minute
                t = float(rng.uniform(0, max(1.0, duration - 6)))
                for k in range(int(rng.uniform(15, 50))):
                    j = int((t + k * rng.uniform(0.08, 0.2)) * SR)
                    if j + 200 < n:
                        clicks[j:j + 200] += (rng.standard_normal(200) * np.exp(-np.arange(200) / 30)).astype(np.float32)
            clicks = level(clicks, float(rng.uniform(-38, -30))) if clicks.any() else clicks
            dev2 = typist.device or remote_device(rng)
            for i in range(0, n, step):
                put(dev2.apply(clicks[i:i + step]), i / SR)
            events.append({"kind": "keyboard", "on": typist.pid})
    return events


def build_meeting(bank: Bank, family: str, seed: int, out: Path, plan: Plan | None = None) -> dict:
    rng = np.random.default_rng(seed)
    if plan is None:
        plan = plan_family(bank, family, rng)
    people, total_s, stress, overlap_p = plan.people, plan.total_s, plan.stress, plan.overlap_p
    spec = {"split": plan.split}
    n = len(people)

    # ---- timeline
    segments = []
    t = float(rng.uniform(0.5, 2.0))
    cur = int(rng.integers(n))
    prev = None
    while t < total_s:
        alive = [i for i, p in enumerate(people) if p.budget_s - p.talk_s > 1.5]
        if not alive:
            break
        if cur not in alive:
            cur = int(rng.choice(alive))
        p = people[cur]
        voice = bank.voices[p.vid]
        median = 5.0 * (0.6 + 2.0 * p.dominance)
        want = float(np.clip(rng.lognormal(np.log(median), 0.85), 1.2, 75.0))
        if stress and rng.random() < 0.05:
            want = float(rng.uniform(60, 120))           # long monologue
        want = min(want, p.budget_s - p.talk_s)
        src = take(voice, p, want)
        if src is None:
            p.budget_s = p.talk_s
            continue
        dur = src[1] - src[0]
        segments.append({"pid": p.pid, "start": round(t, 3), "end": round(t + dur, 3), "kind": "turn",
                         "src": [round(src[0], 3), round(src[1], 3)]})
        p.talk_s += dur
        # backchannels from others during longer turns
        if dur > 5:
            for q in people:
                if q.pid == p.pid or not bank.voices[q.vid].backchannels:
                    continue
                k = rng.poisson(dur / 60.0 * (6 if stress else 3) / max(1, n - 1) * 2)
                for _ in range(int(k)):
                    w = bank.voices[q.vid].backchannels[int(rng.integers(len(bank.voices[q.vid].backchannels)))]
                    bs = float(rng.uniform(t + 1.0, t + dur - 1.0))
                    bsrc = (max(0.0, w[0] - 0.05), w[1] + 0.08)
                    segments.append({"pid": q.pid, "start": round(bs, 3), "end": round(bs + bsrc[1] - bsrc[0], 3),
                                     "kind": "backchannel", "src": [round(bsrc[0], 3), round(bsrc[1], 3)]})
        # next speaker: ping-pong with the previous one, else by dominance
        if prev is not None and prev != cur and rng.random() < 0.3 and prev in alive:
            nxt = prev
        else:
            w = np.array([people[i].dominance if i != cur else 0.0 for i in range(n)])
            w = w / w.sum() if w.sum() > 0 else None
            nxt = int(rng.choice(n, p=w)) if w is not None else cur
        gap = float(-rng.uniform(0.2, 1.2)) if rng.random() < overlap_p else float(np.clip(rng.normal(0.45, 0.35), 0.05, 1.8))
        t = t + dur + gap
        prev, cur = cur, nxt

    duration = max(s["end"] for s in segments) + 1.0
    by_pid = {p.pid: p for p in people}

    # ---- render
    local_pids = [p.pid for p in people if p.channel == "mic"]
    room = make_room(rng, local_pids, "p0")
    mic = np.zeros(int(duration * SR) + SR, np.float32)
    system = np.zeros_like(mic)
    words_out = []
    for seg in segments:
        p = by_pid[seg["pid"]]
        voice = bank.voices[p.vid]
        x = bank.audio(voice.video, seg["src"][0], seg["src"][1])
        if len(x) < 160:
            continue
        rms = np.sqrt(np.mean(x * x)) + 1e-9
        x = x * (10 ** (-23 / 20) / rms)                 # speech level ~ -23 dBFS
        pad = int(0.25 * SR)
        x = np.pad(x, (pad, pad))
        if p.role == "remote":
            dev = p.device
            if p.device_after_switch is not None and seg["start"] > duration / 2:
                dev = p.device_after_switch
            y = dev.apply(x)
            dest = system
        else:
            from scipy.signal import fftconvolve

            y = fftconvolve(x, room.rirs[p.pid])[: len(x)].astype(np.float32)
            y *= 10 ** (-23 / 20) / (np.sqrt(np.mean(y * y)) + 1e-9) * (1.0 if p.role == "you" else 0.6)
            dest = mic
        i0 = int(seg["start"] * SR) - pad
        if i0 < 0:
            y = y[-i0:]
            i0 = 0
        dest[i0: i0 + len(y)] += y[: len(dest) - i0]
        if seg["kind"] == "turn":
            for w in voice.words:
                if seg["src"][0] <= w[0] < seg["src"][1]:
                    off = seg["start"] + (w[0] - seg["src"][0])
                    words_out.append({"pid": p.pid, "start": round(off, 3),
                                      "end": round(off + w[1] - w[0], 3), "w": w[2]})

    # noise: room tone on the mic, faint comfort noise on the call
    mic += (rng.standard_normal(len(mic)).astype(np.float32) * 10 ** (float(rng.uniform(-58, -46)) / 20))
    system += (rng.standard_normal(len(system)).astype(np.float32) * 10 ** (-72 / 20))
    echo = (not spec["split"]) and rng.random() < 0.25
    if echo:
        from scipy.signal import fftconvolve

        d = int(float(rng.uniform(0.02, 0.08)) * SR)
        leak = np.pad(system, (d, 0))[: len(system)] * 10 ** (float(rng.uniform(-38, -28)) / 20)
        mic += fftconvolve(leak, room.rirs["p0"])[: len(mic)].astype(np.float32)
    noise_events = []
    if family == "N":
        noise_events = add_noise_layer(bank, rng, people, system, duration)
    peak = max(np.abs(mic).max(), np.abs(system).max(), 1e-6)
    if peak > 0.98:
        mic *= 0.98 / peak
        system *= 0.98 / peak

    out.mkdir(parents=True, exist_ok=True)
    sf.write(out / "mic.wav", mic, SR, subtype="PCM_16")
    sf.write(out / "system.wav", system, SR, subtype="PCM_16")
    truth = {
        "meeting": out.name, "family": family, "seed": seed, "duration_s": round(duration, 2), "title": plan.title,
        "split_local_speakers": spec["split"], "echo_leak": bool(echo), "room": room.description,
        "noise_events": noise_events,
        "participants": [{"pid": p.pid, "identity": p.identity, "voice": p.vid, "name": p.name, "role": p.role,
                          "channel": p.channel, "talk_s": round(p.talk_s, 1),
                          "device": p.device.to_json() if p.device else None,
                          "device_after_switch": p.device_after_switch.to_json() if p.device_after_switch else None}
                         for p in people],
        "segments": sorted(segments, key=lambda s: s["start"]),
        "words": sorted(words_out, key=lambda w: w["start"]),
    }
    json.dump(truth, open(out / "truth.json", "w"), indent=1)
    json.dump(make_calendar(rng, people), open(out / "calendar.json", "w"), indent=1)
    with open(out / "truth.rttm", "w") as f:
        for s in truth["segments"]:
            ch = by_pid[s["pid"]].channel
            f.write(f"SPEAKER {out.name}_{ch} 1 {s['start']:.3f} {s['end'] - s['start']:.3f} <NA> <NA> {s['pid']} <NA> <NA>\n")
    return truth


def make_calendar(rng: np.random.Generator, people: list[Person]) -> dict:
    """The invite: attendees minus crashers, plus no-shows, with nickname/email noise."""
    present = [p for p in people if p.role != "you"]
    invitees = []
    crasher = present[int(rng.integers(len(present)))].pid if len(present) > 1 and rng.random() < 0.10 else None
    for p in present:
        if p.pid == crasher:
            continue
        first, last = p.name.split(" ", 1)
        display = p.name
        if first in NICKNAMES and rng.random() < 0.5:
            display = f"{NICKNAMES[first]} {last}"
        email = f"{first.lower()}.{last.lower()}@example.com"
        if rng.random() < 0.05:
            display = None
        invitees.append({"name": display, "email": email, "is_person": True, "pid": p.pid})
    if rng.random() < 0.15:
        ghost = fake_names(rng, 1)[0]
        invitees.append({"name": ghost, "email": ghost.lower().replace(" ", ".") + "@example.com",
                         "is_person": True, "pid": None})
    if rng.random() < 0.2:
        invitees.append({"name": "Conference Room 4B", "email": "room-4b@example.com", "is_person": False, "pid": None})
    order = rng.permutation(len(invitees))
    return {"invitees": [invitees[i] for i in order], "crasher_pid": crasher,
            "note": "pid is the answer key; the app only ever sees name/email/is_person"}


TEMPLATES = {
    # title: (minutes range, who), "who" resolved against the company cast
    "1:1 with manager": ((16, 26), ["manager"]),
    "Team standup": ((7, 11), ["team"]),
    "Team sync": ((24, 34), ["manager", "team", "guest?"]),
    "Client call": ((18, 28), ["client", "guest?"]),
}
WEEK = [("Mon", "1:1 with manager"), ("Mon", "Team standup"), ("Tue", "Client call"),
        ("Wed", "Team standup"), ("Thu", "Team sync"), ("Fri", "Team standup")]


def plan_company(bank: Bank, rng: np.random.Generator, weeks: int, hard: bool = False,
                 skip: frozenset = frozenset(), guest_p: float = 0.6):
    """A fake company that meets for `weeks` weeks, sharing one speaker DB.

    Recurring cast: you, a manager, a 5-person team (including two people named
    Sam, and a Robert who is sometimes invited as Bob), and a client. Guests are
    one-off voices. Every person's speech continues through their own audio from
    meeting to meeting, so nothing is reused until a voice runs out.
    """
    voices = sorted((v for v in bank.voices.values() if v.identity not in skip), key=lambda v: -v.usable_s)
    roles = ["you", "manager", "team", "team", "team", "team", "team", "client"]
    cast_ids: list[str] = []
    if hard:
        # Worst case for the voice matcher: a team of mutually sound-alike voices
        # (labeler-model similarity), each with enough audio for weeks of meetings.
        pool = [v.identity for v in voices if v.usable_s >= 20 * 60]
        cast_ids.append(pool.pop(int(rng.integers(min(5, len(pool))))))
        while len(cast_ids) < len(roles) and pool:
            ok = [c for c in pool if bank.compatible(c, cast_ids)]
            if not ok:
                break
            pick = max(ok, key=lambda c: np.mean([bank.similarity(c, x) for x in cast_ids[1:] or cast_ids]))
            cast_ids.append(pick)
            pool.remove(pick)
    else:
        for v in voices:
            if len(cast_ids) == len(roles):
                break
            if bank.compatible(v.identity, cast_ids):
                cast_ids.append(v.identity)
    guests = [v.identity for v in voices if v.identity not in cast_ids and bank.compatible(v.identity, cast_ids)]
    if hard:
        # Guests who sound like someone on the team: the strangers most likely to be
        # silently mislabeled as a known person. Popped from the end, so most similar first.
        guests.sort(key=lambda g: max(bank.similarity(g, c) for c in cast_ids[1:]))
    else:
        rng.shuffle(guests)
    plan_company.cast = cast_ids
    names = ["You", "Priya Nair", "Sam Lee", "Sam Patel", "Robert Chen", "Elena Rossi", "Kwame Mensah", "Grace Kim"]
    cast_people = {ident: (role, name) for ident, role, name in zip(cast_ids, roles, names)}
    cursors: dict[str, tuple[int, float]] = {}
    last_device: dict[str, Device] = {}
    guest_names = iter(fake_names(rng, 400))
    k = 0
    for w in range(1, weeks + 1):
        for day, title in WEEK:
            (lo, hi), who = TEMPLATES[title]
            idents: list[str] = [cast_ids[0]]
            for slot in who:
                if slot == "team":
                    team = [i for i in cast_ids if cast_people[i][0] == "team"]
                    if title == "Team standup" and rng.random() < 0.35:
                        team.remove(team[int(rng.integers(len(team)))])  # someone's out
                    idents += team
                elif slot == "guest?":
                    if rng.random() < guest_p and guests:
                        idents.append(guests.pop())
                else:
                    idents += [i for i in cast_ids if cast_people[i][0] == slot]
            total_s = float(rng.uniform(lo, hi)) * 60
            dom = rng.dirichlet(np.full(len(idents), 1.6))
            people = []
            for i, ident in enumerate(idents):
                role, name = cast_people.get(ident, ("guest", next(guest_names)))
                p = Person(pid=f"p{i}", identity=ident, name=name, role="you" if i == 0 else "remote",
                           dominance=float(dom[i]))
                if i > 0:
                    prev = last_device.get(ident)
                    p.device = prev if prev is not None and rng.random() < 0.7 else remote_device(rng)
                    last_device[ident] = p.device
                p.cursor, p.offset = cursors.get(ident, (0, 0.0))
                p.budget_s = float(dom[i]) * total_s * 1.5 + 20
                people.append(p)
            k += 1
            # The caller renders this plan before resuming us; rendering walks each
            # person's cursor forward, so the next meeting starts where this one ended.
            yield (f"F-w{w}-{day}-{title.split()[0].lower().replace(':', '')}-{k:02d}",
                   Plan(people, total_s, False, 0.08, False, title=title))
            for p in people:
                cursors[p.identity] = (p.cursor, p.offset)


X_TEMPLATES = {
    # Shorter meetings than family F so each person's few recordings last the series.
    "1:1 with manager": ((9, 14), ["manager"]),
    "Team standup": ((5, 7), ["team"]),
    "Team sync": ((13, 18), ["manager", "team", "guest?"]),
    "Client call": ((10, 15), ["client", "guest?"]),
}


def plan_cross_company(bank: Bank, rng: np.random.Generator, weeks: int, guest_p: float = 0.9):
    """Family X: like F, but every recurring person is a cross-recording identity
    (voicebank cross_recording_identities.json: the same voice in 2-8 different
    videos) and their voice rotates to a different recording each meeting. This is
    the honest test of cross-meeting naming: the matcher sees real session-to-session
    voice change instead of one recording cut into pieces.
    """
    groups = [[m for m in g["members"] if m in bank.voices] for g in bank.cross["groups"]]
    groups = [g for g in groups if len(g) >= 2]
    groups.sort(key=lambda g: -sum(bank.voices[m].usable_s for m in g))
    grouped = {m for g in groups for m in g}
    roles = ["manager", "team", "team", "team", "team", "team", "client"]
    if len(groups) < len(roles):
        raise SystemExit(f"need {len(roles)} cross-recording people, bank has {len(groups)}")
    cast = groups[: len(roles)]
    singles = sorted((v for v in bank.voices.values() if v.identity not in grouped), key=lambda v: -v.usable_s)
    you = singles[0].identity
    guests = [v.identity for v in singles[1:] if bank.compatible(v.identity, [m for g in cast for m in g])]
    rng.shuffle(guests)
    names = ["Priya Nair", "Sam Lee", "Sam Patel", "Robert Chen", "Elena Rossi", "Kwame Mensah", "Grace Kim"]
    people_of = {f"xr-{k}": (role, name, g) for k, (role, name, g) in enumerate(zip(roles, names, cast))}
    plan_cross_company.cast = [you] + list(people_of)
    appearances: dict[str, int] = defaultdict(int)
    cursors: dict[str, tuple[int, float]] = {}
    last_device: dict[str, Device] = {}
    guest_names = iter(fake_names(rng, 400))
    k = 0
    for w in range(1, weeks + 1):
        for day, title in WEEK:
            (lo, hi), who = X_TEMPLATES[title]
            ids: list[str] = [you]
            for slot in who:
                if slot == "team":
                    team = [i for i, (r, _, _) in people_of.items() if r == "team"]
                    if title == "Team standup" and rng.random() < 0.35:
                        team.remove(team[int(rng.integers(len(team)))])
                    ids += team
                elif slot == "guest?":
                    if rng.random() < guest_p and guests:
                        ids.append(guests.pop())
                else:
                    ids += [i for i, (r, _, _) in people_of.items() if r == slot]
            total_s = float(rng.uniform(lo, hi)) * 60
            dom = rng.dirichlet(np.full(len(ids), 1.6))
            people = []
            for i, ident in enumerate(ids):
                if ident in people_of:
                    _, name, members = people_of[ident]
                    voice = members[appearances[ident] % len(members)]   # a different recording each time
                    appearances[ident] += 1
                else:
                    name, voice = ("You" if i == 0 else next(guest_names)), ident
                p = Person(pid=f"p{i}", identity=ident, name=name, role="you" if i == 0 else "remote",
                           dominance=float(dom[i]), voice=voice)
                if i > 0:
                    prev = last_device.get(ident)
                    p.device = prev if prev is not None and rng.random() < 0.7 else remote_device(rng)
                    last_device[ident] = p.device
                p.cursor, p.offset = cursors.get(voice, (0, 0.0))
                p.budget_s = float(dom[i]) * total_s * 1.5 + 20
                people.append(p)
            k += 1
            yield (f"X-w{w}-{day}-{title.split()[0].lower().replace(':', '')}-{k:02d}",
                   Plan(people, total_s, False, 0.08, False, title=title))
            for p in people:
                cursors[p.vid] = (p.cursor, p.offset)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lang", default="en")
    ap.add_argument("--family", required=True, choices=sorted(FAMILIES) + ["F", "X"])
    ap.add_argument("--count", type=int, default=10)
    ap.add_argument("--weeks", type=int, default=4, help="family F: weeks of company meetings")
    ap.add_argument("--hard", action="store_true", help="family F: sound-alike team and sound-alike guests")
    ap.add_argument("--skip-cast-of", nargs="*", default=[], help="family F: sets whose cast this company must not reuse")
    ap.add_argument("--guest-p", type=float, default=0.6, help="family F: chance a sync/client call has a guest")
    ap.add_argument("--seed", type=int, default=1000)
    ap.add_argument("--set", required=True, help="output set name under data/eval/yodas3/sim/")
    args = ap.parse_args()
    bank = Bank(args.lang)
    print(f"[sim] bank: {len(bank.voices)} voices, {sum(v.usable_s for v in bank.voices.values())/3600:.1f} h usable")
    set_dir = ROOT / "sim" / args.set
    series_path = set_dir / "series.json"
    series = json.load(open(series_path)) if series_path.exists() else {"set": args.set, "meetings": []}
    have = {m["id"] for m in series["meetings"]}
    if args.family in ("F", "X"):
        if have:
            raise SystemExit(f"{set_dir} already has meetings; a company series must be generated in one go")
        rng = np.random.default_rng(args.seed)
        skip = set()
        for other in args.skip_cast_of:
            skip |= set(json.load(open(ROOT / "sim" / other / "series.json")).get("cast", []))
        if args.family == "X":
            gen = plan_cross_company(bank, rng, args.weeks, guest_p=args.guest_p)
            planner = plan_cross_company
        else:
            gen = plan_company(bank, rng, args.weeks, hard=args.hard, skip=frozenset(skip), guest_p=args.guest_p)
            planner = plan_company
        for k, (mid, plan) in enumerate(gen):
            series["cast"] = planner.cast
            truth = build_meeting(bank, args.family, args.seed + k, set_dir / mid, plan)
            series["meetings"].append({"id": mid, "family": args.family, "seed": args.seed + k, "title": plan.title,
                                       "split_local_speakers": False, "fresh_db": False})
            print(f"[sim] {mid}: {truth['duration_s']/60:.1f} min, {len(truth['participants']) - 1} remote", flush=True)
            json.dump(series, open(series_path, "w"), indent=1)
        return
    for k in range(args.count):
        seed = args.seed + k
        mid = f"{args.family}-{seed}"
        if mid in have:
            continue
        truth = build_meeting(bank, args.family, seed, set_dir / mid)
        series["meetings"].append({"id": mid, "family": args.family, "seed": seed,
                                   "split_local_speakers": truth["split_local_speakers"],
                                   "fresh_db": True})
        ppl = truth["participants"]
        print(f"[sim] {mid}: {truth['duration_s']/60:.1f} min, remote {sum(p['role']=='remote' for p in ppl)}, "
              f"local {sum(p['role']=='local' for p in ppl)}, segments {len(truth['segments'])}", flush=True)
        json.dump(series, open(series_path, "w"), indent=1)


if __name__ == "__main__":
    main()
