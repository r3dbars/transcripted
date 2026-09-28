#!/usr/bin/env python3
"""Hill-climb bench `meeting-import`: time the full meeting pipeline per minute of audio.

    python3 scripts/hillclimb/benches/meeting_import.py --request REQUEST.json
    python3 scripts/hillclimb/benches/meeting_import.py --self-test

For each requested suite item this runs the real headless pipeline,
`transcripted-cli import-audio` (Parakeet v3 + PyAnnote + speaker matching),
into a throwaway output folder, then scores what it wrote:

    turnaround_s          wall clock for the CLI process (decode through publish)
    turnaround_rtf        turnaround_s / audio duration (the objective's primary)
    audio_duration_s      item duration_s, else transcript frontmatter, else a probe
    pipeline_processing_s the transcript's own `processing_time` frontmatter
    transcript_words      words in the Full Transcript section
    speaker_count         distinct speaker labels in the Full Transcript section
    word_recall           vs the item's truth file (Zoom captions or plain text)
    speaker_count_error   |speaker_count - item speakers|

Gates: no_transcript (CLI failed, timed out, or published nothing) and
empty_transcript (a transcript with zero words). A gated item carries no
metrics, so a fast failure can never look like a speedup.

Why it is built this way:
- Every item gets a fresh, empty speaker database, so no run can learn a voice
  from an earlier run and make later ones look better or worse.
- The first CLI process pays model load and CoreML compile time. One untimed
  warmup import of the shortest item runs first (bench_options.warmup, default
  true) so that cost never lands on whichever item happens to be first.
- Word recall and transcript parsing reuse scripts/ops/compare-meeting-corpus.py,
  so this bench and the corpus QA report cannot drift apart.
- The result holds only numbers, ids, hashes and short redacted error strings.
  Output folders hold transcript text, so they are deleted right after scoring
  unless bench_options.keep_outputs is true.

Knobs: speaker.embedder becomes --speaker-embedder; env knobs arrive already
set in the environment and pass through. The diarization/clustering knobs in
LAB_KNOB_IDS go to a flat JSON file named by TRANSCRIPTED_LAB_KNOBS_FILE; an
item errors when the CLI's `[lab-knobs]` stderr says an override fell back to
its default, or never confirms the overrides were loaded.

bench_options: cli_binary (repo-relative ok), models_dir, diarization_models_dir,
warmup (bool), keep_outputs (bool), item_timeout_s (default 3600).
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path
from types import ModuleType
from typing import Any, Mapping

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))

from hc_benches import RESULT_SCHEMA  # noqa: E402
from hc_proc import run_group  # noqa: E402

BENCH_ID = "meeting-import"
DEFAULT_CLI = "Tools/TranscriptedCLI/.build/release/transcripted-cli"
DEFAULT_ITEM_TIMEOUT_S = 3600.0
EMBEDDER_KNOB = "speaker.embedder"
# ImportAudioCommand.swift validate(): the only accepted --speaker-embedder values.
EMBEDDERS = ("app", "wespeaker", "eres2net")
GATES = ("no_transcript", "empty_transcript")
# Knobs the CLI path cannot apply today. The app reads this env var in
# Sources/Speech/ParakeetModelLifecycle.swift, but the CLI builds its AsrManager
# in TranscribeCommand.swift loadManager() without it, so a climb on this knob
# through this bench measures noise.
CLI_IGNORED_KNOBS = ("speech.parakeet.encoder_compute_units",)
# Meeting-pipeline constants the CLI reads from the JSON file named by
# TRANSCRIPTED_LAB_KNOBS_FILE (Sources/TranscriptedCore/Utilities/LabKnobOverrides.swift).
LAB_KNOBS_ENV = "TRANSCRIPTED_LAB_KNOBS_FILE"
LAB_KNOB_IDS = frozenset({
    "diarization.clustering_threshold",
    "diarization.vbx_fa",
    "diarization.vbx_fb",
    "diarization.min_segment_duration",
    "speaker.cluster.same_voice_consolidation.wespeaker",
    "speaker.cluster.small_cluster_absorb.wespeaker",
    "speaker.cluster.same_voice_consolidation.eres2net",
    "speaker.cluster.small_cluster_absorb.eres2net",
})
LAB_KNOBS_TAG = "[lab-knobs]"
# LabKnobOverrides.warn() phrasings that mean an override was NOT applied:
# whole-file failures say "using defaults", per-key type problems say
# "using the default" or "ignoring it".
LAB_KNOBS_REJECTED = ("using defaults", "using the default", "ignoring it")
LAB_KNOBS_ACTIVE = "active overrides:"
DETAIL_LIMIT = 160
PATH_RE = re.compile(r"(?:~|/)[^\s'\"]*")
FRONTMATTER_LINE_RE = re.compile(r"^([A-Za-z0-9_]+):\s*(.*)$")

_OPS_MODULES: dict[str, ModuleType] = {}


class BenchSetupError(RuntimeError):
    """A problem with the request or the machine, not with one item."""


def load_ops_module(name: str) -> ModuleType:
    """Import scripts/ops/<name>.py (hyphenated, so not importable by name)."""
    if name not in _OPS_MODULES:
        path = REPO_ROOT / "scripts" / "ops" / f"{name}.py"
        module_name = "hc_ops_" + name.replace("-", "_")
        spec = importlib.util.spec_from_file_location(module_name, path)
        if spec is None or spec.loader is None:
            raise BenchSetupError(f"cannot import {path}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module  # dataclasses look their module up here
        spec.loader.exec_module(module)
        _OPS_MODULES[name] = module
    return _OPS_MODULES[name]


def compare_module() -> ModuleType:
    return load_ops_module("compare-meeting-corpus")


# ---------------------------------------------------------------- small helpers


def resolve_path(value: str | os.PathLike[str]) -> Path:
    path = Path(os.path.expandvars(str(value))).expanduser()
    return path if path.is_absolute() else REPO_ROOT / path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def os_description() -> str:
    if platform.system() == "Darwin":
        return f"macOS {platform.mac_ver()[0]} {platform.machine()}"
    return platform.platform()


def redact(text: str) -> str:
    """Keep an error short and free of file paths (they can name private meetings)."""
    return PATH_RE.sub("<path>", " ".join(text.split()))[:DETAIL_LIMIT]


def make_empty_speaker_db(path: Path) -> None:
    """A valid, nonempty, schema-less SQLite file.

    The CLI snapshots --speaker-db with SQLite's backup API and rejects a
    zero-byte file (SpeakerDatabaseSnapshot.swift: "must be a nonempty regular
    file") and one that fails quick_check. An empty schema means no saved
    speakers, and SpeakerDatabase creates its tables in the private snapshot.
    """
    connection = sqlite3.connect(path)
    try:
        connection.execute("CREATE TABLE hillclimb_placeholder (x)")
        connection.execute("DROP TABLE hillclimb_placeholder")
        connection.commit()
        connection.execute("VACUUM")
    finally:
        connection.close()


# ------------------------------------------------------------ transcript parsing


def parse_frontmatter(markdown: str) -> dict[str, str]:
    """Flat `key: value` pairs from the YAML frontmatter (TranscriptFormatter.swift)."""
    if not markdown.startswith("---"):
        return {}
    values: dict[str, str] = {}
    for line in markdown.splitlines()[1:]:
        if line.strip() == "---":
            break
        match = FRONTMATTER_LINE_RE.match(line)  # indented (nested) lines never match
        if match:
            values[match.group(1)] = match.group(2).strip().strip('"')
    return values


def parse_clock(value: str | None) -> float | None:
    """`duration: "M:SS"` (or H:MM:SS) to seconds."""
    if not value:
        return None
    parts = value.split(":")
    try:
        numbers = [float(part) for part in parts]
    except ValueError:
        return None
    seconds = 0.0
    for number in numbers:
        seconds = seconds * 60 + number
    return seconds


def parse_seconds(value: str | None) -> float | None:
    """`processing_time: "12.3s"` to 12.3."""
    if not value:
        return None
    try:
        return float(value.rstrip("s").strip())
    except ValueError:
        return None


def probe_duration(path: Path) -> float | None:
    """ffprobe/afinfo via validate-meeting-corpus.py, then the stdlib wave module."""
    try:
        seconds = load_ops_module("validate-meeting-corpus").duration_seconds(path)
    except Exception:  # noqa: BLE001 - a probe is best-effort
        seconds = None
    if seconds:
        return float(seconds)
    if path.suffix.lower() in (".wav", ".wave"):
        try:
            with wave.open(str(path), "rb") as handle:
                rate = handle.getframerate()
                return handle.getnframes() / rate if rate else None
        except (wave.Error, EOFError, OSError):
            return None
    return None


def audio_duration(item: Mapping[str, Any], frontmatter: Mapping[str, str], audio: Path) -> float | None:
    for candidate in (item.get("duration_s"), parse_clock(frontmatter.get("duration"))):
        if isinstance(candidate, (int, float)) and not isinstance(candidate, bool) and candidate > 0:
            return float(candidate)
    return probe_duration(audio)


def truth_text(path: Path) -> str:
    """Zoom caption files keep only spoken text; anything else is plain text."""
    compare = compare_module()
    parsed = compare.parse_zoom(path)
    if parsed["turn_count"] > 0:
        return parsed["text"]
    return path.read_text(encoding="utf-8", errors="replace")


def transcript_words(parsed: Mapping[str, Any]) -> list[str]:
    # parse_transcripted_markdown falls back to scoring the whole body when it
    # finds no transcript rows; that body is analytics boilerplate, not speech.
    if parsed["turn_count"] == 0:
        return []
    return compare_module().tokenize(parsed["text"])


def score_transcript(transcript: Path, item: Mapping[str, Any], truth: Path | None) -> tuple[dict[str, float], dict[str, str], bool]:
    """Quality metrics, the frontmatter, and whether the transcript is empty."""
    compare = compare_module()
    markdown = transcript.read_text(encoding="utf-8", errors="replace")
    frontmatter = parse_frontmatter(markdown)
    parsed = compare.parse_transcripted_markdown(transcript)
    words = transcript_words(parsed)
    metrics: dict[str, float] = {
        "transcript_words": float(len(words)),
        "speaker_count": float(parsed["speaker_label_count"]),
    }
    if truth is not None:
        reference = compare.tokenize(truth_text(truth))
        metrics["word_recall"] = float(compare.overlap_metrics(reference, words)["recall"])
    speakers = item.get("speakers")
    if isinstance(speakers, int) and not isinstance(speakers, bool) and speakers >= 0:
        metrics["speaker_count_error"] = float(abs(parsed["speaker_label_count"] - speakers))
    processing = parse_seconds(frontmatter.get("processing_time"))
    if processing is not None:
        metrics["pipeline_processing_s"] = processing
    return metrics, frontmatter, not words


# ------------------------------------------------------------------ running CLI


class Context:
    """Everything fixed for one request."""

    def __init__(self, request: Mapping[str, Any]):
        options = dict(request.get("bench_options") or {})
        self.cli = resolve_path(options.get("cli_binary") or DEFAULT_CLI)
        if not self.cli.is_file() or not os.access(self.cli, os.X_OK):
            raise BenchSetupError(
                f"CLI binary not found or not executable at {self.cli}. Build it with "
                "TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift build -c release --package-path Tools/TranscriptedCLI"
            )
        self.models_dir = options.get("models_dir")
        self.diarization_models_dir = options.get("diarization_models_dir")
        self.warmup = bool(options.get("warmup", True))
        self.keep_outputs = bool(options.get("keep_outputs", False))
        self.item_timeout_s = float(options.get("item_timeout_s", DEFAULT_ITEM_TIMEOUT_S))
        knobs = request.get("knobs") or {}
        embedder = knobs.get(EMBEDDER_KNOB)
        if embedder is not None and embedder not in EMBEDDERS:
            raise BenchSetupError(f"knob {EMBEDDER_KNOB}={embedder!r} is not one of {list(EMBEDDERS)}")
        self.embedder: str | None = embedder
        self.ignored_knobs = sorted(k for k in CLI_IGNORED_KNOBS if k in knobs)
        result_path = request.get("result_path")
        parent = Path(result_path).resolve().parent if result_path else None
        if parent is not None:
            parent.mkdir(parents=True, exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix="meeting-import-", dir=parent))
        self.env = dict(os.environ)
        self.env["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        self.lab_knobs = {k: v for k, v in knobs.items() if k in LAB_KNOB_IDS}
        self.env.pop(LAB_KNOBS_ENV, None)
        if self.lab_knobs:
            # Kept in the request work dir (ids and numbers only) as a record of the trial.
            knobs_file = (parent or self.scratch) / "lab-knobs.json"
            knobs_file.write_text(json.dumps(self.lab_knobs, indent=2, sort_keys=True))
            self.env[LAB_KNOBS_ENV] = str(knobs_file)
        self._runs = 0

    def argv(self, audio: Path, out_dir: Path, speaker_db: Path) -> list[str]:
        argv = [
            str(self.cli), "import-audio", str(audio),
            "--output-dir", str(out_dir),
            "--no-retain-audio", "--no-download", "--json",
            "--speaker-db", str(speaker_db),
        ]
        if self.embedder is not None:
            argv += ["--speaker-embedder", self.embedder]
        if self.models_dir:
            argv += ["--models-dir", str(resolve_path(self.models_dir))]
        if self.diarization_models_dir:
            argv += ["--diarization-models-dir", str(resolve_path(self.diarization_models_dir))]
        return argv

    def new_run_dir(self, label: str) -> Path:
        self._runs += 1
        safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)[:40]
        run_dir = self.scratch / f"{self._runs:03d}-{safe}"
        (run_dir / "out").mkdir(parents=True)
        (run_dir / "tmp").mkdir()
        return run_dir

    def discard(self, run_dir: Path) -> None:
        if not self.keep_outputs:
            shutil.rmtree(run_dir, ignore_errors=True)

    def close(self) -> None:
        if self.keep_outputs:
            print(f"meeting-import: kept outputs under {self.scratch}", file=sys.stderr)
        else:
            shutil.rmtree(self.scratch, ignore_errors=True)


class CLIRun:
    def __init__(self, returncode: int | None, seconds: float, stdout: str, stderr: str, run_dir: Path):
        self.returncode = returncode  # None means timed out
        self.seconds = seconds
        self.stdout = stdout
        self.stderr = stderr
        self.run_dir = run_dir

    def transcript(self) -> Path | None:
        """The receipt's transcriptPath when it is inside our output dir, else any .md there."""
        out_dir = (self.run_dir / "out").resolve()
        for line in reversed(self.stdout.splitlines()):
            try:
                receipt = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(receipt, dict) and receipt.get("transcriptPath"):
                path = Path(receipt["transcriptPath"]).resolve()
                if path.is_file() and out_dir in path.parents:
                    return path
                break
        found = sorted(out_dir.glob("*.md"))
        return found[0] if found else None

    def lab_knob_problem(self, expected: bool) -> str | None:
        """Why the lab knob overrides did not apply in this run, if they did not."""
        lines = [line for line in self.stderr.splitlines() if LAB_KNOBS_TAG in line]
        for line in lines:
            if any(phrase in line for phrase in LAB_KNOBS_REJECTED):
                return "lab knob overrides not applied: " + redact(line.split(LAB_KNOBS_TAG, 1)[1])
        if expected and not any(LAB_KNOBS_ACTIVE in line for line in lines):
            return "lab knob overrides not confirmed by the CLI (binary older than LabKnobOverrides?)"
        return None

    def failure(self) -> str:
        if self.returncode is None:
            return "import-audio timed out"
        lines = [line for line in self.stderr.splitlines() if line.strip()]
        tail = redact(lines[-1]) if lines else "no stderr"
        return f"import-audio exited {self.returncode}: {tail}"


def run_cli(ctx: Context, audio: Path, label: str) -> CLIRun:
    run_dir = ctx.new_run_dir(label)
    speaker_db = run_dir / "speakers.sqlite"
    make_empty_speaker_db(speaker_db)
    env = dict(ctx.env)
    env["TMPDIR"] = str(run_dir / "tmp")  # MeetingImportWorkflow honors TMPDIR for its job dir
    started = time.monotonic()
    try:
        completed = run_group(
            ctx.argv(audio, run_dir / "out", speaker_db),
            cwd=run_dir, env=env, timeout=ctx.item_timeout_s,
        )
        returncode: int | None = completed.returncode
        stdout, stderr = completed.stdout, completed.stderr
    except subprocess.TimeoutExpired:
        returncode, stdout, stderr = None, "", ""
    return CLIRun(returncode, time.monotonic() - started, stdout, stderr, run_dir)


# --------------------------------------------------------------------- scoring


def item_row(item_id: str, *, metrics: Mapping[str, float] | None = None, gates: Mapping[str, int] | None = None,
             error: str | None = None, detail: str | None = None) -> dict[str, Any]:
    row: dict[str, Any] = {"id": item_id, "metrics": dict(metrics or {}), "gates": dict(gates or {}), "error": error}
    if detail:
        row["detail"] = detail
    return row


def gated(item_id: str, gate: str, detail: str) -> dict[str, Any]:
    gates = {name: 0 for name in GATES}
    gates[gate] = 1
    return item_row(item_id, gates=gates, detail=detail)


def measure_item(ctx: Context, item: Mapping[str, Any]) -> dict[str, Any]:
    item_id = str(item["id"])
    audio = Path(str(item.get("audio") or "")).expanduser()
    if not item.get("audio") or not audio.is_file():
        return item_row(item_id, error="audio file missing on this machine")
    truth = Path(str(item["truth"])).expanduser() if item.get("truth") else None
    if truth is not None and not truth.is_file():
        return item_row(item_id, error="truth file missing on this machine")

    run = run_cli(ctx, audio, item_id)
    try:
        if run.returncode != 0:
            return gated(item_id, "no_transcript", run.failure())
        knob_problem = run.lab_knob_problem(expected=bool(ctx.lab_knobs))
        if knob_problem:
            return item_row(item_id, error=knob_problem)
        transcript = run.transcript()
        if transcript is None:
            return gated(item_id, "no_transcript", "import-audio exited 0 but published no transcript")
        try:
            quality, frontmatter, empty = score_transcript(transcript, item, truth)
        except (OSError, UnicodeError) as error:
            return item_row(item_id, error=redact(f"could not score transcript: {error}"))
        if empty:
            return gated(item_id, "empty_transcript", "transcript has zero words")
        duration = audio_duration(item, frontmatter, audio)
        if not duration:
            return item_row(item_id, error="audio duration unknown (set duration_s on the item)")
        metrics = {
            "turnaround_s": run.seconds,
            "turnaround_rtf": run.seconds / duration,
            "audio_duration_s": duration,
            **quality,
        }
        return item_row(item_id, metrics=metrics, gates={name: 0 for name in GATES})
    finally:
        ctx.discard(run.run_dir)


def audio_size(item: Mapping[str, Any]) -> float:
    try:
        return float(Path(str(item["audio"])).expanduser().stat().st_size)
    except (KeyError, OSError):
        return float("inf")


def warmup_item(items: list[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The shortest item whose audio exists (by duration_s, then file size)."""
    present = [item for item in items if item.get("audio") and Path(str(item["audio"])).expanduser().is_file()]
    if not present:
        return None

    def key(item: Mapping[str, Any]) -> tuple[float, float]:
        duration = item.get("duration_s")
        known = isinstance(duration, (int, float)) and not isinstance(duration, bool) and duration > 0
        return (float(duration) if known else float("inf"), audio_size(item))

    return min(present, key=key)


def run_warmup(ctx: Context, items: list[Mapping[str, Any]]) -> dict[str, Any]:
    if not ctx.warmup:
        return {"enabled": False}
    item = warmup_item(items)
    if item is None:
        return {"enabled": True, "ran": False}
    run = run_cli(ctx, Path(str(item["audio"])).expanduser(), "warmup")
    ctx.discard(run.run_dir)
    return {
        "enabled": True,
        "ran": True,
        "item": str(item["id"]),
        "ok": run.returncode == 0,
        "seconds": round(run.seconds, 3),
        "counted": False,
    }


def cli_build_info(ctx: Context) -> dict[str, Any] | None:
    """`transcripted-cli build-info` prints JSON unconditionally; it has no --json flag."""
    try:
        completed = run_group([str(ctx.cli), "build-info"], env=ctx.env, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    for line in reversed(completed.stdout.splitlines()):
        try:
            info = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(info, dict):
            return info
    return None


def environment(ctx: Context, build_info: Mapping[str, Any] | None, warmup: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "app_revision": "sha256:" + sha256_file(ctx.cli)[:16],
        "host": platform.node(),
        "os": os_description(),
        "cli_build_info": dict(build_info) if build_info else None,
        "speaker_embedder": ctx.embedder or "app (CLI default)",
        "speaker_embedder_env": os.environ.get("TRANSCRIPTED_SPEAKER_EMBEDDER"),
        "encoder_compute_units_env": os.environ.get("TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS"),
        "ignored_knobs": ctx.ignored_knobs,
        "lab_knob_ids": sorted(ctx.lab_knobs),
        "speaker_db": "fresh empty database per item run",
        "warmup": dict(warmup),
    }


def run_request(request: Mapping[str, Any]) -> dict[str, Any]:
    ctx = Context(request)
    try:
        build_info = cli_build_info(ctx)
        if build_info is not None and build_info.get("meetingImport") is False:
            raise BenchSetupError(
                "CLI was built without meeting import (build-info meetingImport=false). Rebuild with "
                "TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1."
            )
        items = list(request.get("items") or [])
        warmup = run_warmup(ctx, items)
        rows = [measure_item(ctx, item) for item in items]
        return {
            "schema": RESULT_SCHEMA,
            "bench": BENCH_ID,
            "environment": environment(ctx, build_info, warmup),
            "items": rows,
        }
    finally:
        ctx.close()


def run_self_test() -> int:
    import unittest

    sys.path.insert(0, str(HERE))
    suite = unittest.defaultTestLoader.loadTestsFromName("test_meeting_import")
    outcome = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if outcome.wasSuccessful() else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--request", type=Path, help="request.json written by the climber")
    parser.add_argument("--self-test", action="store_true", help="run this adapter's unit tests")
    args = parser.parse_args(argv)
    if args.self_test:
        return run_self_test()
    if not args.request:
        parser.error("--request is required")
    request = json.loads(args.request.read_text())
    try:
        result = run_request(request)
    except BenchSetupError as error:
        print(f"meeting-import: {error}", file=sys.stderr)
        return 2
    result_path = Path(request.get("result_path") or args.request.with_name("result.json"))
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
