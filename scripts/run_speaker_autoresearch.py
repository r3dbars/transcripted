#!/usr/bin/env python3
"""Reproducible ASK/SUGGEST/AUTO speaker-identification auto-research loop.

The loop freezes and verifies cached real-audio fingerprints, evaluates one-knob
changes on stable identity splits, builds a bounded interaction sweep from safe
dev winners, and reveals holdout only for the selected finalists. Ground truth
only simulates the user's answer after ASK/SUGGEST and scores the prediction; it
is never passed to the production matcher or naming policy.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import pathlib
import subprocess
import sys
from typing import Any, Iterable


EVALUATOR_SCHEMA_VERSION = 2

BASELINE: dict[str, Any] = {
    "id": "baseline-production",
    "autoMaturityEvidence": "confirmed_meetings",
    "matchMaturityEvidence": "appearances",
    "requiredMaturityCount": 5,
    "autoSimilarity": 0.92,
    "autoMargin": 0.12,
    "minimumAverageSimilarity": -1.0,
    "minimumSpeechSeconds": 0.0,
    "minimumSegmentCount": 0,
    "matchFloorOffset": 0.0,
    "writeBackEvidence": "production",
    "writeBackMargin": 0.12,
    "confidentWriteSimilarity": 0.80,
    "cautiousWriteSimilarity": 0.72,
    "confidentBlendAlpha": 0.15,
    "cautiousBlendAlpha": 0.05,
    "maximumExemplars": 3,
    "exemplarSameConditionSimilarity": 0.80,
    "exemplarBlendAlpha": 0.30,
}

SAFETY_KEYS = (
    "falseAutomaticNames",
    "falseAutomaticNamesAllPurities",
    "openSetFalseAutomaticNames",
    "falseMergeIndicators",
    "withinMeetingFalseMergeIndicators",
    "crossMeetingFalseMergeIndicators",
    "contaminatedProfiles",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--input-root", required=True, type=pathlib.Path)
    parser.add_argument("--state-dir", required=True, type=pathlib.Path)
    parser.add_argument("--phase", choices=("prepare", "discover", "validate", "all"), default="all")
    parser.add_argument("--top-k", type=int, default=8)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--no-resume", action="store_true")
    return parser.parse_args()


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent


def config(group: str, label: str, **changes: Any) -> tuple[str, dict[str, Any]]:
    value = copy.deepcopy(BASELINE)
    value.update(changes)
    value["id"] = f"{group}-{label}"
    return group, value


def one_knob_grid() -> list[tuple[str, dict[str, Any]]]:
    grid: list[tuple[str, dict[str, Any]]] = [("baseline", copy.deepcopy(BASELINE))]
    grid.append(config(
        "maturity-evidence",
        "passive-appearances",
        autoMaturityEvidence="appearances",
    ))
    grid.extend(
        config(
            "confirmed-maturity",
            str(required),
            autoMaturityEvidence="confirmed_meetings",
            requiredMaturityCount=required,
        )
        for required in range(1, 7)
    )
    grid.extend(config("auto-similarity", str(value), autoSimilarity=value) for value in (0.90, 0.92, 0.94, 0.96, 0.98))
    grid.extend(config("auto-margin", str(value), autoMargin=value) for value in (0.08, 0.12, 0.16, 0.20, 0.25))
    grid.extend(config("average-similarity", str(value), minimumAverageSimilarity=value) for value in (0.80, 0.85, 0.90, 0.92))
    grid.extend(config("speech-seconds", str(value), minimumSpeechSeconds=value) for value in (1.0, 2.0, 4.0, 8.0, 15.0))
    grid.extend(config("segment-count", str(value), minimumSegmentCount=value) for value in (1, 2, 3, 4))
    grid.append(config("match-maturity", "confirmed", matchMaturityEvidence="confirmed_meetings"))
    grid.extend(config("match-floor", f"{offset:+.2f}", matchFloorOffset=offset) for offset in (-0.04, -0.02, 0.02, 0.04))
    grid.extend(
        (
            config("write-evidence", "confirmed-or-auto", writeBackEvidence="confirmed_or_auto"),
            config("write-evidence", "confirmed-only", writeBackEvidence="confirmed_only"),
        )
    )
    grid.extend(
        (
            config("update-weight", "freeze", confidentBlendAlpha=0.0, cautiousBlendAlpha=0.0),
            config("update-weight", "slow", confidentBlendAlpha=0.05, cautiousBlendAlpha=0.02),
            config("update-weight", "medium", confidentBlendAlpha=0.10, cautiousBlendAlpha=0.04),
            config("update-weight", "fast", confidentBlendAlpha=0.25, cautiousBlendAlpha=0.10),
        )
    )
    grid.extend(config("max-exemplars", str(value), maximumExemplars=value) for value in (1, 2, 3, 4, 5))

    # Remove exact baseline duplicates while preserving the explicit baseline row.
    unique: list[tuple[str, dict[str, Any]]] = []
    seen: set[str] = set()
    for group, item in grid:
        signature = json.dumps({k: v for k, v in item.items() if k != "id"}, sort_keys=True)
        if signature in seen:
            continue
        seen.add(signature)
        unique.append((group, item))
    return unique


def guarded_maturity_grid() -> list[tuple[str, dict[str, Any]]]:
    """Compensatory grid: earlier trust is allowed only alongside independent safety gates."""
    trials: list[tuple[str, dict[str, Any]]] = []
    for required in (1, 2, 3):
        for best_similarity in (0.92, 0.94, 0.96):
            for average_similarity in (-1.0, 0.80, 0.85, 0.90):
                for minimum_segments in (1, 2, 3, 4):
                    label = (
                        f"c{required}-best{best_similarity:.2f}-"
                        f"avg{'off' if average_similarity < 0 else f'{average_similarity:.2f}'}-"
                        f"seg{minimum_segments}"
                    )
                    trials.append(config(
                        "guarded-maturity",
                        label,
                        autoMaturityEvidence="confirmed_meetings",
                        requiredMaturityCount=required,
                        autoSimilarity=best_similarity,
                        minimumAverageSimilarity=average_similarity,
                        minimumSegmentCount=minimum_segments,
                    ))
    return trials


def verify_manifest(manifest: pathlib.Path, input_root: pathlib.Path) -> int:
    try:
        root = input_root.resolve(strict=True)
    except OSError as error:
        raise SystemExit(f"input root is unavailable: {input_root}: {error}") from error
    if not root.is_dir():
        raise SystemExit(f"input root is not a directory: {root}")
    try:
        lines = manifest.read_text().splitlines()
    except OSError as error:
        raise SystemExit(f"cannot read manifest {manifest}: {error}") from error

    count = 0
    seen: set[pathlib.Path] = set()
    for line_number, raw in enumerate(lines, 1):
        if not raw.strip():
            continue
        fields = raw.split(maxsplit=1)
        if len(fields) != 2:
            raise SystemExit(f"bad manifest line {line_number}: expected SHA256 and relative path")
        expected, relative = fields
        expected = expected.lower()
        if len(expected) != 64 or any(character not in "0123456789abcdef" for character in expected):
            raise SystemExit(f"bad manifest SHA256 on line {line_number}")
        relative_path = pathlib.Path(relative)
        if relative_path.is_absolute():
            raise SystemExit(f"manifest path must be relative on line {line_number}: {relative}")
        try:
            path = (root / relative_path).resolve(strict=True)
            path.relative_to(root)
        except (OSError, ValueError) as error:
            raise SystemExit(
                f"manifest path escapes input root or is missing on line {line_number}: {relative}"
            ) from error
        if not path.is_file():
            raise SystemExit(f"manifest input missing: {path}")
        if path in seen:
            raise SystemExit(f"duplicate manifest input on line {line_number}: {relative}")
        seen.add(path)
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise SystemExit(f"manifest checksum mismatch: {path}")
        count += 1
    if not count:
        raise SystemExit("manifest contains no inputs")
    return count


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def evaluator_source_sha256(root: pathlib.Path) -> str:
    candidates = [
        root / "Package.swift",
        root / "Tools/SpeakerEvalHarness/Package.swift",
    ]
    candidates.extend(sorted((root / "Sources/TranscriptedCore").rglob("*.swift")))
    candidates.extend(sorted((root / "Tools/SpeakerEvalHarness/Sources").rglob("*.swift")))
    digest = hashlib.sha256()
    for path in candidates:
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def binary_source_stamp(binary: pathlib.Path) -> pathlib.Path:
    return binary.parent / f"{binary.name}.source-sha256"


def runtime_identity(
    *,
    root: pathlib.Path,
    binary: pathlib.Path,
    manifest: pathlib.Path,
    input_root: pathlib.Path,
) -> dict[str, Any]:
    return {
        "evaluatorSchemaVersion": EVALUATOR_SCHEMA_VERSION,
        "binarySHA256": file_sha256(binary),
        "evaluatorSourceSHA256": evaluator_source_sha256(root),
        "runnerSHA256": file_sha256(pathlib.Path(__file__).resolve()),
        "manifestSHA256": file_sha256(manifest),
        "manifestPath": str(manifest.resolve()),
        "inputRoot": str(input_root.resolve()),
    }


def require_current_binary_source(root: pathlib.Path, binary: pathlib.Path) -> None:
    stamp = binary_source_stamp(binary)
    current = evaluator_source_sha256(root)
    try:
        built_from = stamp.read_text().strip()
    except OSError as error:
        raise SystemExit(
            f"--skip-build cannot verify evaluator source identity; rebuild without --skip-build: {error}"
        ) from error
    if built_from != current:
        raise SystemExit(
            "--skip-build binary is stale for the current evaluator source; rebuild without --skip-build"
        )


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def build_harness(root: pathlib.Path) -> pathlib.Path:
    subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", "Tools/SpeakerEvalHarness"],
        cwd=root,
        check=True,
    )
    binary = root / "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
    if not binary.is_file():
        raise SystemExit(f"harness build succeeded but binary is missing: {binary}")
    binary_source_stamp(binary).write_text(evaluator_source_sha256(root) + "\n")
    return binary


def report_configs(path: pathlib.Path) -> dict[str, dict[str, Any]]:
    try:
        return {
            item["config"]["id"]: item["config"]
            for item in json.loads(path.read_text())["reports"]
        }
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        return {}


def checkpoint_identity(
    *,
    runtime: dict[str, Any],
    split: str,
    configs: dict[str, dict[str, Any]],
    result_path: pathlib.Path,
) -> dict[str, Any]:
    return {
        **runtime,
        "split": split,
        "configs": configs,
        "resultSHA256": file_sha256(result_path),
    }


def checkpoint_validation_error(
    *,
    result_path: pathlib.Path,
    identity_path: pathlib.Path,
    runtime: dict[str, Any],
    split: str,
    expected_configs: dict[str, dict[str, Any]] | None = None,
) -> str | None:
    if not result_path.is_file():
        return f"missing result {result_path}"
    if not identity_path.is_file():
        return f"missing identity {identity_path}"
    try:
        payload = json.loads(result_path.read_text())
        saved_identity = json.loads(identity_path.read_text())
        configs = {
            item["config"]["id"]: item["config"]
            for item in payload["reports"]
        }
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        return f"unreadable checkpoint: {error}"
    if payload.get("schemaVersion") != EVALUATOR_SCHEMA_VERSION:
        return "evaluator schema version changed"
    if payload.get("split") != split:
        return f"checkpoint split is {payload.get('split')!r}, expected {split!r}"
    if expected_configs is not None and configs != expected_configs:
        return "checkpoint configs changed"
    expected_identity = checkpoint_identity(
        runtime=runtime,
        split=split,
        configs=configs,
        result_path=result_path,
    )
    if saved_identity != expected_identity:
        return "manifest, input root, evaluator, binary, runner, configs, or result identity changed"
    return None


def require_checkpoint_identity(
    *,
    result_path: pathlib.Path,
    identity_path: pathlib.Path,
    runtime: dict[str, Any],
    split: str,
    expected_configs: dict[str, dict[str, Any]] | None = None,
) -> None:
    error = checkpoint_validation_error(
        result_path=result_path,
        identity_path=identity_path,
        runtime=runtime,
        split=split,
        expected_configs=expected_configs,
    )
    if error is not None:
        raise SystemExit(f"stale or invalid checkpoint {result_path.name}: {error}")


def run_eval(
    *,
    root: pathlib.Path,
    binary: pathlib.Path,
    manifest: pathlib.Path,
    input_root: pathlib.Path,
    state: pathlib.Path,
    name: str,
    split: str,
    configs: list[dict[str, Any]],
    resume: bool,
    runtime: dict[str, Any],
) -> pathlib.Path:
    config_path = state / "checkpoints" / f"{name}-configs.json"
    identity_path = state / "checkpoints" / f"{name}-identity.json"
    result_path = state / "results" / f"{name}.json"
    log_path = state / "logs" / f"{name}.log"
    expected_configs = {item["id"]: item for item in configs}
    write_json(config_path, configs)
    if resume and result_path.is_file():
        error = checkpoint_validation_error(
            result_path=result_path,
            identity_path=identity_path,
            runtime=runtime,
            split=split,
            expected_configs=expected_configs,
        )
        if error is None:
            print(f"AUTO_RESEARCH resume {name}: existing result identity verified")
            return result_path
        print(f"AUTO_RESEARCH rerun {name}: {error}")

    command = [
        str(binary),
        "autoeval",
        "--manifest",
        str(manifest),
        "--input-root",
        str(input_root),
        "--configs",
        str(config_path),
        "--split",
        split,
        "--out",
        str(result_path),
    ]
    environment = os.environ.copy()
    environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        log.write("command: " + " ".join(command) + "\n")
        process = subprocess.Popen(
            command,
            cwd=root,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            if line.startswith("AUTOEVAL "):
                print(line, end="")
        return_code = process.wait()
    if return_code:
        raise SystemExit(f"{name} failed with exit {return_code}; see {log_path}")
    if report_configs(result_path) != expected_configs:
        raise SystemExit(f"{name} produced incomplete or mismatched configs; see {result_path}")
    write_json(
        identity_path,
        checkpoint_identity(
            runtime=runtime,
            split=split,
            configs=expected_configs,
            result_path=result_path,
        ),
    )
    return result_path


def load_reports(path: pathlib.Path) -> dict[str, dict[str, Any]]:
    payload = json.loads(path.read_text())
    return {item["config"]["id"]: item for item in payload["reports"]}


def no_safety_regression(candidate: dict[str, Any], baseline: dict[str, Any]) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    cm = candidate["metrics"]
    bm = baseline["metrics"]
    for key in SAFETY_KEYS:
        if cm[key] > bm[key]:
            reasons.append(f"{key} {cm[key]}>{bm[key]}")
    if cm["automaticNames"] < bm["automaticNames"]:
        reasons.append(f"automaticNames {cm['automaticNames']}<{bm['automaticNames']} coverage floor")
    for slice_name, baseline_slice in baseline["slices"].items():
        candidate_slice = candidate["slices"].get(slice_name)
        if candidate_slice is None:
            reasons.append(f"missing slice {slice_name}")
            continue
        for key in SAFETY_KEYS:
            if candidate_slice[key] > baseline_slice[key]:
                reasons.append(f"{slice_name}:{key} {candidate_slice[key]}>{baseline_slice[key]}")
    return not reasons, reasons


def rank_safe(
    reports: Iterable[dict[str, Any]], baseline: dict[str, Any]
) -> list[tuple[dict[str, Any], list[str]]]:
    ranked: list[tuple[dict[str, Any], list[str]]] = []
    for report in reports:
        safe, reasons = no_safety_regression(report, baseline)
        if safe:
            ranked.append((report, reasons))
    ranked.sort(
        key=lambda item: (
            item[0]["metrics"]["repeatPrompts"],
            item[0]["metrics"]["falseAutomaticNamesAllPurities"],
            -item[0]["metrics"]["correctAutomaticNames"],
            item[0]["config"]["id"],
        )
    )
    return ranked


def meaningful(candidate: dict[str, Any], baseline: dict[str, Any]) -> bool:
    cm, bm = candidate["metrics"], baseline["metrics"]
    prompt_gain = (bm["repeatPrompts"] - cm["repeatPrompts"]) / max(1, bm["repeatPrompts"])
    coverage_gain = (cm.get("autoCoverage") or 0.0) - (bm.get("autoCoverage") or 0.0)
    return prompt_gain >= 0.10 or coverage_gain >= 0.05


def group_for(config_id: str, grid_groups: dict[str, str]) -> str:
    return grid_groups.get(config_id, "interaction")


def bounded_interactions(
    grid_reports: dict[str, dict[str, Any]],
    grid_groups: dict[str, str],
) -> list[dict[str, Any]]:
    baseline = grid_reports[BASELINE["id"]]
    safe = rank_safe(grid_reports.values(), baseline)
    best_by_group: dict[str, dict[str, Any]] = {}
    for report, _ in safe:
        config_id = report["config"]["id"]
        group = group_for(config_id, grid_groups)
        if group == "baseline" or report["metrics"]["repeatPrompts"] >= baseline["metrics"]["repeatPrompts"]:
            continue
        best_by_group.setdefault(group, report["config"])

    ordered_groups = (
        "confirmed-maturity",
        "auto-similarity",
        "auto-margin",
        "speech-seconds",
        "segment-count",
        "match-maturity",
        "match-floor",
        "write-evidence",
        "update-weight",
        "max-exemplars",
    )
    current = copy.deepcopy(BASELINE)
    interactions: list[dict[str, Any]] = []
    applied: list[str] = []
    for group in ordered_groups:
        winner = best_by_group.get(group)
        if winner is None:
            continue
        for key, value in winner.items():
            if key != "id" and value != BASELINE.get(key):
                current[key] = value
        applied.append(group)
        trial = copy.deepcopy(current)
        trial["id"] = "interaction-" + "+".join(applied)
        interactions.append(trial)
    return interactions[:10]


def append_ledger(
    state: pathlib.Path,
    checkpoint: str,
    reports: dict[str, dict[str, Any]],
    baseline: dict[str, Any],
    grid_groups: dict[str, str],
    log_name: str,
) -> None:
    path = state / "results.tsv"
    if path.exists():
        lines = path.read_text().splitlines()
    else:
        lines = ["attempt\tcheckpoint\tknob\tstatus\tcommand\tprimary\tguardrails\tlog\tdecision\tdescription"]
    existing = {(fields[1], fields[2]) for line in lines[1:] if len(fields := line.split("\t")) >= 3}
    attempt = len(lines)
    for config_id in sorted(reports):
        key = (checkpoint, config_id)
        if key in existing:
            continue
        report = reports[config_id]
        safe, reasons = no_safety_regression(report, baseline)
        metric = report["metrics"]
        status = "safe" if safe else "rejected"
        decision = "candidate" if safe and meaningful(report, baseline) else ("safe-no-win" if safe else "guardrail")
        row = (
            str(attempt),
            checkpoint,
            config_id,
            status,
            f"run_speaker_autoresearch.py {checkpoint}",
            f"repeatPrompts={metric['repeatPrompts']};autoCoverage={metric.get('autoCoverage')}",
            (
                f"falseAuto={metric['falseAutomaticNames']};"
                f"falseMerge={metric['falseMergeIndicators']};"
                f"within={metric['withinMeetingFalseMergeIndicators']};"
                f"cross={metric['crossMeetingFalseMergeIndicators']}"
            ),
            f"logs/{log_name}.log",
            decision,
            "; ".join(reasons) if reasons else group_for(config_id, grid_groups),
        )
        lines.append("\t".join(row))
        attempt += 1
    path.write_text("\n".join(lines) + "\n")


def write_resume(state: pathlib.Path, status: str, best: str, next_action: str) -> None:
    (state / "resume.md").write_text(
        "# Autoeval Resume: Transcripted speaker identification\n\n"
        f"- Status: {status}\n"
        f"- Current best: `{best}`\n"
        "- Frozen evaluator: chronological ASK/SUGGEST/AUTO replay through production matching\n"
        "- Frozen data: SHA-256 manifest plus identity-level train/dev/holdout split\n"
        "- Hard rule: no false-auto, open-set false-auto, within-meeting merge, cross-meeting merge, or contamination regression\n"
        f"- Next action: {next_action}\n"
    )


def write_final_report(
    state: pathlib.Path,
    dev_reports: dict[str, dict[str, Any]],
    holdout_reports: dict[str, dict[str, Any]],
) -> list[dict[str, Any]]:
    baseline_dev = dev_reports[BASELINE["id"]]
    baseline_holdout = holdout_reports[BASELINE["id"]]
    promoted: list[dict[str, Any]] = []
    rows: list[str] = []
    for config_id, holdout in holdout_reports.items():
        if config_id == BASELINE["id"]:
            continue
        safe, reasons = no_safety_regression(holdout, baseline_holdout)
        dev = dev_reports[config_id]
        passes = safe and meaningful(holdout, baseline_holdout) and meaningful(dev, baseline_dev)
        if passes:
            promoted.append(holdout)
        hm = holdout["metrics"]
        rows.append(
            f"| `{config_id}` | {'PROMOTE' if passes else 'REJECT'} | {hm['repeatPrompts']} | "
            f"{hm['automaticNames']} | {hm['falseAutomaticNames']} | {hm['falseMergeIndicators']} | "
            f"{'; '.join(reasons) if reasons else 'none'} |"
        )
    rows.sort()
    bm = baseline_holdout["metrics"]
    lines = [
        "# Speaker identification auto-research report",
        "",
        "The evaluator replays real cached WeSpeaker fingerprints chronologically. Ground truth is used only to simulate the user's answer after a prompt and to score predictions.",
        "",
        "## Frozen holdout baseline",
        "",
        f"- Repeat prompts: **{bm['repeatPrompts']}**",
        f"- Automatic names: **{bm['automaticNames']}**",
        f"- False automatic names: **{bm['falseAutomaticNames']}** scorable / **{bm['falseAutomaticNamesAllPurities']}** all purities",
        (
            f"- False-merge indicators: **{bm['falseMergeIndicators']}** total "
            f"(**{bm['withinMeetingFalseMergeIndicators']}** within meeting / "
            f"**{bm['crossMeetingFalseMergeIndicators']}** across meetings)"
        ),
        "",
        "## Finalists",
        "",
        "| config | verdict | repeat prompts | autos | false autos | false merges | failed guardrails |",
        "|---|---:|---:|---:|---:|---:|---|",
        *rows,
        "",
        "A promotion requires a dev and holdout utility win plus no safety regression overall or in any frozen condition slice. Zero observed false autos is accompanied by the report's 3/N upper bound; it is not claimed as zero real-world risk.",
        "",
    ]
    (state / "final-report.md").write_text("\n".join(lines))
    return promoted


def load_discovery_state(
    state: pathlib.Path,
    runtime: dict[str, Any],
    top_k: int,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    """Load the locked finalists and their dev reports without rerunning discovery."""
    finalist_path = state / "checkpoints" / "holdout-finalists.json"
    if not finalist_path.is_file():
        raise SystemExit(
            f"validation requires completed discovery: missing {finalist_path}"
        )
    try:
        locked = json.loads(finalist_path.read_text())
        saved_identity = json.loads(
            (state / "checkpoints" / "holdout-finalists-identity.json").read_text()
        )
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"cannot read locked finalists {finalist_path}: {error}") from error
    expected_finalist_identity = {
        **runtime,
        "topK": top_k,
        "finalistsSHA256": file_sha256(finalist_path),
    }
    if saved_identity != expected_finalist_identity:
        raise SystemExit(
            "locked finalists are stale for the current manifest, evaluator, binary, runner, input root, or top-k"
        )
    if not isinstance(locked, list) or not locked:
        raise SystemExit(f"locked finalists must be a non-empty config list: {finalist_path}")
    configs_by_id = {
        item.get("id"): item for item in locked
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    if len(configs_by_id) != len(locked):
        raise SystemExit("locked finalists contain malformed or duplicate config ids")
    if configs_by_id.get(BASELINE["id"]) != BASELINE:
        raise SystemExit("locked finalists do not contain the exact production baseline")
    finalists = [
        item for item in locked
        if isinstance(item, dict) and item.get("id") != BASELINE["id"]
    ]

    all_dev: dict[str, dict[str, Any]] = {}
    for name in ("baseline-dev", "one-knob-dev", "guarded-maturity-dev", "interaction-dev"):
        path = state / "results" / f"{name}.json"
        if path.is_file():
            require_checkpoint_identity(
                result_path=path,
                identity_path=state / "checkpoints" / f"{name}-identity.json",
                runtime=runtime,
                split="dev",
            )
            all_dev.update(load_reports(path))
    required_ids = {BASELINE["id"]}
    required_ids.update(item["id"] for item in finalists)
    missing = sorted(required_ids - all_dev.keys())
    if missing:
        raise SystemExit(
            "validation requires completed dev reports for: " + ", ".join(missing)
        )
    return finalists, all_dev


def run_holdout_validation(
    *,
    root: pathlib.Path,
    binary: pathlib.Path,
    manifest: pathlib.Path,
    input_root: pathlib.Path,
    state: pathlib.Path,
    finalists: list[dict[str, Any]],
    dev_reports: dict[str, dict[str, Any]],
    grid_groups: dict[str, str],
    resume: bool,
    runtime: dict[str, Any],
) -> int:
    """Run only the locked holdout checkpoint and write the final decision."""
    holdout_configs = [copy.deepcopy(BASELINE), *finalists]
    run_name = "finalists-holdout" if finalists else "baseline-holdout"
    holdout_path = run_eval(
        root=root,
        binary=binary,
        manifest=manifest,
        input_root=input_root,
        state=state,
        name=run_name,
        split="holdout",
        configs=holdout_configs,
        resume=resume,
        runtime=runtime,
    )
    holdout = load_reports(holdout_path)
    append_ledger(
        state,
        run_name,
        holdout,
        holdout[BASELINE["id"]],
        grid_groups,
        run_name,
    )
    promoted = write_final_report(state, dev_reports, holdout)
    write_resume(
        state,
        "complete",
        promoted[0]["config"]["id"] if promoted else BASELINE["id"],
        "implement and verify the promoted operating point"
        if promoted else "keep production baseline; gather stronger data before another sweep",
    )
    print("AUTO_RESEARCH promoted=" + (
        ",".join(item["config"]["id"] for item in promoted) or "none"
    ))
    return 0


def main() -> int:
    args = parse_args()
    root = repo_root()
    manifest = args.manifest.resolve()
    input_root = args.input_root.resolve()
    state = args.state_dir.resolve()
    for directory in (state / "logs", state / "results", state / "checkpoints"):
        directory.mkdir(parents=True, exist_ok=True)

    count = verify_manifest(manifest, input_root)
    print(f"AUTO_RESEARCH manifest verified: {count} fingerprint caches")
    binary = root / "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
    if not args.skip_build:
        binary = build_harness(root)
    elif not binary.is_file():
        raise SystemExit(f"--skip-build requested but binary is missing: {binary}")
    else:
        require_current_binary_source(root, binary)
    run_identity = runtime_identity(
        root=root,
        binary=binary,
        manifest=manifest,
        input_root=input_root,
    )

    grid = one_knob_grid()
    guarded = [("baseline", copy.deepcopy(BASELINE)), *guarded_maturity_grid()]
    grid_groups = {item["id"]: group for group, item in [*grid, *guarded]}
    write_json(state / "checkpoints" / "one-knob-grid.json", [item for _, item in grid])
    write_json(state / "checkpoints" / "guarded-maturity-grid.json", [item for _, item in guarded])
    write_json(state / "checkpoints" / "config-groups.json", grid_groups)
    if args.phase == "prepare":
        write_resume(state, "prepared", BASELINE["id"], "run --phase discover")
        return 0

    resume = not args.no_resume
    if args.phase == "validate":
        finalists, all_dev = load_discovery_state(state, run_identity, args.top_k)
        return run_holdout_validation(
            root=root,
            binary=binary,
            manifest=manifest,
            input_root=input_root,
            state=state,
            finalists=finalists,
            dev_reports=all_dev,
            grid_groups=grid_groups,
            resume=resume,
            runtime=run_identity,
        )

    baseline_configs = [copy.deepcopy(BASELINE)]
    baseline_train_path = run_eval(
        root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
        name="baseline-train", split="train", configs=baseline_configs, resume=resume,
        runtime=run_identity,
    )
    baseline_dev_path = run_eval(
        root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
        name="baseline-dev", split="dev", configs=baseline_configs, resume=resume,
        runtime=run_identity,
    )
    baseline_train = load_reports(baseline_train_path)
    baseline_dev = load_reports(baseline_dev_path)
    append_ledger(state, "baseline-train", baseline_train, baseline_train[BASELINE["id"]], grid_groups, "baseline-train")
    append_ledger(state, "baseline-dev", baseline_dev, baseline_dev[BASELINE["id"]], grid_groups, "baseline-dev")

    grid_configs = [item for _, item in grid]
    grid_train_path = run_eval(
        root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
        name="one-knob-train", split="train", configs=grid_configs, resume=resume,
        runtime=run_identity,
    )
    grid_dev_path = run_eval(
        root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
        name="one-knob-dev", split="dev", configs=grid_configs, resume=resume,
        runtime=run_identity,
    )
    grid_train = load_reports(grid_train_path)
    grid_dev = load_reports(grid_dev_path)
    append_ledger(state, "one-knob-train", grid_train, grid_train[BASELINE["id"]], grid_groups, "one-knob-train")
    append_ledger(state, "one-knob-dev", grid_dev, grid_dev[BASELINE["id"]], grid_groups, "one-knob-dev")

    guarded_configs = [item for _, item in guarded]
    guarded_train_path = run_eval(
        root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
        name="guarded-maturity-train", split="train", configs=guarded_configs, resume=resume,
        runtime=run_identity,
    )
    guarded_dev_path = run_eval(
        root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
        name="guarded-maturity-dev", split="dev", configs=guarded_configs, resume=resume,
        runtime=run_identity,
    )
    guarded_train = load_reports(guarded_train_path)
    guarded_dev = load_reports(guarded_dev_path)
    append_ledger(state, "guarded-maturity-train", guarded_train, guarded_train[BASELINE["id"]], grid_groups, "guarded-maturity-train")
    append_ledger(state, "guarded-maturity-dev", guarded_dev, guarded_dev[BASELINE["id"]], grid_groups, "guarded-maturity-dev")

    interactions = bounded_interactions(grid_dev, grid_groups)
    interaction_train: dict[str, dict[str, Any]] = {}
    interaction_dev: dict[str, dict[str, Any]] = {}
    if interactions:
        interaction_train_path = run_eval(
            root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
            name="interaction-train", split="train", configs=interactions, resume=resume,
            runtime=run_identity,
        )
        interaction_path = run_eval(
            root=root, binary=binary, manifest=manifest, input_root=input_root, state=state,
            name="interaction-dev", split="dev", configs=interactions, resume=resume,
            runtime=run_identity,
        )
        interaction_train = load_reports(interaction_train_path)
        interaction_dev = load_reports(interaction_path)
        append_ledger(state, "interaction-train", interaction_train, grid_train[BASELINE["id"]], grid_groups, "interaction-train")
        append_ledger(state, "interaction-dev", interaction_dev, grid_dev[BASELINE["id"]], grid_groups, "interaction-dev")

    all_train = {**grid_train, **guarded_train, **interaction_train}
    all_dev = {**grid_dev, **guarded_dev, **interaction_dev}
    ranked = rank_safe(all_dev.values(), grid_dev[BASELINE["id"]])
    finalists: list[dict[str, Any]] = []
    for report, _ in ranked:
        config_id = report["config"]["id"]
        if config_id == BASELINE["id"] or not meaningful(report, grid_dev[BASELINE["id"]]):
            continue
        train_report = all_train.get(config_id)
        if train_report is None:
            continue
        train_safe, _ = no_safety_regression(train_report, grid_train[BASELINE["id"]])
        if not train_safe or train_report["metrics"]["repeatPrompts"] > grid_train[BASELINE["id"]]["metrics"]["repeatPrompts"]:
            continue
        finalists.append(report["config"])
        if len(finalists) >= args.top_k:
            break
    finalist_path = state / "checkpoints" / "holdout-finalists.json"
    write_json(finalist_path, [BASELINE, *finalists])
    write_json(
        state / "checkpoints" / "holdout-finalists-identity.json",
        {
            **run_identity,
            "topK": args.top_k,
            "finalistsSHA256": file_sha256(finalist_path),
        },
    )
    write_resume(
        state,
        "discovery complete" if finalists else "discovery complete; no qualifying finalist",
        finalists[0]["id"] if finalists else BASELINE["id"],
        "run locked holdout validation" if finalists else "inspect rejected attempts; do not weaken guardrails",
    )
    if args.phase == "discover":
        return 0
    return run_holdout_validation(
        root=root,
        binary=binary,
        manifest=manifest,
        input_root=input_root,
        state=state,
        finalists=finalists,
        dev_reports=all_dev,
        grid_groups=grid_groups,
        resume=resume,
        runtime=run_identity,
    )


if __name__ == "__main__":
    raise SystemExit(main())
