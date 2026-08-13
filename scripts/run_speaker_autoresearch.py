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
import json
import pathlib
from typing import Any

from speaker_autoresearch_contract import (
    BASELINE,
    EVALUATOR_SCHEMA_VERSION,
    SAFETY_KEYS,
    append_ledger,
    bounded_interactions,
    config,
    group_for,
    guarded_maturity_grid,
    meaningful,
    no_safety_regression,
    one_knob_grid,
    rank_safe,
    write_final_report,
    write_resume,
)
from speaker_autoresearch_runtime import (
    binary_source_stamp,
    build_harness,
    checkpoint_identity,
    checkpoint_validation_error,
    evaluator_source_sha256,
    file_sha256,
    load_reports,
    report_configs,
    require_checkpoint_identity,
    require_current_binary_source,
    run_eval,
    runtime_identity,
    verify_manifest,
    write_json,
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
