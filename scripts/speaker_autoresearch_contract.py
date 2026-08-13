"""Parameter grids, promotion guardrails, and reports for speaker auto-research."""

from __future__ import annotations

import copy
import json
import pathlib
from typing import Any, Iterable

EVALUATOR_SCHEMA_VERSION = 3

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
    "wrongSuggestions",
    "openSetWrongSuggestions",
    "falseMergeIndicators",
    "withinMeetingFalseMergeIndicators",
    "crossMeetingFalseMergeIndicators",
    "contaminatedProfiles",
)

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
        if candidate_slice["automaticNames"] < baseline_slice["automaticNames"]:
            reasons.append(
                f"{slice_name}:automaticNames {candidate_slice['automaticNames']}"
                f"<{baseline_slice['automaticNames']} coverage floor"
            )
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
        "- Hard rule: no false-auto, wrong-suggestion, open-set, merge, or contamination regression overall or in a fixed condition bucket\n"
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
