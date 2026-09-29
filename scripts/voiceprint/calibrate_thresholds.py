#!/usr/bin/env python3
"""Calibrate a `SpeakerEmbeddingThresholds` file for a candidate voiceprint model.

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md. VP = data/eval/voiceprint (or $VP_ROOT).

Every cosine bar in the app's `.weSpeaker` preset (read from
Sources/TranscriptedCore/Speaker/SpeakerEmbeddingThresholds.swift, so new fields are picked up) is
moved to the candidate model by EQUAL FALSE-ACCEPT RATE, the idea of the old
scripts/recalibrate_eres2net_groundtruth.py (git 802a9e32), redone on the bake-off's human-labeled
sets and on call audio:

  1. For each bar, build the impostor trials that match what the app compares with it
     (TRIAL TYPES below): a single clip or a session mean against a speaker profile, or two
     clusters of one meeting against each other.
  2. The reference model's (default app-wespeaker-coreml, the app's voiceprint) false-accept rate
     at the WeSpeaker value, per condition scope.
  3. The candidate's threshold with the same false-accept rate in that scope. The bar written is
     the highest over scopes (clean, opus12, noisy, and clean profile vs degraded probe), so the
     new model never false-accepts more than today's on any of them.

Estimating the false-accept rate:
  * >= MIN_EMP impostor scores at or above the WeSpeaker value: empirical. The candidate's bar
    lets through the same number of impostors on the same trials.
  * fewer (the high bars sit far past every impostor score): tail fit. Take the top 1% of
    impostor scores (at least TAIL_MIN), fit a Gaussian to them in probit space
    (score = mu + s * z, z = the normal quantile of each score's rank / n), read the reference's
    FAR at its bar off its fit and invert the candidate's fit at that FAR. A GPD (peaks over the
    99th percentile) is fitted too and reported next to it; it is not used for the bar because
    cosine tails are bounded, so the GPD shape comes out negative and puts FAR = 0 past a finite
    endpoint, where nothing can be matched. Guard: the candidate's bar must also let through no
    more observed impostors than chance allows around the reference's count (the 99% Poisson
    quantile of the reference's observed count, or of its fitted expected count when it had none:
    usually 0 or 1). One mislabeled pair can't set a bar that way, a heavier tail can. The report
    says when the guard binds.
  Deep-tail FARs (1e-8 and below) are extrapolations; they say where the bar sits relative to the
  impostor spread, not a measured rate. Read them as "z-score of the bar in the impostor tail".

Margins (differences between two cosines: top-1 minus top-2, gaps, bonuses) are multiplied by the
ratio of impostor-score standard deviations, candidate / reference, on the profile-vs-session-mean
trials (the comparison the margins guard), again the highest ratio over scopes. As a check the
report also gives the "stranger gap" pass rate: for every session mean with its own speaker's
profile removed, top-1 minus top-2 over the other profiles in the set; the share of strangers that
clear the margin under each model, and the candidate margin with the same share.

TRIAL TYPES (targets = same person, impostors = different people; `profile` = L2-normalized mean
of the speaker's per-session means over up to 3 of their other sessions, never the probe's own):
  P1  profile vs one segment: one clip (2, 4 or 8 s) vs a profile
  P3  profile vs 2-3 segments: mean of 2-3 clips of one session vs a profile
  PA  profile vs session mean: mean of all (>= 4) clips of a speaker's session vs a profile
  PS  session vs session: the same session mean vs ONE other session's mean (a rejected sample,
      a one-meeting profile)
  W1  meeting, segment vs cluster: one clip vs the mean of another speaker's clips in the SAME
      session (targets: vs the same speaker's other clips there)
  W2  meeting, small cluster vs cluster: mean of 2 clips vs another speaker's session mean
  WA  meeting, cluster vs cluster: two speakers' session means in the same session (targets: two
      halves of one speaker's session)
  Only AMI and ICSI have several labeled people per session, so same-session W impostors come from
  them; targets come from all sets. A W bar must also hold against cross-session impostors (the
  other speaker's cluster from another session, every set), so it is the higher of the two. When a
  scope has too few same-session impostors (no AMI/ICSI embeddings), only cross-session is used.
  SPECS below maps every field to its type; a field the script doesn't know gets one from its name
  (margin/gap/bonus -> margin; micro/ghost -> W1; absorb -> W2; cluster/link -> WA; else PA) and the
  report flags it.

Kinds: `sim` bars (same person above it) get the equal-FAR remap. `margin` fields get the std
ratio. `exemplarSameCondition` is not an identity decision (it splits one person's sessions into
"same condition" or "new condition"), so it keeps the share of same-person PA trials above it.

Condition scopes: every condition in --conds with embeddings for both models; profile trials also
get `clean>c` (profile clean, probe in c), because profiles build up over earlier, often cleaner calls.
Leave-one-set-out: every sim bar is recomputed with each set dropped; the report shows the range.

Outputs:
  --out (default VP/results/thresholds/<model_id>.json): the loader's shape
  (`SpeakerEmbeddingThresholds.load(contentsOf:)`): snake_case keys under "thresholds", with
  provenance next to it. Sidecar <out stem>.report.md: the table and the fits.

Usage:
  VP/venv/bin/python scripts/voiceprint/calibrate_thresholds.py --model 3dspeaker-eres2net-en-voxceleb
  ... --model X [--ref app-wespeaker-coreml] [--sets vox1o,libri,ami,icsi] [--conds clean,opus12,noisy]
      [--out VP/results/thresholds/X.json] [--compare-preset eRes2Net]
Never touches the app's real speaker database or preferences.
"""
from __future__ import annotations

import os

for _var in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
    os.environ.setdefault(_var, "3")

import argparse  # noqa: E402
import hashlib  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import re  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
from collections import defaultdict  # noqa: E402
from dataclasses import dataclass, field  # noqa: E402
from pathlib import Path  # noqa: E402

import numpy as np  # noqa: E402
from scipy import stats  # noqa: E402

VERSION = "1.0"
REPO = Path(__file__).resolve().parents[2]
DEFAULT_VP = Path(os.environ.get("VP_ROOT", str(REPO / "data" / "eval" / "voiceprint")))
DEFAULT_SWIFT = REPO / "Sources" / "TranscriptedCore" / "Speaker" / "SpeakerEmbeddingThresholds.swift"
SPEAKER_SRC = REPO / "Sources" / "TranscriptedCore" / "Speaker"

HUMAN_SETS = ("vox1o", "libri", "ami", "icsi")
DEFAULT_CONDS = ("clean", "opus12", "noisy")
PROFILE_SESSIONS = 3      # a profile averages up to this many of the speaker's other sessions
TAIL_FRAC = 0.01          # tail fit on the top 1% of impostor scores ...
TAIL_MIN = 50             # ... but at least this many
MIN_EMP = 30              # >= this many impostors at/above the bar: empirical FAR, no fit
MIN_W_IMPOSTORS = 500     # fewer same-session impostors in a scope: W types use cross-session
GUARD_EPS = 1e-4
GUARD_Q = 0.99           # guard: Poisson quantile of the reference's impostor count

TRIAL_TYPES = {
    "P1": "profile vs one segment: one clip vs a speaker profile (mean of up to 3 other sessions)",
    "P3": "profile vs 2-3 segments: mean of 2-3 clips of one session vs a speaker profile",
    "PA": "profile vs session mean: mean of all (>=4) clips of a session vs a speaker profile",
    "PS": "session vs session: mean of all (>=4) clips of a session vs the mean of one other session",
    "W1": "same meeting, segment vs cluster: one clip vs another speaker's mean in that session",
    "W2": "same meeting, small cluster vs cluster: mean of 2 clips vs another speaker's mean in that session",
    "WA": "same meeting, cluster vs cluster: two speakers' means in the same session",
}
PROFILE_TYPES = ("P1", "P3", "PA", "PS")
WITHIN_TYPES = ("W1", "W2", "WA")
MARGIN_TYPE = "PA"

# Known fields: (trial type, kind, what the app compares). kind: sim = a same-person cosine bar,
# margin = a difference of two cosines, copy = not a cosine (carried over unchanged).
SPECS: dict[str, tuple[str | None, str, str]] = {
    "matchOneSegment": ("P1", "sim", "DB match when the session's voice has 1 segment (mean vs stored profile)"),
    "matchFewSegments": ("P3", "sim", "DB match with 2-3 segments"),
    "matchManySegments": ("PA", "sim", "DB match with 4+ segments"),
    "ghostMergeFloor": ("W1", "sim", "force-merge a short ghost cluster into the closest real speaker of the meeting"),
    "consolidation": ("WA", "sim", "merge two same-voice clusters of one meeting"),
    "absorb": ("W2", "sim", "absorb a small (<30 s, <3 turns) cluster into a large one"),
    "microAbsorb": ("W1", "sim", "absorb a very short (<10 s) cluster"),
    "perSegmentSplit": ("P1", "sim", "per-segment match to a known profile when splitting a mixed cluster"),
    "knownProfileConflict": ("PA", "sim", "a cluster centroid matches a known profile (blocks consolidation)"),
    # identity bars (matching guards, write-back, naming ladder, cleanup)
    "immatureProfileMatchBonus": ("PA", "margin", "added to the match floor for a profile heard in <= 2 calls"),
    "developingProfileMatchBonus": ("PA", "margin", "added to the match floor for a profile heard in 3-4 calls"),
    "ambiguousMatchMargin": ("PA", "margin", "runner-up this close to the winner makes a match ambiguous"),
    "negativeVetoFloor": ("PS", "sim", "a session mean this close to a rejected sample (another voice's session) vetoes the profile"),
    "writeBackMarginMin": ("PA", "margin", "margin to the runner-up before a match may adapt the voiceprint"),
    "confidentWriteBack": ("PA", "sim", "match adapts the voiceprint at the full rate"),
    "cautiousWriteBack": ("PA", "sim", "match adapts the voiceprint slowly"),
    "crossClusterLink": ("WA", "sim", "two clusters of one meeting that matched the same profile fuse"),
    "exemplarSameCondition": ("PA", "target", "a confirmed session mean counts as the same capture condition as a stored "
                              "representative of the SAME person (not an identity decision: matched by equal "
                              "same-person pass rate)"),
    "autoAcceptSimilarity": ("PA", "sim", "silent auto-name, global ladder"),
    "autoAcceptMarginMin": ("PA", "margin", "silent auto-name margin to the runner-up, global ladder"),
    "inviteeSimilarity": ("PA", "sim", "silent auto-name for someone on the meeting's lineup"),
    "inviteeMarginMin": ("PA", "margin", "lineup auto-name margin to the runner-up"),
    "highConfidenceSimilarity": ("PA", "sim", "an auto-named speaker is labeled high confidence"),
    "duplicateProfileMerge": ("PS", "sim", "after-meeting cleanup merges two saved profiles"),
    "separationMerge": ("WA", "sim", "speaker separation merges two call-channel voices of one meeting"),
}
# Offsets added to a similarity bar: besides the std-ratio remap, the report shows the equal-FAR
# remap of (base + offset) minus the remapped base, as a check.
OFFSET_BASE = {"immatureProfileMatchBonus": "matchManySegments", "developingProfileMatchBonus": "matchManySegments"}


def log(msg: str) -> None:
    print(f"[calibrate {time.strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def infer_spec(name: str, swift_type: str) -> tuple[str | None, str, str]:
    """Trial type for a field this script has no explicit entry for, from its name."""
    n = name.lower()
    if swift_type in ("Int", "Int32", "Int64", "UInt"):
        return (None, "copy", "integer, not a cosine (inferred from type)")
    if any(k in n for k in ("alpha", "weight", "scale", "count", "meetings", "duration", "seconds")):
        return (None, "copy", "not a cosine (inferred from name)")
    if any(k in n for k in ("margin", "gap", "separation", "bonus", "offset", "delta")):
        return (MARGIN_TYPE, "margin", "difference of two cosines (inferred from name)")
    if "micro" in n or "ghost" in n:
        return ("W1", "sim", "short cluster vs a meeting cluster (inferred from name)")
    if "absorb" in n:
        return ("W2", "sim", "small cluster vs a meeting cluster (inferred from name)")
    if any(k in n for k in ("consolidat", "pairwise", "crosscluster", "link", "fuse", "cluster")):
        return ("WA", "sim", "cluster vs cluster in one meeting (inferred from name)")
    if "persegment" in n or ("segment" in n and "split" in n) or "onesegment" in n:
        return ("P1", "sim", "one segment vs a profile (inferred from name)")
    if "fewsegment" in n:
        return ("P3", "sim", "2-3 segments vs a profile (inferred from name)")
    return ("PA", "sim", "session mean vs a profile (inferred from name; default)")


# ----------------------------------------------------------------------------------------------
# Swift source


def _balanced(text: str, start: int, open_ch: str, close_ch: str) -> tuple[str, int]:
    """Content between text[start] == open_ch and its matching close, and the index after it."""
    assert text[start] == open_ch
    depth, i, in_str = 0, start, False
    while i < len(text):
        c = text[i]
        if c == '"' and text[i - 1] != "\\":
            in_str = not in_str
        elif not in_str:
            if c == open_ch:
                depth += 1
            elif c == close_ch:
                depth -= 1
                if depth == 0:
                    return text[start + 1:i], i + 1
        i += 1
    raise ValueError("unbalanced source")


def _split_top(args: str) -> list[str]:
    out, depth, cur, in_str = [], 0, [], False
    for i, c in enumerate(args):
        if c == '"' and (i == 0 or args[i - 1] != "\\"):
            in_str = not in_str
        if not in_str:
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "," and depth == 0:
                out.append("".join(cur))
                cur = []
                continue
        cur.append(c)
    if "".join(cur).strip():
        out.append("".join(cur))
    return out


_NUM = r"[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"


def _resolve_constant(expr: str) -> float | None:
    """`Type.name` -> the literal it is declared with somewhere under TranscriptedCore/Speaker."""
    m = re.fullmatch(r"(?:\w+\.)*(\w+)", expr.strip())
    if not m:
        return None
    name = m.group(1)
    for path in sorted(SPEAKER_SRC.parent.rglob("*.swift")):
        try:
            text = path.read_text()
        except OSError:
            continue
        hit = re.search(rf"static\s+let\s+{re.escape(name)}\s*(?::\s*\w+)?\s*=\s*({_NUM})\b", text)
        if hit:
            return float(hit.group(1))
    return None


def _value(expr: str) -> float | None:
    expr = expr.strip()
    if re.fullmatch(_NUM, expr):
        return float(expr)
    m = re.search(rf"default:\s*({_NUM})", expr)  # LabKnobOverrides.float("key", default: 0.88)
    if m:
        return float(m.group(1))
    m = re.fullmatch(rf"(?:Float|Double|Int)\(\s*({_NUM})\s*\)", expr)
    if m:
        return float(m.group(1))
    return _resolve_constant(expr)


@dataclass
class SwiftThresholds:
    fields: dict[str, str]                 # stored property -> Swift type, declaration order
    coding_keys: list[tuple[str, str]]     # (property, JSON key before snake conversion)
    presets: dict[str, dict[str, float]]
    sha1: str
    unresolved: dict[str, list[str]] = field(default_factory=dict)


def parse_swift(path: Path) -> SwiftThresholds:
    src = path.read_text()
    code = re.sub(r"//[^\n]*", "", src)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    m = re.search(r"struct\s+SpeakerEmbeddingThresholds\b[^{]*\{", code)
    if not m:
        raise SystemExit(f"no SpeakerEmbeddingThresholds struct in {path}")
    body, _ = _balanced(code, m.end() - 1, "{", "}")
    # stored properties only: `let name: Type` not followed by a getter block
    fields: dict[str, str] = {}
    depth = 0
    for line in body.splitlines():
        if depth == 0:
            fm = re.match(r"\s*(?:public\s+|internal\s+)?let\s+(\w+)\s*:\s*(\w+)", line)
            if fm:
                fields[fm.group(1)] = fm.group(2)
        depth += line.count("{") - line.count("}")
    # CodingKeys (the loader's key list)
    coding: list[tuple[str, str]] = []
    cm = re.search(r"enum\s+CodingKeys\s*:[^{]*\{", code)
    if cm:
        ck_body, _ = _balanced(code, cm.end() - 1, "{", "}")
        for case in re.findall(r"case\s+([^\n]+)", ck_body):
            for item in _split_top(case):
                item = item.strip()
                km = re.fullmatch(r'(\w+)\s*(?:=\s*"([^"]+)")?', item)
                if km:
                    coding.append((km.group(1), km.group(2) or km.group(1)))
    # init defaults (a preset may leave a defaulted parameter out)
    init_defaults: dict[str, float] = {}
    im = re.search(r"public\s+init\s*\(", body)
    if im:
        params, _ = _balanced(body, im.end() - 1, "(", ")")
        for p in _split_top(params):
            pm = re.match(r"\s*(\w+)\s*:\s*[\w.]+\s*=\s*(.+)$", p.strip(), flags=re.S)
            if pm:
                v = _value(pm.group(2))
                if v is not None:
                    init_defaults[pm.group(1)] = v
    presets: dict[str, dict[str, float]] = {}
    unresolved: dict[str, list[str]] = {}
    for pm in re.finditer(r"static\s+(?:let|var)\s+(\w+)\s*(?::\s*\w+\s*)?=\s*(?:SpeakerEmbeddingThresholds)?\s*\(", code):
        args, _ = _balanced(code, pm.end() - 1, "(", ")")
        vals = dict(init_defaults)
        bad = []
        for a in _split_top(args):
            am = re.match(r"\s*(\w+)\s*:\s*(.+)$", a.strip(), flags=re.S)
            if not am:
                continue
            v = _value(am.group(2))
            if v is None:
                bad.append(am.group(1))
            else:
                vals[am.group(1)] = v
        presets[pm.group(1)] = vals
        if bad:
            unresolved[pm.group(1)] = bad
    return SwiftThresholds(fields, coding, presets, hashlib.sha1(src.encode()).hexdigest()[:12], unresolved)


# ----------------------------------------------------------------------------------------------
# Data


@dataclass
class SetData:
    name: str
    seg_ids: list[str]
    speaker: np.ndarray          # int speaker index per row
    session: np.ndarray          # int session index per row
    speakers: list[str]
    sessions: list[str]
    groups: dict[tuple[int, int], list[int]]   # (speaker, session) -> rows, file order
    spk_sessions: dict[int, list[int]]         # speaker -> sessions, first-appearance order


def load_segments(vp: Path, name: str) -> list[dict]:
    path = vp / "sets" / name / "segments.jsonl"
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    order_key = {}
    for i, r in enumerate(rows):
        order_key.setdefault(r["session"], (r.get("session_order", 0), r.get("date", ""), i))
    return rows


def build_set(name: str, rows: list[dict], keep: set[str]) -> SetData:
    rows = [r for r in rows if r["seg_id"] in keep]
    spk_idx: dict[str, int] = {}
    ses_idx: dict[str, int] = {}
    speaker, session = [], []
    groups: dict[tuple[int, int], list[int]] = defaultdict(list)
    spk_sessions: dict[int, list[int]] = defaultdict(list)
    for i, r in enumerate(rows):
        a = spk_idx.setdefault(r["speaker"], len(spk_idx))
        x = ses_idx.setdefault(r["session"], len(ses_idx))
        speaker.append(a)
        session.append(x)
        groups[(a, x)].append(i)
        if x not in spk_sessions[a]:
            spk_sessions[a].append(x)
    return SetData(name, [r["seg_id"] for r in rows], np.array(speaker), np.array(session),
                   list(spk_idx), list(ses_idx), dict(groups), dict(spk_sessions))


def load_emb(vp: Path, model: str, set_name: str, cond: str) -> dict[str, np.ndarray] | None:
    path = vp / "emb" / model / f"{set_name}__{cond}.npz"
    if not path.exists():
        return None
    try:
        z = np.load(path)
        ids = [str(s) for s in z["seg_id"]]
        e = np.asarray(z["emb"], dtype=np.float64)
    except Exception as exc:  # a file being written, or corrupt
        log(f"skip {path.name} for {model}: {exc}")
        return None
    norms = np.linalg.norm(e, axis=1, keepdims=True)
    ok = (norms[:, 0] > 0) & np.isfinite(e).all(axis=1)
    e = e / np.where(norms > 0, norms, 1.0)
    return {s: e[i] for i, s in enumerate(ids) if ok[i]}


def unit(v: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    return v / np.where(n > 0, n, 1.0)


# ----------------------------------------------------------------------------------------------
# Trials. Every builder is deterministic in the set's row order, so both models get the same
# trial list and FAR matching can also be done by counts.


@dataclass
class Trials:
    """Score arrays. The builders append plain arrays; `collect` tags each with its set."""
    imp: list = field(default_factory=list)
    tgt: list = field(default_factory=list)
    gap: list = field(default_factory=list)       # PA only: stranger top-1 minus top-2
    imp_alt: list = field(default_factory=list)   # W only: cross-session impostors

    def cat(self, name: str, excl: str | None = None) -> np.ndarray:
        parts = [a for s, a in getattr(self, name) if s != excl]
        return np.concatenate(parts).astype(np.float64) if parts else np.zeros(0)

    def add(self, other: "Trials", set_name: str) -> None:
        for name in ("imp", "tgt", "gap", "imp_alt"):
            getattr(self, name).extend((set_name, a) for a in getattr(other, name))


class Side:
    """One model's impostor scores on one trial list, sorted once, with its tail fit."""

    def __init__(self, x: np.ndarray):
        self.asc = np.sort(np.asarray(x, dtype=np.float64))
        self.n = len(self.asc)
        self.fit = tail_fit(self.asc)

    def count_ge(self, t: float) -> int:
        return int(self.n - np.searchsorted(self.asc, t, side="left"))

    def desc(self, i: int) -> float:
        """i-th largest score (0 = max)."""
        return float(self.asc[self.n - 1 - i])


def profile_trials(sd: SetData, e_probe: np.ndarray, e_prof: np.ndarray, out: dict[str, Trials]) -> None:
    """P1/P3/PA/PS. e_probe, e_prof: unit embeddings per row of sd (probe side, profile side)."""
    n_spk = len(sd.speakers)
    n_ses = len(sd.sessions)
    sess_mean = {k: unit(e_prof[rows].mean(axis=0)) for k, rows in sd.groups.items()}

    def build(n_sessions: int) -> tuple[np.ndarray, np.ndarray] | None:
        """Profiles averaging up to n_sessions of a speaker's sessions, never session x;
        cols[x, b] = row of speaker b's profile for a probe from session x (-1: none)."""
        vecs, key_row = [], {}
        for b in range(n_spk):
            ss = sd.spk_sessions[b]
            for excl in [None] + ss[:n_sessions]:
                sel = [s for s in ss if s != excl][:n_sessions]
                if sel:
                    key_row[(b, excl)] = len(vecs)
                    vecs.append(unit(np.mean([sess_mean[(b, s)] for s in sel], axis=0)))
        if not vecs:
            return None
        cols = np.full((n_ses, n_spk), -1, dtype=np.int64)
        for x in range(n_ses):
            for b in range(n_spk):
                key = (b, x) if x in sd.spk_sessions[b][:n_sessions] else (b, None)
                cols[x, b] = key_row.get(key, -1)
        return np.stack(vecs), cols

    profiles = {PROFILE_SESSIONS: build(PROFILE_SESSIONS), 1: build(1)}
    probes: dict[str, list[tuple[int, int, np.ndarray]]] = {"P1": [], "P3": [], "PA": []}
    for (a, x), rows in sd.groups.items():
        for r in rows:
            probes["P1"].append((a, x, e_probe[r]))
        n = len(rows)
        for c in (rows[i:i + 3] for i in range(0, n, 3)):
            if len(c) >= 2:
                probes["P3"].append((a, x, unit(e_probe[c].mean(axis=0))))
        if n >= 4:
            probes["PA"].append((a, x, unit(e_probe[rows].mean(axis=0))))

    for kind, probe_kind, n_sessions in (("P1", "P1", PROFILE_SESSIONS), ("P3", "P3", PROFILE_SESSIONS),
                                         ("PA", "PA", PROFILE_SESSIONS), ("PS", "PA", 1)):
        plist, built = probes[probe_kind], profiles[n_sessions]
        if not plist or built is None:
            continue
        prof, cols = built
        spk = np.array([p[0] for p in plist])
        ses = np.array([p[1] for p in plist])
        vec = np.stack([p[2] for p in plist])
        m = vec @ prof.T
        c = cols[ses]                                   # (P, n_spk)
        valid = c >= 0
        s = np.take_along_axis(m, np.where(valid, c, 0), axis=1)
        own = np.arange(n_spk)[None, :] == spk[:, None]
        out[kind].tgt.append(s[valid & own])
        out[kind].imp.append(s[valid & ~own])
        if kind == MARGIN_TYPE:
            imp_rows = np.where(valid & ~own, s, -np.inf)
            if imp_rows.shape[1] >= 2:
                top2 = -np.sort(-imp_rows, axis=1)[:, :2]
                ok = np.isfinite(top2).all(axis=1)
                out[kind].gap.append(top2[ok, 0] - top2[ok, 1])


def within_trials(sd: SetData, e: np.ndarray, out: dict[str, Trials]) -> None:
    """W1/W2/WA in one condition. Impostors from the same session (and a cross-session fallback)."""
    cm = {k: unit(e[rows].mean(axis=0)) for k, rows in sd.groups.items()}
    by_session: dict[int, list[int]] = defaultdict(list)
    for (a, x) in sd.groups:
        by_session[x].append(a)
    # cross-session partner cluster for each (speaker, excluded session): first other session
    other_cluster = {}
    for b, ss in sd.spk_sessions.items():
        for x in set(ss) | {-1}:
            y = next((s for s in ss if s != x), None)
            if y is not None:
                other_cluster[(b, x)] = cm[(b, y)]
    n_spk = len(sd.speakers)
    alt_keys = {}

    def alt_refs(a: int, x: int) -> np.ndarray | None:
        key = (a, x)
        if key not in alt_keys:
            vs = [other_cluster.get((b, x)) if x in sd.spk_sessions[b] else other_cluster.get((b, -1))
                  for b in range(n_spk) if b != a]
            vs = [v for v in vs if v is not None]
            alt_keys[key] = np.stack(vs) if vs else None
        return alt_keys[key]

    w1_i, w1_t, w2_i, w2_t, wa_i, wa_t = [], [], [], [], [], []
    w1_x, w2_x, wa_x = [], [], []
    for (a, x), rows in sd.groups.items():
        others = [b for b in by_session[x] if b != a]
        o = np.stack([cm[(b, x)] for b in others]) if others else None
        alt = alt_refs(a, x)
        er = e[rows]
        n = len(rows)
        # W1: every clip vs the other speakers' clusters
        if o is not None:
            w1_i.append((er @ o.T).ravel())
        if alt is not None:
            w1_x.append((er @ alt.T).ravel())
        if n >= 3:
            tot = er.sum(axis=0)
            for i in range(n):
                w1_t.append(float(er[i] @ unit(tot - er[i])))
        # W2: disjoint pairs vs clusters
        pairs = [rows[i:i + 2] for i in range(0, n - 1, 2)]
        pv = np.stack([unit(e[p].mean(axis=0)) for p in pairs]) if pairs else None
        if pv is not None:
            if o is not None:
                w2_i.append((pv @ o.T).ravel())
            if alt is not None:
                w2_x.append((pv @ alt.T).ravel())
            if n >= 4:
                for p, v in zip(pairs, pv):
                    rest = [r for r in rows if r not in p]
                    w2_t.append(float(v @ unit(e[rest].mean(axis=0))))
        # WA: cluster vs cluster (each unordered same-session pair once); targets: halves
        mine = cm[(a, x)]
        wa_i.extend(float(mine @ cm[(b, x)]) for b in others if b > a)
        if alt is not None:
            wa_x.append(alt @ mine)
        if n >= 4:
            wa_t.append(float(unit(e[rows[0::2]].mean(axis=0)) @ unit(e[rows[1::2]].mean(axis=0))))

    def arr(parts):
        if not parts:
            return np.zeros(0)
        if isinstance(parts[0], np.ndarray):
            return np.concatenate(parts)
        return np.asarray(parts, dtype=np.float64)

    for kind, imp, tgt, alt in (("W1", w1_i, w1_t, w1_x), ("W2", w2_i, w2_t, w2_x), ("WA", wa_i, wa_t, wa_x)):
        out[kind].imp.append(arr(imp))
        out[kind].tgt.append(arr(tgt))
        out[kind].imp_alt.append(arr(alt))


# ----------------------------------------------------------------------------------------------
# Tail fits and FAR matching


def tail_fit(asc: np.ndarray) -> dict:
    """Tail fits of impostor scores (asc: sorted ascending)."""
    x = asc
    n = len(x)
    k = min(max(int(math.ceil(TAIL_FRAC * n)), TAIL_MIN), n // 2)
    d = x[::-1]
    top = d[:k]
    u = float(d[k]) if k < n else float(d[-1])
    fit = {"n": n, "k": k, "u": round(u, 4), "max": round(float(d[0]), 4),
           "mean": round(float(x.mean()), 4), "std": round(float(x.std()), 4)}
    if k < 10:
        return fit
    z = stats.norm.isf((np.arange(1, k + 1) - 0.5) / n)
    s, mu = np.polyfit(z, top, 1)
    resid = top - (mu + s * z)
    fit.update({"gauss_mu": float(mu), "gauss_s": float(s),
                "gauss_rmse": float(np.sqrt(np.mean(resid ** 2)))})
    # check the fit where it can still be checked: the score with max(5, 1e-4 * n) impostors above it
    kq = max(5, int(round(1e-4 * n)))
    if kq < k:
        tq = float(d[kq - 1])
        fit.update({"check_t": round(tq, 4), "check_far_emp": kq / n,
                    "check_far_gauss": float(stats.norm.sf((tq - mu) / s)) if s > 0 else None})
    y = top - u
    y = y[y > 0]
    if len(y) >= 10:
        try:
            xi, _, sigma = stats.genpareto.fit(y, floc=0)
            fit.update({"gpd_xi": float(xi), "gpd_sigma": float(sigma), "gpd_pu": len(y) / n,
                        "gpd_endpoint": float(u - sigma / xi) if xi < 0 else None})
        except Exception:  # noqa: BLE001 - a failed fit is reported as missing
            pass
    return fit


def far_gauss(f: dict, t: float) -> float | None:
    if "gauss_s" not in f or f["gauss_s"] <= 0:
        return None
    return float(stats.norm.sf((t - f["gauss_mu"]) / f["gauss_s"]))


def isf_gauss(f: dict, far: float) -> float | None:
    if "gauss_s" not in f or f["gauss_s"] <= 0 or not far or far <= 0:
        return None
    return float(f["gauss_mu"] + f["gauss_s"] * stats.norm.isf(far))


def far_gpd(f: dict, t: float) -> float | None:
    if "gpd_xi" not in f:
        return None
    xi, sg, pu, u = f["gpd_xi"], f["gpd_sigma"], f["gpd_pu"], f["u"]
    if t <= u:
        return None
    if abs(xi) < 1e-9:
        return pu * math.exp(-(t - u) / sg)
    base = 1 + xi * (t - u) / sg
    return 0.0 if base <= 0 else pu * base ** (-1 / xi)


def isf_gpd(f: dict, far: float | None) -> float | None:
    if "gpd_xi" not in f or not far or far <= 0:
        return None
    xi, sg, pu, u = f["gpd_xi"], f["gpd_sigma"], f["gpd_pu"], f["u"]
    q = far / pu
    if q >= 1:
        return None
    return u - sg * math.log(q) if abs(xi) < 1e-9 else u + sg / xi * (q ** (-xi) - 1)


def match_far(t_ref: float, ref: Side, cand: Side) -> dict:
    """Candidate threshold with the reference's false-accept rate at t_ref, on one trial list."""
    n, fr, fc = ref.n, ref.fit, cand.fit
    k_ref = ref.count_ge(t_ref)
    d = cand.asc[::-1]
    # Guard: the candidate may let through no more observed impostors than chance allows around the
    # reference's count (99% Poisson quantile of its observed count, or of its fitted expected count
    # when it saw none), so one mislabeled pair can't set a bar but a heavier tail can.
    lam = float(k_ref) if k_ref > 0 else (far_gauss(fr, t_ref) or 0.0) * n
    allowed = max(k_ref, int(stats.poisson.ppf(GUARD_Q, lam)) if lam > 0 else 0)
    guard = float(d[allowed] + GUARD_EPS) if allowed < n else float(d[-1])
    res = {"n": n, "ref_count": k_ref, "far_emp": k_ref / n if n else None, "guard_allows": allowed}
    if k_ref >= MIN_EMP:
        t = float(0.5 * (d[k_ref - 1] + d[k_ref])) if k_ref < n else float(d[-1])
        res.update({"method": "empirical", "far": k_ref / n, "t_new": t, "t_fit": t, "t_guard": guard})
    else:
        far = far_gauss(fr, t_ref)
        t_fit = isf_gauss(fc, far) if far else None
        gfar = far_gpd(fr, t_ref)
        res.update({"method": "gauss-tail", "far": far, "t_fit": t_fit, "t_guard": guard,
                    "far_gpd": gfar, "t_gpd": isf_gpd(fc, gfar),
                    "gpd_note": ("reference past its GPD endpoint (FAR 0)" if gfar == 0.0 else None)})
        if t_fit is None:
            res.update({"method": "guard-only", "t_new": guard})
        else:
            res["t_new"] = max(t_fit, guard)
            if guard > t_fit:
                res["method"] = "gauss-tail+guard"
    res["cand_count"] = cand.count_ge(res["t_new"])
    res["cand_far_gauss"] = far_gauss(fc, res["t_new"])
    return res


def _sig(v):
    return float(f"{v:.6g}") if isinstance(v, float) else v


def ceil3(v: float) -> float:
    return math.ceil(round(v * 1000, 6)) / 1000


# ----------------------------------------------------------------------------------------------
# Main


def scopes_for(conds: list[str]) -> tuple[list[tuple[str, str]], list[str]]:
    prof = [(c, c) for c in conds] + [(c, "clean") for c in conds if c != "clean" and "clean" in conds]
    return prof, list(conds)


def scope_name(probe: str, prof: str) -> str:
    return probe if probe == prof else f"{prof}>{probe}"


def collect(vp: Path, models: list[str], sets: list[str], conds: list[str]):
    """trials[model][type][scope] -> Trials, plus data notes."""
    prof_scopes, w_scopes = scopes_for(conds)
    trials = {m: {t: defaultdict(Trials) for t in TRIAL_TYPES} for m in models}
    notes = {"sets": {}, "missing": []}
    for s in sets:
        seg_path = vp / "sets" / s / "segments.jsonl"
        if not seg_path.exists():
            notes["missing"].append(f"{s}: no segments.jsonl")
            continue
        rows = load_segments(vp, s)
        embs = {m: {c: load_emb(vp, m, s, c) for c in conds} for m in models}
        have = [c for c in conds if all(embs[m][c] is not None for m in models)]
        for c in conds:
            if c not in have:
                who = [m for m in models if embs[m][c] is None]
                notes["missing"].append(f"{s}/{c}: no embeddings for {', '.join(who)}")
        if not have:
            continue
        keep = set(r["seg_id"] for r in rows)
        for m in models:
            for c in have:
                keep &= set(embs[m][c])
        sd = build_set(s, rows, keep)
        notes["sets"][s] = {"conds": have, "clips": len(sd.seg_ids), "dropped": len(rows) - len(sd.seg_ids),
                            "speakers": len(sd.speakers), "sessions": len(sd.sessions)}
        for m in models:
            mat = {c: np.stack([embs[m][c][i] for i in sd.seg_ids]) for c in have}
            for probe, prof in prof_scopes:
                if probe in have and prof in have:
                    tmp = {t: Trials() for t in PROFILE_TYPES}
                    profile_trials(sd, mat[probe], mat[prof], tmp)
                    for t in PROFILE_TYPES:
                        trials[m][t][scope_name(probe, prof)].add(tmp[t], s)
            for c in w_scopes:
                if c in have:
                    tmp = {t: Trials() for t in WITHIN_TYPES}
                    within_trials(sd, mat[c], tmp)
                    for t in WITHIN_TYPES:
                        trials[m][t][c].add(tmp[t], s)
        log(f"{s}: {len(sd.seg_ids)} clips, conds {have}")
    return trials, notes


def calibrate(args) -> None:
    vp = Path(args.vp)
    sw = parse_swift(Path(args.swift))
    ref_preset = sw.presets.get(args.ref_preset)
    if not ref_preset:
        raise SystemExit(f"preset .{args.ref_preset} not found in {args.swift}")
    fields = [k for k, _ in sw.coding_keys] or list(sw.fields)
    json_key = {k: snake(j) for k, j in sw.coding_keys} if sw.coding_keys else {k: snake(k) for k in fields}
    for k in sw.fields:  # stored fields outside CodingKeys still get written (the loader ignores them)
        if k not in json_key:
            fields.append(k)
            json_key[k] = snake(k)
    missing_vals = [k for k in fields if k not in ref_preset]
    if missing_vals:
        raise SystemExit(f".{args.ref_preset} has no value for {missing_vals} "
                         f"(unresolved: {sw.unresolved.get(args.ref_preset)})")

    sets = [s for s in args.sets.split(",") if s]
    conds = [c for c in args.conds.split(",") if c]
    models = [args.ref, args.model]
    log(f"model {args.model} vs {args.ref}; sets {sets}; conds {conds}")
    trials, notes = collect(vp, models, sets, conds)
    ref_t, cand_t = trials[args.ref], trials[args.model]

    def scope_entries(t: str, excl: str | None) -> dict[str, dict]:
        """scope -> {"r","c": Side, targets, ...} for trial type t, leaving set `excl` out.
        W types fall back to cross-session impostors when a scope has too few same-session ones."""
        out = {}
        for sc, tr in sorted(ref_t[t].items()):
            ctr = cand_t[t][sc]
            imp_r, imp_c = tr.cat("imp", excl), ctr.cat("imp", excl)
            source = "same-session" if t in WITHIN_TYPES else "cross-session"
            if t in WITHIN_TYPES and len(imp_r) < MIN_W_IMPOSTORS:
                imp_r, imp_c, source = tr.cat("imp_alt", excl), ctr.cat("imp_alt", excl), "cross-session fallback"
            if len(imp_r) < TAIL_MIN * 2 or len(imp_r) != len(imp_c):
                continue
            e = {"r": Side(imp_r), "c": Side(imp_c), "source": source,
                 "tgt_r": tr.cat("tgt", excl), "tgt_c": ctr.cat("tgt", excl)}
            if t in WITHIN_TYPES and source == "same-session":
                ar, ac = tr.cat("imp_alt", excl), ctr.cat("imp_alt", excl)
                if len(ar) >= TAIL_MIN * 2:
                    e["alt"] = (Side(ar), Side(ac))
            if t == MARGIN_TYPE and excl is None:
                e["gap_r"], e["gap_c"] = tr.cat("gap"), ctr.cat("gap")
                e["std_r"], e["std_c"] = float(imp_r.std()), float(imp_c.std())
            out[sc] = e
        return out

    def sim_matches(t_ref: float, entries: dict[str, dict]) -> dict[str, dict]:
        """Per-scope FAR matches; W bars must also hold against the other speaker's cluster from
        ANOTHER session, which brings in every set (vox1o and libri have one person per session)."""
        per = {sc: match_far(t_ref, e["r"], e["c"]) for sc, e in entries.items()}
        for sc, e in entries.items():
            if "alt" in e:
                per[f"{sc} (cross-session)"] = match_far(t_ref, *e["alt"])
        return per

    type_scopes: dict[str, dict[str, dict]] = {}
    fits: dict[str, dict] = {}
    for t in TRIAL_TYPES:
        type_scopes[t] = scope_entries(t, None)
        for sc, e in type_scopes[t].items():
            fits[f"{t}/{sc}"] = {"source": e["source"], "ref": e["r"].fit, "cand": e["c"].fit}
            if "alt" in e:
                fits[f"{t}/{sc} (cross-session)"] = {"source": "cross-session", "ref": e["alt"][0].fit,
                                                     "cand": e["alt"][1].fit}
        if type_scopes[t]:
            ents = list(type_scopes[t].values())
            pool = {"r": Side(np.concatenate([e["r"].asc for e in ents])),
                    "c": Side(np.concatenate([e["c"].asc for e in ents])),
                    "tgt_r": np.concatenate([e["tgt_r"] for e in ents]),
                    "tgt_c": np.concatenate([e["tgt_c"] for e in ents]),
                    "source": ",".join(sorted({e["source"] for e in ents}))}
            if t == MARGIN_TYPE:
                pool["gap_r"] = np.concatenate([e["gap_r"] for e in ents])
                pool["gap_c"] = np.concatenate([e["gap_c"] for e in ents])
            type_scopes[t]["pooled"] = pool
            if len(ents) > 1:
                fits[f"{t}/pooled"] = {"source": pool["source"], "ref": pool["r"].fit, "cand": pool["c"].fit}

    # Leave-one-set-out: the same calibration without each set, to show how much a bar depends on
    # which people happen to be in the data.
    used_sets = list(notes["sets"])
    loso_cache: dict[tuple[str, str], dict[str, dict]] = {}

    def loso_entries(t: str, excl: str) -> dict[str, dict]:
        if (t, excl) not in loso_cache:
            loso_cache[(t, excl)] = scope_entries(t, excl) if len(used_sets) > 1 else {}
        return loso_cache[(t, excl)]

    cmp_name = args.compare_preset
    if cmp_name is None and "eres2net" in args.model.lower() and "eRes2Net" in sw.presets:
        cmp_name = "eRes2Net"
    compare_vals = sw.presets.get(cmp_name, {}) if cmp_name else {}

    thresholds: dict[str, float] = {}
    details: dict[str, dict] = {}
    for name in fields:
        key = json_key[name]
        ref_val = float(ref_preset[name])
        spec = SPECS.get(name) or infer_spec(name, sw.fields.get(name, "Double"))
        ttype, kind, meaning = spec
        det = {"field": name, "weSpeaker": ref_val, "kind": kind, "meaning": meaning,
               "explicit_spec": name in SPECS}
        if kind == "copy" or not ttype or not type_scopes.get(ttype):
            thresholds[key] = ref_val
            det.update({"new": ref_val, "method": "carried over" if kind == "copy" else "no trials: carried over"})
            details[key] = det
            continue
        scopes = {sc: e for sc, e in type_scopes[ttype].items() if sc != "pooled"}
        pooled = type_scopes[ttype]["pooled"]
        det.update({"trial_type": ttype, "trial_desc": TRIAL_TYPES[ttype], "impostors": pooled["source"]})
        if kind == "sim":
            per = sim_matches(ref_val, scopes)
            pl = match_far(ref_val, pooled["r"], pooled["c"])
            worst = max(per, key=lambda sc: per[sc]["t_new"])
            new = min(ceil3(per[worst]["t_new"]), 0.999)
            far_worst_sc = max(per, key=lambda sc: per[sc]["far"] or 0)
            if per[worst]["t_new"] > 0.999:
                det["capped"] = True  # the matched bar is past any cosine: the check effectively never fires
            det.update({
                "new": new, "binding_scope": worst, "method": per[worst]["method"],
                "far_ref_pooled": pl["far"], "far_ref_pooled_method": pl["method"],
                "far_ref_worst": per[far_worst_sc]["far"], "far_ref_worst_scope": far_worst_sc,
                "new_pooled_only": ceil3(pl["t_new"]),
                "per_scope": {sc: {k: _sig(v) for k, v in r.items()} for sc, r in per.items()},
                "tar_ref": float((pooled["tgt_r"] >= ref_val).mean()) if len(pooled["tgt_r"]) else None,
                "tar_new": float((pooled["tgt_c"] >= new).mean()) if len(pooled["tgt_c"]) else None,
                "tar_by_scope": {sc: [float((e["tgt_r"] >= ref_val).mean()), float((e["tgt_c"] >= new).mean()),
                                      int(len(e["tgt_r"]))] for sc, e in scopes.items() if len(e["tgt_r"])},
                "n_targets": int(len(pooled["tgt_r"])), "n_impostors": int(pooled["r"].n),
            })
            loso = {}
            for excl in used_sets:
                ents = loso_entries(ttype, excl)
                if ents:
                    loso[excl] = min(ceil3(max(r["t_new"] for r in sim_matches(ref_val, ents).values())), 0.999)
            if loso:
                det["leave_one_set_out"] = loso
            same = [r["t_new"] for sc, r in per.items() if not sc.endswith("(cross-session)")]
            cross = [r["t_new"] for sc, r in per.items() if sc.endswith("(cross-session)")]
            if cross:
                det["same_session_only"] = ceil3(max(same))
                det["cross_session_only"] = ceil3(max(cross))
            if compare_vals.get(name) is not None:
                cv = float(compare_vals[name])
                det["compare"] = {"value": cv,
                                  "cand_far_emp": pooled["c"].count_ge(cv) / pooled["c"].n,
                                  "cand_far_gauss": far_gauss(pooled["c"].fit, cv),
                                  "ref_far_emp": pooled["r"].count_ge(ref_val) / pooled["r"].n,
                                  "ref_far_gauss": far_gauss(pooled["r"].fit, ref_val),
                                  "cand_tar": float((pooled["tgt_c"] >= cv).mean()) if len(pooled["tgt_c"]) else None}
            tar_worst = min(det["tar_by_scope"].items(), key=lambda kv: kv[1][0]) if det["tar_by_scope"] else None
            if tar_worst:
                det["tar_hardest_scope"] = [tar_worst[0]] + tar_worst[1][:2]
        elif kind == "target":  # equal same-person pass rate (not an identity bar)
            tr, tc = pooled["tgt_r"], pooled["tgt_c"]
            rate = float((tr >= ref_val).mean())
            new = min(round(float(np.quantile(tc, 1 - rate)), 3), 0.999) if 0 < rate < 1 else ref_val
            det.update({"new": new, "method": "equal same-person pass rate", "binding_scope": "pooled",
                        "pass_rate_ref": rate, "pass_rate_new": float((tc >= new).mean()),
                        "pass_by_scope": {sc: [float((e["tgt_r"] >= ref_val).mean()), float((e["tgt_c"] >= new).mean()),
                                               int(len(e["tgt_r"]))] for sc, e in scopes.items() if len(e["tgt_r"])},
                        "far_ref_pooled": pooled["r"].count_ge(ref_val) / pooled["r"].n,
                        "far_new_pooled": pooled["c"].count_ge(new) / pooled["c"].n})
        else:  # margin
            ratios = {sc: e["std_c"] / e["std_r"] for sc, e in scopes.items()}
            worst = max(ratios, key=ratios.get)
            new = min(ceil3(ref_val * ratios[worst]), 0.999)
            pooled_ratio = float(pooled["c"].asc.std() / pooled["r"].asc.std())
            gr, gc = pooled.get("gap_r", np.zeros(0)), pooled.get("gap_c", np.zeros(0))
            check = {}
            if len(gr):
                rate_r = float((gr >= ref_val).mean())
                rate_c = float((gc >= new).mean())
                eq = {}
                for sc, e in scopes.items():
                    if len(e.get("gap_r", [])):
                        rr = float((e["gap_r"] >= ref_val).mean())
                        eq[sc] = float(np.quantile(e["gap_c"], 1 - rr)) if 0 < rr < 1 else None
                eqv = [v for v in eq.values() if v is not None]
                check = {"stranger_gap_pass_ref": rate_r, "stranger_gap_pass_new": rate_c,
                         "equal_pass_margin": ceil3(max(eqv)) if eqv else None, "n_strangers": int(len(gr))}
            det.update({"new": new, "method": "std ratio", "std_ratio_used": ratios[worst], "binding_scope": worst,
                        "std_ratio_pooled": pooled_ratio, "std_ratio_by_scope": ratios, **check})
            base = OFFSET_BASE.get(name)
            if base and base in ref_preset:
                b0 = float(ref_preset[base])
                t0 = max(match_far(b0, e["r"], e["c"])["t_new"] for e in scopes.values())
                t1 = max(match_far(b0 + ref_val, e["r"], e["c"])["t_new"] for e in scopes.values())
                det["equal_far_offset_check"] = {"base": base, "value": round(t1 - t0, 4)}
        thresholds[key] = det["new"]
        details[key] = det

    compare = None
    if cmp_name and cmp_name in sw.presets:
        compare = {"preset": cmp_name, "values": {json_key[k]: v for k, v in sw.presets[cmp_name].items() if k in json_key}}
        # Context for reading an old preset: how wide each model's different-speaker session-mean
        # scores are on clean audio (the June ERes2Net remap cites WeSpeaker p95 0.62 there), and
        # where a remap that floors FAR at 1e-4 without a tail model (the June method) lands.
        ps = type_scopes.get("PS", {}).get("clean")
        if ps:
            k4 = max(1, int(round(1e-4 * ps["c"].n)))
            compare["context"] = {
                "trial": "PS clean (session mean vs another session's mean, different people)",
                "ref_p95": float(np.quantile(ps["r"].asc, 0.95)), "cand_p95": float(np.quantile(ps["c"].asc, 0.95)),
                "cand_at_far_1e-4": ps["c"].desc(k4 - 1)}

    out = Path(args.out) if args.out else vp / "results" / "thresholds" / f"{args.model}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    doc = {
        "model_id": args.model,
        "thresholds": thresholds,
        "reference_model": args.ref,
        "reference_preset": args.ref_preset,
        "reference_values": {json_key[k]: float(ref_preset[k]) for k in fields},
        "method": ("equal false-accept rate per condition scope, highest over scopes; empirical when >= "
                   f"{MIN_EMP} reference impostors clear the bar, else Gaussian fit to the top "
                   f"{TAIL_FRAC:.0%} (>= {TAIL_MIN}) impostor scores with an observed-count guard; margins "
                   "scaled by the impostor std ratio (highest over scopes)"),
        "trial_types": TRIAL_TYPES,
        "sets": notes["sets"],
        "missing_inputs": notes["missing"],
        "details": details,
        "tail_fits": fits,
        "compare_preset": compare,
        "swift_source": {"path": str(Path(args.swift).relative_to(REPO)) if Path(args.swift).is_relative_to(REPO) else Path(args.swift).name,
                         "sha1": sw.sha1, "fields": list(fields)},
        "script": {"name": "scripts/voiceprint/calibrate_thresholds.py", "version": VERSION},
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    tmp = out.with_name(f".{out.name}.tmp")
    tmp.write_text(json.dumps(doc, indent=1, default=_json_default) + "\n")
    os.replace(tmp, out)
    report = out.with_name(out.stem + ".report.md")
    report.write_text(render_report(doc))
    log(f"wrote {out} and {report.name}")
    for k, v in thresholds.items():
        d = details[k]
        print(f"  {k:28s} {d['weSpeaker']:.3f} -> {v:.3f}  {d.get('method', '')}"
              + (f"  TAR {d['tar_ref']:.3f}->{d['tar_new']:.3f}" if d.get("tar_ref") is not None else ""))


def _json_default(o):
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, (np.integer,)):
        return int(o)
    raise TypeError(type(o))


def _far(v) -> str:
    if v is None:
        return "-"
    if v == 0:
        return "0"
    return f"{v:.1e}" if v < 1e-3 else f"{v:.4f}"


def _pct(v) -> str:
    return "-" if v is None else f"{100 * v:.1f}%"


def render_report(doc: dict) -> str:
    d = doc["details"]
    cmpv = (doc.get("compare_preset") or {}).get("values", {})
    cmp_name = (doc.get("compare_preset") or {}).get("preset")
    lines = [
        f"# Threshold calibration: {doc['model_id']}",
        "",
        f"Reference: `{doc['reference_model']}` with the app's `.{doc['reference_preset']}` preset. "
        f"Generated {doc['generated_at']} by `{doc['script']['name']}` v{doc['script']['version']}.",
        "",
        "Each bar is moved by equal false-accept rate (FAR) on impostor trials of the matching type, "
        "per condition scope, and the highest candidate value over scopes is kept, so the new model "
        "false-accepts no more than today's on clean audio or call audio. Very low FARs come from a "
        "Gaussian fit to the top 1% of impostor scores, so read them as a position in the impostor "
        "tail, not a measured rate. Margins scale by the impostor score std ratio. TAR = share of "
        "same-person trials of that type that clear the bar (pooled over sets and scopes). "
        "Leave-one-set-out = the same calibration with each set dropped in turn (min-max): how much a "
        "bar depends on which people are in the data.",
        "",
        "| threshold | trial | WeSpeaker | ref FAR there (pooled / worst scope) | new value | leave-one-set-out | how | binding scope | TAR old | TAR new | TAR old/new, hardest scope |"
        + (f" `.{cmp_name}` |" if cmp_name else ""),
        "|---|---|---|---|---|---|---|---|---|---|---|" + ("---|" if cmp_name else ""),
    ]
    for key, x in d.items():
        if x["kind"] == "margin":
            far = f"n/a (std ratio {x['std_ratio_used']:.3f})"
            tar_o = tar_n = hard = "-"
        elif x["kind"] == "target":
            far = f"n/a: same-person pass rate {_pct(x['pass_rate_ref'])} kept"
            tar_o, tar_n, hard = _pct(x["pass_rate_ref"]), _pct(x["pass_rate_new"]), "-"
        elif "far_ref_pooled" in x:
            far = f"{_far(x['far_ref_pooled'])} / {_far(x['far_ref_worst'])} ({x['far_ref_worst_scope']})"
            tar_o, tar_n = _pct(x.get("tar_ref")), _pct(x.get("tar_new"))
            h = x.get("tar_hardest_scope")
            hard = f"{_pct(h[1])} / {_pct(h[2])} ({h[0]})" if h else "-"
        else:
            far, tar_o, tar_n, hard = "-", "-", "-", "-"
        lo = x.get("leave_one_set_out")
        loso = f"{min(lo.values()):.3f}-{max(lo.values()):.3f}" if lo else "-"
        cap = " (capped)" if x.get("capped") else ""
        row = (f"| `{key}` | {x.get('trial_type', '-')} | {x['weSpeaker']:.3f} | {far} | **{x['new']:.3f}**{cap} | {loso} | "
               f"{x['method']} | {x.get('binding_scope', '-')} | {tar_o} | {tar_n} | {hard} |")
        if cmp_name:
            cv = cmpv.get(key)
            row += f" {cv:.2f} |" if cv is not None else " - |"
        lines.append(row)
    lines += ["", "## Trial types", ""]
    for t, desc in doc["trial_types"].items():
        lines.append(f"- **{t}**: {desc}")
    lines += ["", "Profile trials (P) use every set; targets are the same person in another session. "
              "Meeting trials (W) take impostors from people in the same session (AMI, ICSI only), "
              "targets from every set.", ""]
    inferred = [k for k, x in d.items() if not x.get("explicit_spec") and x["kind"] != "copy"]
    if inferred:
        lines += [f"Trial type inferred from the field name (no explicit entry in the script): {', '.join('`'+k+'`' for k in inferred)}.", ""]

    lines += ["## Per scope", "", "| threshold | scope | ref FAR | how | ref count / n | guard allows | new (fit / guard) | GPD new |", "|---|---|---|---|---|---|---|---|"]
    for key, x in d.items():
        for sc, r in (x.get("per_scope") or {}).items():
            fit = r.get("t_fit")
            lines.append(f"| `{key}` | {sc} | {_far(r.get('far'))} | {r['method']} | {r['ref_count']} / {r['n']} | {r.get('guard_allows', '-')} | "
                         f"{r['t_new']:.3f} ({'-' if fit is None else f'{fit:.3f}'} / {r['t_guard']:.3f}) | "
                         f"{'-' if r.get('t_gpd') is None else format(r['t_gpd'], '.3f')}"
                         f"{' (ref past GPD endpoint)' if r.get('gpd_note') else ''} |")
    checks = [(k, x["same_session_only"], x["cross_session_only"]) for k, x in d.items() if "cross_session_only" in x]
    if checks:
        lines += ["", "Meeting (W) bars are the highest of two matches: impostors from the same session (AMI, "
                  "ICSI) and impostors from another session (the other speaker's cluster from a different "
                  "session, all four sets). Same-session / cross-session: "
                  + ", ".join(f"`{k}` {a:.3f} / {b:.3f}" for k, a, b in checks) + "."]
    cmp_rows = [(k, x) for k, x in d.items() if "compare" in x]
    if cmp_rows:
        lines += ["", f"## Against the `.{cmp_name}` preset", "",
                  "Candidate FAR at the preset's value vs the reference's FAR at the WeSpeaker value, same "
                  "trials (pooled over scopes); empirical count share, then the Gaussian tail estimate.", "",
                  f"| threshold | trial | `.{cmp_name}` | cand FAR there (emp / fit) | ref FAR at WeSpeaker (emp / fit) | cand TAR there | calibrated |",
                  "|---|---|---|---|---|---|---|"]
        for k, x in cmp_rows:
            c = x["compare"]
            lines.append(f"| `{k}` | {x['trial_type']} | {c['value']:.2f} | {_far(c['cand_far_emp'])} / {_far(c['cand_far_gauss'])} | "
                         f"{_far(c['ref_far_emp'])} / {_far(c['ref_far_gauss'])} | {_pct(c['cand_tar'])} | {x['new']:.3f} |")
        ctx = (doc.get("compare_preset") or {}).get("context")
        if ctx:
            para = (f"Context, {ctx['trial']}: different-speaker p95 is {ctx['ref_p95']:.3f} for the reference "
                    f"and {ctx['cand_p95']:.3f} for the candidate. A remap that floors FAR at 1e-4 with no tail "
                    f"model would send every bar whose reference FAR is below 1e-4 to the candidate's 1e-4 "
                    f"point, {ctx['cand_at_far_1e-4']:.3f} here, whatever the bar.")
            if cmp_name == "eRes2Net":
                para += (" That is the June 2026 method behind `.eRes2Net`, and its header cites a WeSpeaker "
                         "different-speaker p95 of 0.62 on AMI cross-call means: the WeSpeaker embedding it was "
                         "matched against was far wider than today's app embedding, so its bars had real FARs "
                         "to match and came out much lower.")
            lines += ["", para]

    margins = [(k, x) for k, x in d.items() if x["kind"] == "margin"]
    lines += ["", "## Margins", ""]
    if margins:
        lines += ["| margin | WeSpeaker | std ratio (used / pooled) | new | stranger gap pass old / new | equal-pass margin | equal-FAR offset check |",
                  "|---|---|---|---|---|---|---|"]
        for k, x in margins:
            off = x.get("equal_far_offset_check")
            lines.append(f"| `{k}` | {x['weSpeaker']:.3f} | {x['std_ratio_used']:.3f} ({x['binding_scope']}) / {x['std_ratio_pooled']:.3f} | "
                         f"**{x['new']:.3f}** | {_pct(x.get('stranger_gap_pass_ref'))} / {_pct(x.get('stranger_gap_pass_new'))} | "
                         f"{'-' if x.get('equal_pass_margin') is None else format(x['equal_pass_margin'], '.3f')} | "
                         f"{'-' if not off else format(off['value'], '.3f') + ' (on ' + off['base'] + ')'} |")
        lines += ["", "A margin is a difference of two cosines, so it scales with how spread out the scores are, "
                  "not with where the bars sit. The new margin = WeSpeaker margin x (std of the candidate's "
                  "impostor PA scores / std of the reference's), taking the highest ratio over scopes. Check: "
                  "for every session mean, drop its own speaker's profile and take top-1 minus top-2 over the "
                  "other profiles in the set (a stranger's gap). The equal-pass margin is the candidate margin "
                  "that lets the same share of strangers through as the WeSpeaker margin does. For the match "
                  "bonuses (added to a floor), the offset check remaps floor + bonus by equal FAR and subtracts the "
                  "remapped floor."]
    else:
        pa = doc["tail_fits"].get(f"{MARGIN_TYPE}/pooled")
        ratio = (pa["cand"]["std"] / pa["ref"]["std"]) if pa and pa["ref"]["std"] else None
        lines += ["The struct has no margin fields yet. When one is added (a name with margin/gap/separation/bonus), "
                  "it is scaled by the impostor std ratio on PA trials"
                  + (f": pooled ratio here {ratio:.3f}." if ratio else ".")]

    lines += ["", "## Tail fits (impostor scores)", "",
              "Gaussian fit to the top 1% (at least 50) in probit space: score = mu + s * z. "
              "GPD: excesses over u (xi < 0 means a bounded tail with that endpoint).", "",
              "| type/scope | impostors | model | n | max | mean | std | gauss mu / s (rmse) | fit check: score, FAR emp / fit | GPD xi / sigma / endpoint |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    n_scopes = defaultdict(int)
    for k in doc["tail_fits"]:
        if not k.endswith("/pooled") and "(cross-session)" not in k:
            n_scopes[k.split("/")[0]] += 1
    for k, f in doc["tail_fits"].items():
        if k.endswith("/pooled") and n_scopes[k.split("/")[0]] <= 1:
            continue  # one scope: pooled is the same numbers
        for who in ("ref", "cand"):
            g = f[who]
            gauss = (f"{g['gauss_mu']:.3f} / {g['gauss_s']:.4f} ({g['gauss_rmse']:.4f})" if "gauss_mu" in g else "-")
            gpd = (f"{g['gpd_xi']:.3f} / {g['gpd_sigma']:.4f} / "
                   f"{'-' if g.get('gpd_endpoint') is None else format(g['gpd_endpoint'], '.3f')}" if "gpd_xi" in g else "-")
            chk = (f"{g['check_t']:.3f}: {_far(g['check_far_emp'])} / {_far(g.get('check_far_gauss'))}"
                   if "check_t" in g else "-")
            lines.append(f"| {k} | {f['source']} | {who} | {g['n']} | {g['max']:.3f} | {g['mean']:.3f} | {g['std']:.4f} | {gauss} | {chk} | {gpd} |")

    used = sorted({c for info in doc["sets"].values() for c in info["conds"]})
    if used == ["clean"]:
        lines[4:4] = ["> **Clean audio only.** No call-audio embeddings (opus12, noisy) exist yet for both models, "
                      "so these bars are not yet checked on bad audio. Rerun when they land.", ""]
    lines += ["", "## Inputs", ""]
    for s, info in doc["sets"].items():
        lines.append(f"- {s}: {info['clips']} clips ({info['dropped']} dropped for a missing embedding), "
                     f"{info['speakers']} speakers, {info['sessions']} sessions; conditions {', '.join(info['conds'])}")
    if doc["missing_inputs"]:
        lines.append(f"- not available yet: {'; '.join(doc['missing_inputs'])}")
    lines.append(f"- Swift source sha1 {doc['swift_source']['sha1']}, fields: {', '.join(doc['swift_source']['fields'])}")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="candidate model_id (VP/emb/<model_id>/)")
    ap.add_argument("--ref", default="app-wespeaker-coreml", help="reference model_id, the model the preset was tuned for")
    ap.add_argument("--ref-preset", default="weSpeaker", help="preset in SpeakerEmbeddingThresholds.swift that holds the reference bars")
    ap.add_argument("--compare-preset", default=None, help="another preset to show next to the result (default: eRes2Net for ERes2Net models)")
    ap.add_argument("--sets", default=",".join(HUMAN_SETS))
    ap.add_argument("--conds", default=",".join(DEFAULT_CONDS))
    ap.add_argument("--out", default=None, help="JSON path (default VP/results/thresholds/<model>.json); report goes next to it")
    ap.add_argument("--vp", default=str(DEFAULT_VP))
    ap.add_argument("--swift", default=str(DEFAULT_SWIFT))
    args = ap.parse_args()
    if args.model == args.ref:
        log("candidate equals reference: the result should reproduce the preset (identity check)")
    calibrate(args)


if __name__ == "__main__":
    main()
