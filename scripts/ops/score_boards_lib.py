"""Core scoring math for the Transcripted board scorecard.

Pure functions only — no I/O, no app, no network. This is the piece that turns
raw dimension evidence into per-board 0-100 scores and an overall roll-up, and it
is the piece that has real unit tests (see test-score-boards.py).

A "board" is one testable surface of the app (Dictation, Speakers, Summary, ...).
Each board scores on up to three dimensions:

  ui          did the surface render and respond (from ui-smoke evidence)
  functional  did the underlying flow produce valid artifacts (from validate-all)
  accuracy    where there is ground truth, how close was the output (from a scorer)

A dimension with no evidence is INCOMPLETE, not 0. We never turn "we didn't test
it" into a green or a red. Board score is the weighted mean over the dimensions
that actually have evidence, with weights renormalized over those present.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# Status tiers, worst-first so they sort/compare cleanly.
STATUS_RED = "RED"
STATUS_YELLOW = "YELLOW"
STATUS_GREEN = "GREEN"
STATUS_INCOMPLETE = "INCOMPLETE"

_STATUS_RANK = {STATUS_RED: 0, STATUS_INCOMPLETE: 1, STATUS_YELLOW: 2, STATUS_GREEN: 3}


def status_rank(status: str) -> int:
    return _STATUS_RANK.get(status, 1)


@dataclass
class DimensionScore:
    """One dimension's evidence for one board.

    score is 0-100 when present is True, otherwise None. present=False means we
    have no evidence and the dimension is INCOMPLETE.
    """

    name: str
    present: bool
    score: Optional[float] = None
    detail: str = ""

    @staticmethod
    def missing(name: str, detail: str = "no evidence") -> "DimensionScore":
        return DimensionScore(name=name, present=False, score=None, detail=detail)

    @staticmethod
    def scored(name: str, score: float, detail: str = "") -> "DimensionScore":
        return DimensionScore(name=name, present=True, score=clamp_score(score), detail=detail)


@dataclass
class BoardScore:
    board_id: str
    name: str
    category: str
    automatable: str  # auto | hardware | human
    weight: float
    dimensions: list[DimensionScore] = field(default_factory=list)
    score: Optional[float] = None
    status: str = STATUS_INCOMPLETE
    detail: str = ""


def clamp_score(value: float) -> float:
    if value < 0.0:
        return 0.0
    if value > 100.0:
        return 100.0
    return float(value)


def status_for_score(
    score: Optional[float],
    green_threshold: float,
    yellow_threshold: float,
) -> str:
    """Map a 0-100 board score to a tier. None -> INCOMPLETE."""
    if score is None:
        return STATUS_INCOMPLETE
    if score >= green_threshold:
        return STATUS_GREEN
    if score >= yellow_threshold:
        return STATUS_YELLOW
    return STATUS_RED


def blend_dimensions(
    dimensions: list[DimensionScore],
    weights: dict[str, float],
) -> tuple[Optional[float], str]:
    """Weighted mean over present dimensions, weights renormalized over them.

    Returns (score, detail). Score is None when no dimension has evidence.
    A dimension with no configured weight defaults to weight 1.0 so a registry
    typo degrades gracefully instead of silently dropping the dimension.
    """
    present = [d for d in dimensions if d.present and d.score is not None]
    if not present:
        return None, "no dimension evidence"

    total_weight = 0.0
    weighted_sum = 0.0
    for dim in present:
        w = weights.get(dim.name, 1.0)
        if w <= 0.0:
            continue
        total_weight += w
        weighted_sum += w * float(dim.score)

    if total_weight <= 0.0:
        return None, "all present dimensions have zero weight"

    score = clamp_score(weighted_sum / total_weight)
    missing = sorted({d.name for d in dimensions if not d.present})
    detail = "scored on " + ", ".join(sorted(d.name for d in present))
    if missing:
        detail += "; incomplete: " + ", ".join(missing)
    return score, detail


def checks_to_dimension_score(name: str, statuses: list[str]) -> DimensionScore:
    """Turn a list of PASS/WARN/FAIL check statuses into a 0-100 dimension score.

    PASS=100, WARN=50, FAIL=0, mean over all matched checks. An empty list means
    no matching evidence was found, which is INCOMPLETE, not a pass.
    """
    if not statuses:
        return DimensionScore.missing(name, detail="no matching checks")
    points = {"PASS": 100.0, "WARN": 50.0, "FAIL": 0.0}
    values = [points.get(s.upper(), 0.0) for s in statuses]
    mean = sum(values) / len(values)
    passed = sum(1 for s in statuses if s.upper() == "PASS")
    return DimensionScore.scored(
        name,
        mean,
        detail=f"{passed}/{len(statuses)} checks pass",
    )


def finalize_board(
    board: BoardScore,
    weights: dict[str, float],
    green_threshold: float,
    yellow_threshold: float,
) -> BoardScore:
    score, detail = blend_dimensions(board.dimensions, weights)
    board.score = None if score is None else round(score, 1)
    board.status = status_for_score(board.score, green_threshold, yellow_threshold)
    board.detail = detail
    return board


def overall_score(boards: list[BoardScore]) -> Optional[float]:
    """Board-weighted mean over boards that have a score. None if none scored."""
    scored = [b for b in boards if b.score is not None]
    if not scored:
        return None
    total_weight = sum(b.weight for b in scored if b.weight > 0)
    if total_weight <= 0:
        return None
    weighted = sum(b.weight * b.score for b in scored if b.weight > 0)
    return round(clamp_score(weighted / total_weight), 1)


def overall_status(boards: list[BoardScore]) -> str:
    """Worst board status wins, so one RED board cannot hide behind green ones.

    Boards that are explicitly hardware/human-gated do not drag the verdict to
    INCOMPLETE on their own — that is expected and reported separately — but an
    auto board with no evidence does.
    """
    relevant = [b for b in boards if b.automatable == "auto"]
    if not relevant:
        relevant = boards
    if not relevant:
        return STATUS_INCOMPLETE
    return min((b.status for b in relevant), key=status_rank)
