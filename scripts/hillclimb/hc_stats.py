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
    n: int  # independent units (clusters) actually tested
    mean: float
    ci_low: float
    ci_high: float
    missing_items: list[str] = field(default_factory=list)
    items: int = 0  # paired items before clustering
    p_value: float = 1.0  # one-sided sign-flip p for the hypothesis tested

    def as_dict(self) -> dict:
        return {
            "metric": self.metric,
            "n": self.n,
            "items": self.items,
            "mean": round(self.mean, 6),
            "ci_low": round(self.ci_low, 6),
            "ci_high": round(self.ci_high, 6),
            "p_value": round(self.p_value, 6),
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
    clusters: Mapping[str, str] | None = None,
    null_shift: float = 0.0,
) -> PairedComparison:
    """Compare two per-item metric maps on the items both measured.

    Items one side lacks are reported, never silently dropped: a candidate that
    stops producing a value for an item is a failure the caller must see.
    Items sharing a cluster are averaged into one unit before testing. The
    p-value tests H0: mean improvement <= null_shift (0 for "is it better",
    -margin for "is it no worse than the margin").
    """
    shared = sorted(set(baseline) & set(candidate))
    missing = sorted(set(baseline) ^ set(candidate))
    if not shared:
        return PairedComparison(metric, 0, 0.0, -math.inf, math.inf, missing)
    per_item = {
        item: improvement(baseline[item], candidate[item], direction, compare)
        for item in shared
    }
    units = cluster_means(per_item, clusters)
    low, high = bootstrap_mean_ci(units, iterations=iterations, seed=seed)
    p = sign_flip_pvalue(units, shift=null_shift, seed=seed)
    return PairedComparison(metric, len(units), sum(units) / len(units), low, high, missing, len(shared), p)


def spread(samples: Iterable[float]) -> float:
    """Sample standard deviation; 0 for fewer than two samples."""
    values = list(samples)
    if len(values) < 2:
        return 0.0
    mean = sum(values) / len(values)
    return math.sqrt(sum((v - mean) ** 2 for v in values) / (len(values) - 1))


# Exact enumeration up to this many units; Monte Carlo above it.
_EXACT_SIGN_FLIP_MAX = 16
# Monte Carlo draws whole blocks of signs at once from precomputed tables.
_SIGN_TABLE_BITS = 12


def _signed_sums(values: Sequence[float]) -> list[float]:
    """Sum of every +/- sign pattern over `values` (2**len entries)."""
    sums = [0.0]
    for value in values:
        sums = [s + value for s in sums] + [s - value for s in sums]
    return sums


def sign_flip_pvalue(
    deltas: Sequence[float],
    *,
    shift: float = 0.0,
    iterations: int = 20000,
    seed: int = 0,
) -> float:
    """One-sided paired sign-flip permutation test.

    H0: the mean of `deltas` is <= `shift`. Returns P(mean of randomly
    sign-flipped (delta - shift) >= observed). Exact for small n, which is
    where the percentile bootstrap is badly anti-conservative. With n units the
    smallest possible p-value is 1 / 2**n, so 4 or fewer units can never reach
    p < 0.05: a tiny suite cannot produce a "significant" win at all.
    """
    centered = [d - shift for d in deltas]
    n = len(centered)
    if n == 0:
        return 1.0
    observed = sum(centered)
    tolerance = 1e-12 * max(1.0, sum(abs(v) for v in centered))
    if n <= _EXACT_SIGN_FLIP_MAX:
        sums = _signed_sums(centered)
        return sum(1 for s in sums if s >= observed - tolerance) / len(sums)
    blocks = [centered[i : i + _SIGN_TABLE_BITS] for i in range(0, n, _SIGN_TABLE_BITS)]
    tables = [(len(block), _signed_sums(block)) for block in blocks]
    rng = random.Random(seed)
    hits = 1  # count the observed labelling itself
    for _ in range(iterations):
        s = 0.0
        for bits, table in tables:
            s += table[rng.getrandbits(bits)]
        if s >= observed - tolerance:
            hits += 1
    return hits / (iterations + 1)


def cluster_means(deltas: Mapping[str, float], clusters: Mapping[str, str] | None) -> list[float]:
    """Average per-item deltas within a cluster so correlated items count once."""
    if not clusters:
        return [deltas[k] for k in sorted(deltas)]
    grouped: dict[str, list[float]] = {}
    for item_id in sorted(deltas):
        grouped.setdefault(clusters.get(item_id, item_id), []).append(deltas[item_id])
    return [sum(v) / len(v) for _, v in sorted(grouped.items())]


def null_accept_rate(
    n_units: int,
    *,
    sd: float,
    min_effect: float,
    alpha: float,
    trials: int = 2000,
    seed: int = 0,
) -> float:
    """How often pure noise passes the primary rule at this many units.

    Draws per-unit improvements from N(0, sd) (no real effect) and counts how
    often both the sign-flip test (p < alpha) and the min_effect bar pass.
    This is the per-candidate false-accept rate; a climb multiplies it by
    roughly the number of candidates it tries.
    """
    if n_units <= 0:
        return 0.0
    rng = random.Random(seed)
    hits = 0
    for trial in range(trials):
        deltas = [rng.gauss(0.0, sd) for _ in range(n_units)]
        if sum(deltas) / n_units < min_effect:
            continue
        if sign_flip_pvalue(deltas, seed=seed + trial, iterations=2000) < alpha:
            hits += 1
    return hits / trials
