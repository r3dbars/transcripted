#!/usr/bin/env python3
"""Hill-climb bench adapter for the speaker lab (scripts/run_speaker_lab.sh --single).

    python3 scripts/hillclimb/benches/speaker_lab.py --request REQUEST.json
    python3 scripts/hillclimb/benches/speaker_lab.py --self-test

What it measures
----------------
The speaker lab runs the meeting speaker pipeline on AMI meeting series (the
same 4 people across sessions a-d of one series): diarizer backend x voice
embedder, then the real clusterer + speaker DB replayed meeting by meeting. It
scores whether each returning person landed on the profile that already held
their voice (recognized), on someone else's (wrong person), on a brand-new
profile (asked again), and whether a first-time speaker got glued to a known
profile (new-person false match). See Tools/SpeakerEvalHarness/README.md
"Speaker lab" for the scores.json schema this adapter reads.

This adapter turns the climber's knob values into one `run_speaker_lab.sh
--single` call over every requested series, then splits the run back into
per-series items using scores.json (per-meeting DER rows) and
recognition-events.json (per-appearance outcomes).

Per-item unit
-------------
A suite item is one AMI series, pinned to a climber split:

    {"id": "ami-ES2002", "corpus": "ami", "series": "ES2002", "split": "dev"}

All series of one request replay through ONE speaker DB, in series order
(ES2002a-d, then ES2003a-d, ...). That is on purpose: the other series' people
are the distractors that make wrong-person and new-person-false-match
possible at all (one series alone has only 4 people). The consequence: an
item's numbers depend on which other items share the request. The climber
always sends the whole split, so candidate and incumbent see the same DB
context and the paired comparison is fair, but dev numbers and holdout numbers
are not comparable in absolute terms (holdout has fewer distractors).

Metrics per item: recognition_rate (recognized / returning appearances),
recognized, returning_appearances, asked_again, undetected,
first_appearances, pipeline_der, raw_der (mean over the series' meetings),
speaker_count_abs_error (pipeline), raw_speaker_count_abs_error, objective
(recognition_rate - wrong_penalty * (wrong rate + first-appearance false-match
rate), the scorer's formula applied to one series).
Gates per item (non-negative int counts): wrong_person,
new_person_false_match.

A series that is not fully downloaded, has fewer than 2 sessions, or has no
returning speaker with enough speech comes back as an item error, never zeros.
If the lab run itself fails (dump/replay/scoring), every runnable item gets
that error.

Determinism
-----------
Replay + scoring are deterministic given the dumps, and dumps are cached per
variant under <data_dir>/eval/ami/dumps/<variant>/, so one repetition is
enough once a variant's dumps exist. The FIRST trial of a variant runs the
diarizer (pyannote or Nemotron on CoreML) over every meeting. CoreML on the
ANE/GPU is not guaranteed bit-identical across runs, so re-dumping (REDUMP=1,
or deleting the cache) can move the numbers slightly: never delete dumps in
the middle of a climb. That first trial also takes minutes per meeting, so
pre-warm each variant you plan to search with a plain
`bash scripts/run_speaker_lab.sh --variants "..."` before climbing.

The cache check (score_speaker_lab.py dump-ok) matches backend/embedder/preset
only, not the harness build. After rebuilding the harness with a diarizer or
embedding change, clear the dump cache yourself: app_revision changes with the
harness binary, but stale dumps would otherwise be reused.

Input it needs (only on the Mac)
--------------------------------
1. The harness binary (bench_options.harness_binary, default
   Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness):
       bash build-deps.sh && swift build -c release --package-path Tools/SpeakerEvalHarness
   The adapter always passes --skip-build, so a climb never rebuilds mid-run.
2. AMI audio + RTTMs under <data_dir>/ami/{audio,rttm} (bench_options.data_dir,
   default <repo>/data):  bash scripts/download_ami.sh lab
3. For speaker.embedder = eres2net: the ERes2Net Model.mlmodelc
   (bench_options.eres2net_model, else the driver's FluidAudio cache default).

environment.app_revision = "sha256:<16 hex harness>+<12 hex corpus>+<8 hex lab scripts>".
corpus = SHA-256 over each requested meeting's RTTM bytes plus its audio's size
and first/last MiB (full-hashing ~3.5 GB of audio per trial is not worth it);
lab scripts = run_speaker_lab.sh, score_speaker_lab.py, speaker_eval_common.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import sys
import time
import unittest
from pathlib import Path
from typing import Any, Mapping, Sequence

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))

try:  # present once the hill-climb lab (scripts/hillclimb/hc_benches.py) is on this branch
    from hc_benches import RESULT_SCHEMA, validate_result  # noqa: E402
    PROTOCOL_SOURCE = "hc_benches"
except ImportError:  # pragma: no cover - exercised on branches without the climber
    RESULT_SCHEMA = "transcripted.hillclimb.result.v1"
    PROTOCOL_SOURCE = "fallback"

    def validate_result(result: Mapping[str, Any], expected_ids: Sequence[str]) -> list[str]:
        """Local mirror of hc_benches.validate_result (keep in sync)."""
        problems = []
        if result.get("schema") != RESULT_SCHEMA:
            problems.append(f"schema must be {RESULT_SCHEMA}, got {result.get('schema')!r}")
        items = result.get("items")
        if not isinstance(items, list):
            return problems + ["items must be a list"]
        seen = set()
        for item in items:
            item_id = item.get("id") if isinstance(item, dict) else None
            if not item_id:
                problems.append("every result item needs an id")
                continue
            if item_id in seen:
                problems.append(f"duplicate result item {item_id}")
            seen.add(item_id)
            for name, value in (item.get("metrics") or {}).items():
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                    problems.append(f"item {item_id} metric {name} is not a finite number")
            for name, value in (item.get("gates") or {}).items():
                if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                    problems.append(f"item {item_id} gate {name} must be a non-negative int")
        unexpected = seen - set(expected_ids)
        if unexpected:
            problems.append(f"result has items that were not requested: {sorted(unexpected)}")
        return problems


BENCH_ID = "speaker-lab"
CORPUS = "ami"
SERIES_RE = re.compile(r"^[A-Z]{2}[0-9]{4}$")
AUDIO_SUFFIX = ".Mix-Headset.wav"
SCORES_SCHEMA = "transcripted.speaker-lab.scores"
SCORES_SCHEMA_VERSION = 1

DEFAULT_DRIVER = "scripts/run_speaker_lab.sh"
DEFAULT_HARNESS = "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
DEFAULT_DATA_DIR = "data"
DEFAULT_TIMEOUT_SECONDS = 20_000.0
LAB_SCRIPTS = ("scripts/run_speaker_lab.sh", "scripts/score_speaker_lab.py", "scripts/speaker_eval_common.py")
MAX_ERROR_CHARS = 240
EDGE_BYTES = 1 << 20

# Driver env twins (run_speaker_lab.sh reads each as a default) plus env vars the
# harness itself reads. All scrubbed so a stray shell export can never change a trial;
# everything the trial needs is passed as a flag or set explicitly below.
SCRUBBED_ENV = (
    "VARIANTS", "BACKEND", "EMBEDDER", "NEMOTRON_PRESET", "ERES2NET_MODEL", "CORPUS", "SERIES",
    "OWN_CALLS", "OWN_CALLS_LIMIT", "MATCH", "SAME_VOICE", "CONSOLIDATION", "WRITE_PATH_FIXES",
    "THRESHOLDS", "DEDUP", "BLEND_CONFIDENT", "BLEND_CAUTIOUS", "WRITEBACK_CONFIDENT_SIM",
    "WRITEBACK_CAUTIOUS_SIM", "WRITEBACK_MARGIN", "SINGLE", "COLLAR", "MIN_APPEARANCE_SEC",
    "WRONG_PENALTY", "OUT_DIR", "SKIP_BUILD", "REDUMP", "ALLOW_PARTIAL_CORPUS", "HARNESS_BIN",
    "LAB_DATA_DIR", "TRANSCRIPTED_NEMOTRON_PRESET", "TRANSCRIPTED_SPEAKER_EMBEDDER",
    "TRANSCRIPTED_DIARIZATION_BACKEND", "TRANSCRIPTED_LAB_KNOBS_FILE",
)

# ---------------------------------------------------------------- knobs
#
# knob id -> how it reaches run_speaker_lab.sh. Ids that already exist in
# config/hillclimb/knobs.json keep their id (a winner edits the same source
# constant); new ids are proposed in speaker_lab.README.md.

BACKENDS = ("pyannote", "nemotron")
EMBEDDERS = {"wespeaker": "native", "eres2net": "eres2net"}
# Presets NemotronDiarizationRunner.resolvePresetName accepts (DiarizationBackendTests.swift
# pins fast128/fast32/fast32-int8; offline is documented in TranscriptedCore/CLAUDE.md). An
# unknown name silently falls back to fast128 while the dump records the typo, so the adapter
# only allows known ones.
NEMOTRON_PRESETS = ("fast128", "fast32", "fast32-int8", "offline")
NEMOTRON_DEFAULT_PRESET = "fast128"
MATCH_MODES = ("adaptive", "fixed")

K_BACKEND = "diarization.backend"
K_PRESET = "diarization.nemotron.preset"
K_EMBEDDER = "speaker.embedder"
K_MATCH_MODE = "speaker.match.mode"
K_MATCH_FLOOR = "speaker.match.fixed_floor"
K_SAME_VOICE = {
    "wespeaker": "speaker.cluster.same_voice_consolidation.wespeaker",
    "eres2net": "speaker.cluster.same_voice_consolidation.eres2net",
}
K_DEDUP = "speaker.profile.duplicate_merge_similarity_replay"
K_PATH_FIXES = "speaker.writeback.path_fixes"
# float knob -> (driver flag, scores.json settings.knobs field that echoes it)
FLOAT_FLAGS: dict[str, tuple[str, str]] = {
    K_DEDUP: ("--dedup", "dedup"),
    "speaker.writeback.confident_blend_alpha": ("--blend-confident", "blendConfident"),
    "speaker.writeback.cautious_blend_alpha": ("--blend-cautious", "blendCautious"),
    "speaker.writeback.confident_similarity": ("--writeback-confident-sim", "writebackConfidentSim"),
    "speaker.writeback.cautious_similarity": ("--writeback-cautious-sim", "writebackCautiousSim"),
    "speaker.writeback.margin": ("--writeback-margin", "writebackMargin"),
}
KNOB_IDS = (
    K_BACKEND, K_PRESET, K_EMBEDDER, K_MATCH_MODE, K_MATCH_FLOOR,
    *K_SAME_VOICE.values(), K_PATH_FIXES, *FLOAT_FLAGS,
)


class AdapterError(RuntimeError):
    """A request-level problem: nothing can be measured."""


def _enum(knobs: Mapping[str, Any], knob_id: str, choices: Sequence[str], default: str) -> str:
    value = knobs.get(knob_id, default)
    if not isinstance(value, str) or value not in choices:
        raise AdapterError(f"knob {knob_id}: {value!r} not in {list(choices)}")
    return value


def _number(knob_id: str, value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise AdapterError(f"knob {knob_id}: expected a finite number, got {value!r}")
    return float(value)


def _flag_number(value: float) -> str:
    return repr(round(value, 6))


def build_invocation(knobs: Mapping[str, Any]) -> tuple[list[str], dict[str, Any], list[str]]:
    """Map knob values onto driver flags.

    Returns (flags, expected, ignored): the run_speaker_lab.sh flags, the values
    scores.json must echo back (variant + effective replay knobs), and knob ids
    that had no effect in this config (e.g. a Nemotron preset under pyannote).
    Unset knobs are not passed, so the driver's production defaults apply.
    """
    unknown = sorted(set(knobs) - set(KNOB_IDS))
    if unknown:
        raise AdapterError(f"unknown knob ids for {BENCH_ID}: {unknown}")
    ignored: list[str] = []
    backend = _enum(knobs, K_BACKEND, BACKENDS, "pyannote")
    embedder = _enum(knobs, K_EMBEDDER, tuple(EMBEDDERS), "wespeaker")
    preset = _enum(knobs, K_PRESET, NEMOTRON_PRESETS, NEMOTRON_DEFAULT_PRESET)
    flags = ["--backend", backend, "--embedder", EMBEDDERS[embedder]]
    effective_preset = None
    if backend != "nemotron":
        if K_PRESET in knobs:
            ignored.append(K_PRESET)
    elif preset != NEMOTRON_DEFAULT_PRESET:
        # fast128 is what an unset preset loads; passing it would only fork the dump cache
        flags += ["--preset", preset]
        effective_preset = preset
    expected: dict[str, Any] = {
        "backend": backend,
        "embedder": EMBEDDERS[embedder],
        "nemotronPreset": effective_preset,
    }

    mode = _enum(knobs, K_MATCH_MODE, MATCH_MODES, "adaptive")
    if mode == "fixed":
        if K_MATCH_FLOOR not in knobs:
            raise AdapterError(f"knob {K_MATCH_MODE} = fixed needs {K_MATCH_FLOOR}")
        floor = _number(K_MATCH_FLOOR, knobs[K_MATCH_FLOOR])
        flags += ["--match", _flag_number(floor)]
        expected["match"] = round(floor, 4)
    else:
        if K_MATCH_FLOOR in knobs:
            _number(K_MATCH_FLOOR, knobs[K_MATCH_FLOOR])
            ignored.append(K_MATCH_FLOOR)
        flags += ["--match", "adaptive"]
        expected["match"] = "adaptive"

    for name, knob_id in K_SAME_VOICE.items():
        if knob_id not in knobs:
            continue
        value = _number(knob_id, knobs[knob_id])
        if name == embedder:
            flags += ["--same-voice", _flag_number(value)]
            expected["sameVoice"] = round(value, 4)
        else:
            ignored.append(knob_id)

    if K_PATH_FIXES in knobs:
        value = knobs[K_PATH_FIXES]
        if not isinstance(value, bool):
            raise AdapterError(f"knob {K_PATH_FIXES}: expected bool, got {value!r}")
        flags += ["--write-path-fixes", "on" if value else "off"]
        expected["writePathFixes"] = value

    for knob_id, (flag, field) in FLOAT_FLAGS.items():
        if knob_id in knobs:
            value = _number(knob_id, knobs[knob_id])
            flags += [flag, _flag_number(value)]
            expected[field] = round(value, 4)
    return flags, expected, sorted(ignored)


def check_echo(variant: Mapping[str, Any], setting: Mapping[str, Any], expected: Mapping[str, Any]) -> None:
    """scores.json must show that every knob we set was actually used."""
    effective = dict(setting.get("knobs") or {})
    for key in ("backend", "embedder", "nemotronPreset"):
        effective[key] = variant.get(key)
    wrong = []
    for key, want in expected.items():
        got = effective.get(key)
        if isinstance(want, float) and isinstance(got, (int, float)) and not isinstance(got, bool):
            if abs(float(got) - want) > 1e-3:
                wrong.append(f"{key}={got!r} (sent {want!r})")
        elif got != want:
            wrong.append(f"{key}={got!r} (sent {want!r})")
    if wrong:
        raise AdapterError("lab run did not use the requested knobs: " + ", ".join(wrong))


# ---------------------------------------------------------------- paths and identity


def _option_path(options: Mapping[str, Any], key: str, default: str) -> Path:
    raw = options.get(key) or default
    path = Path(os.path.expandvars(str(raw))).expanduser()
    return path if path.is_absolute() else REPO_ROOT / path


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def audio_fingerprint(path: Path, digest: "hashlib._Hash") -> None:
    size = path.stat().st_size
    digest.update(f"{path.name}\0{size}\0".encode())
    with path.open("rb") as handle:
        digest.update(handle.read(EDGE_BYTES))
        if size > 2 * EDGE_BYTES:
            handle.seek(size - EDGE_BYTES)
            digest.update(handle.read(EDGE_BYTES))


def corpus_fingerprint(data_dir: Path, meetings: Sequence[str]) -> str:
    digest = hashlib.sha256()
    for meeting in sorted(meetings):
        rttm = data_dir / CORPUS / "rttm" / f"{meeting}.rttm"
        digest.update(f"{meeting}\0".encode())
        digest.update(rttm.read_bytes())
        audio_fingerprint(data_dir / CORPUS / "audio" / f"{meeting}{AUDIO_SUFFIX}", digest)
    return digest.hexdigest()


def lab_scripts_fingerprint(driver: Path) -> str:
    digest = hashlib.sha256()
    for rel in LAB_SCRIPTS:
        path = driver if rel == DEFAULT_DRIVER else REPO_ROOT / rel
        digest.update(rel.encode() + b"\0")
        digest.update(path.read_bytes() if path.is_file() else b"<missing>")
    return digest.hexdigest()


def app_revision(harness: Path, corpus: str, lab: str) -> str:
    return f"sha256:{file_sha256(harness)[:16]}+{corpus[:12]}+{lab[:8]}"


# ---------------------------------------------------------------- items


def _short(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= MAX_ERROR_CHARS else text[: MAX_ERROR_CHARS - 3] + "..."


def _error_row(item_id: str, message: str) -> dict[str, Any]:
    return {"id": item_id, "metrics": {}, "gates": {}, "error": _short(message)}


def series_sessions(data_dir: Path, series: str) -> tuple[list[str], str | None]:
    """Sessions of one series that the driver will pick up, or an error.

    Mirrors run_speaker_lab.sh: a series id expands to every downloaded <series><x>.rttm.
    Unlike the driver, a session with an RTTM but no audio is an item error here (the
    driver would refuse the whole run over it).
    """
    rttm_dir = data_dir / CORPUS / "rttm"
    audio_dir = data_dir / CORPUS / "audio"
    pattern = re.compile(rf"^{series}[a-z]\.rttm$")
    names = sorted(p.name for p in rttm_dir.iterdir() if pattern.match(p.name)) if rttm_dir.is_dir() else []
    sessions = [name[: -len(".rttm")] for name in names]
    if not sessions:
        return [], f"series {series} is not downloaded (no RTTM under {rttm_dir}; run bash scripts/download_ami.sh lab)"
    empty = [m for m in sessions if (rttm_dir / f"{m}.rttm").stat().st_size == 0]
    if empty:
        return [], f"series {series} has empty RTTMs for {', '.join(empty)}"
    missing = [m for m in sessions if not (audio_dir / f"{m}{AUDIO_SUFFIX}").is_file()
               or (audio_dir / f"{m}{AUDIO_SUFFIX}").stat().st_size == 0]
    if missing:
        return [], f"series {series} has RTTMs but no audio for {', '.join(missing)}"
    if len(sessions) < 2:
        return [], f"series {series} has only {len(sessions)} session(s); recognition needs at least 2"
    return sessions, None


def item_problem(item: Mapping[str, Any], request_split: str) -> str | None:
    if item.get("corpus", CORPUS) != CORPUS:
        return f"suite item corpus must be {CORPUS!r}, got {item.get('corpus')!r}"
    series = item.get("series")
    if not isinstance(series, str) or not SERIES_RE.match(series):
        return f"suite item needs an AMI series id like ES2002, got {series!r}"
    pinned = item.get("split")
    if pinned is not None and pinned != request_split:
        return f"item pinned to the {pinned} split may not be measured in the climber's {request_split} split"
    return None


# ---------------------------------------------------------------- lab run


def run_lab(
    *,
    driver: Path,
    harness: Path,
    data_dir: Path,
    series: Sequence[str],
    flags: Sequence[str],
    options: Mapping[str, Any],
    out_dir: Path,
    log_dir: Path,
    timeout: float,
) -> Path:
    """Run the driver once; return the scores.json path or raise AdapterError."""
    argv = ["bash", str(driver), "--single", "--skip-build", "--corpus", CORPUS,
            "--series", " ".join(series), *flags, "--out-dir", str(out_dir)]
    for key, flag in (("collar", "--collar"), ("min_appearance_sec", "--min-appearance-sec"),
                      ("wrong_penalty", "--wrong-penalty")):
        if options.get(key) is not None:
            argv += [flag, str(options[key])]
    if options.get("eres2net_model"):
        argv += ["--eres2net-model", str(_option_path(options, "eres2net_model", ""))]
    env = {k: v for k, v in os.environ.items() if k not in SCRUBBED_ENV}
    env.update({
        "HARNESS_BIN": str(harness),
        "LAB_DATA_DIR": str(data_dir),
        "ALLOW_PARTIAL_CORPUS": "0",
        "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1",
    })
    log_dir.mkdir(parents=True, exist_ok=True)
    (log_dir / "speaker-lab.argv.json").write_text(json.dumps(argv, indent=1) + "\n")
    try:
        completed = subprocess.run(argv, cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise AdapterError(f"speaker lab timed out after {timeout:.0f}s") from error
    except OSError as error:
        raise AdapterError(f"speaker lab could not start: {error}") from error
    (log_dir / "speaker-lab.stdout.log").write_text(completed.stdout[-200_000:])
    (log_dir / "speaker-lab.stderr.log").write_text(completed.stderr[-200_000:])
    if completed.returncode != 0:
        tail = " | ".join(completed.stderr.strip().splitlines()[-3:])
        raise AdapterError(f"speaker lab exited {completed.returncode}: {tail}")
    lines = completed.stdout.strip().splitlines()
    scores = Path(lines[-1].strip()) if lines else None
    if scores is None or not scores.is_file():
        raise AdapterError("speaker lab printed no scores.json path on its last stdout line")
    return scores


def load_scores(scores_path: Path) -> tuple[dict, dict, dict, list]:
    """Return (scores, variant, setting, events) for a --single corpus run."""
    try:
        scores = json.loads(scores_path.read_text())
        events_all = json.loads((scores_path.parent / "recognition-events.json").read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AdapterError(f"unreadable lab output: {error}") from error
    if scores.get("schema") != SCORES_SCHEMA or scores.get("schemaVersion") != SCORES_SCHEMA_VERSION:
        raise AdapterError(
            f"scores.json schema {scores.get('schema')!r} v{scores.get('schemaVersion')!r}, "
            f"expected {SCORES_SCHEMA} v{SCORES_SCHEMA_VERSION}")
    if scores.get("mode") != "corpus" or not scores.get("single"):
        raise AdapterError("scores.json is not a --single corpus run")
    variants = scores.get("variants")
    if not isinstance(variants, list) or len(variants) != 1:
        raise AdapterError("scores.json must hold exactly one variant")
    variant = variants[0]
    settings = variant.get("settings")
    if not isinstance(settings, list) or len(settings) != 1:
        raise AdapterError("scores.json variant must hold exactly one setting")
    setting = settings[0]
    events = (events_all.get(variant.get("name")) or {}).get(setting.get("tag"))
    if not isinstance(events, list):
        raise AdapterError("recognition-events.json has no events for this variant/setting")
    return scores, variant, setting, events


def _mean(values: Sequence[float]) -> float:
    return sum(values) / len(values)


def item_measurement(
    series: str,
    sessions: Sequence[str],
    scores: Mapping[str, Any],
    variant: Mapping[str, Any],
    setting: Mapping[str, Any],
    events: Sequence[Mapping[str, Any]],
) -> tuple[dict[str, float], dict[str, int]]:
    wanted = set(sessions)
    scored = set(scores.get("meetings") or ())
    if not wanted <= scored:
        raise AdapterError(f"lab run did not score {', '.join(sorted(wanted - scored))}")
    pipe_rows = {r.get("meeting"): r for r in setting.get("perMeeting") or ()}
    raw_rows = {r.get("meeting"): r for r in (variant.get("raw") or {}).get("perMeeting") or ()}
    per_meeting = []
    for meeting in sorted(wanted):
        pipe, raw = pipe_rows.get(meeting), raw_rows.get(meeting)
        if pipe is None or raw is None:
            raise AdapterError(f"no per-meeting DER row for {meeting}")
        values = (pipe.get("der"), raw.get("der"), pipe.get("countError"), raw.get("countError"))
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) for v in values):
            raise AdapterError(f"per-meeting DER row for {meeting} has missing values")
        per_meeting.append(values)

    mine = [e for e in events if e.get("meeting") in wanted]
    returning = [e for e in mine if e.get("returning")]
    first = [e for e in mine if not e.get("returning")]
    if not returning:
        min_app = scores.get("minAppearanceSeconds")
        raise AdapterError(f"series {series} has no returning speaker with >= {min_app} s of speech")
    count = lambda rows, outcome: sum(1 for e in rows if e.get("outcome") == outcome)  # noqa: E731
    recognized = count(returning, "recognized")
    wrong = count(returning, "wrong_person")
    asked = count(returning, "asked_again")
    undetected = count(returning, "undetected")
    false_match = count(first, "false_match")
    penalty = float(scores.get("wrongPenalty", 2.0))
    rate = recognized / len(returning)
    fm_rate = false_match / len(first) if first else 0.0
    metrics: dict[str, float] = {
        "recognition_rate": rate,
        "recognized": float(recognized),
        "returning_appearances": float(len(returning)),
        "asked_again": float(asked),
        "undetected": float(undetected),
        "first_appearances": float(len(first)),
        "pipeline_der": _mean([v[0] for v in per_meeting]),
        "raw_der": _mean([v[1] for v in per_meeting]),
        "speaker_count_abs_error": _mean([abs(v[2]) for v in per_meeting]),
        "raw_speaker_count_abs_error": _mean([abs(v[3]) for v in per_meeting]),
        "objective": rate - penalty * (wrong / len(returning) + fm_rate),
    }
    gates = {"wrong_person": int(wrong), "new_person_false_match": int(false_match)}
    return metrics, gates


# ---------------------------------------------------------------- request


def run(request: Mapping[str, Any]) -> dict[str, Any]:
    """Measure every requested item. Raises AdapterError when nothing can be measured."""
    flags, expected, ignored = build_invocation(request.get("knobs") or {})
    options = request.get("bench_options") or {}
    items = list(request.get("items") or ())
    driver = _option_path(options, "driver", DEFAULT_DRIVER)
    harness = _option_path(options, "harness_binary", DEFAULT_HARNESS)
    data_dir = _option_path(options, "data_dir", DEFAULT_DATA_DIR)
    if not driver.is_file():
        raise AdapterError(f"speaker lab driver missing at {driver}")
    if not harness.is_file() or not os.access(harness, os.X_OK):
        raise AdapterError(
            f"harness binary missing at {harness}; build it on the Mac with "
            "`swift build -c release --package-path Tools/SpeakerEvalHarness`")
    result_path = request.get("result_path")
    work = Path(result_path).parent if result_path else Path.cwd()
    timeout = float(options.get("lab_timeout_seconds", DEFAULT_TIMEOUT_SECONDS))
    request_split = str(request.get("split", ""))

    rows: dict[str, dict[str, Any]] = {}
    runnable: dict[str, tuple[Mapping[str, Any], list[str]]] = {}
    for item in items:
        item_id = str(item["id"])
        problem = item_problem(item, request_split)
        sessions: list[str] = []
        if problem is None:
            sessions, problem = series_sessions(data_dir, str(item["series"]))
        if problem:
            rows[item_id] = _error_row(item_id, problem)
        elif any(entry[0]["series"] == item["series"] for entry in runnable.values()):
            rows[item_id] = _error_row(item_id, f"series {item['series']} is requested twice")
        else:
            runnable[item_id] = (item, sessions)

    series = sorted(str(entry[0]["series"]) for entry in runnable.values())
    meetings = [m for entry in runnable.values() for m in entry[1]]
    corpus = corpus_fingerprint(data_dir, meetings)
    seconds = None
    scores_meta: dict[str, Any] = {}
    if runnable:
        started = time.monotonic()
        try:
            scores_path = run_lab(
                driver=driver, harness=harness, data_dir=data_dir, series=series, flags=flags,
                options=options, out_dir=work / "speaker-lab-run", log_dir=work, timeout=timeout,
            )
            scores, variant, setting, events = load_scores(scores_path)
            check_echo(variant, setting, expected)
            lab_error = None
            scores_meta = {
                "variant": variant.get("name"),
                "setting": setting.get("tag"),
                "lab_git_revision": scores.get("gitRevision"),
                "lab_git_dirty": scores.get("gitDirty"),
                "scores_path": str(scores_path),
            }
        except AdapterError as error:
            lab_error = str(error)
        seconds = round(time.monotonic() - started, 3)
        for item_id, (item, sessions) in runnable.items():
            if lab_error:
                rows[item_id] = _error_row(item_id, lab_error)
                continue
            try:
                metrics, gates = item_measurement(str(item["series"]), sessions, scores, variant, setting, events)
                rows[item_id] = {"id": item_id, "metrics": metrics, "gates": gates, "error": None}
            except AdapterError as error:
                rows[item_id] = _error_row(item_id, str(error))

    return {
        "schema": RESULT_SCHEMA,
        "bench": BENCH_ID,
        "environment": {
            "app_revision": app_revision(harness, corpus, lab_scripts_fingerprint(driver)),
            "host": platform.node(),
            "os": platform.platform(),
            "series": series,
            "meetings": len(meetings),
            "lab_seconds": seconds,
            "driver_flags": flags,
            "ignored_knobs": ignored,
            "protocol_source": PROTOCOL_SOURCE,
            **scores_meta,
        },
        "items": [rows[str(item["id"])] for item in items],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--request", type=Path, help="request.json written by the climber")
    parser.add_argument("--self-test", action="store_true", help="run this adapter's unit tests")
    args = parser.parse_args(argv)
    if args.self_test:
        suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_speaker_lab.py")
        outcome = unittest.TextTestRunner(verbosity=1).run(suite)
        return 0 if outcome.wasSuccessful() else 1
    if args.request is None:
        parser.error("--request is required")
    request = json.loads(args.request.read_text())
    result_path = request.get("result_path") or os.environ.get("TRANSCRIPTED_HILLCLIMB_RESULT")
    if not result_path:
        print("request has no result_path", file=sys.stderr)
        return 2
    request = {**request, "result_path": result_path}
    try:
        result = run(request)
    except AdapterError as error:
        print(f"{BENCH_ID}: {error}", file=sys.stderr)
        return 2
    problems = validate_result(result, [str(item["id"]) for item in request.get("items") or ()])
    if problems:
        print(f"{BENCH_ID}: result violates protocol: " + "; ".join(problems), file=sys.stderr)
        return 3
    Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
