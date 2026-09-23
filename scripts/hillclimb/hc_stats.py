"""Small, dependency-free statistics for the hill-climb lab.

Everything here is deterministic given a seed, so the same ledger replays to
the same verdicts. Improvements are always expressed so that positive means
"better for the user", whatever the metric's raw direction.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Iterable, Mapping, Sequence

LOWER_IS_BETTER = "lower"
HIGHER_IS_BETTER = "higher"
DIRECTIONS = (LOWER_IS_BETTER, HIGHER_IS_BETTER)

# How two per-item values are turned into one paired improvement.
# log_ratio suits latencies and other strictly positive, multiplicative
# quantities (0.05 ~= 5% faster). difference suits rates and scores that live
# on a fixed scale (0.05 == five percentage points).
COMPARE_LOG_RATIO = "log_ratio"
COMPARE_DIFFERENCE = "difference"
COMPARISONS = (COMPARE_LOG_RATIO, COMPARE_DIFFERENCE)

AGGREGATES = ("median", "mean", "max", "min")

# Floor for log_ratio inputs so a 0 ms reading cannot produce -inf.
_LOG_FLOOR = 1e-9


def percentile(values: Sequence[float], q: float) -> float:
    """Linear-interpolated percentile, q in [0, 100]."""
    if not values:
        raise ValueError("percentile of empty sequence")
    if not 0.0 <= q <= 100.0:
        raise ValueError(f"percentile q out of range: {q}")
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    rank = (len(ordered) - 1) * q / 100.0
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return float(ordered[low])
    fraction = rank - low
    return float(ordered[low] + (ordered[high] - ordered[low]) * fraction)


def aggregate(values: Sequence[float], how: str) -> float:
    if not values:
        raise ValueError("aggregate of empty sequence")
    if how == "median":
        return percentile(values, 50.0)
    if how == "mean":
        return float(sum(values) / len(values))
    if how == "max":
        return float(max(values))
    if how == "min":
        return float(min(values))
    raise ValueError(f"unknown aggregate: {how}")


def improvement(baseline: float, candidate: float, direction: str, compare: str) -> float:
    """Paired improvement of candidate over baseline; positive is better."""
    if direction not in DIRECTIONS:
        raise ValueError(f"unknown direction: {direction}")
    if compare == COMPARE_LOG_RATIO:
        if baseline < 0 or candidate < 0:
            raise ValueError("log_ratio needs non-negative values")
        raw = math.log(max(candidate, _LOG_FLOOR)) - math.log(max(baseline, _LOG_FLOOR))
    elif compare == COMPARE_DIFFERENCE:
        raw = candidate - baseline
    else:
        raise ValueError(f"unknown comparison: {compare}")
    return -raw if direction == LOWER_IS_BETTER else raw


def bootstrap_mean_ci(
    samples: Sequence[float],
    *,
    iterations: int = 2000,
    confidence: float = 0.95,
    seed: int = 0,
) -> tuple[float, float]:
    """Percentile bootstrap CI for the mean. Deterministic for a given seed."""
    if not samples:
        raise ValueError("bootstrap of empty sequence")
    if len(samples) == 1:
        value = float(samples[0])
        return value, value
    rng = random.Random(seed)
    n = len(samples)
    means = []
    for _ in range(iterations):
        total = 0.0
        for _ in range(n):
            total += samples[rng.randrange(n)]
        means.append(total / n)
    tail = (1.0 - confidence) / 2.0 * 100.0
    return percentile(means, tail), percentile(means, 100.0 - tail)


@dataclass
class PairedComparison:
    metric: str
    n: int
    mean: float
    ci_low: float
    ci_high: float
    missing_items: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "metric": self.metric,
            "n": self.n,
            "mean": round(self.mean, 6),
            "ci_low": round(self.ci_low, 6),
            "ci_high": round(self.ci_high, 6),
            "missing_items": list(self.missing_items),
        }


def paired_compare(
    metric: str,
    baseline: Mapping[str, float],
    candidate: Mapping[str, float],
    *,
    direction: str,
    compare: str,
    seed: int = 0,
    iterations: int = 2000,
) -> PairedComparison:
    """Compare two per-item metric maps on the items both measured.

    Items one side lacks are reported, never silently dropped: a candidate that
    stops producing a value for an item is a failure the caller must see.
    """
    shared = sorted(set(baseline) & set(candidate))
    missing = sorted(set(baseline) ^ set(candidate))
    if not shared:
        return PairedComparison(metric, 0, 0.0, -math.inf, math.inf, missing)
    deltas = [
        improvement(baseline[item], candidate[item], direction, compare)
        for item in shared
    ]
    low, high = bootstrap_mean_ci(deltas, iterations=iterations, seed=seed)
    return PairedComparison(metric, len(deltas), sum(deltas) / len(deltas), low, high, missing)


def spread(samples: Iterable[float]) -> float:
    """Sample standard deviation; 0 for fewer than two samples."""
    values = list(samples)
    if len(values) < 2:
        return 0.0
    mean = sum(values) / len(values)
    return math.sqrt(sum((v - mean) ** 2 for v in values) / (len(values) - 1))
