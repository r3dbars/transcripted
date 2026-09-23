#!/usr/bin/env python3
"""Hill-climb bench adapter for SpeakerEvalHarness `autoeval` (speaker naming across calls).

    python3 scripts/hillclimb/benches/speaker_autoeval.py --request REQUEST.json
    python3 scripts/hillclimb/benches/speaker_autoeval.py --self-test

What it measures
----------------
`speaker-eval-harness autoeval` replays frozen voice fingerprints meeting by
meeting through the production matcher and an ASK / SUGGEST / AUTO simulation
(Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/AutoResearch.swift). It
is deterministic, so one repetition is enough. This adapter turns the climber's
knob values into one `AutoResearchConfig`, runs the harness once per harness
identity split the request needs, and reads the per-corpus slices of the
schema-3 report (`reports[0].slices[<cache corpus>]`).

Per-item unit
-------------
A suite item is one pinned (corpus, harness_split) pair:

    {"id": "ami_orig-dev", "corpus": "ami_orig", "harness_split": "dev", "split": "dev"}

* `corpus` matches a report slice key exactly (the FingerprintCache `corpus`
  field, e.g. `ami_orig`) or a corpus family (`ami` sums every `ami_*` slice,
  using the harness's own `corpusFamily` rule, AutoResearch.swift:792).
* `harness_split` is the harness's identity split: FNV-1a(family|truth) buckets
  0-5 train, 6-7 dev, 8-9 holdout (AutoResearch.swift:799). Every quality
  variant of one person lands in the same split, so pinning harness `holdout`
  to the climber's holdout and `train`/`dev` to the climber's dev split means
  dev and holdout never share a person. The adapter refuses (item error) any
  item whose harness_split would leak across that line.
* Condition-bucket slices (`condition/...`) are pooled over all corpora in the
  report and overlap across dimensions, so they are not items. The climber's
  hard gates therefore see per-corpus safety totals only; the per-bucket
  no-regression rule in scripts/speaker_autoresearch_contract.py is NOT applied
  here. Re-check any winner with scripts/run_speaker_autoresearch.py before
  shipping it.

Metrics per item: auto_coverage (correct automatic names / returning
opportunities), prompts_per_recurring_speaker (repeat prompts / recurring
speakers), auto_precision (only when there was at least one automatic name),
repeat_prompts, correct_automatic_names, returning_opportunities.
Gates per item (counts): false_automatic_name (scorable purity),
false_automatic_name_all_purities, open_set_false_automatic_name,
cross_person_merge (within + cross meeting false-merge indicators),
contaminated_profile, wrong_suggestion, open_set_wrong_suggestion.
A corpus with no scored identities or no returning speaker in a split comes
back as an item error, never as zeros.

Input it needs (only on the Mac)
--------------------------------
1. The harness binary, built on Apple Silicon:
       bash build-deps.sh
       swift build -c release --package-path Tools/SpeakerEvalHarness
   (default bench_options.harness_binary:
   Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness)
2. FingerprintCache JSON files, one per corpus x audio-quality variant:
       {"corpus": "ami_orig", "meetings": [{"meeting": str, "order": int,
         "speakers": [{"gtSpeaker": str, "embedding": [256 floats],
                       "durationSeconds": float, "segmentCount": int,
                       "clusterCount": int, "purity": float}]}]}
   (AutoResearchModels.swift:7-25). Expected layout on the Mac, gitignored:
       data/eval/qmatrix/<corpus>_<quality>/fingerprints.json   (~11 GB total)
   NOTHING IN THIS REPO PRODUCES THESE FILES. The docs name an out-of-tree
   `ladder-fingerprints` harness command
   (Tests/TranscriptedCoreTests/SpeakerTests/SpeakerExemplarDeltaEvalTests.swift:21-22,
   docs/speaker-eval-exemplar-delta-2026-07.md:80-82), but main.swift only
   dispatches dump / replay / autoeval / autoeval-self-test (main.swift:318-321)
   and no script writes `gtSpeaker`/`purity`/`clusterCount` records. The
   producer probably lives on the unmerged remote branch
   eval/ladder-sweep-multi-meeting (unverified). The caches must be copied
   onto the Mac from wherever they were made.
3. A SHA-256 manifest of those caches, paths relative to the input root:
       cd data/eval/qmatrix && shasum -a 256 */fingerprints.json > ../qmatrix-manifest.sha256
   Point bench_options.manifest / bench_options.input_root at them, or set
   TRANSCRIPTED_SPEAKER_AUTOEVAL_MANIFEST / TRANSCRIPTED_SPEAKER_AUTOEVAL_INPUT_ROOT.
   Defaults: data/eval/qmatrix-manifest.sha256 and data/eval/qmatrix.

environment.app_revision = "sha256:<16 hex of harness binary>+<12 hex of manifest>",
so trials on a rebuilt harness or a changed fingerprint set never compare.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import subprocess
import sys
import time
import unittest
from pathlib import Path
from typing import Any, Mapping, Sequence

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from hc_benches import RESULT_SCHEMA, validate_result  # noqa: E402
from speaker_autoresearch_contract import BASELINE, EVALUATOR_SCHEMA_VERSION  # noqa: E402
from speaker_autoresearch_runtime import (  # noqa: E402
    binary_source_stamp,
    evaluator_source_sha256,
    file_sha256,
    verify_manifest,
)

BENCH_ID = "speaker-autoeval"
CONFIG_ID = "hillclimb-candidate"
HARNESS_SPLITS = ("train", "dev", "holdout")
# Climber split -> harness identity splits allowed in it. Holdout identities
# must never be measured while climbing, and vice versa.
ALLOWED_HARNESS_SPLITS = {"dev": ("train", "dev"), "holdout": ("holdout",)}

DEFAULT_HARNESS = "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
DEFAULT_MANIFEST = "data/eval/qmatrix-manifest.sha256"
DEFAULT_INPUT_ROOT = "data/eval/qmatrix"
MANIFEST_ENV = "TRANSCRIPTED_SPEAKER_AUTOEVAL_MANIFEST"
INPUT_ROOT_ENV = "TRANSCRIPTED_SPEAKER_AUTOEVAL_INPUT_ROOT"
DEFAULT_HARNESS_TIMEOUT_SECONDS = 3300.0
MAX_ERROR_CHARS = 240

KNOB_FIELDS: dict[str, str] = {
    "speaker.naming.auto_similarity": "autoSimilarity",
    "speaker.naming.auto_margin": "autoMargin",
    "speaker.naming.required_maturity_count": "requiredMaturityCount",
    "speaker.naming.auto_maturity_evidence": "autoMaturityEvidence",
    "speaker.naming.match_maturity_evidence": "matchMaturityEvidence",
    "speaker.naming.match_floor_offset": "matchFloorOffset",
    "speaker.naming.minimum_average_similarity": "minimumAverageSimilarity",
    "speaker.naming.minimum_speech_seconds": "minimumSpeechSeconds",
    "speaker.naming.minimum_segment_count": "minimumSegmentCount",
    "speaker.writeback.evidence": "writeBackEvidence",
    "speaker.writeback.margin": "writeBackMargin",
    "speaker.writeback.confident_similarity": "confidentWriteSimilarity",
    "speaker.writeback.cautious_similarity": "cautiousWriteSimilarity",
    "speaker.writeback.confident_blend_alpha": "confidentBlendAlpha",
    "speaker.writeback.cautious_blend_alpha": "cautiousBlendAlpha",
    "speaker.exemplar.max_count": "maximumExemplars",
    "speaker.exemplar.same_condition_similarity": "exemplarSameConditionSimilarity",
    "speaker.exemplar.blend_alpha": "exemplarBlendAlpha",
}
# Swift raw values of MaturityEvidence / WriteBackEvidence (AutoResearchModels.swift:70-82).
ENUM_FIELDS: dict[str, tuple[str, ...]] = {
    "autoMaturityEvidence": ("appearances", "confirmed_meetings"),
    "matchMaturityEvidence": ("appearances", "confirmed_meetings"),
    "writeBackEvidence": ("production", "confirmed_or_auto", "confirmed_only"),
}
INT_FIELDS = ("requiredMaturityCount", "minimumSegmentCount", "maximumExemplars")

# Report MetricSnapshot counters summed when an item spans several slices.
COUNT_FIELDS = (
    "observations",
    "scorableObservations",
    "recurringSpeakerUnits",
    "returningOpportunities",
    "asks",
    "suggestions",
    "automaticNames",
    "correctAutomaticNames",
    "falseAutomaticNames",
    "falseAutomaticNamesAllPurities",
    "automaticNamesOnLowPurity",
    "wrongSuggestions",
    "repeatPrompts",
    "openSetTrials",
    "openSetFalseAutomaticNames",
    "openSetWrongSuggestions",
    "falseMergeIndicators",
    "withinMeetingFalseMergeIndicators",
    "crossMeetingFalseMergeIndicators",
    "fragmentationExcess",
    "contaminatedProfiles",
)
GATE_FIELDS = {
    "false_automatic_name": "falseAutomaticNames",
    "false_automatic_name_all_purities": "falseAutomaticNamesAllPurities",
    "open_set_false_automatic_name": "openSetFalseAutomaticNames",
    "cross_person_merge": "falseMergeIndicators",
    "contaminated_profile": "contaminatedProfiles",
    "wrong_suggestion": "wrongSuggestions",
    "open_set_wrong_suggestion": "openSetWrongSuggestions",
}


class AdapterError(RuntimeError):
    """A request-level problem: nothing can be measured."""


# ---------------------------------------------------------------- knobs


def _coerce(field: str, knob_id: str, value: Any) -> Any:
    if field in ENUM_FIELDS:
        text = str(value).replace("-", "_") if isinstance(value, str) else None
        if text not in ENUM_FIELDS[field]:
            raise AdapterError(f"knob {knob_id}: {value!r} not in {list(ENUM_FIELDS[field])}")
        return text
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise AdapterError(f"knob {knob_id}: expected a finite number, got {value!r}")
    if field in INT_FIELDS:
        if float(value) != int(value):
            raise AdapterError(f"knob {knob_id}: expected an integer, got {value!r}")
        return int(value)
    return float(value)


def build_config(knobs: Mapping[str, Any]) -> dict[str, Any]:
    """Map knob ids onto one AutoResearchConfig; unset fields keep the production baseline."""
    unknown = sorted(set(knobs) - set(KNOB_FIELDS))
    if unknown:
        raise AdapterError(f"unknown knob ids for {BENCH_ID}: {unknown}")
    config = dict(BASELINE)
    config["id"] = CONFIG_ID
    for knob_id, value in knobs.items():
        field = KNOB_FIELDS[knob_id]
        config[field] = _coerce(field, knob_id, value)
    return config


def configs_match(sent: Mapping[str, Any], echoed: Mapping[str, Any]) -> bool:
    """Swift echoes the decoded config; Float fields may round-trip with tiny noise."""
    if set(sent) != set(echoed):
        return False
    for key, value in sent.items():
        other = echoed[key]
        if isinstance(value, float) and isinstance(other, (int, float)) and not isinstance(other, bool):
            if abs(value - float(other)) > 1e-6:
                return False
        elif value != other:
            return False
    return True


# ---------------------------------------------------------------- paths and identity


def _option_path(options: Mapping[str, Any], key: str, env_name: str | None, default: str) -> Path:
    raw = options.get(key) or (os.environ.get(env_name) if env_name else None) or default
    path = Path(os.path.expandvars(str(raw))).expanduser()
    return path if path.is_absolute() else REPO_ROOT / path


def resolve_inputs(options: Mapping[str, Any]) -> tuple[Path, Path, Path]:
    harness = _option_path(options, "harness_binary", None, DEFAULT_HARNESS)
    manifest = _option_path(options, "manifest", MANIFEST_ENV, DEFAULT_MANIFEST)
    input_root = _option_path(options, "input_root", INPUT_ROOT_ENV, DEFAULT_INPUT_ROOT)
    if not harness.is_file():
        raise AdapterError(
            f"harness binary missing at {harness}; build it on the Mac with "
            "`swift build -c release --package-path Tools/SpeakerEvalHarness`"
        )
    if not manifest.is_file():
        raise AdapterError(f"fingerprint manifest missing at {manifest} (set bench_options.manifest or {MANIFEST_ENV})")
    if not input_root.is_dir():
        raise AdapterError(f"fingerprint input root missing at {input_root} (set bench_options.input_root or {INPUT_ROOT_ENV})")
    return harness, manifest, input_root


def app_revision(harness: Path, manifest: Path) -> str:
    return f"sha256:{file_sha256(harness)[:16]}+{file_sha256(manifest)[:12]}"


def harness_source_state(harness: Path) -> str:
    """fresh / stale / unstamped: whether the binary was built from the current evaluator source."""
    stamp = binary_source_stamp(harness)
    if not stamp.is_file():
        return "unstamped"
    try:
        return "fresh" if stamp.read_text().strip() == evaluator_source_sha256(REPO_ROOT) else "stale"
    except OSError:
        return "unstamped"


# ---------------------------------------------------------------- harness runs


def _short(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= MAX_ERROR_CHARS else text[: MAX_ERROR_CHARS - 3] + "..."


def run_harness(
    *,
    harness: Path,
    manifest: Path,
    input_root: Path,
    config: Mapping[str, Any],
    split: str,
    work: Path,
    timeout: float,
) -> dict[str, Any]:
    """Run autoeval for one harness split; return the single config report or raise AdapterError."""
    work.mkdir(parents=True, exist_ok=True)
    configs_path = work / f"autoeval-{split}-configs.json"
    out_path = work / f"autoeval-{split}-report.json"
    configs_path.write_text(json.dumps([config], indent=2, sort_keys=True) + "\n")
    if out_path.exists():
        out_path.unlink()
    argv = [
        str(harness), "autoeval",
        "--manifest", str(manifest),
        "--input-root", str(input_root),
        "--configs", str(configs_path),
        "--split", split,
        "--out", str(out_path),
    ]
    env = dict(os.environ)
    env["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    try:
        completed = subprocess.run(argv, cwd=REPO_ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise AdapterError(f"harness split {split} timed out after {timeout:.0f}s") from error
    except OSError as error:
        raise AdapterError(f"harness could not start: {error}") from error
    (work / f"autoeval-{split}.stdout.log").write_text(completed.stdout[-200_000:])
    (work / f"autoeval-{split}.stderr.log").write_text(completed.stderr[-200_000:])
    if completed.returncode != 0:
        tail = " | ".join(completed.stderr.strip().splitlines()[-3:])
        raise AdapterError(f"harness split {split} exited {completed.returncode}: {_short(tail)}")
    try:
        report = json.loads(out_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AdapterError(f"harness split {split} wrote no readable report: {error}") from error
    return check_report(report, config, split)


def check_report(report: Mapping[str, Any], config: Mapping[str, Any], split: str) -> dict[str, Any]:
    if report.get("schemaVersion") != EVALUATOR_SCHEMA_VERSION:
        raise AdapterError(f"report schemaVersion {report.get('schemaVersion')!r}, expected {EVALUATOR_SCHEMA_VERSION}")
    if report.get("split") != split:
        raise AdapterError(f"report split {report.get('split')!r}, expected {split!r}")
    rows = report.get("reports")
    if not isinstance(rows, list) or len(rows) != 1:
        raise AdapterError("report must hold exactly one config row")
    row = rows[0]
    if not isinstance(row, dict) or not configs_match(config, row.get("config") or {}):
        raise AdapterError("report config does not match the config that was sent")
    if not isinstance(row.get("slices"), dict):
        raise AdapterError("report row has no slices")
    return row


# ---------------------------------------------------------------- per-item extraction


def corpus_family(corpus: str) -> str:
    """Python mirror of corpusFamily in AutoResearch.swift:792."""
    for family in ("ami", "voxceleb", "voxconverse"):
        if corpus.startswith(family + "_"):
            return family
    return corpus.split("_")[0] if corpus else corpus


def corpus_slices(slices: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    return {key: value for key, value in slices.items() if not key.startswith("condition/")}


def matching_slices(slices: Mapping[str, Any], corpus: str) -> list[str]:
    return sorted(key for key in corpus_slices(slices) if key == corpus or corpus_family(key) == corpus)


def sum_counts(snapshots: Sequence[Mapping[str, Any]]) -> dict[str, int]:
    totals = {name: 0 for name in COUNT_FIELDS}
    for snapshot in snapshots:
        for name in COUNT_FIELDS:
            value = snapshot.get(name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise AdapterError(f"report field {name} is not a non-negative int")
            totals[name] += value
    return totals


def item_measurement(row: Mapping[str, Any], corpus: str, split: str) -> tuple[dict[str, float], dict[str, int]]:
    keys = matching_slices(row["slices"], corpus)
    if not keys:
        available = ", ".join(sorted(corpus_slices(row["slices"]))) or "none"
        raise AdapterError(f"no slice for corpus {corpus!r} in harness split {split}; report has: {available}")
    counts = sum_counts([row["slices"][key] for key in keys])
    if counts["observations"] == 0:
        raise AdapterError(f"corpus {corpus!r} has no scored identities in harness split {split}")
    if counts["returningOpportunities"] == 0 or counts["recurringSpeakerUnits"] == 0:
        raise AdapterError(f"corpus {corpus!r} has no returning speakers in harness split {split}")
    metrics: dict[str, float] = {
        "auto_coverage": counts["correctAutomaticNames"] / counts["returningOpportunities"],
        "prompts_per_recurring_speaker": counts["repeatPrompts"] / counts["recurringSpeakerUnits"],
        "repeat_prompts": float(counts["repeatPrompts"]),
        "correct_automatic_names": float(counts["correctAutomaticNames"]),
        "returning_opportunities": float(counts["returningOpportunities"]),
    }
    if counts["automaticNames"] > 0:
        metrics["auto_precision"] = (counts["automaticNames"] - counts["falseAutomaticNames"]) / counts["automaticNames"]
    gates = {gate: counts[field] for gate, field in GATE_FIELDS.items()}
    return metrics, gates


def item_problem(item: Mapping[str, Any], request_split: str) -> str | None:
    corpus = item.get("corpus")
    harness_split = item.get("harness_split")
    if not isinstance(corpus, str) or not corpus:
        return "suite item needs a corpus"
    if harness_split not in HARNESS_SPLITS:
        return f"suite item harness_split must be one of {list(HARNESS_SPLITS)}, got {harness_split!r}"
    allowed = ALLOWED_HARNESS_SPLITS.get(request_split)
    if allowed is None:
        return f"unknown climber split {request_split!r}"
    if harness_split not in allowed:
        return f"harness split {harness_split} may not be measured in the climber's {request_split} split"
    return None


# ---------------------------------------------------------------- request


def _error_row(item_id: str, message: str) -> dict[str, Any]:
    return {"id": item_id, "metrics": {}, "gates": {}, "error": _short(message)}


def run(request: Mapping[str, Any]) -> dict[str, Any]:
    """Measure every requested item. Raises AdapterError when nothing can be measured."""
    config = build_config(request.get("knobs") or {})
    options = request.get("bench_options") or {}
    items = list(request.get("items") or ())
    harness, manifest, input_root = resolve_inputs(options)
    try:
        input_count = verify_manifest(manifest, input_root)
    except SystemExit as error:  # the shared verifier reports by exiting
        raise AdapterError(f"fingerprint manifest failed verification: {error}") from error
    result_path = request.get("result_path")
    work = Path(result_path).parent if result_path else Path.cwd()
    timeout = float(options.get("harness_timeout_seconds", DEFAULT_HARNESS_TIMEOUT_SECONDS))
    request_split = str(request.get("split", ""))

    rows: dict[str, dict[str, Any]] = {}
    by_split: dict[str, list[Mapping[str, Any]]] = {}
    for item in items:
        item_id = str(item["id"])
        problem = item_problem(item, request_split)
        if problem:
            rows[item_id] = _error_row(item_id, problem)
        else:
            by_split.setdefault(str(item["harness_split"]), []).append(item)

    seconds: dict[str, float] = {}
    for split in HARNESS_SPLITS:
        if split not in by_split:
            continue
        started = time.monotonic()
        try:
            report_row: dict[str, Any] | None = run_harness(
                harness=harness, manifest=manifest, input_root=input_root,
                config=config, split=split, work=work, timeout=timeout,
            )
            split_error = None
        except AdapterError as error:
            report_row, split_error = None, str(error)
        seconds[split] = round(time.monotonic() - started, 3)
        for item in by_split[split]:
            item_id = str(item["id"])
            if report_row is None:
                rows[item_id] = _error_row(item_id, split_error or "harness failed")
                continue
            try:
                metrics, gates = item_measurement(report_row, str(item["corpus"]), split)
                rows[item_id] = {"id": item_id, "metrics": metrics, "gates": gates, "error": None}
            except AdapterError as error:
                rows[item_id] = _error_row(item_id, str(error))

    return {
        "schema": RESULT_SCHEMA,
        "bench": BENCH_ID,
        "environment": {
            "app_revision": app_revision(harness, manifest),
            "host": platform.node(),
            "os": platform.platform(),
            "evaluator_schema_version": EVALUATOR_SCHEMA_VERSION,
            "harness_source": harness_source_state(harness),
            "manifest_inputs": input_count,
            "harness_seconds": seconds,
            "config_id": CONFIG_ID,
        },
        "items": [rows[str(item["id"])] for item in items],
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--request", type=Path, help="request.json written by the climber")
    parser.add_argument("--self-test", action="store_true", help="run this adapter's unit tests")
    args = parser.parse_args(argv)
    if args.self_test:
        suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_speaker_autoeval.py")
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
        print(f"speaker-autoeval: {error}", file=sys.stderr)
        return 2
    problems = validate_result(result, [str(item["id"]) for item in request.get("items") or ()])
    if problems:
        print("speaker-autoeval: result violates protocol: " + "; ".join(problems), file=sys.stderr)
        return 3
    Path(result_path).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
