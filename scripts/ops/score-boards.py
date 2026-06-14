#!/usr/bin/env python3
"""Aggregate Transcripted QA evidence into a per-board accuracy scorecard.

This is the roll-up layer. It does not test the app itself — it reads the JSON
that the existing tools already emit and turns it into one 0-100 score per board
plus an overall verdict:

  ui          transcripted-qa ui-smoke --format json
  functional  transcripted-qa validate-all --format json
  accuracy    score-<input>.json written by the scorer scripts in this folder

Run it after those tools have produced their JSON. Missing evidence is reported
as INCOMPLETE per board, never silently passed. Privacy: this reads only check
names, statuses, and numeric scores — it never copies transcript text, speaker
names, or paths into the report.

Example:

  python3 scripts/ops/score-boards.py \
    --registry .agents/board-scorecard.yml \
    --ui-json /tmp/qa/raw/ui-smoke.json \
    --functional-json /tmp/qa/raw/validate-all.json \
    --accuracy-dir /tmp/qa/raw \
    --json-out /tmp/qa/board-scorecard.json \
    --markdown-out /tmp/qa/board-scorecard.md
"""

from __future__ import annotations

import argparse
import ast
import fnmatch
import json
import sys
from pathlib import Path
from typing import Any, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from score_boards_lib import (  # noqa: E402
    STATUS_GREEN,
    STATUS_INCOMPLETE,
    STATUS_RED,
    STATUS_YELLOW,
    BoardScore,
    DimensionScore,
    checks_to_dimension_score,
    finalize_board,
    overall_score,
    overall_status,
    status_rank,
)


def strip_yaml_comment(line: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    for idx, ch in enumerate(line):
        if ch == "\\" and in_double and not escaped:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single and not escaped:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return line[:idx]
        escaped = False
    return line


def parse_yaml_scalar(value: str) -> Any:
    value = value.strip()
    if value == "":
        return ""
    if value.startswith("[") and value.endswith("]"):
        try:
            parsed = ast.literal_eval(value)
        except (SyntaxError, ValueError):
            inner = value[1:-1].strip()
            return [] if not inner else [parse_yaml_scalar(part.strip()) for part in inner.split(",")]
        if not isinstance(parsed, list):
            raise ValueError(f"expected inline list in registry, got {type(parsed).__name__}")
        return parsed
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return ast.literal_eval(value)
    if value in ("true", "false"):
        return value == "true"
    if value in ("null", "~"):
        return None
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        return value


def split_yaml_key_value(text: str) -> tuple[str, str]:
    if ":" not in text:
        raise ValueError(f"invalid registry line: {text}")
    key, value = text.split(":", 1)
    return key.strip(), value.strip()


def tokenize_registry(text: str) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    for raw in text.splitlines():
        without_comment = strip_yaml_comment(raw).rstrip()
        if not without_comment.strip():
            continue
        rows.append((len(without_comment) - len(without_comment.lstrip(" ")), without_comment.strip()))
    return rows


def parse_yaml_mapping(rows: list[tuple[int, str]], index: int, indent: int) -> tuple[dict[str, Any], int]:
    result: dict[str, Any] = {}
    while index < len(rows):
        row_indent, text = rows[index]
        if row_indent < indent:
            break
        if row_indent > indent:
            raise ValueError(f"unexpected indentation in registry near: {text}")
        if text.startswith("- "):
            break
        key, value = split_yaml_key_value(text)
        index += 1
        if value:
            result[key] = parse_yaml_scalar(value)
        elif index < len(rows) and rows[index][0] > row_indent:
            result[key], index = parse_yaml_block(rows, index, rows[index][0])
        else:
            result[key] = {}
    return result, index


def parse_yaml_list(rows: list[tuple[int, str]], index: int, indent: int) -> tuple[list[Any], int]:
    result: list[Any] = []
    while index < len(rows):
        row_indent, text = rows[index]
        if row_indent < indent:
            break
        if row_indent != indent or not text.startswith("- "):
            break
        item_text = text[2:].strip()
        index += 1
        if not item_text:
            if index >= len(rows) or rows[index][0] <= row_indent:
                raise ValueError("empty list item in registry")
            item, index = parse_yaml_block(rows, index, rows[index][0])
        elif ":" in item_text:
            key, value = split_yaml_key_value(item_text)
            if value:
                item = {key: parse_yaml_scalar(value)}
            elif index < len(rows) and rows[index][0] > row_indent:
                child, index = parse_yaml_block(rows, index, rows[index][0])
                item = {key: child}
            else:
                item = {key: {}}
            if index < len(rows) and rows[index][0] > row_indent:
                extra, index = parse_yaml_mapping(rows, index, rows[index][0])
                item.update(extra)
        else:
            item = parse_yaml_scalar(item_text)
        result.append(item)
    return result, index


def parse_yaml_block(rows: list[tuple[int, str]], index: int, indent: int) -> tuple[Any, int]:
    if index >= len(rows):
        return {}, index
    if rows[index][1].startswith("- "):
        return parse_yaml_list(rows, index, indent)
    return parse_yaml_mapping(rows, index, indent)


def load_registry(path: Path) -> dict[str, Any]:
    rows = tokenize_registry(path.read_text(encoding="utf-8"))
    data, index = parse_yaml_block(rows, 0, 0)
    if index != len(rows):
        raise ValueError(f"registry {path} has trailing unparsed rows")
    if not isinstance(data, dict) or "boards" not in data:
        raise ValueError(f"registry {path} has no 'boards' list")
    return data


def normalize_status(value: Any) -> str:
    status = str(value or "FAIL").upper()
    if status == "INCOMPLETE":
        return "WARN"
    if status in ("SKIP", "SKIPPED", "N/A", "NA"):
        return "WARN"
    if status not in ("PASS", "WARN", "FAIL"):
        return "WARN"
    return status


def load_report_results(path: Optional[Path]) -> Optional[list[dict[str, Any]]]:
    """Load check rows from ValidationReport or ui-smoke JSON, or None if absent."""
    if path is None:
        return None
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        raise ValueError(f"report {path} is not valid JSON") from exc
    rows = payload.get("results")
    if not isinstance(rows, list):
        rows = payload.get("checks")
    if not isinstance(rows, list):
        return []
    normalized = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        normalized.append({
            "check": str(row.get("check") or row.get("id") or ""),
            "target": str(row.get("target", "")),
            "status": normalize_status(row.get("status")),
        })
    return normalized


def match_check_statuses(
    results: Optional[list[dict[str, Any]]],
    globs: list[str],
) -> Optional[list[str]]:
    """Statuses of rows whose check (or target) matches any glob.

    Returns None when no report was supplied at all (so the dimension is
    INCOMPLETE for lack of a run), and a possibly-empty list when a report was
    supplied (an empty list still means INCOMPLETE, but for lack of coverage).
    """
    if results is None:
        return None
    matched: list[str] = []
    for row in results:
        check = str(row.get("check", ""))
        target = str(row.get("target", ""))
        if any(fnmatch.fnmatch(check, g) or fnmatch.fnmatch(target, g) for g in globs):
            matched.append(str(row.get("status", "FAIL")))
    return matched


def load_accuracy_input(accuracy_dir: Optional[Path], input_name: str) -> DimensionScore:
    if accuracy_dir is None:
        return DimensionScore.missing("accuracy", detail=f"no accuracy dir for '{input_name}'")
    path = accuracy_dir / f"score-{input_name}.json"
    if not path.is_file():
        return DimensionScore.missing("accuracy", detail=f"missing {path.name}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return DimensionScore.missing("accuracy", detail=f"invalid {path.name}")
    if not payload.get("present", True):
        return DimensionScore.missing("accuracy", detail=payload.get("detail", "scorer reported no evidence"))
    score = payload.get("score")
    if score is None:
        return DimensionScore.missing("accuracy", detail="scorer produced no score")
    try:
        numeric_score = float(score)
    except (TypeError, ValueError):
        return DimensionScore.missing("accuracy", detail=f"invalid score in {path.name}")
    return DimensionScore.scored("accuracy", numeric_score, detail=payload.get("detail", input_name))


def build_dimension(
    dim_name: str,
    config: Any,
    ui_results: Optional[list[dict[str, Any]]],
    functional_results: Optional[list[dict[str, Any]]],
    accuracy_dir: Optional[Path],
) -> DimensionScore:
    if dim_name == "accuracy":
        if not isinstance(config, dict):
            return DimensionScore.missing("accuracy", detail="invalid accuracy config")
        return load_accuracy_input(accuracy_dir, str(config.get("input", "")))
    results = ui_results if dim_name == "ui" else functional_results
    globs = config.get("check_globs", []) if isinstance(config, dict) else []
    statuses = match_check_statuses(results, globs)
    if statuses is None:
        label = "ui-smoke" if dim_name == "ui" else "validate-all"
        return DimensionScore.missing(dim_name, detail=f"no {label} run supplied")
    return checks_to_dimension_score(dim_name, statuses)


def score_boards(
    registry: dict[str, Any],
    ui_results: Optional[list[dict[str, Any]]],
    functional_results: Optional[list[dict[str, Any]]],
    accuracy_dir: Optional[Path],
) -> list[BoardScore]:
    defaults = registry.get("defaults", {})
    default_weights = defaults.get("weights", {})
    thresholds = defaults.get("thresholds", {})
    green = float(thresholds.get("green", 85))
    yellow = float(thresholds.get("yellow", 65))

    boards: list[BoardScore] = []
    for entry in registry.get("boards", []):
        weights = dict(default_weights)
        weights.update(entry.get("weights", {}) or {})

        dims: list[DimensionScore] = []
        for dim_name in ("ui", "functional", "accuracy"):
            if dim_name in entry:
                dims.append(
                    build_dimension(dim_name, entry[dim_name], ui_results, functional_results, accuracy_dir)
                )

        board = BoardScore(
            board_id=str(entry["id"]),
            name=str(entry.get("name", entry["id"])),
            category=str(entry.get("category", "")),
            automatable=str(entry.get("automatable", "auto")),
            weight=float(entry.get("weight", 1.0)),
            dimensions=dims,
        )
        boards.append(finalize_board(board, weights, green, yellow))
    return boards


def fmt_score(score: Optional[float]) -> str:
    return "n/a" if score is None else f"{score:.0f}"


def fmt_dims(board: BoardScore) -> str:
    parts = []
    for dim in board.dimensions:
        parts.append(f"{dim.name[:4]}={fmt_score(dim.score)}")
    return " ".join(parts) if parts else "—"


def short_summary(boards: list[BoardScore]) -> str:
    auto = [b for b in boards if b.automatable == "auto"]
    overall = overall_score(auto)
    status = overall_status(boards)
    reds = [b for b in auto if b.status == STATUS_RED]
    incompletes = [b for b in auto if b.status == STATUS_INCOMPLETE]
    score_txt = fmt_score(overall)
    if status == STATUS_GREEN:
        return f"GREEN: auto-board score {score_txt}/100. All {len(auto)} auto boards passing."
    if status == STATUS_RED:
        return f"RED: auto-board score {score_txt}/100. {len(reds)} board(s) below bar: {', '.join(b.board_id for b in reds)}."
    if status == STATUS_YELLOW:
        return f"YELLOW: auto-board score {score_txt}/100. Some boards in the warn band."
    return f"INCOMPLETE: auto-board score {score_txt}/100. {len(incompletes)} board(s) without evidence."


def write_markdown(path: Path, boards: list[BoardScore]) -> None:
    auto = [b for b in boards if b.automatable == "auto"]
    overall = overall_score(auto)
    status = overall_status(boards)

    lines = [
        "# Transcripted Board Scorecard",
        "",
        "## Short Answer",
        "",
        short_summary(boards),
        "",
        f"- Overall verdict: {status}",
        f"- Auto-board score: {fmt_score(overall)}/100",
        f"- Boards: {len(boards)} ({len(auto)} auto, "
        f"{sum(1 for b in boards if b.automatable == 'hardware')} hardware, "
        f"{sum(1 for b in boards if b.automatable == 'human')} human)",
        "",
        "Scores blend reachable-UI, functional-artifact, and ground-truth-accuracy",
        "evidence. A dimension with no evidence is INCOMPLETE, not a pass. No",
        "transcript text, speaker names, or paths appear in this report.",
        "",
        "## Boards",
        "",
        "| Board | Category | Mode | Score | Status | Dimensions |",
        "| --- | --- | --- | ---: | --- | --- |",
    ]

    ordered = sorted(boards, key=lambda b: (status_rank(b.status), -(b.score if b.score is not None else -1), b.board_id))
    for board in ordered:
        lines.append(
            f"| `{board.board_id}` | {board.category} | {board.automatable} | "
            f"{fmt_score(board.score)} | {board.status} | {fmt_dims(board)} |"
        )

    flagged = [b for b in boards if b.status in (STATUS_RED, STATUS_YELLOW)]
    incomplete_auto = [b for b in boards if b.automatable == "auto" and b.status == STATUS_INCOMPLETE]
    lines += ["", "## Flags", ""]
    if not flagged:
        lines.append("No boards below the pass bar.")
    for board in flagged:
        worst = ", ".join(
            f"{d.name}={fmt_score(d.score)} ({d.detail})"
            for d in board.dimensions
            if d.present and (d.score if d.score is not None else 100) < 85
        )
        lines.append(f"- {board.status} `{board.board_id}` ({fmt_score(board.score)}): {worst or board.detail}")

    if incomplete_auto:
        lines += ["", "## Incomplete auto boards (no evidence yet)", ""]
        for board in incomplete_auto:
            lines.append(f"- `{board.board_id}`: {board.detail}")

    needs_other = [b for b in boards if b.automatable in ("hardware", "human")]
    if needs_other:
        lines += ["", "## Needs hardware / human", ""]
        for board in needs_other:
            lines.append(f"- `{board.board_id}` ({board.automatable}): not auto-scorable; route to the manual packet")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_payload(boards: list[BoardScore]) -> dict[str, Any]:
    auto = [b for b in boards if b.automatable == "auto"]
    return {
        "overallStatus": overall_status(boards),
        "autoBoardScore": overall_score(auto),
        "boardCount": len(boards),
        "boards": [
            {
                "id": b.board_id,
                "name": b.name,
                "category": b.category,
                "automatable": b.automatable,
                "weight": b.weight,
                "score": b.score,
                "status": b.status,
                "detail": b.detail,
                "dimensions": [
                    {"name": d.name, "present": d.present, "score": d.score, "detail": d.detail}
                    for d in b.dimensions
                ],
            }
            for b in boards
        ],
    }


def exit_code_for(boards: list[BoardScore]) -> int:
    status = overall_status(boards)
    if status == STATUS_RED:
        return 1
    if status in (STATUS_YELLOW, STATUS_INCOMPLETE):
        return 3
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--registry", default=".agents/board-scorecard.yml")
    parser.add_argument("--ui-json", default="", help="ValidationReport JSON from `transcripted-qa ui-smoke`.")
    parser.add_argument("--functional-json", default="", help="ValidationReport JSON from `transcripted-qa validate-all`.")
    parser.add_argument("--accuracy-dir", default="", help="Directory holding score-<input>.json files from the scorers.")
    parser.add_argument("--json-out", required=True)
    parser.add_argument("--markdown-out", required=True)
    args = parser.parse_args()

    registry = load_registry(Path(args.registry).expanduser())
    ui_results = load_report_results(Path(args.ui_json).expanduser() if args.ui_json else None)
    functional_results = load_report_results(Path(args.functional_json).expanduser() if args.functional_json else None)
    accuracy_dir = Path(args.accuracy_dir).expanduser() if args.accuracy_dir else None

    boards = score_boards(registry, ui_results, functional_results, accuracy_dir)

    json_path = Path(args.json_out)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(build_payload(boards), indent=2, sort_keys=True), encoding="utf-8")
    write_markdown(Path(args.markdown_out), boards)

    print(short_summary(boards))
    print(f"Report: {args.markdown_out}")
    return exit_code_for(boards)


if __name__ == "__main__":
    raise SystemExit(main())
