#!/usr/bin/env python3
"""Naming simulation for the voiceprint bake-off: what a user actually feels per model.

For every voiceprint model with embeddings in VP/emb/<model>/, this replays meetings through a
Python mirror of the app's speaker naming and measures:

  * wrong silent names (the headline: must be 0; the owner said one false name ruins trust)
  * wrong suggestions ("Was this Taylor?" when it wasn't)
  * meetings until a regular is first named automatically (median, p90)
  * share of regular appearances named automatically from their 3rd meeting on
  * naming work per meeting (type 3, pick 2, confirm 1, correct a suggestion 3, wrong silent name 10;
    same scoring as scripts/speaker_lab/naming_replay.py)
  * strangers (and first-time people) silently given someone's name
  * look-alike pairs over the bar: held-out pairs (A, B) where one session of A clears the lineup
    bar against B's two-session profile; world-free, so it catches risks the random meetings miss

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md. Reads VP/sets/*/segments.jsonl and
VP/emb/<model>/<set>__<cond>.npz; writes VP/results/naming/<model_id>.json and
VP/results/naming_summary.md. Never touches the app's real speaker database.

----------------------------------------------------------------------------------------------
How the app is mirrored (TranscriptedCore/Speaker + Pipeline/TranscriptionPipeline*.swift)
----------------------------------------------------------------------------------------------
Per meeting, per voice (one voice = one person; the diarizer is assumed perfect, the bake-off
scores the voiceprint only):
  1. Sample = L2-normalized mean of the person's clip embeddings in that session (1, 3 or all
     clips; each clip counts as one diarizer segment for the adaptive floor).
  2. Match against a snapshot of the profiles from before the meeting
     (`Transcription.matchAgainstProfiles`): disputed profiles are skipped; score =
     best of {blended average, stored exemplars}; negative-exemplar veto with condition
     transport; adaptive floor by segment count (1 / 2-3 / 4+); maturity bonus for young
     profiles (callCount <= 2, 3-4); ambiguity check (runner-up within `separation`).
     Two voices matching one profile: the better match keeps it, the other becomes a new
     profile (`planCrossClusterLinks` spin-off; fusion is not modelled).
  3. Write-back at match time (`SpeakerWritePathPolicy.voiceprintBlendAlpha`): EMA 0.15 / 0.05 /
     frozen by similarity and runner-up margin; exemplars updated when alpha > 0
     (`SpeakerExemplarPolicy.updated`, K=3). Unmatched voices become new unnamed profiles.
  4. Silent naming (`SpeakerNamingPolicy.shouldAutoAccept`): named, confirmed in enough distinct
     meetings, healthy (no dispute, last verdict not a correction, < 2 corrections in the last 5),
     similarity > bar, and average-based margin over the runner-up. Lineup naming is always on:
     a profile on the lineup uses `InviteeBars` (2 confirmations, lineup bar, margin 0.10); anyone
     else uses the global ladder (5 confirmations, global bar, margin 0.12). Lineup = the calendar
     invite (mode `invite`: the group's roster, present or not) or, with no invite (mode `recent`),
     the 12 named people heard most recently (`lineupNameKeys`).
  5. The simulated user reviews every other voice and always knows who is who:
     - correct suggestion -> confirm (1): +1 confirmed meeting
     - wrong suggestion (3) or wrong silent name (10) -> correction: the wrong profile is restored
       to its pre-meeting state, disputed (excluded from matching until the user names someone as
       it again), and gets a negative exemplar; the voice is taught to the right person (EMA 0.15)
       or becomes their new profile; +1 confirmed meeting for the right person
     - no match, person already known -> pick them (2): merge (call-count weighted blend,
       exemplars cleared, dispute reset), +1 confirmed meeting
     - no match, new person -> type a name (3)
     Everyone gets named, strangers included (a named one-off stranger is a realistic decoy).

----------------------------------------------------------------------------------------------
Fair bars per model (only the model-specific cosine bars change; structure stays the app's)
----------------------------------------------------------------------------------------------
Speakers are split into two disjoint halves. Bars are calibrated on one half and scored on the
other, then the halves swap (2 folds). One set of bars per model, pooled over every set,
condition, talk time and lineup mode, because the app ships one set of bars per model.

  * Auto-name bars (lineup bar A_L, global bar A_G). An "impostor top" is a voice whose best
    candidate profile is someone else: strangers, first-timers, and regulars whose own profile
    lost. Every calibration voice with a wrong top counts, whatever the profile's confirmations
    (those depend on the run; the voice geometry doesn't). Each distinct (condition, person +
    session, wrongly matched person) counts once at its highest similarity: reps, talk times and
    lineup modes replay the same voices, and counting the copies let one look-alike pair (ICSI
    me001 vs me026 in opus12) fill the fitted tail.
      - Lowest zero-wrong bar: the highest impostor top that beats the runner-up by the path's
        margin (0.10 lineup / 0.12 global). Clear-margin impostors are rare, so this max is noisy:
        a first version used only fully eligible impostors (0-2 per half) and a synthetic check
        then let a stranger at 0.50 through a 0.45 bar set on the other half.
      - Safety margin, from the tail: fit an exponential tail to the top 2% (at least 25) of
        impostor-top similarities (threshold u, scale beta = mean excess over u, k points; with only
        10 points beta was +-30% and the two halves of one set disagreed by 0.3) and put the bar where
        the fit leaves a share p = 1e-4 of distinct impostor encounters above it (any margin, before
        the margin, confirmation and lineup gates): u + beta * ln(k / (n * p)). One fit per audio
        condition, strictest wins, so the bar holds if every meeting is in the worst condition.
        Why p = 1e-4: a half has ~1,600 distinct impostor tops (~530 per condition), so rates much
        below ~1/1,000 are pure extrapolation; at 1e-5 the halves disagreed by 0.06-0.10, at 1e-4
        by ~0.05, and 1e-4 puts the baseline at 0.78/0.83, next to the app's lab-tuned 0.80, with
        every bar above the other half's worst distinct impostor. `--impostor-rate` is the knob.
        (Earlier versions: one impostor per 100 calibration pools, i.e. p = 1/(100 n), tightened the
        bar whenever conditions or reps grew n, taking the baseline from 0.80 to 0.98; and the tail
        counted replays of the same voice, which let one look-alike pair fill it.) Pooled over conditions and talk times, a std-based
        cushion measured how mixed the conditions were rather than the tail; beta only looks at
        the extreme, and the 99th percentile it starts from agreed to 0.005 between halves in the
        synthetic checks. Real impostor tails are Gaussian-like and fall off faster than
        exponential, so this errs safe. It counts impostors of any margin, so the margin rule
        adds further slack. On a synthetic WeSpeaker-like model it lands at ~0.80, next to the
        app's lab-tuned lineup bar.
      - bar = max(tail bar, clear-margin max + beta). Re-run at the bar and raise until the
        calibration split has nothing above it. Too few impostor tops (< 50): no silent naming.
    A_G >= A_L is kept (the invite shrinks the lineup). The impostor tops are the same voices for
    both paths, so the two usually come out equal and the global path stays stricter through its
    5 confirmations and 0.12 margin.
  * Suggest bar F (the 4+-segment match floor): candidates are the model's own impostor-pair
    quantiles at FAR 10%, 3%, 1%, 0.3%, 0.1%, 0.03%, 0.01% (session means, calibration speakers);
    pick the one with the least naming work on the calibration split with zero wrong silent names
    (ties within 2% go to the stricter bar). Then the auto bars are re-calibrated at that F.
  * Every other cosine constant is carried over from the WeSpeaker value, linearly between the
    model's and the baseline's median impostor and median genuine session-mean cosine (calibration
    speakers, same sets and conditions): c' = imp_m + (c - imp_b) * scale, scale =
    (gen_m - imp_m) / (gen_b - imp_b); differences (floor offsets for 1 and 2-3 segments, maturity
    bonus, ambiguity gap) and the margins (0.12 global, 0.10 lineup, 0.12 write-back) are
    multiplied by scale. Identity for the baseline. The app ported thresholds to ERes2Net by equal
    false-accept rate on AMI, but on clean sets no WeSpeaker impostor pair reaches 0.70, so that
    remap collapses every constant above 0.70 onto one value; the linear map has no such tail.
    Scaling the margins keeps the rule and its meaning: un-centered x-vectors put every cosine in
    0.95-1.0, where a 0.12 gap is impossible. Scaled margins are the headline (coordinator-approved);
    each model is also calibrated and scored with the literal 0.12/0.10 margins as a secondary
    result (`fixed_margin_variant` in the JSON, last summary column). `--fixed-margins` makes the
    literal margins the headline; `--no-fixed-variant` skips the second pass.
  * Fixed: confirmations (5 global / 2 lineup), EMA weights, K=3 exemplars, recent lineup of 12.

The baseline (model.json "baseline": true) is also scored with the app's production bars
(0.70 floor, 0.80 lineup, 0.92 global) on both halves, as a reference.

----------------------------------------------------------------------------------------------
Meetings
----------------------------------------------------------------------------------------------
  * AMI / ICSI (rows carry `group`, or the set name starts with ami/icsi): real sessions grouped by
    series (`group`, else ES2002a-d -> ES2002, Bmr001 -> Bmr), in `session_order` / `date` / id
    order inside a series. Speaker halves are split by connected component of co-attendance
    when no component holds more than 35% of speakers (AMI: whole series), else by speaker (ICSI).
  * Other sets: synthetic groups of 3-6 people meeting 4-8 times; each member attends as many
    meetings as they have sessions (a different session each time).
  * Strangers: `stranger_only` speakers, plus 20% of each half's multi-session speakers (or series)
    held out. Each appears once: dropped into a group meeting (at most 2 per meeting, about one per
    two meetings) or, when there are more (yodas), in one-off calls of 2-4 strangers placed through
    the timeline. Every person's first meeting is also a "first-time" voice. A silent name on
    either counts as a stranger wrongly named.
  * Groups run staggered (about 3 series active at a time), a world holds <= 40 regulars, and
    `--reps` (default 4) reseeds the worlds (group composition, held-out strangers, which clip is
    "1 clip").
  * Random worlds rarely put a look-alike pair in the worst position (B a confirmed regular on the
    lineup, A walking in), so each fold also counts held-out look-alike pairs over the lineup bar:
    B's profile from their first two sessions, any single session of A (all clips) against it,
    ignoring margin and meeting membership. It over-counts on purpose.
  * Conditions: every `<set>__<cond>.npz` present, plus `mixed` (each person-meeting drawn from
    clean/opus12/phone/noisy) when all four exist. clean vs call-audio (opus12, phone, noisy, mixed)
    are reported separately. One set of bars covers every condition a model has (the app can't tell
    them apart), so a model's bars get stricter once its call audio lands: compare models on equal
    coverage (`--conds clean --tag clean` gives a clean-only table in its own files).
  * Answer-key audit drops: seg_ids in VP/results/audit/drop_<set>.txt are excluded before meetings
    are built (a speaker left with one session becomes a stranger). `--no-drops` keeps them. The
    drop files are part of each model's input fingerprint, so a regenerated list triggers a rerun.

Run:
  VP/venv/bin/python scripts/voiceprint/naming_sim.py                 # every model with embeddings
  VP/venv/bin/python scripts/voiceprint/naming_sim.py --models wespeaker-resnet34-lm --force
  VP/venv/bin/python scripts/voiceprint/naming_sim.py --conds clean --tag clean   # clean-only table
  VP/venv/bin/python scripts/voiceprint/naming_sim.py --summary-only
Models whose inputs haven't changed since their JSON was written are skipped unless --force.
"""
from __future__ import annotations

import os

for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_var, "1")

import argparse
import hashlib
import json
import math
import re
import sys
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

import numpy as np

REPO = Path(__file__).resolve().parents[2]


def vp_root() -> Path:
    return Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))


CONDS = ("clean", "opus12", "phone", "noisy")
CALL_CONDS = ("opus12", "phone", "noisy", "mixed")
TALKS = ("1", "3", "all")
MODES = ("recent", "invite")
NATURAL_PREFIXES = ("ami", "icsi")
FAR_GRID = (0.1, 0.03, 0.01, 0.003, 0.001, 0.0003, 0.0001)
FAR_START = 0.01
TAIL_FRAC = 0.02     # impostor tops used to fit the tail: the top 2% (at least TAIL_MIN)
TAIL_MIN = 25
IMPOSTOR_RATE = 1e-4  # tolerated share of distinct impostor encounters above the auto bar, worst condition

# App constants (WeSpeaker units), from TranscriptedCore/Speaker/*.swift.
APP = {
    "floor_many": 0.70, "floor_few": 0.78, "floor_one": 0.85,          # SpeakerEmbeddingThresholds.weSpeaker
    "bonus_immature": 0.08, "bonus_young": 0.04, "separation": 0.05,    # matchAgainstProfiles
    "auto_global": 0.92, "margin_global": 0.12, "confirms_global": 5,   # SpeakerNamingPolicy
    "auto_lineup": 0.80, "margin_lineup": 0.10, "confirms_lineup": 2,   # InviteeBars.labTuned
    "wb_confident": 0.80, "wb_cautious": 0.72, "wb_margin": 0.12,       # SpeakerWritePathPolicy
    "alpha_confident": 0.15, "alpha_cautious": 0.05,
    "ex_same": 0.80, "ex_alpha": 0.30, "ex_max": 3,                     # SpeakerExemplarPolicy
    "veto_floor": 0.80, "veto_transport": 0.75,                         # SpeakerNegativeExemplarPolicy
    "recent_limit": 12, "health_window": 5,
}
COST = {"auto_ok": 0, "suggest_ok": 1, "suggest_wrong": 3, "ask_new": 3, "ask_existing": 2, "auto_wrong": 10}


def log(msg: str) -> None:
    print(f"[naming_sim {time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def hnum(*parts: object) -> int:
    return int.from_bytes(hashlib.sha1("|".join(map(str, parts)).encode()).digest()[:8], "big")


def rng_for(*parts: object) -> np.random.Generator:
    return np.random.default_rng(hnum(*parts))


def unit(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v / n if n > 0 else v


def cos(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b))  # all stored vectors are unit length


# ---------------------------------------------------------------------------------------------
# Bars
# ---------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Bars:
    floor: float
    floor_few: float
    floor_one: float
    bonus_immature: float
    bonus_young: float
    separation: float
    auto_lineup: float
    auto_global: float
    wb_confident: float
    wb_cautious: float
    ex_same: float
    veto_floor: float
    margin_lineup: float = APP["margin_lineup"]
    margin_global: float = APP["margin_global"]
    wb_margin: float = APP["wb_margin"]
    confirms_lineup: int = APP["confirms_lineup"]
    confirms_global: int = APP["confirms_global"]

    def floor_for(self, nseg: int) -> float:
        if nseg <= 1:
            return self.floor_one
        if nseg <= 3:
            return self.floor_few
        return self.floor

    def public(self) -> dict:
        return {k: (round(v, 4) if isinstance(v, float) and math.isfinite(v) else (None if isinstance(v, float) else v))
                for k, v in self.__dict__.items()}


@dataclass(frozen=True)
class Geometry:
    """Maps a WeSpeaker-unit cosine onto a model: linear between each model's median impostor and
    median genuine session-mean cosine. Identity for the baseline (and when nothing is known)."""
    imp: float = 0.0
    gen: float = 1.0
    base_imp: float = 0.0
    base_gen: float = 1.0
    note: str = "identity"

    @property
    def scale(self) -> float:
        return (self.gen - self.imp) / (self.base_gen - self.base_imp)

    def map(self, c: float) -> float:
        return self.imp + (c - self.base_imp) * self.scale

    def public(self) -> dict:
        return {"model_median_impostor": round(self.imp, 4), "model_median_genuine": round(self.gen, 4),
                "baseline_median_impostor": round(self.base_imp, 4), "baseline_median_genuine": round(self.base_gen, 4),
                "scale": round(self.scale, 4), "note": self.note}


IDENTITY = Geometry()


def make_bars(floor: float, auto_lineup: float, auto_global: float, geo: Geometry = IDENTITY,
              fixed_margins: bool = False) -> Bars:
    k = geo.scale
    mk = 1.0 if fixed_margins else k
    return Bars(
        floor=floor,
        floor_few=floor + (APP["floor_few"] - APP["floor_many"]) * k,
        floor_one=floor + (APP["floor_one"] - APP["floor_many"]) * k,
        bonus_immature=APP["bonus_immature"] * k,
        bonus_young=APP["bonus_young"] * k,
        separation=APP["separation"] * k,
        auto_lineup=auto_lineup,
        auto_global=max(auto_global, auto_lineup),
        wb_confident=geo.map(APP["wb_confident"]),
        wb_cautious=geo.map(APP["wb_cautious"]),
        ex_same=geo.map(APP["ex_same"]),
        veto_floor=geo.map(APP["veto_floor"]),
        margin_lineup=APP["margin_lineup"] * mk,
        margin_global=APP["margin_global"] * mk,
        wb_margin=APP["wb_margin"] * mk,
    )


APP_BARS = make_bars(APP["floor_many"], APP["auto_lineup"], APP["auto_global"])


# ---------------------------------------------------------------------------------------------
# Data: sets, worlds, samples
# ---------------------------------------------------------------------------------------------

@dataclass
class SetInfo:
    name: str
    clips: dict[tuple[str, str], list[str]]
    sessions_of: dict[str, list[str]]
    speakers_of: dict[str, list[str]]
    stranger_only: set[str]
    dur: dict[str, float]
    natural: bool
    group_of: dict[str, str] = field(default_factory=dict)     # session -> meeting series (from rows)
    order_of: dict[str, tuple] = field(default_factory=dict)   # session -> sort key inside its series
    dropped: int = 0                                            # clips excluded by the audit drop list


def drop_path(name: str) -> Path:
    return vp_root() / "results" / "audit" / f"drop_{name}.txt"


def load_drops(name: str) -> set[str]:
    """seg_ids the answer-key audit wants excluded (VP/results/audit/drop_<set>.txt); empty if none."""
    p = drop_path(name)
    if not p.exists():
        return set()
    return {ln.strip() for ln in p.read_text().splitlines() if ln.strip() and not ln.startswith("#")}


def load_set(name: str, natural_prefixes: Iterable[str] = NATURAL_PREFIXES, drops: bool = True) -> SetInfo | None:
    path = vp_root() / "sets" / name / "segments.jsonl"
    if not path.exists():
        return None
    dropset = load_drops(name) if drops else set()
    n_dropped = 0
    clips: dict[tuple[str, str], list[str]] = defaultdict(list)
    stranger: set[str] = set()
    dur: dict[str, float] = {}
    group_of: dict[str, str] = {}
    order_of: dict[str, tuple] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if r["seg_id"] in dropset:
            n_dropped += 1
            continue
        clips[(r["speaker"], r["session"])].append(r["seg_id"])
        dur[r["seg_id"]] = float(r.get("dur", r.get("bucket", 0)) or 0)
        if r.get("stranger_only"):
            stranger.add(r["speaker"])
        if r.get("group"):
            group_of[r["session"]] = str(r["group"])
        if r.get("session_order") is not None or r.get("date"):
            order_of[r["session"]] = (float(r.get("session_order", 0) or 0), str(r.get("date") or ""), r["session"])
    sessions_of: dict[str, set[str]] = defaultdict(set)
    speakers_of: dict[str, set[str]] = defaultdict(set)
    for spk, ses in clips:
        sessions_of[spk].add(ses)
        speakers_of[ses].add(spk)
    for spk, ses in list(sessions_of.items()):
        if len(ses) < 2:
            stranger.add(spk)
    natural = bool(group_of) or any(name == p or name.startswith(p + "_") or name.startswith(p + "-")
                                    for p in natural_prefixes)
    return SetInfo(name, {k: sorted(v) for k, v in clips.items()},
                   {k: sorted(v) for k, v in sessions_of.items()},
                   {k: sorted(v) for k, v in speakers_of.items()}, stranger, dur, natural, group_of, order_of,
                   n_dropped)


def components(pairs_by_session: dict[str, list[str]], nodes: Iterable[str]) -> list[list[str]]:
    parent = {n: n for n in nodes}

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for members in pairs_by_session.values():
        members = [m for m in members if m in parent]
        for m in members[1:]:
            ra, rb = find(members[0]), find(m)
            if ra != rb:
                parent[rb] = ra
    groups: dict[str, list[str]] = defaultdict(list)
    for n in parent:
        groups[find(n)].append(n)
    return sorted((sorted(g) for g in groups.values()), key=lambda g: g[0])


def split_speakers(si: SetInfo) -> tuple[dict[str, int], str]:
    """Deterministic, balanced two-way split of speakers. Returns (speaker -> 0/1, method)."""
    spk = sorted(si.sessions_of)
    if si.natural:
        comps = components(si.speakers_of, spk)
        if comps and max(len(c) for c in comps) <= 0.35 * len(spk) and len(comps) >= 4:
            sizes = [0, 0]
            out: dict[str, int] = {}
            for comp in sorted(comps, key=lambda c: (-len(c), hnum("split", si.name, c[0]))):
                side = 0 if sizes[0] < sizes[1] else 1 if sizes[1] < sizes[0] else hnum("tie", si.name, comp[0]) % 2
                for s in comp:
                    out[s] = side
                sizes[side] += len(comp)
            return out, "component"
    out = {}
    for pool in (sorted(s for s in spk if s not in si.stranger_only), sorted(s for s in spk if s in si.stranger_only)):
        for i, s in enumerate(sorted(pool, key=lambda s: hnum("split", si.name, s))):
            out[s] = i % 2
    return out, "speaker"


@dataclass
class Attendee:
    person: str
    session: str
    stranger: bool


@dataclass
class Meeting:
    mid: str
    group: str
    attendees: list[Attendee]
    roster: frozenset


@dataclass
class World:
    set: str
    split: int
    rep: int
    wid: str
    meetings: list[Meeting]


def group_key(session: str) -> str:
    s = session.split(":", 1)[-1]
    m = re.match(r"^(.*\d)[a-z]$", s)
    if m:
        return m.group(1)
    m = re.match(r"^([A-Za-z]+)\d+$", s)
    if m:
        return m.group(1)
    return s


def stagger(groups: dict[str, list[Meeting]], rng: np.random.Generator, concurrency: int = 3) -> list[Meeting]:
    """Interleave group series the way a calendar does: ~`concurrency` series running at once."""
    names = [sorted(groups)[i] for i in rng.permutation(len(groups))]
    queues = {g: list(groups[g]) for g in names}
    waiting = list(names)
    active: list[str] = []
    out: list[Meeting] = []
    while waiting or active:
        while waiting and len(active) < concurrency:
            active.append(waiting.pop(0))
        for i in rng.permutation(len(active)):
            g = active[i]
            if queues[g]:
                out.append(queues[g].pop(0))
        active = [g for g in active if queues[g]]
    return out


MAX_DROPINS = 2  # strangers dropping into one group meeting; the rest meet in one-off calls


def place_strangers(worlds: list[World], strangers: list[Attendee], rng: np.random.Generator) -> None:
    """Each stranger appears once: a drop-in to a group meeting (at most MAX_DROPINS per meeting,
    about one per two meetings), or, when there are more strangers than that, a one-off call of
    2-4 strangers inserted at a random point in the timeline (yodas has ~120 strangers per half)."""
    if not worlds or not strangers:
        return
    per_world: list[list[Attendee]] = [[] for _ in worlds]
    for i, a in enumerate(strangers):
        per_world[i % len(worlds)].append(a)
    for w, pool in zip(worlds, per_world):
        n = len(w.meetings)
        n_drop = min(len(pool), (n + 1) // 2) if n else 0
        load = Counter()
        for a in pool[:n_drop]:
            open_slots = [i for i in range(n) if load[i] < MAX_DROPINS]
            i = open_slots[int(rng.integers(len(open_slots)))]
            load[i] += 1
            w.meetings[i].attendees.append(a)
        rest = pool[n_drop:]
        k = 0
        while k < len(rest):
            size = min(int(rng.integers(2, 5)), len(rest) - k)
            call = Meeting(f"{w.wid}:oneoff{k}", "oneoff", list(rest[k:k + size]), frozenset())
            w.meetings.insert(int(rng.integers(len(w.meetings) + 1)), call)
            k += size


def build_worlds(si: SetInfo, split_map: dict[str, int], split: int, rep: int, world_size: int = 40,
                 hold_frac: float = 0.2) -> list[World]:
    rng = rng_for("world", si.name, split, rep)
    S = sorted(s for s, side in split_map.items() if side == split)
    if si.natural:
        return _natural_worlds(si, S, split, rep, rng, world_size, hold_frac)
    return _synthetic_worlds(si, S, split, rep, rng, world_size, hold_frac)


def _pick_session(si: SetInfo, spk: str, rng: np.random.Generator) -> str:
    ses = si.sessions_of[spk]
    return ses[int(rng.integers(len(ses)))]


def _synthetic_worlds(si, S, split, rep, rng, world_size, hold_frac) -> list[World]:
    multi = [s for s in S if s not in si.stranger_only]
    single = [s for s in S if s in si.stranger_only]
    multi = sorted(multi, key=lambda s: hnum("hold", si.name, rep, s))
    n_hold = int(hold_frac * len(multi))
    held, regs = multi[:n_hold], multi[n_hold:]
    regs = [regs[i] for i in rng.permutation(len(regs))]
    worlds: list[World] = []
    for w0 in range(0, len(regs), world_size):
        chunk = regs[w0:w0 + world_size]
        sizes: list[int] = []
        left = len(chunk)
        while left > 0:
            g = int(rng.integers(3, 7))
            if left - g < 3 and left - g != 0:
                g = left if left <= 6 else left - 3
            sizes.append(min(g, left))
            left -= sizes[-1]
        groups: dict[str, list[Meeting]] = {}
        pos = 0
        for gi, g in enumerate(sizes):
            members = chunk[pos:pos + g]
            pos += g
            gname = f"{si.name}:g{split}.{rep}.{w0 // world_size}.{gi}"
            M = int(rng.integers(4, 9))
            slots: dict[int, list[Attendee]] = defaultdict(list)
            for p in members:
                ses = si.sessions_of[p]
                n = min(len(ses), M)
                attend = sorted(int(x) for x in rng.choice(M, n, replace=False))
                order = [ses[i] for i in rng.permutation(len(ses))][:n]
                for k, s in zip(attend, order):
                    slots[k].append(Attendee(p, s, False))
            roster = frozenset(members)
            groups[gname] = [Meeting(f"{gname}#{k}", gname, slots[k], roster) for k in sorted(slots)]
        wid = f"{si.name}/s{split}/r{rep}/w{w0 // world_size}"
        worlds.append(World(si.name, split, rep, wid, stagger(groups, rng)))
    strangers = [Attendee(p, _pick_session(si, p, rng), True) for p in single + held]
    strangers = [strangers[i] for i in rng.permutation(len(strangers))]
    place_strangers(worlds, strangers, rng)
    return worlds


def _natural_worlds(si, S, split, rep, rng, world_size, hold_frac) -> list[World]:
    Sset = set(S)
    sessions = {ses: [p for p in spk if p in Sset] for ses, spk in si.speakers_of.items()}
    sessions = {k: v for k, v in sessions.items() if v}
    multi = [s for s in S if s not in si.stranger_only]
    comps = components(sessions, multi)
    # Hold out ~hold_frac of the regulars as drop-in strangers: whole components when they are
    # small (AMI series), else single speakers (ICSI).
    held: set[str] = set()
    if comps and max(len(c) for c in comps) <= 0.35 * max(1, len(multi)) and len(comps) >= 4:
        target = hold_frac * len(multi)
        for comp in sorted(comps, key=lambda c: hnum("hold", si.name, rep, c[0])):
            if len(held) + len(comp) > target + 0.5:
                continue
            held.update(comp)
    else:
        ordered = sorted(multi, key=lambda s: hnum("hold", si.name, rep, s))
        held = set(ordered[:int(hold_frac * len(multi))])
    regs = [s for s in multi if s not in held]
    reg_set = set(regs)
    natural_strangers = {s for s in S if s in si.stranger_only}
    comps = components(sessions, regs)
    # Pack components into worlds of <= world_size regulars.
    worlds_members: list[set[str]] = []
    for comp in sorted(comps, key=lambda c: hnum("pack", si.name, rep, c[0])):
        for wm in worlds_members:
            if len(wm) + len(comp) <= world_size:
                wm.update(comp)
                break
        else:
            worlds_members.append(set(comp))
    world_of = {p: i for i, wm in enumerate(worlds_members) for p in wm}
    per_world: list[dict[str, list[tuple[str, list[str]]]]] = [defaultdict(list) for _ in worlds_members]
    orphan: list[tuple[str, list[str]]] = []
    for ses in sorted(sessions):
        people = [p for p in sessions[ses] if p in reg_set or p in natural_strangers]
        if not people:
            continue
        regs_here = [p for p in people if p in reg_set]
        if regs_here:
            per_world[world_of[regs_here[0]]][si.group_of.get(ses) or group_key(ses)].append((ses, people))
        else:
            orphan.append((ses, people))
    worlds: list[World] = []
    for wi, groups_raw in enumerate(per_world):
        groups: dict[str, list[Meeting]] = {}
        for g, items in groups_raw.items():
            roster = frozenset(p for _, ppl in items for p in ppl if p in reg_set)
            items = sorted(items, key=lambda it: si.order_of.get(it[0], (0.0, "", it[0])))
            groups[g] = [Meeting(ses, g, [Attendee(p, ses, p not in reg_set) for p in ppl], roster) for ses, ppl in items]
        worlds.append(World(si.name, split, rep, f"{si.name}/s{split}/r{rep}/w{wi}", stagger(groups, rng)))
    if not worlds and orphan:
        worlds.append(World(si.name, split, rep, f"{si.name}/s{split}/r{rep}/w0", []))
    for ses, people in orphan:  # sessions with only one-off people: drop them in as-is
        w = worlds[hnum("orphan", ses) % len(worlds)]
        w.meetings.insert(hnum("orphanpos", ses) % (len(w.meetings) + 1),
                          Meeting(ses, si.group_of.get(ses) or group_key(ses), [Attendee(p, ses, True) for p in people], frozenset()))
    strangers = [Attendee(p, _pick_session(si, p, rng), True) for p in sorted(held)]
    strangers = [strangers[i] for i in rng.permutation(len(strangers))]
    place_strangers(worlds, strangers, rng)
    return worlds


def talk_clips(si: SetInfo, person: str, session: str, talk: str, rep: int) -> list[str]:
    segs = sorted(si.clips.get((person, session), []), key=lambda s: hnum("talk", rep, s))
    if talk == "all":
        return segs
    return segs[:int(talk)]


@dataclass
class Voice:
    person: str
    stranger: bool
    vec: np.ndarray
    nseg: int
    seconds: float
    key: str = ""        # person|session: the same voice sample across reps, talk times and modes


@dataclass
class SimMeeting:
    voices: list[Voice]
    roster: frozenset


class EmbStore:
    """Normalized clip embeddings for one model: (set, cond) -> (seg index, matrix)."""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.dir = vp_root() / "emb" / model_id
        self.cache: dict[tuple[str, str], tuple[dict[str, int], np.ndarray] | None] = {}
        self.dim: int | None = None

    def path(self, set_name: str, cond: str) -> Path:
        return self.dir / f"{set_name}__{cond}.npz"

    def conds(self, set_name: str) -> list[str]:
        return [c for c in CONDS if self.path(set_name, c).exists()]

    def get(self, set_name: str, cond: str):
        key = (set_name, cond)
        if key not in self.cache:
            self.cache[key] = self._load(set_name, cond)
        return self.cache[key]

    def _load(self, set_name: str, cond: str):
        p = self.path(set_name, cond)
        if not p.exists():
            return None
        try:
            try:
                z = np.load(p, allow_pickle=False)
                ids, emb = z["seg_id"], z["emb"]
            except ValueError:
                z = np.load(p, allow_pickle=True)
                ids, emb = z["seg_id"], z["emb"]
        except Exception as exc:  # a half-written or corrupt file: skip it
            log(f"{self.model_id}: cannot read {p.name}: {exc}")
            return None
        emb = np.asarray(emb, dtype=np.float64)
        if emb.ndim != 2 or len(ids) != len(emb):
            log(f"{self.model_id}: bad shape in {p.name}")
            return None
        norms = np.linalg.norm(emb, axis=1)
        ok = np.isfinite(norms) & (norms > 1e-8) & np.all(np.isfinite(emb), axis=1)
        emb = (emb[ok] / norms[ok, None]).astype(np.float32)
        ids = [str(s) for s, keep in zip(ids, ok) if keep]
        self.dim = emb.shape[1]
        return {s: i for i, s in enumerate(ids)}, emb

    def sample(self, set_name: str, cond: str, segs: list[str]) -> np.ndarray | None:
        got = self.sample_n(set_name, cond, segs)
        return None if got is None else got[0]

    def sample_n(self, set_name: str, cond: str, segs: list[str]) -> tuple[np.ndarray, list[str]] | None:
        """L2-normalized mean of the clips present, and which clips those were."""
        got = self.get(set_name, cond)
        if got is None:
            return None
        idx, emb = got
        used = [s for s in segs if s in idx]
        if not used:
            return None
        return unit(emb[[idx[s] for s in used]].mean(axis=0).astype(np.float64)).astype(np.float32), used


def sim_meetings(world: World, si: SetInfo, store: EmbStore, cond: str, talk: str) -> tuple[list[SimMeeting], int]:
    """Turn a world's meetings into voices for one (cond, talk). Returns (meetings, voices dropped)."""
    out: list[SimMeeting] = []
    dropped = 0
    for m in world.meetings:
        voices = []
        for a in m.attendees:
            segs = talk_clips(si, a.person, a.session, talk, world.rep)
            c = cond
            if cond == "mixed":
                c = CONDS[hnum("mix", world.rep, a.person, a.session) % len(CONDS)]
            got = store.sample_n(si.name, c, segs)
            if got is None:
                dropped += 1
                continue
            vec, used = got
            voices.append(Voice(a.person, a.stranger, vec, len(used), sum(si.dur.get(s, 0.0) for s in used),
                                f"{a.person}|{a.session}"))
        if voices:
            out.append(SimMeeting(voices, m.roster))
    return out, dropped


# ---------------------------------------------------------------------------------------------
# The simulation
# ---------------------------------------------------------------------------------------------

class Prof:
    __slots__ = ("pid", "person", "avg", "ex", "neg", "calls", "conf", "dispute", "last", "outc", "alive")

    def __init__(self, pid: int, person: str | None, vec: np.ndarray, mi: int):
        self.pid = pid
        self.person = person
        self.avg = vec
        self.ex: list[np.ndarray] = []
        self.neg: list[np.ndarray] = []
        self.calls = 1
        self.conf: set[int] = set()
        self.dispute = 0
        self.last = mi
        self.outc: list[str] = []
        self.alive = True


def healthy(p: Prof) -> bool:
    """SpeakerProfileHealth.assess == .trusted."""
    if p.dispute > 0:
        return False
    window = p.outc[-APP["health_window"]:][::-1]
    latest = next((k for k in window if k != "auto"), None)
    if latest == "corrected":
        return False
    return sum(1 for k in window if k == "corrected") < 2


def wb_alpha(sim: float, second: float, bars: Bars) -> float:
    """SpeakerWritePathPolicy.voiceprintBlendAlpha."""
    if second >= 0 and sim - second < bars.wb_margin:
        return 0.0
    if sim >= bars.wb_confident:
        return APP["alpha_confident"]
    if sim >= bars.wb_cautious:
        return APP["alpha_cautious"]
    return 0.0


def ex_update(current: list[np.ndarray], new: np.ndarray, avg: np.ndarray, bars: Bars) -> list[np.ndarray]:
    """SpeakerExemplarPolicy.updated."""
    best, bi = cos(new, avg), None
    for i, e in enumerate(current):
        s = cos(new, e)
        if s > best:
            best, bi = s, i
    if best >= bars.ex_same:
        if bi is None:
            return current
        out = list(current)
        a = APP["ex_alpha"]
        out[bi] = unit(current[bi] * (1 - a) + new * a).astype(np.float32)
        return out
    if len(current) < APP["ex_max"]:
        return current + [new]
    victim, red = None, -math.inf
    for i, e in enumerate(current):
        r = cos(e, avg)
        for j, o in enumerate(current):
            if j != i:
                r = max(r, cos(e, o))
        if r > red:
            victim, red = i, r
    if victim is None or not red > best:
        return current
    out = list(current)
    out[victim] = new
    return out


def neg_similarity(x: np.ndarray, p: Prof) -> float:
    """SpeakerNegativeExemplarPolicy.maxNegativeSimilarity with condition transport."""
    best = max(cos(x, n) for n in p.neg)
    shifts = [e - p.avg for e in p.ex]
    for n in p.neg:
        for sh in shifts:
            t = n + APP["veto_transport"] * sh
            nt = float(np.linalg.norm(t))
            if nt > 0:
                best = max(best, float(np.dot(x, t)) / nt)
    return best


@dataclass
class RunResult:
    counts: Counter = field(default_factory=Counter)
    first_auto: Counter = field(default_factory=Counter)   # appearance index -> regulars, "never"
    elig: dict = field(default_factory=lambda: {"lineup": [], "global": []})  # fully eligible (diagnostic)
    wrong_top: list = field(default_factory=list)      # (similarity, average-based margin) of wrong top candidates
    wrong_names: list = field(default_factory=list)    # one dict per wrong silent name (dataset speaker ids)
    seconds: float = 0.0

    def add(self, other: "RunResult") -> None:
        self.counts.update(other.counts)
        self.first_auto.update(other.first_auto)
        for k in self.elig:
            self.elig[k].extend(other.elig[k])
        self.wrong_top.extend(other.wrong_top)
        self.wrong_names.extend(other.wrong_names)
        self.seconds += other.seconds


def simulate(meetings: list[SimMeeting], bars: Bars, mode: str, events: bool = False) -> RunResult:
    res = RunResult()
    c = res.counts
    profs: list[Prof] = []
    by_person: dict[str, Prof] = {}
    appear: Counter = Counter()
    log_rows: list[tuple[str, int, str, bool, str]] = []  # person, appearance index, decision, stranger, miss reason
    next_pid = 0

    def new_prof(person: str | None, vec: np.ndarray, mi: int) -> Prof:
        nonlocal next_pid
        p = Prof(next_pid, person, vec, mi)
        next_pid += 1
        profs.append(p)
        return p

    for mi, meeting in enumerate(meetings):
        live = [p for p in profs if p.alive]
        if mode == "invite":
            lineup = {p.pid for p in live if p.person in meeting.roster}
        else:
            recent = sorted((p for p in live if p.person and len(p.conf) >= 1), key=lambda p: (-p.last, -p.pid))
            lineup = {p.pid for p in recent[:APP["recent_limit"]]}
        cand = [p for p in live if p.dispute == 0]
        voices = meeting.voices
        V = len(voices)
        matches: list[dict | None] = [None] * V
        tops: list[tuple[Prof, float, float] | None] = [None] * V
        if cand:
            X = np.stack([v.vec for v in voices])
            avg_s = X @ np.stack([p.avg for p in cand]).T
            best_s = avg_s.copy()
            ex_rows = [(ci, e) for ci, p in enumerate(cand) for e in p.ex]
            if ex_rows:
                ex_s = X @ np.stack([e for _, e in ex_rows]).T
                for k, (ci, _) in enumerate(ex_rows):
                    np.maximum(best_s[:, ci], ex_s[:, k], out=best_s[:, ci])
            valid = np.ones(best_s.shape, dtype=bool)
            for ci, p in enumerate(cand):
                if p.neg:
                    for vi in range(V):
                        ns = neg_similarity(X[vi], p)
                        if ns >= bars.veto_floor and ns >= best_s[vi, ci]:
                            valid[vi, ci] = False
            for vi, v in enumerate(voices):
                ok = valid[vi]
                if not ok.any():
                    continue
                sims = np.where(ok, best_s[vi], -np.inf)
                top = int(np.argmax(sims))
                top_sim = float(sims[top])
                arest = np.where(ok, avg_s[vi], -np.inf)
                arest[top] = -np.inf
                a2 = float(arest.max()) if len(arest) > 1 else -np.inf
                tops[vi] = (cand[top], top_sim, float(avg_s[vi, top]) - a2 if math.isfinite(a2) else math.inf)
                thr = bars.floor_for(v.nseg)
                if top_sim < thr:
                    continue
                rest = sims.copy()
                rest[top] = -np.inf
                second_raw = float(rest.max()) if len(rest) > 1 else -np.inf
                second = second_raw if second_raw >= thr else -1.0
                p = cand[top]
                bonus = bars.bonus_immature if p.calls <= 2 else bars.bonus_young if p.calls <= 4 else 0.0
                if top_sim < thr + bonus:
                    continue
                if second >= thr and top_sim - second < bars.separation:
                    continue
                matches[vi] = {"p": p, "sim": top_sim, "second": second, "avg_top": float(avg_s[vi, top]),
                               "avg_second": a2 if math.isfinite(a2) else None}
        # Two voices on one profile: the better match keeps it, the other is spun off.
        claimed: dict[int, list[int]] = defaultdict(list)
        for vi, mt in enumerate(matches):
            if mt:
                claimed[mt["p"].pid].append(vi)
        for vis in claimed.values():
            if len(vis) > 1:
                keep = max(vis, key=lambda i: (matches[i]["sim"], voices[i].nseg, -i))
                for i in vis:
                    if i != keep:
                        matches[i] = None
        # Write-back at match time; unmatched voices become new unnamed profiles.
        snap: dict[int, tuple] = {}
        fresh: list[Prof | None] = [None] * V
        for vi, v in enumerate(voices):
            mt = matches[vi]
            if mt:
                p = mt["p"]
                snap[p.pid] = (p.avg, list(p.ex), p.calls, p.last)
                alpha = wb_alpha(mt["sim"], mt["second"], bars)
                if alpha > 0:
                    p.avg = unit(p.avg * (1 - alpha) + v.vec * alpha).astype(np.float32)
                    p.ex = ex_update(p.ex, v.vec, p.avg, bars)
                p.calls += 1
                p.last = mi
            else:
                fresh[vi] = new_prof(None, v.vec, mi)
        known_before = {v.person: by_person.get(v.person) for v in voices}

        def correct(w: Prof, v: Voice) -> None:
            if w.pid in snap:
                w.avg, w.ex, w.calls, w.last = snap.pop(w.pid)
            w.dispute += 1
            w.neg.append(v.vec)
            w.outc.append("corrected")
            t = by_person.get(v.person)
            if t is not None and t is not w and t.alive:
                t.avg = unit(t.avg * (1 - APP["alpha_confident"]) + v.vec * APP["alpha_confident"]).astype(np.float32)
                t.ex = ex_update(t.ex, v.vec, t.avg, bars)
                t.calls += 1
                t.last = mi
                t.dispute = 0
                t.conf.add(mi)
            else:
                q = new_prof(v.person, v.vec, mi)
                q.conf.add(mi)
                by_person[v.person] = q

        for vi, v in enumerate(voices):
            appear[v.person] += 1
            idx = appear[v.person]
            is_new = known_before[v.person] is None
            mt = matches[vi]
            if events and tops[vi] is not None and tops[vi][0].person != v.person:
                res.wrong_top.append((tops[vi][1], tops[vi][2], v.key or v.person, tops[vi][0].person))
            if mt is not None:
                p: Prof = mt["p"]
                if p.pid in lineup:
                    path, req, bar, mmin = "lineup", bars.confirms_lineup, bars.auto_lineup, bars.margin_lineup
                else:
                    path, req, bar, mmin = "global", bars.confirms_global, bars.auto_global, bars.margin_global
                enough = p.person is not None and len(p.conf) >= req
                trusted = healthy(p)
                recog = enough and trusted
                margin_ok = mt["avg_second"] is None or (mt["avg_top"] - mt["avg_second"]) >= mmin
                right = p.person == v.person
                if not right:
                    miss = "wrong_match"
                elif not enough:
                    miss = "off_lineup_confirmations" if path == "global" else "lineup_confirmations"
                elif not trusted:
                    miss = "health"
                elif not margin_ok:
                    miss = "margin"
                else:
                    miss = "below_bar"
                if events and not right and recog and margin_ok:
                    res.elig[path].append(mt["sim"])
                if recog and margin_ok and mt["sim"] > bar:
                    c[f"auto_{path}"] += 1
                    if right:
                        decision = "auto_ok"
                        p.outc.append("auto")
                    else:
                        decision = "auto_wrong"
                        res.wrong_names.append({
                            "meeting": mi, "voice": v.person, "named_as": p.person, "similarity": round(mt["sim"], 4),
                            "margin": None if mt["avg_second"] is None else round(mt["avg_top"] - mt["avg_second"], 4),
                            "bar": round(bar, 4), "path": path, "confirmations": len(p.conf),
                            "first_meeting": is_new, "stranger": v.stranger, "clips": v.nseg})
                        p.outc.append("auto")
                        correct(p, v)
                elif right:
                    decision = "suggest_ok"
                    p.conf.add(mi)
                    p.outc.append("confirmed")
                    p.dispute = 0
                else:
                    decision = "suggest_wrong"
                    correct(p, v)
            else:
                miss = "no_match"
                q = fresh[vi]
                k = by_person.get(v.person)
                if k is not None and k.alive:
                    decision = "ask_existing"
                    tot = k.calls + q.calls
                    k.avg = unit((k.avg * k.calls + q.avg * q.calls) / tot).astype(np.float32)
                    k.calls = tot
                    k.ex = []
                    k.last = mi
                    k.dispute = 0
                    k.conf.add(mi)
                    k.outc.append("merged")
                    q.alive = False
                else:
                    decision = "ask_new"
                    q.person = v.person
                    q.conf.add(mi)
                    q.outc.append("named")
                    by_person[v.person] = q
            c[decision] += 1
            c["work"] += COST[decision]
            c["appearances"] += 1
            c["seconds"] += v.seconds
            if is_new:
                c["new_voices"] += 1
                c[f"new_{decision}"] += 1
            if v.stranger:
                c["stranger_voices"] += 1
                c[f"stranger_{decision}"] += 1
            log_rows.append((v.person, idx, decision, v.stranger, miss))
        c["meetings"] += 1
    # Regulars: non-strangers seen in >= 3 meetings.
    total = Counter(p for p, _, _, s, _ in log_rows if not s)
    regulars = {p for p, n in total.items() if n >= 3}
    first: dict[str, int] = {}
    for person, idx, decision, _, miss in log_rows:
        if person in regulars:
            if decision == "auto_ok":
                first.setdefault(person, idx)
            if idx >= 3:
                c["reg_apps_3plus"] += 1
                c["reg_auto_3plus"] += decision == "auto_ok"
                c["reg_work_3plus"] += COST[decision]
                if decision != "auto_ok":
                    c[f"miss_{miss}"] += 1
    c["regulars"] += len(regulars)
    for person in regulars:
        res.first_auto[str(first[person]) if person in first else "never"] += 1
    return res


# ---------------------------------------------------------------------------------------------
# Metrics
# ---------------------------------------------------------------------------------------------

def derive(counts: dict, first_auto: dict) -> dict:
    c = Counter(counts)
    sugg = c["suggest_ok"] + c["suggest_wrong"]
    hist = []
    for k, n in first_auto.items():
        hist += [math.inf if k == "never" else int(k)] * int(n)
    hist.sort()

    def q(p: float):
        if not hist:
            return None
        v = hist[min(len(hist) - 1, int(math.ceil(p * len(hist))) - 1)]
        return None if v == math.inf else v

    return {
        "meetings": c["meetings"], "appearances": c["appearances"], "regulars": c["regulars"],
        "wrong_silent_names": c["auto_wrong"],
        "strangers_wrongly_named": c["new_auto_wrong"],
        "stranger_pool_wrongly_named": c["stranger_auto_wrong"],
        "wrong_suggestions": c["suggest_wrong"],
        "wrong_suggestion_rate": round(c["suggest_wrong"] / sugg, 4) if sugg else None,
        "strangers_wrongly_suggested": c["new_suggest_wrong"],
        "auto_named": c["auto_ok"],
        "auto_share_from_meeting3": round(c["reg_auto_3plus"] / c["reg_apps_3plus"], 4) if c["reg_apps_3plus"] else None,
        "first_auto_median": q(0.5), "first_auto_p90": q(0.9),
        "never_auto_share": round(first_auto.get("never", 0) / len(hist), 4) if hist else None,
        "work_per_meeting": round(c["work"] / c["meetings"], 3) if c["meetings"] else None,
        "regular_work_from_meeting3": c["reg_work_3plus"],
        "decisions": {k: c[k] for k in ("auto_ok", "auto_wrong", "suggest_ok", "suggest_wrong", "ask_new", "ask_existing")},
        "auto_paths": {"lineup": c["auto_lineup"], "global": c["auto_global"]},
        "why_not_auto_from_meeting3": {k[5:]: v for k, v in sorted(c.items()) if k.startswith("miss_") and v},
        "talk_seconds_mean": round(c["seconds"] / c["appearances"], 2) if c["appearances"] else None,
    }


# ---------------------------------------------------------------------------------------------
# Per-model evaluation
# ---------------------------------------------------------------------------------------------

@dataclass
class Spec:
    set: str
    split: int
    cond: str
    talk: str
    mode: str
    meetings: list[SimMeeting]


def pair_scores(si: SetInfo, store: EmbStore, cond: str, speakers: set[str],
                cap: int = 200_000) -> tuple[np.ndarray, np.ndarray]:
    """Cosines between session means (all clips) of the given speakers: (different people, same
    person in different sessions)."""
    keys = [(s, ses) for (s, ses) in sorted(si.clips) if s in speakers]
    vecs, owners = [], []
    for s, ses in keys:
        v = store.sample(si.name, cond, si.clips[(s, ses)])
        if v is not None:
            vecs.append(v)
            owners.append(s)
    if len(vecs) < 2:
        return np.zeros(0, dtype=np.float32), np.zeros(0, dtype=np.float32)
    X = np.stack(vecs)
    S = X @ X.T
    iu = np.triu_indices(len(X), 1)
    own = np.array(owners)
    same = own[iu[0]] == own[iu[1]]
    flat = S[iu]
    imp, gen = flat[~same], flat[same]
    if len(imp) > cap:
        imp = imp[rng_for("imp", si.name, cond).choice(len(imp), cap, replace=False)]
    return imp.astype(np.float32), gen.astype(np.float32)


def lookalike_pairs(si: SetInfo, store: EmbStore, cond: str, speakers: set[str], bar: float,
                    top_n: int = 5) -> dict:
    """World-free worst case at a bar: person B has a profile from their first two sessions (as
    after two confirmations); does any single session of a different person A clear the bar
    against it? Counts ordered pairs (A, B). Session means use all clips."""
    means: dict[str, list[np.ndarray]] = defaultdict(list)
    for spk in sorted(speakers):
        for ses in si.sessions_of.get(spk, []):
            v = store.sample(si.name, cond, si.clips[(spk, ses)])
            if v is not None:
                means[spk].append(v)
    people = sorted(p for p in means if means[p])
    owners = [p for p in people if len(means[p]) >= 2]
    if not owners or len(people) < 2:
        return {"pairs_checked": 0, "pairs_over_bar": 0, "worst": []}
    P = np.stack([unit(np.mean(means[b][:2], axis=0)) for b in owners])
    X = np.concatenate([np.stack(means[a]) for a in people])
    who = np.array([a for a in people for _ in means[a]])
    S = X @ P.T
    over, worst = 0, []
    for j, b in enumerate(owners):
        col = S[:, j]
        others = who != b
        best: dict[str, float] = {}
        for a, sim in zip(who[others], col[others]):
            best[a] = max(best.get(a, -1.0), float(sim))
        for a, sim in best.items():
            if sim > bar:
                over += 1
            worst.append((sim, a, b))
    worst.sort(reverse=True)
    return {"pairs_checked": sum(len(people) - 1 for _ in owners), "pairs_over_bar": over,
            "worst": [{"voice": a, "profile": b, "similarity": round(x, 4)} for x, a, b in worst[:top_n]]}


def run_pool(specs: list[Spec], bars: Bars, events: bool = False) -> RunResult:
    """Simulate every spec; impostor-top events come back as (similarity, margin, condition)."""
    total = RunResult()
    for s in specs:
        t0 = time.perf_counter()
        r = simulate(s.meetings, bars, s.mode, events)
        r.seconds = time.perf_counter() - t0
        r.wrong_top = [(x, m, s.cond, vk, pp) for x, m, vk, pp in r.wrong_top]
        total.add(r)
    return total


def tail_fit(sims: np.ndarray, rate: float) -> dict | None:
    """Exponential tail above the top TAIL_FRAC of impostor-top similarities.

    Returns the threshold u, the tail scale beta (mean excess over u), the tail size k out of n and
    the bar where the fit puts the share of impostor tops above it at `rate`:
    P(X > u + y) = (k / n) * exp(-y / beta) = rate  ->  bar = u + beta * ln(k / (n * rate)).
    The rate is per impostor encounter, so the bar doesn't tighten just because the pool is bigger.
    None when there are too few impostor tops to fit.
    """
    n = len(sims)
    if n < 50:
        return None
    k = max(TAIL_MIN, int(math.ceil(TAIL_FRAC * n)))
    srt = np.sort(sims)
    u = float(srt[-(k + 1)])
    beta = max(float((srt[-k:] - u).mean()), 1e-4)
    return {"n": n, "u": u, "beta": beta, "k": k, "bar": u + beta * max(0.0, math.log(k / (n * rate))),
            "max": float(srt[-1])}


def calibrate_auto(specs: list[Spec], floor: float, geo: Geometry, rate: float, fixed_margins: bool,
                   max_iter: int = 6) -> tuple[float, float, list[dict]]:
    """Lowest safe auto bars (see module doc). Returns (A_L, A_G, trace)."""
    AL = AG = math.inf
    trace = []
    for it in range(max_iter):
        bars = make_bars(floor, AL, AG, geo, fixed_margins)
        r = run_pool(specs, bars, events=True)
        # Distinct impostor encounters: the same (condition, voice sample, wrongly matched person)
        # recurs across reps, talk times and lineup modes; counting each copy let one look-alike
        # pair fill the fitted tail. Keep its highest similarity (and that event's margin).
        distinct: dict[tuple, tuple[float, float]] = {}
        for x, m, c, vk, pp in r.wrong_top:
            key = (c, vk, pp)
            if key not in distinct or x > distinct[key][0]:
                distinct[key] = (x, m)
        keys = list(distinct)
        sims = np.array([distinct[k][0] for k in keys]) if keys else np.zeros(0)
        margins = np.array([distinct[k][1] for k in keys]) if keys else np.zeros(0)
        conds = np.array([k[0] for k in keys]) if keys else np.zeros(0, dtype=str)
        # One tail per audio condition; the strictest wins, so the bar holds even if every
        # meeting is in the worst condition (the app uses one bar and can't tell them apart).
        per_cond = {c: tail_fit(sims[conds == c], rate) for c in sorted(set(conds.tolist()))}
        per_cond = {c: t for c, t in per_cond.items() if t is not None}
        tail = max(per_cond.values(), key=lambda t: t["bar"]) if per_cond else None
        # Zero-wrong bar: the highest impostor that tops the lineup by the path's margin, whatever
        # its confirmations (those depend on the run; the voice geometry doesn't).
        clearL = sims[margins >= bars.margin_lineup]
        clearG = sims[margins >= bars.margin_global]
        eL = float(clearL.max()) if len(clearL) else None
        eG = float(clearG.max()) if len(clearG) else None
        if tail is None:
            nAL = nAG = math.inf  # too little impostor evidence to set a safe bar: never name silently
        else:
            b = tail["beta"]
            nAL = max(tail["bar"], (eL + b) if eL is not None else -math.inf)
            nAG = max(tail["bar"], (eG + b) if eG is not None else -math.inf, nAL)
        trace.append({"iter": it, "bars_in": [None if math.isinf(AL) else round(AL, 4), None if math.isinf(AG) else round(AG, 4)],
                      "impostor_tops": int(len(sims)), "impostor_top_events": len(r.wrong_top),
                      "tail": tail and {k: round(v, 4) if isinstance(v, float) else v for k, v in tail.items()},
                      "tail_by_cond": {c: round(t["bar"], 4) for c, t in per_cond.items()},
                      "tail_cond": next((c for c, t in per_cond.items() if t is tail), None),
                      "impostor_top_std": round(float(np.std(sims)), 4) if len(sims) else None,
                      "clear_margin_impostors": {"lineup": int(len(clearL)), "global": int(len(clearG))},
                      "max_clear_margin_impostor": {"lineup": eL and round(eL, 4), "global": eG and round(eG, 4)},
                      "fully_eligible_impostors": {"lineup": len(r.elig["lineup"]), "global": len(r.elig["global"])},
                      "max_fully_eligible_impostor": {k: (round(max(v), 4) if v else None) for k, v in r.elig.items()},
                      "wrong_silent": r.counts["auto_wrong"], "work": r.counts["work"]})
        if it == 0:
            AL, AG = nAL, nAG
            if math.isinf(AL):
                break
            continue
        if nAL <= AL + 1e-9 and nAG <= AG + 1e-9:
            break
        AL, AG = max(AL, nAL), max(AG, nAG)
    return AL, AG, trace


def calibrate(specs: list[Spec], imp: np.ndarray, geo: Geometry, rate: float,
              fixed_margins: bool = False) -> tuple[Bars, dict]:
    grid = [(far, float(np.quantile(imp, 1 - far))) for far in FAR_GRID] if len(imp) else [(FAR_START, geo.map(APP["floor_many"]))]
    F0 = next((f for far, f in grid if far == FAR_START), grid[len(grid) // 2][1])
    AL, AG, trace0 = calibrate_auto(specs, F0, geo, rate, fixed_margins)
    sweep = []
    for far, F in grid:
        r = run_pool(specs, make_bars(F, AL, AG, geo, fixed_margins))
        sweep.append({"far": far, "floor": round(F, 4), "work_per_meeting": round(r.counts["work"] / max(1, r.counts["meetings"]), 4),
                      "wrong_silent": r.counts["auto_wrong"], "wrong_suggestions": r.counts["suggest_wrong"],
                      "auto_named": r.counts["auto_ok"], "_work": r.counts["work"]})
    ok = [s for s in sweep if s["wrong_silent"] == 0] or sweep
    best = min(s["_work"] for s in ok)
    chosen = max((s for s in ok if s["_work"] <= best * 1.02), key=lambda s: s["floor"])
    F = chosen["floor"]
    AL, AG, trace1 = calibrate_auto(specs, F, geo, rate, fixed_margins)
    bars = make_bars(F, AL, AG, geo, fixed_margins)
    for s in sweep:
        s.pop("_work")
    info = {"impostor_rate": rate, "tail_final": trace1[-1]["tail"], "tail_cond": trace1[-1]["tail_cond"],
            "tail_by_cond": trace1[-1]["tail_by_cond"],
            "floor_grid": sweep, "floor_chosen_far": chosen["far"], "auto_trace_start": trace0, "auto_trace_final": trace1}
    return bars, info


def read_meta(model_id: str) -> dict:
    p = vp_root() / "models" / model_id / "model.json"
    try:
        return json.loads(p.read_text())
    except Exception:
        return {"model_id": model_id}


def find_baseline() -> str | None:
    cands = []
    for p in sorted((vp_root() / "models").glob("*/model.json")):
        try:
            meta = json.loads(p.read_text())
        except Exception:
            continue
        if meta.get("baseline"):
            cands.append(meta.get("model_id", p.parent.name))
    cands.sort(key=lambda m: (not ("wespeaker" in m and "resnet34" in m), m))
    return cands[0] if cands else None


def input_fingerprint(store: EmbStore, sets: list[str], drops: bool = True,
                      conds: list[str] | None = None, used: dict[str, list[str]] | None = None) -> dict:
    """mtime/size of every input. `used` (set -> conds actually loaded) pins it to what a run read,
    so files that land mid-run make the next run redo the model."""
    fp = {}
    for s in sets:
        seg = vp_root() / "sets" / s / "segments.jsonl"
        if not seg.exists():
            continue
        present = store.conds(s) if used is None else [c for c in used.get(s, []) if c != "mixed"]
        present = [c for c in present if not conds or c in conds]
        if not present:
            continue  # nothing of this set was (or would be) read
        for cnd in present:
            st = store.path(s, cnd).stat()
            fp[f"{s}__{cnd}"] = [int(st.st_mtime), st.st_size]
        fp[f"{s}/segments"] = [int(seg.stat().st_mtime), seg.stat().st_size]
        if drops and drop_path(s).exists():
            st = drop_path(s).stat()
            fp[f"{s}/drops"] = [int(st.st_mtime), st.st_size]
    return fp


@dataclass
class Options:
    sets: list[str] | None = None
    conds: list[str] | None = None
    talks: tuple[str, ...] = TALKS
    modes: tuple[str, ...] = MODES
    reps: int = 2
    world_size: int = 40
    impostor_rate: float = IMPOSTOR_RATE
    fixed_margins: bool = False          # headline variant uses the app's literal 0.12/0.10 margins
    secondary_fixed: bool = True         # also score the fixed-margin variant as a secondary result
    drops: bool = True                   # exclude VP/results/audit/drop_<set>.txt
    tag: str | None = None               # write to results/naming_<tag>/ and naming_summary_<tag>.md
    natural: tuple[str, ...] = NATURAL_PREFIXES
    mixed: bool = True


def discover_sets() -> list[str]:
    return sorted(p.parent.name for p in (vp_root() / "sets").glob("*/segments.jsonl") if not p.parent.name.startswith("_"))


def evaluate_model(model_id: str, opts: Options) -> dict | None:
    t_start = time.time()
    meta = read_meta(model_id)
    store = EmbStore(model_id)
    set_names = opts.sets or discover_sets()
    baseline_id = find_baseline()
    is_baseline = bool(meta.get("baseline")) or model_id == baseline_id
    base_store = EmbStore(baseline_id) if baseline_id and not is_baseline else None

    sets: dict[str, SetInfo] = {}
    conds_of: dict[str, list[str]] = {}
    for s in set_names:
        conds = store.conds(s)
        if opts.conds:
            conds = [c for c in conds if c in opts.conds]
        if not conds:
            continue
        si = load_set(s, opts.natural, opts.drops)
        if si is None:
            continue
        loaded = [c for c in conds if store.get(s, c) is not None]
        if not loaded:
            continue
        if opts.mixed and all(c in loaded for c in CONDS) and (not opts.conds or "mixed" in opts.conds):
            loaded = loaded + ["mixed"]
        sets[s] = si
        conds_of[s] = loaded
    if not sets:
        log(f"{model_id}: no embeddings for any set yet; skipped")
        return None

    specs: dict[int, list[Spec]] = {0: [], 1: []}
    split_info = {}
    dropped = 0
    split_maps = {}
    for s, si in sets.items():
        split_map, method = split_speakers(si)
        split_maps[s] = split_map
        split_info[s] = {"method": method, "speakers": [sum(1 for v in split_map.values() if v == k) for k in (0, 1)],
                         "natural": si.natural}
        for split in (0, 1):
            for rep in range(opts.reps):
                for w in build_worlds(si, split_map, split, rep, opts.world_size):
                    for cond in conds_of[s]:
                        for talk in opts.talks:
                            ms, d = sim_meetings(w, si, store, cond, talk)
                            dropped += d
                            if not ms:
                                continue
                            for mode in opts.modes:
                                specs[split].append(Spec(s, split, cond, talk, mode, ms))
    fold_inputs = []
    for fold, (cal, test) in enumerate(((0, 1), (1, 0))):
        imp_parts, anchor_m, anchor_b, anchor_pairs = [], ([], []), ([], []), []
        for s, si in sets.items():
            spk = {p for p, v in split_maps[s].items() if v == cal}
            for cond in conds_of[s]:
                if cond == "mixed":
                    continue
                imp_m, gen_m = pair_scores(si, store, cond, spk)
                imp_parts.append(imp_m)
                if base_store is not None and base_store.get(s, cond) is not None and len(imp_m) and len(gen_m):
                    imp_b, gen_b = pair_scores(si, base_store, cond, spk)
                    if len(imp_b) and len(gen_b):
                        anchor_m[0].append(imp_m)
                        anchor_m[1].append(gen_m)
                        anchor_b[0].append(imp_b)
                        anchor_b[1].append(gen_b)
                        anchor_pairs.append(f"{s}__{cond}")
        imp = np.concatenate(imp_parts) if imp_parts else np.zeros(0, np.float32)
        if is_baseline:
            geo = Geometry(note="identity (this is the baseline)")
        elif anchor_pairs:
            med = lambda parts: float(np.median(np.concatenate(parts)))  # noqa: E731
            geo = Geometry(med(anchor_m[0]), med(anchor_m[1]), med(anchor_b[0]), med(anchor_b[1]),
                           f"linear vs {baseline_id} on {', '.join(anchor_pairs)}")
            if not geo.scale > 0:
                geo = Geometry(note=f"identity (no genuine/impostor gap vs {baseline_id})")
        else:
            geo = Geometry(note="identity (no baseline embeddings on these sets)")
        if specs[cal]:
            fold_inputs.append((fold, cal, test, imp, geo))

    def run_variant(fixed_margins: bool) -> tuple[list[dict], list[dict]]:
        folds, rows = [], []
        for fold, cal, test, imp, geo in fold_inputs:
            log(f"{model_id}: fold {fold} calibrating on {len(specs[cal])} runs"
                f"{' (fixed margins)' if fixed_margins else ''}")
            bars, info = calibrate(specs[cal], imp, geo, opts.impostor_rate, fixed_margins)
            info["geometry"] = geo.public()
            info["impostor_pairs"] = int(len(imp))
            look = {}
            for s_name, si in sets.items():
                spk_test = {p for p, v in split_maps[s_name].items() if v == test}
                for cond in conds_of[s_name]:
                    if cond != "mixed":
                        look[f"{s_name}__{cond}"] = lookalike_pairs(si, store, cond, spk_test, bars.auto_lineup)
            folds.append({"fold": fold, "calib_split": cal, "test_split": test, "bars": bars.public(), "calibration": info,
                          "test_lookalikes": look,
                          "test_lookalike_pairs_over_bar": sum(v["pairs_over_bar"] for v in look.values()),
                          "test_lookalike_pairs_checked": sum(v["pairs_checked"] for v in look.values())})
            for split_name, split in (("calib", cal), ("test", test)):
                for sp in specs[split]:
                    r = simulate(sp.meetings, bars, sp.mode)
                    rows.append({"set": sp.set, "cond": sp.cond, "talk": sp.talk, "mode": sp.mode, "fold": fold,
                                 "split": split_name, "counts": dict(r.counts), "first_auto": dict(r.first_auto),
                                 "wrong_names": r.wrong_names})
        return folds, merge_rows(rows)

    folds, rows = run_variant(opts.fixed_margins)
    secondary = None
    if opts.secondary_fixed and not opts.fixed_margins and not is_baseline_scale(fold_inputs):
        f2, r2 = run_variant(True)
        secondary = {"fixed_margins": True, "folds": [{k: f[k] for k in ("fold", "bars", "test_lookalike_pairs_over_bar",
                                                                         "test_lookalike_pairs_checked")} for f in f2],
                     "pooled": {sp: {k: v for k, v in pv.items() if k in ("all", "clean", "call", "by_set", "by_mode")}
                                for sp, pv in pooled_views(r2, []).items()},
                     "wrong_silent_name_events": wrong_name_events(r2)}
    app_rows = []
    if is_baseline:
        for split in (0, 1):
            for sp in specs[split]:
                r = simulate(sp.meetings, APP_BARS, sp.mode)
                app_rows.append({"set": sp.set, "cond": sp.cond, "talk": sp.talk, "mode": sp.mode, "fold": "app",
                                 "split": f"half{split}", "counts": dict(r.counts), "first_auto": dict(r.first_auto),
                                 "wrong_names": r.wrong_names})
    app_rows = merge_rows(app_rows)
    out = {
        "model_id": model_id, "baseline": is_baseline, "family": meta.get("family"), "dim": meta.get("dim") or store.dim,
        "params_m": meta.get("params_m"), "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "inputs": input_fingerprint(store, list(sets), opts.drops, opts.conds, conds_of), "sets": {s: conds_of[s] for s in sets},
        "splits": split_info,
        "options": {"talks": list(opts.talks), "modes": list(opts.modes), "reps": opts.reps, "world_size": opts.world_size,
                    "impostor_rate": opts.impostor_rate, "fixed_margins": opts.fixed_margins,
                    "secondary_fixed": opts.secondary_fixed, "drops": opts.drops, "conds": opts.conds,
                    "tag": opts.tag},
        "policy": {"app_constants": APP, "cost": COST, "far_grid": FAR_GRID, "app_bars": APP_BARS.public()},
        "voices_dropped_missing_embeddings": dropped,
        "audit_drops": ({s: {"clips_dropped": si.dropped, "file": str(drop_path(s).relative_to(vp_root()))}
                         for s, si in sets.items()} if opts.drops else "disabled (--no-drops)"),
        "fixed_margin_variant": secondary if secondary is not None else
            ("same as headline (scale 1: margins unchanged)" if not opts.fixed_margins else "headline is fixed margins"),
        "folds": folds,
        "pooled": pooled_views(rows, app_rows),
        "wrong_silent_name_events": wrong_name_events(rows),
        "app_bar_wrong_silent_name_events": wrong_name_events(app_rows),
        "rows": [finish_row(r) for r in rows],
        "app_bar_rows": [finish_row(r) for r in app_rows],
        "runtime_s": round(time.time() - t_start, 1),
    }
    return out


def merge_rows(rows: list[dict]) -> list[dict]:
    """Sum runs that share (set, cond, talk, mode, fold, split): worlds and reps become one row."""
    keyf = ("set", "cond", "talk", "mode", "fold", "split")
    out: dict[tuple, dict] = {}
    for r in rows:
        k = tuple(r[f] for f in keyf)
        if k not in out:
            out[k] = {**{f: r[f] for f in keyf}, "counts": Counter(), "first_auto": Counter(), "wrong_names": []}
        out[k]["counts"].update(r["counts"])
        out[k]["first_auto"].update(r["first_auto"])
        out[k]["wrong_names"].extend(r.get("wrong_names") or [])
    return [{**v, "counts": dict(v["counts"]), "first_auto": dict(v["first_auto"])} for v in out.values()]


def is_baseline_scale(fold_inputs: list) -> bool:
    """True when every fold's geometry is identity-scaled, so fixed margins would change nothing."""
    return all(abs(geo.scale - 1.0) < 1e-9 for *_, geo in fold_inputs)


def finish_row(r: dict) -> dict:
    out = {**{k: r[k] for k in ("set", "cond", "talk", "mode", "fold", "split")}, **derive(r["counts"], r["first_auto"]),
           "counts": r["counts"], "first_auto_hist": r["first_auto"]}
    if r.get("wrong_names"):
        out["wrong_name_events"] = r["wrong_names"]
    return out


def wrong_name_events(rows: list[dict]) -> list[dict]:
    """Every wrong silent name, with its run context. The same voice usually recurs across talk
    times and lineup modes, so `distinct` groups by (split, fold, set, voice, named_as)."""
    out = []
    for r in rows:
        for e in r.get("wrong_names") or []:
            out.append({**{k: r[k] for k in ("split", "fold", "set", "cond", "talk", "mode")}, **e})
    return out


def pool(rows: list[dict], pred: Callable[[dict], bool]) -> dict | None:
    counts: Counter = Counter()
    fa: Counter = Counter()
    n = 0
    for r in rows:
        if pred(r):
            counts.update(r["counts"])
            fa.update(r.get("first_auto") or r.get("first_auto_hist") or {})
            n += 1
    return {**derive(counts, fa), "runs": n} if n else None


def pooled_views(rows: list[dict], app_rows: list[dict]) -> dict:
    views = {}
    for split in ("test", "calib"):
        base = [r for r in rows if r["split"] == split]
        views[split] = {
            "all": pool(base, lambda r: True),
            "clean": pool(base, lambda r: r["cond"] == "clean"),
            "call": pool(base, lambda r: r["cond"] in CALL_CONDS),
            "by_cond": {c: pool(base, lambda r, c=c: r["cond"] == c) for c in CONDS + ("mixed",)},
            "by_talk": {t: pool(base, lambda r, t=t: r["talk"] == t) for t in TALKS},
            "by_mode": {m: pool(base, lambda r, m=m: r["mode"] == m) for m in MODES},
            "by_set": {s: pool(base, lambda r, s=s: r["set"] == s) for s in sorted({r["set"] for r in base})},
        }
    if app_rows:
        views["app_bars"] = {
            "all": pool(app_rows, lambda r: True),
            "clean": pool(app_rows, lambda r: r["cond"] == "clean"),
            "call": pool(app_rows, lambda r: r["cond"] in CALL_CONDS),
        }
    return views


# ---------------------------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------------------------

def fmt(v, pct: bool = False, nd: int = 2) -> str:
    if v is None:
        return "–"
    if pct:
        return f"{100 * v:.0f}%" if v >= 0.1 or v == 0 else f"{100 * v:.1f}%"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def first_auto_cell(p: dict | None) -> str:
    if not p or not p.get("regulars"):
        return "–"
    med = p["first_auto_median"]
    p90 = p["first_auto_p90"]
    ever = 1 - (p.get("never_auto_share") or 0)
    return f"{med if med is not None else 'never'} / {p90 if p90 is not None else 'never'} ({fmt(ever, pct=True)})"


def write_summary(results_dir: Path, out_path: Path) -> str:
    docs = []
    for p in sorted(results_dir.glob("*.json")):
        try:
            docs.append(json.loads(p.read_text()))
        except Exception:
            continue
    lines = ["# Voiceprint naming simulation", "",
             f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `scripts/voiceprint/naming_sim.py`. "
             "Test-split numbers: bars are calibrated on one half of the speakers and scored on the other, "
             "both ways (2 folds), pooled over sets, talk times (1 / 3 / all clips) and lineup modes "
             "(calendar invite / 12 most recent). Clean = `clean`; call = opus12, phone, noisy and mixed.", "",
             "Ranked by the share of a regular's appearances named automatically from their 3rd meeting on, "
             "among models with zero wrong silent names (then models with look-alike pairs over their bar, then "
             "models with wrong names). **Wrong silent names must be 0.** Headline: every cosine constant, margins "
             "included, carried to each model's scale; last column: the app's literal 0.12/0.10 margins.", ""]
    cond_filters = sorted({",".join(d.get("options", {}).get("conds") or ["all present"]) for d in docs})
    lines += [f"Conditions used for calibration and scoring: {'; '.join(cond_filters)}. One set of bars per model covers "
              "every condition it has, like the app; a model with call audio gets stricter bars than the same model "
              "on clean alone, so compare models on the same coverage.", ""]
    drops: dict[str, int] = {}
    no_drops = []
    for d in docs:
        ad = d.get("audit_drops")
        if isinstance(ad, dict):
            for st, v in ad.items():
                drops[st] = max(drops.get(st, 0), v["clips_dropped"])
        else:
            no_drops.append(d["model_id"])
    if drops:
        lines += ["Answer-key audit drops applied (`VP/results/audit/drop_<set>.txt`, clips excluded before building "
                  "meetings): " + ", ".join(f"{st} {n}" for st, n in sorted(drops.items())) + "."
                  + (f" Run without drops: {', '.join(no_drops)}." if no_drops else ""), ""]
    if not docs:
        lines.append("No results yet.")
        text = "\n".join(lines) + "\n"
        out_path.write_text(text)
        return text

    def key(d):
        t = d["pooled"]["test"]["all"] or {}
        wrong = (t.get("wrong_silent_names") or 0) + ((d["pooled"]["calib"]["all"] or {}).get("wrong_silent_names") or 0)
        look = sum(f.get("test_lookalike_pairs_over_bar", 0) for f in d.get("folds", []))
        return (wrong > 0, look > 0, -(t.get("auto_share_from_meeting3") or 0), t.get("work_per_meeting") or 99)

    def worst_lookalikes(d) -> str:
        items = [(w["similarity"], w["voice"], w["profile"], f["bars"]["auto_lineup"])
                 for f in d.get("folds", []) for v in f.get("test_lookalikes", {}).values() for w in v["worst"]]
        items = [x for x in sorted(items, reverse=True) if x[0] > x[3]]
        return "; ".join(f"{a} as {b} {s:.3f} (bar {bar:.3f})" for s, a, b, bar in items[:3])

    docs.sort(key=key)
    lines += ["| # | model | wrong silent names clean / call | look-alike pairs over bar | strangers wrongly named | wrong suggestions | "
              "auto from mtg 3+ clean | auto from mtg 3+ call | first auto median / p90 clean | first auto median / p90 call | "
              "work per meeting clean / call | coverage | bars fold 0; fold 1 (suggest / lineup / global) | "
              "fixed margins 0.12/0.10: wrong clean / call · auto from mtg 3+ clean / call |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for i, d in enumerate(docs, 1):
        t = d["pooled"]["test"]
        cl, ca, al = t["clean"], t["call"], t["all"]
        name = f"**{d['model_id']}** (baseline)" if d.get("baseline") else d["model_id"]
        wrong = f"{(cl or {}).get('wrong_silent_names', '–')} / {(ca or {}).get('wrong_silent_names', '–')}"
        if al and al["wrong_silent_names"]:
            wrong = f"**{wrong}**"
        bars = "; ".join(f"{f['bars']['floor']:.2f} / {f['bars']['auto_lineup']:.2f} / {f['bars']['auto_global']:.2f}"
                         for f in d.get("folds", []))
        cov = f"{len(d['sets'])} sets, {sum(len(v) for v in d['sets'].values())} set×cond"
        fv = d.get("fixed_margin_variant")
        if isinstance(fv, dict):
            ft = fv["pooled"]["test"]
            fcl, fca = ft.get("clean") or {}, ft.get("call") or {}
            fixed = (f"{fcl.get('wrong_silent_names', '–')} / {fca.get('wrong_silent_names', '–')} · "
                     f"{fmt(fcl.get('auto_share_from_meeting3'), pct=True)} / {fmt(fca.get('auto_share_from_meeting3'), pct=True)}")
            if (ft.get("all") or {}).get("wrong_silent_names"):
                fixed = f"**{fixed}**"
        else:
            fixed = "same" if fv else "–"
        look_over = sum(f.get("test_lookalike_pairs_over_bar", 0) for f in d.get("folds", []))
        look_n = sum(f.get("test_lookalike_pairs_checked", 0) for f in d.get("folds", []))
        look = f"{look_over} / {look_n}" if look_n else "–"
        if look_over:
            look = f"**{look}**"
        lines.append(
            f"| {i} | {name} | {wrong} | {look} | {fmt((al or {}).get('strangers_wrongly_named'))} | "
            f"{fmt((al or {}).get('wrong_suggestions'))} ({fmt((al or {}).get('wrong_suggestion_rate'), pct=True)}) | "
            f"{fmt((cl or {}).get('auto_share_from_meeting3'), pct=True)} | {fmt((ca or {}).get('auto_share_from_meeting3'), pct=True)} | "
            f"{first_auto_cell(cl)} | {first_auto_cell(ca)} | "
            f"{fmt((cl or {}).get('work_per_meeting'))} / {fmt((ca or {}).get('work_per_meeting'))} | {cov} | {bars} | {fixed} |")
    base = [d for d in docs if d.get("baseline") and d["pooled"].get("app_bars")]
    if base:
        lines += ["", "Baseline with the app's production bars (0.70 / 0.80 / 0.92), both halves, no calibration:", "",
                  "| model | wrong silent names clean / call | strangers wrongly named | auto from mtg 3+ clean / call | "
                  "first auto median / p90 clean | work per meeting clean / call |", "|---|---|---|---|---|---|"]
        for d in base:
            a = d["pooled"]["app_bars"]
            cl, ca, al = a["clean"] or {}, a["call"] or {}, a["all"] or {}
            lines.append(f"| {d['model_id']} | {cl.get('wrong_silent_names', '–')} / {ca.get('wrong_silent_names', '–')} | "
                         f"{fmt(al.get('strangers_wrongly_named'))} | {fmt(cl.get('auto_share_from_meeting3'), pct=True)} / "
                         f"{fmt(ca.get('auto_share_from_meeting3'), pct=True)} | {first_auto_cell(cl)} | "
                         f"{fmt(cl.get('work_per_meeting'))} / {fmt(ca.get('work_per_meeting'))} |")
    sets = sorted({s for d in docs for s in d["sets"]})
    if sets:
        lines += ["", "Per set (test split, all conditions): auto from meeting 3+ · wrong silent names", "",
                  "| model | " + " | ".join(sets) + " |", "|---|" + "---|" * len(sets)]
        for d in docs:
            cells = []
            for s in sets:
                p = d["pooled"]["test"]["by_set"].get(s)
                cells.append("–" if not p else f"{fmt(p['auto_share_from_meeting3'], pct=True)} · {p['wrong_silent_names']}")
            lines.append(f"| {d['model_id']} | " + " | ".join(cells) + " |")
        lines += ["", "Per lineup mode (test split, all conditions): auto from meeting 3+ · wrong silent names", "",
                  "| model | invite | recent-12 |", "|---|---|---|"]
        for d in docs:
            bm = d["pooled"]["test"]["by_mode"]
            cells = ["–" if not bm.get(m) else f"{fmt(bm[m]['auto_share_from_meeting3'], pct=True)} · {bm[m]['wrong_silent_names']}"
                     for m in ("invite", "recent")]
            lines.append(f"| {d['model_id']} | " + " | ".join(cells) + " |")
    bad = [(d, e) for d in docs for e in d.get("wrong_silent_name_events", []) if e["split"] == "test"]
    if bad:
        lines += ["", "Wrong silent names on held-out speakers (one row per distinct voice → name; runs = how many "
                  "cond × talk × mode runs repeated it):", "",
                  "| model | set | voice | named as | similarity (max) | bar | lineup path | first meeting | runs |",
                  "|---|---|---|---|---|---|---|---|---|"]
        groups: dict[tuple, list[dict]] = defaultdict(list)
        for d, e in bad:
            groups[(d["model_id"], e["set"], e["voice"], e["named_as"])].append(e)
        for (mid, st, voice, named), es in sorted(groups.items()):
            lines.append(f"| {mid} | {st} | {voice} | {named} | {max(x['similarity'] for x in es):.3f} | "
                         f"{min(x['bar'] for x in es):.3f} | {'/'.join(sorted({x['path'] for x in es}))} | "
                         f"{'yes' if any(x['first_meeting'] for x in es) else 'no'} | {len(es)} |")
    risky = [(d["model_id"], worst_lookalikes(d)) for d in docs if worst_lookalikes(d)]
    if risky:
        lines += ["", "Look-alike pairs over the lineup bar on held-out speakers (world-free worst case: B has a profile from two "
                  "sessions, one session of A clears the bar against it):", ""]
        lines += [f"- {mid}: {txt}" for mid, txt in risky]
    calib_wrong = [d["model_id"] for d in docs if (d["pooled"]["calib"]["all"] or {}).get("wrong_silent_names")]
    lines += ["", "Notes:",
              "- Work: type a name 3, pick an existing person 2, confirm a suggestion 1, correct a wrong suggestion 3, "
              "fix a wrong silent name 10.",
              "- A 'regular' has 3+ meetings; 'first auto' is the regular's own meeting number (3 is the earliest the "
              "lineup ladder allows); 'never' = more than that share of regulars was never named silently; the "
              "percentage is the share of regulars named silently at least once.",
              "- Strangers wrongly named = silent names on one-off strangers or on anyone's first meeting.",
              "- Look-alike pairs over bar = held-out (A, B) pairs where one session of A clears the lineup bar against B's "
              "two-session profile (ignores the margin rule and who is in the meeting, so it over-counts; a nonzero value is "
              "a wrong-name risk the random meetings may not have hit).",
              "- Bars: suggest floor (4+ segments) / lineup auto bar / global auto bar, in each model's own cosine units. "
              "Auto bar = exponential tail of distinct impostor tops, one fit per condition, strictest wins, leaving a "
              "share of 1e-4 above it (`--impostor-rate`); never below the worst clear-margin impostor + beta.",
              "- Coverage differs while embeddings land; compare models on the same coverage before drawing conclusions."]
    if calib_wrong:
        lines.append(f"- Calibration split still had wrong silent names for: {', '.join(calib_wrong)} (should never happen; check).")
    text = "\n".join(lines) + "\n"
    out_path.write_text(text)
    return text


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def results_paths(tag: str | None) -> tuple[Path, Path]:
    base = vp_root() / "results"
    if not tag:
        return base / "naming", base / "naming_summary.md"
    return base / f"naming_{tag}", base / f"naming_summary_{tag}.md"


def discover_models() -> list[str]:
    d = vp_root() / "emb"
    return sorted(p.name for p in d.iterdir() if p.is_dir() and any(p.glob("*__*.npz"))) if d.exists() else []


def run_one(args: tuple[str, Options, bool]) -> tuple[str, str]:
    model_id, opts, force = args
    out_dir = results_paths(opts.tag)[0]
    out_path = out_dir / f"{model_id}.json"
    store = EmbStore(model_id)
    fp = input_fingerprint(store, opts.sets or discover_sets(), opts.drops, opts.conds)
    if not fp:
        return model_id, "skipped: no embeddings"
    if out_path.exists() and not force:
        try:
            old = json.loads(out_path.read_text())
            o = old.get("options", {})
            if (old.get("inputs") == fp and o.get("impostor_rate") == opts.impostor_rate
                    and o.get("fixed_margins", False) == opts.fixed_margins and o.get("drops", False) == opts.drops
                    and o.get("secondary_fixed", False) == opts.secondary_fixed and o.get("reps") == opts.reps):
                return model_id, "up to date"
        except Exception:
            pass
    doc = evaluate_model(model_id, opts)
    if doc is None:
        return model_id, "skipped: no usable embeddings"
    out_dir.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=1, default=lambda o: None if isinstance(o, float) and not math.isfinite(o) else str(o)))
    os.replace(tmp, out_path)
    t = doc["pooled"]["test"]["all"] or {}
    return model_id, (f"done in {doc['runtime_s']}s: test wrong silent {t.get('wrong_silent_names')}, "
                      f"auto from mtg 3+ {fmt(t.get('auto_share_from_meeting3'), pct=True)}, "
                      f"work/meeting {t.get('work_per_meeting')}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models", help="comma-separated model ids (default: every VP/emb/<model> with embeddings)")
    ap.add_argument("--sets", help="comma-separated set names (default: all)")
    ap.add_argument("--conds", help="comma-separated conditions (default: all present, plus mixed)")
    ap.add_argument("--talks", default=",".join(TALKS))
    ap.add_argument("--modes", default=",".join(MODES))
    ap.add_argument("--reps", type=int, default=2, help="reseeded worlds per split")
    ap.add_argument("--world-size", type=int, default=40)
    ap.add_argument("--impostor-rate", type=float, default=IMPOSTOR_RATE,
                    help="tolerated share of impostor encounters above the auto bar, in the worst condition")
    ap.add_argument("--fixed-margins", action="store_true",
                    help="headline uses the app's margins at 0.12/0.10 in every model's units instead of scaling them")
    ap.add_argument("--no-fixed-variant", action="store_true",
                    help="skip the secondary fixed-margin variant (halves the run time)")
    ap.add_argument("--no-drops", action="store_true",
                    help="keep the clips listed in VP/results/audit/drop_<set>.txt")
    ap.add_argument("--jobs", type=int, default=2, help="models in parallel (max 2 heavy processes per agent)")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--summary-only", action="store_true")
    ap.add_argument("--tag", help="write results to VP/results/naming_<tag>/ and naming_summary_<tag>.md "
                                  "(e.g. --conds clean --tag clean for a table comparable while call audio lands)")
    args = ap.parse_args()

    results_dir, summary_path = results_paths(args.tag)
    if not args.summary_only:
        opts = Options(sets=args.sets.split(",") if args.sets else None,
                       conds=args.conds.split(",") if args.conds else None,
                       talks=tuple(args.talks.split(",")), modes=tuple(args.modes.split(",")),
                       reps=args.reps, world_size=args.world_size, impostor_rate=args.impostor_rate,
                       fixed_margins=args.fixed_margins, secondary_fixed=not args.no_fixed_variant,
                       drops=not args.no_drops, tag=args.tag)
        models = args.models.split(",") if args.models else discover_models()
        if not models:
            log("no models with embeddings yet")
        jobs = max(1, min(2, args.jobs))
        work = [(m, opts, args.force) for m in models]
        if jobs > 1 and len(work) > 1:
            from multiprocessing import get_context
            with get_context("spawn").Pool(jobs) as pool_:
                for model_id, status in pool_.imap_unordered(run_one, work):
                    log(f"{model_id}: {status}")
        else:
            for w in work:
                model_id, status = run_one(w)
                log(f"{model_id}: {status}")
    results_dir.mkdir(parents=True, exist_ok=True)
    write_summary(results_dir, summary_path)
    log(f"wrote {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
