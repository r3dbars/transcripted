#!/usr/bin/env python3
"""Karpathy-style autoresearch loop for Transcripted speaker learning.

This does not upload data or print transcript text. It repeatedly runs the
local speaker-learning eval, scores candidate routes, and keeps a compact log
of what improved.
"""

from __future__ import annotations

import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from speaker_learning_eval import DEFAULT_CORPUS, evaluate_audio_corpus, evaluate_corpus, write_report


DEFAULT_OUTPUT_DIR = Path(".transcripted-speaker-eval/autoresearch")
WRONG_NAME_PENALTY = 1_000_000.0


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def candidate_routes(report: dict[str, Any]) -> list[dict[str, Any]]:
    """Extract comparable product routes from a speaker-learning report."""

    routes: list[dict[str, Any]] = []

    add_policy_route(
        routes,
        route="current_product_gate",
        kind="auto_naming_policy",
        source="auto_recognition_experiment.current_product_gate_projection",
        policy=report.get("auto_recognition_experiment", {}).get("current_product_gate_projection"),
        next_action="Keep as the safety floor unless another route beats it with zero wrong names.",
    )
    add_policy_route(
        routes,
        route="clean_folders_current_gate",
        kind="auto_naming_policy",
        source="auto_recognition_after_oracle_merge_experiment.current_product_gate_projection",
        policy=report.get("auto_recognition_after_oracle_merge_experiment", {}).get(
            "current_product_gate_projection"
        ),
        next_action="Ship only after the duplicate review UX makes these merges user-confirmed.",
    )

    quality_sections = [
        (
            "raw_quality_knobs",
            report.get("auto_recognition_quality_knob_experiment", {}),
            "Use as eval guidance only; raw folders can be messy.",
        ),
        (
            "clean_folders_quality_knobs",
            report.get("auto_recognition_quality_after_oracle_merge_knob_experiment", {}),
            "Most promising tuning lane after confirmed duplicate cleanup.",
        ),
    ]
    for lane, section, next_action in quality_sections:
        for goal, policy in section.get("best_zero_false_by_goal", {}).items():
            add_policy_route(
                routes,
                route=f"{lane}.{goal}",
                kind="auto_naming_policy",
                source=f"{lane}.best_zero_false_by_goal.{goal}",
                policy=policy,
                next_action=next_action,
            )

    duplicate_review = report.get("duplicate_merge_review", {})
    for strategy in duplicate_review.get("strategy_experiment", {}).get("best_zero_wrong_strategies", []):
        if not isinstance(strategy, dict):
            continue
        routes.append(
            {
                "route": f"duplicate_review.{strategy.get('strategy', 'unknown')}",
                "kind": "duplicate_review_strategy",
                "source": "duplicate_merge_review.strategy_experiment.best_zero_wrong_strategies",
                "metrics": {
                    "correct_duplicate_candidates": int(strategy.get("correct_candidates") or 0),
                    "wrong_duplicate_candidates": int(strategy.get("wrong_candidates") or 0),
                    "projected_duplicate_reduction_upper_bound": int(
                        strategy.get("projected_duplicate_reduction_upper_bound") or 0
                    ),
                    "precision": strategy.get("precision"),
                },
                "next_action": "Turn this into a user-confirmed duplicate-review queue, not silent merging.",
            }
        )

    if not routes and isinstance(report.get("summary"), dict):
        summary = report["summary"]
        routes.append(
            {
                "route": "baseline_label_carry_forward_scoreboard",
                "kind": "baseline_scoreboard",
                "source": "summary",
                "metrics": {
                    "correct_automatic_matches": int(summary.get("correct_automatic_matches") or 0),
                    "false_automatic_matches": int(
                        summary.get("false_automatic_matches", summary.get("false_matches", 0)) or 0
                    ),
                    "confirmation_labels_avoided": int(summary.get("correct_automatic_matches") or 0),
                },
                "next_action": "Use this as a parser and corpus sanity check before trusting audio-backed runs.",
            }
        )

    return routes


def add_policy_route(
    routes: list[dict[str, Any]],
    route: str,
    kind: str,
    source: str,
    policy: dict[str, Any] | None,
    next_action: str,
) -> None:
    if not isinstance(policy, dict):
        return
    routes.append(
        {
            "route": route,
            "kind": kind,
            "source": source,
            "metrics": compact_policy_metrics(policy),
            "next_action": next_action,
        }
    )


def compact_policy_metrics(policy: dict[str, Any]) -> dict[str, Any]:
    keys = [
        "policy",
        "automatic_matches_total",
        "correct_automatic_matches",
        "false_automatic_matches",
        "precision",
        "confirmation_labels_avoided",
        "recognized_recurring_speakers",
        "median_meetings_after_first_seen",
        "minimum_total_observations",
        "minimum_prior_meetings",
        "minimum_similarity",
        "minimum_similarity_separation",
        "minimum_speaker_duration_seconds",
        "minimum_embedding_count",
        "channel_mode",
    ]
    return {key: policy.get(key) for key in keys if key in policy}


def score_route(route: dict[str, Any], max_false_names: int = 0) -> dict[str, Any]:
    metrics = route.get("metrics", {})
    wrong_names = number(metrics, "false_automatic_matches")
    wrong_duplicates = number(metrics, "wrong_duplicate_candidates")
    wrong_total = wrong_names + wrong_duplicates

    correct_names = number(metrics, "correct_automatic_matches")
    recurring = number(metrics, "recognized_recurring_speakers")
    avoided = number(metrics, "confirmation_labels_avoided")
    duplicate_reduction = number(metrics, "projected_duplicate_reduction_upper_bound")
    duplicate_correct = number(metrics, "correct_duplicate_candidates")
    median_gap = metrics.get("median_meetings_after_first_seen")

    score = (
        correct_names * 100.0
        + recurring * 40.0
        + avoided * 8.0
        + duplicate_reduction * 25.0
        + duplicate_correct * 5.0
    )
    if isinstance(median_gap, (int, float)):
        score -= float(median_gap) * 3.0
    if wrong_total > max_false_names:
        score -= WRONG_NAME_PENALTY + (wrong_total * 10_000.0)

    return {
        **route,
        "safe": wrong_total <= max_false_names,
        "wrong_total": wrong_total,
        "score": round(score, 3),
    }


def number(metrics: dict[str, Any], key: str) -> float:
    value = metrics.get(key)
    if isinstance(value, bool):
        return float(int(value))
    if isinstance(value, (int, float)):
        return float(value)
    return 0.0


def rank_routes(routes: list[dict[str, Any]], max_false_names: int = 0) -> list[dict[str, Any]]:
    scored = [score_route(route, max_false_names=max_false_names) for route in routes]
    return sorted(
        scored,
        key=lambda route: (
            not route["safe"],
            -route["score"],
            route["route"],
        ),
    )


def run_eval(args: argparse.Namespace) -> dict[str, Any]:
    if args.mode == "audio":
        return evaluate_audio_corpus(
            corpus_root=args.corpus.expanduser(),
            limit=args.limit,
            include_speaker_labels=args.include_speaker_labels,
            audio_cache_dir=args.audio_cache,
            diarizer_command=args.diarizer_command,
        )
    return evaluate_corpus(
        corpus_root=args.corpus.expanduser(),
        limit=args.limit,
        include_speaker_labels=args.include_speaker_labels,
    )


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_summary(path: Path, entry: dict[str, Any]) -> None:
    best = entry["best_route"]
    summary = entry["summary"]
    lines = [
        "# Speaker Autoresearch",
        "",
        f"- run: `{entry['run_id']}`",
        f"- mode: `{entry['mode']}`",
        f"- meetings: `{summary.get('meetings_evaluated')}`",
        f"- unknown labels: `{summary.get('unknown_labels_required')}`",
        f"- confirmations: `{summary.get('confirmation_labels_required', 0)}`",
        f"- correct auto names: `{summary.get('correct_automatic_matches')}`",
        f"- false names: `{summary.get('false_automatic_matches', summary.get('false_matches', 0))}`",
        f"- best route: `{best['route']}`",
        f"- best score: `{best['score']}`",
        f"- best route safe: `{best['safe']}`",
        "",
        "## Next Action",
        "",
        best["next_action"],
        "",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def should_replace_best(best_path: Path, candidate: dict[str, Any]) -> bool:
    if not best_path.exists():
        return True
    current = json.loads(best_path.read_text(encoding="utf-8"))
    current_best = current.get("best_route", {})
    candidate_best = candidate.get("best_route", {})
    return (
        bool(candidate_best.get("safe")),
        float(candidate_best.get("score", -WRONG_NAME_PENALTY)),
    ) > (
        bool(current_best.get("safe")),
        float(current_best.get("score", -WRONG_NAME_PENALTY)),
    )


def run_cycle(args: argparse.Namespace, cycle: int) -> dict[str, Any]:
    started = utc_now()
    run_id = f"{started.replace(':', '').replace('+0000', 'Z')}-cycle-{cycle:03d}"
    run_dir = args.output_dir / run_id
    report_path = run_dir / "report.json"
    started_time = time.perf_counter()
    report = run_eval(args)
    runtime_seconds = round(time.perf_counter() - started_time, 3)
    write_report(report, report_path)

    ranked = rank_routes(candidate_routes(report), max_false_names=args.max_false_names)
    best_route = ranked[0] if ranked else {
        "route": "no_candidate_routes",
        "safe": False,
        "score": -WRONG_NAME_PENALTY,
        "next_action": "Fix the eval report extraction before trusting results.",
    }

    entry = {
        "run_id": run_id,
        "started_at": started,
        "cycle": cycle,
        "mode": args.mode,
        "limit": args.limit,
        "runtime_seconds": runtime_seconds,
        "summary": report["summary"],
        "best_route": best_route,
        "top_routes": ranked[: args.top_routes],
        "report_path": str(report_path),
    }
    append_jsonl(args.output_dir / "experiments.jsonl", entry)
    write_json(run_dir / "result.json", entry)
    write_summary(run_dir / "summary.md", entry)
    best_path = args.output_dir / "best.json"
    if should_replace_best(best_path, entry):
        write_json(best_path, entry)
        write_summary(args.output_dir / "best.md", entry)
    return entry


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run a local autoresearch loop over Transcripted speaker-learning eval reports."
    )
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS, help="Path to meeting-corpus root.")
    parser.add_argument("--mode", choices=("baseline", "audio"), default="audio")
    parser.add_argument("--limit", type=int, help="Evaluate only the first N usable meetings.")
    parser.add_argument("--cycles", type=int, default=1, help="Number of eval cycles to run.")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--audio-cache",
        type=Path,
        default=Path(".transcripted-speaker-eval/audio-cache"),
        help="Local cache directory for audio-backed diarization JSON.",
    )
    parser.add_argument("--diarizer-command", help="Base command ending in `transcripted-cli diarize`.")
    parser.add_argument("--max-false-names", type=int, default=0, help="Hard safety budget for wrong names.")
    parser.add_argument("--top-routes", type=int, default=8, help="Top scored routes to keep per cycle.")
    parser.add_argument("--include-speaker-labels", action="store_true", help="Local debugging only.")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.cycles < 1:
        raise SystemExit("--cycles must be at least 1")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for cycle in range(1, args.cycles + 1):
        entry = run_cycle(args, cycle)
        best = entry["best_route"]
        print(
            "autoresearch cycle complete "
            f"cycle={cycle} mode={entry['mode']} limit={entry['limit']} "
            f"best={best['route']} score={best['score']} safe={best['safe']} "
            f"runtime_seconds={entry['runtime_seconds']} "
            f"result={args.output_dir / entry['run_id'] / 'result.json'}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
