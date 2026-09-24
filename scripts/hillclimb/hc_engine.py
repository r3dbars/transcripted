"""Trials, verdicts, and the ledger.

A trial is one knob config measured on one split of one suite, possibly over
several repetitions. A verdict compares a candidate trial to the incumbent's
trial measured under the same conditions. Every trial and verdict is appended
to the campaign ledger, so a campaign can be audited or replayed later.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from hc_benches import REQUEST_SCHEMA, Bench, BenchError, validate_result
from hc_registry import Objective, Registry
from hc_splits import DEV, HOLDOUT, Suite, item_ids
from hc_stats import aggregate, paired_compare

ITEM_ERROR_GATE = "item_error"

# Significance level for moves on the dev split. The holdout check is the gate
# that produces a recommendation, so it is stricter.
DEV_ALPHA = 0.05
HOLDOUT_ALPHA = 0.01
# Fewest independent units (items, or clusters of correlated items) a split
# needs before the lab will climb or confirm on it. Below this the tests have
# almost no power and a lucky draw looks like a win.
MIN_UNITS = {DEV: 10, HOLDOUT: 8}
# A guardrail measured on fewer units than this share of the primary's units
# is treated as missing, and a missing guardrail rejects the candidate.
GUARDRAIL_MIN_COVERAGE = 0.5


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def config_hash(config: Mapping[str, Any]) -> str:
    blob = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest()[:12]


def diff_from(base: Mapping[str, Any], config: Mapping[str, Any]) -> dict[str, list[Any]]:
    return {k: [base.get(k), v] for k, v in sorted(config.items()) if base.get(k) != v}


@dataclass
class Trial:
    trial_id: str
    config: dict[str, Any]
    split: str
    repetitions: list[dict] = field(default_factory=list)
    started_at: str = ""
    finished_at: str = ""

    @property
    def config_hash(self) -> str:
        return config_hash(self.config)

    def environments(self) -> list[dict[str, Any]]:
        """Distinct build/host/OS fingerprints seen across repetitions.

        Repetitions that failed before reporting an environment are skipped;
        their items already count as item errors.
        """
        seen: list[dict[str, Any]] = []
        for rep in self.repetitions:
            env = rep.get("environment") or {}
            fields = {k: env.get(k) for k in ("app_revision", "host", "os") if k in env}
            if fields and fields not in seen:
                seen.append(fields)
        return seen

    def environment(self) -> dict[str, Any]:
        """Fields that must match for two trials to be comparable.

        Every repetition must agree: a rebuild halfway through a trial means
        later repetitions measured a different binary.
        """
        seen = self.environments()
        if not seen:
            return {}
        if len(seen) > 1:
            return {"inconsistent": seen}
        return seen[0]

    @classmethod
    def pooled(cls, first: "Trial", second: "Trial") -> "Trial":
        """One trial holding both trials' repetitions (same config and split)."""
        if first.config != second.config or first.split != second.split:
            raise ValueError("can only pool trials of the same config and split")
        return cls(
            f"{first.trial_id}+{second.trial_id}",
            dict(first.config),
            first.split,
            [*first.repetitions, *second.repetitions],
            first.started_at,
            second.finished_at,
        )

    def per_item(self, metric: str, how: str) -> dict[str, float]:
        """Aggregate each item's repetitions into one value per item."""
        values: dict[str, list[float]] = {}
        for rep in self.repetitions:
            for item in rep.get("items", ()):
                if item.get("error"):
                    continue
                value = (item.get("metrics") or {}).get(metric)
                if value is not None:
                    values.setdefault(item["id"], []).append(float(value))
        return {item_id: aggregate(vals, how) for item_id, vals in values.items()}

    def gate_totals(self) -> dict[str, int]:
        totals: dict[str, int] = {}
        for rep in self.repetitions:
            for item in rep.get("items", ()):
                for gate, count in (item.get("gates") or {}).items():
                    totals[gate] = totals.get(gate, 0) + int(count)
                if item.get("error"):
                    totals[ITEM_ERROR_GATE] = totals.get(ITEM_ERROR_GATE, 0) + 1
        return totals

    def summary(self, objective: Objective) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for spec in objective.metrics():
            per_item = self.per_item(spec.id, spec.aggregate)
            if per_item:
                vals = sorted(per_item.values())
                out[spec.id] = {
                    "items": len(vals),
                    "median": aggregate(vals, "median"),
                    "mean": aggregate(vals, "mean"),
                }
        return out

    def as_record(self, objective: Objective) -> dict[str, Any]:
        # Holdout per-item values never go into the shared ledger: a later
        # climb could read them and tune toward the holdout. Only aggregates
        # and the verdict are kept.
        per_item: Any = (
            "sealed"
            if split_is_holdout(self.split)
            else {spec.id: self.per_item(spec.id, spec.aggregate) for spec in objective.metrics()}
        )
        return {
            "kind": "trial",
            "trial_id": self.trial_id,
            "config_hash": self.config_hash,
            "config": self.config,
            "split": self.split,
            "repetitions": len(self.repetitions),
            "environment": self.environment(),
            "summary": self.summary(objective),
            "gates": self.gate_totals(),
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "per_item": per_item,
        }


@dataclass
class Verdict:
    accept: bool
    reasons: list[str]
    primary: dict[str, Any]
    guardrails: list[dict[str, Any]]
    gates: dict[str, list[int]]
    # Rejected only because the sample was too small to be sure either way:
    # the point estimates look like a safe win but a CI straddles the line.
    # The climber may re-measure once with more repetitions; it never accepts
    # an inconclusive verdict as is.
    inconclusive: bool = False

    def as_record(self) -> dict[str, Any]:
        return {
            "accept": self.accept,
            "inconclusive": self.inconclusive,
            "reasons": self.reasons,
            "primary": self.primary,
            "guardrails": self.guardrails,
            "gates": self.gates,
        }


def decide(
    objective: Objective,
    incumbent: Trial,
    candidate: Trial,
    *,
    seed: int = 0,
    clusters: Mapping[str, str] | None = None,
    alpha: float = DEV_ALPHA,
) -> Verdict:
    """Accept only a clear, safe win.

    Rules, in order. Any failure rejects:
      1. Every repetition of both trials ran under the same app build, host
         and OS.
      2. No hard gate (or item error) fires more often than for the incumbent.
      3. The candidate measured every item the incumbent measured.
      4. Primary metric: a one-sided paired sign-flip test on per-unit
         improvement gives p < alpha, and the mean clears min_effect.
      5. Guardrails (non-inferiority): each one is measured on at least half
         as many units as the primary, lost no items, and the sign-flip test
         rejects "worse than max_regression" at p < alpha. A guardrail with
         no data rejects; it is never skipped.

    Items sharing a `clusters` value are averaged into one unit first, so
    correlated items (same people, same meeting) count once.
    """
    reasons: list[str] = []
    ok = True
    # Failures that more data could flip. Anything else is a firm rejection.
    noise_only = True
    inc_env, cand_env = incumbent.environment(), candidate.environment()
    if "inconsistent" in inc_env or "inconsistent" in cand_env:
        ok = noise_only = False
        reasons.append("not comparable: the build, host or OS changed between repetitions")
    elif inc_env != cand_env:
        ok = noise_only = False
        reasons.append(f"not comparable: environment differs {inc_env} vs {cand_env}")

    inc_gates, cand_gates = incumbent.gate_totals(), candidate.gate_totals()
    gate_view: dict[str, list[int]] = {}
    for gate in (*objective.hard_gates, ITEM_ERROR_GATE):
        before, after = inc_gates.get(gate, 0), cand_gates.get(gate, 0)
        gate_view[gate] = [before, after]
        if after > before:
            ok = noise_only = False
            reasons.append(f"hard gate {gate}: {before} -> {after}")

    spec = objective.primary
    inc_primary = incumbent.per_item(spec.id, spec.aggregate)
    primary = paired_compare(
        spec.id,
        inc_primary,
        candidate.per_item(spec.id, spec.aggregate),
        direction=spec.direction,
        compare=spec.compare,
        seed=seed,
        clusters=clusters,
    )
    lost = [i for i in primary.missing_items if i in inc_primary]
    if lost:
        ok = noise_only = False
        reasons.append(f"candidate lost items: {lost}")
    if primary.n == 0:
        ok = noise_only = False
        reasons.append("no paired items to compare")
    elif primary.p_value >= alpha:
        ok = False
        noise_only = noise_only and primary.mean >= spec.min_effect
        reasons.append(
            f"{spec.id}: improvement {primary.mean:+.4f} not significant "
            f"(p={primary.p_value:.4f} over {primary.n} units, need < {alpha})"
        )
    elif primary.mean < spec.min_effect:
        ok = noise_only = False
        reasons.append(f"{spec.id}: improvement {primary.mean:+.4f} below min_effect {spec.min_effect}")

    guard_rows = []
    for guard in objective.guardrails:
        inc_guard = incumbent.per_item(guard.id, guard.aggregate)
        comparison = paired_compare(
            guard.id,
            inc_guard,
            candidate.per_item(guard.id, guard.aggregate),
            direction=guard.direction,
            compare=guard.compare,
            seed=seed + 1,
            clusters=clusters,
            null_shift=-guard.max_regression,
        )
        row = comparison.as_dict()
        row["max_regression"] = guard.max_regression
        guard_rows.append(row)
        guard_lost = [i for i in comparison.missing_items if i in inc_guard]
        needed = max(1, math.ceil(GUARDRAIL_MIN_COVERAGE * primary.n))
        if guard_lost:
            ok = noise_only = False
            reasons.append(f"guardrail {guard.id}: candidate lost items {guard_lost}")
        elif comparison.n < needed:
            ok = noise_only = False
            reasons.append(
                f"guardrail {guard.id}: measured on {comparison.n} units, need at least {needed} "
                f"(half the primary's {primary.n}); a speed win with no quality check is not shipped"
            )
        elif comparison.p_value >= alpha:
            ok = False
            noise_only = noise_only and comparison.mean >= -guard.max_regression
            reasons.append(
                f"guardrail {guard.id}: cannot rule out a regression worse than -{guard.max_regression} "
                f"(mean {comparison.mean:+.4f}, CI low {comparison.ci_low:+.4f}, p={comparison.p_value:.4f})"
            )
    if ok:
        reasons.append(
            f"{spec.id}: {primary.mean:+.4f} (CI {primary.ci_low:+.4f}..{primary.ci_high:+.4f}, "
            f"p={primary.p_value:.4f}, {primary.n} units)"
        )
    return Verdict(ok, reasons, primary.as_dict(), guard_rows, gate_view, inconclusive=(not ok) and noise_only)


class Ledger:
    """Append-only JSONL files under one campaign directory."""

    def __init__(self, root: Path):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)

    def append(self, name: str, record: Mapping[str, Any]) -> None:
        line = json.dumps({"at": utc_now(), **record}, sort_keys=True)
        with (self.root / f"{name}.jsonl").open("a") as handle:
            handle.write(line + "\n")

    def read(self, name: str) -> list[dict]:
        path = self.root / f"{name}.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def write_json(self, name: str, payload: Any) -> Path:
        path = self.root / name
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return path


class Evaluator:
    """Runs trials through a bench and caches deterministic results."""

    def __init__(
        self,
        registry: Registry,
        objective: Objective,
        suite: Suite,
        bench: Bench,
        ledger: Ledger,
        *,
        repetitions: int | None = None,
    ):
        self.registry = registry
        self.objective = objective
        self.suite = suite
        self.bench = bench
        self.ledger = ledger
        self.repetitions = repetitions or objective.repetitions
        self._cache: dict[tuple[str, str], Trial] = {}
        self._counter = len(ledger.read("trials"))
        self.clusters = suite.clusters()

    def _next_id(self) -> str:
        self._counter += 1
        return f"t{self._counter:04d}"

    def _request(self, trial: Trial, repetition: int, items: Sequence[Mapping[str, Any]]) -> dict:
        return {
            "schema": REQUEST_SCHEMA,
            "trial_id": trial.trial_id,
            "objective": self.objective.id,
            "suite": self.suite.id,
            "split": trial.split,
            "repetition": repetition,
            "knobs": dict(trial.config),
            "items": [dict(item) for item in items],
            "bench_options": dict(self.objective.bench_options),
        }

    def _run_rep(self, trial: Trial, repetition: int) -> None:
        items = self.suite.items_in(trial.split)
        ids = item_ids(items)
        try:
            result = self.bench.run(self._request(trial, repetition, items))
        except BenchError as error:
            result = {
                "environment": {},
                "items": [{"id": i, "metrics": {}, "gates": {}, "error": str(error)} for i in ids],
                "bench_error": str(error),
            }
        else:
            problems = validate_result(result, ids)
            if problems:
                result = {
                    "environment": _environment_of(result),
                    "items": [
                        {"id": i, "metrics": {}, "gates": {}, "error": "protocol: " + "; ".join(problems)}
                        for i in ids
                    ],
                    "bench_error": "protocol violation",
                }
        returned = {item["id"] for item in result["items"]}
        for missing in sorted(set(ids) - returned):
            result["items"].append({"id": missing, "metrics": {}, "gates": {}, "error": "bench returned no row"})
        trial.repetitions.append(result)

    def _new_trial(self, config: Mapping[str, Any], split: str) -> Trial:
        self.registry.validate_config(config)
        return Trial(self._next_id(), dict(config), split, started_at=utc_now())

    def _finish(self, trial: Trial) -> Trial:
        trial.finished_at = utc_now()
        self.ledger.append("trials", trial.as_record(self.objective))
        return trial

    def evaluate(self, config: Mapping[str, Any], split: str) -> Trial:
        key = (config_hash(config), split)
        if key in self._cache:
            return self._cache[key]
        trial = self._new_trial(config, split)
        for rep in range(self.repetitions):
            self._run_rep(trial, rep)
        self._finish(trial)
        if not self.objective.interleave:
            self._cache[key] = trial
        return trial

    def evaluate_pair(
        self,
        incumbent: Mapping[str, Any],
        candidate: Mapping[str, Any],
        split: str,
        *,
        repetitions: int | None = None,
    ) -> tuple[Trial, Trial]:
        """Measure both configs under the same conditions.

        Deterministic benches reuse the cached incumbent. Timing benches
        (interleave=true) re-measure the incumbent every time, alternating the
        order each repetition (ABBA...) so thermal drift and background load
        hit both sides equally.
        """
        if not self.objective.interleave:
            return self.evaluate(incumbent, split), self.evaluate(candidate, split)
        inc, cand = self._new_trial(incumbent, split), self._new_trial(candidate, split)
        for rep in range(repetitions or self.repetitions):
            order = (inc, cand) if rep % 2 == 0 else (cand, inc)
            for trial in order:
                self._run_rep(trial, rep)
        return self._finish(inc), self._finish(cand)


# A new holdout that shares more than this share of its items with an earlier
# one is the same holdout for budget purposes.
HOLDOUT_OVERLAP_LIMIT = 0.5


def _environment_of(result: Any) -> dict[str, Any]:
    env = result.get("environment") if isinstance(result, dict) else None
    return env if isinstance(env, dict) else {}


def holdout_peeks(
    state_root: Path,
    objective_id: str,
    holdout_ids: Iterable[str],
    suite_fingerprint: str | None = None,
) -> list[dict]:
    """Earlier holdout checks for this objective that saw mostly these items.

    Counted by item overlap, not by suite version: adding a few items changes
    the fingerprint but leaves the old holdout items in holdout, so a
    fingerprint-keyed budget would reset while the agent keeps peeking at the
    same clips. Rows written before item ids were recorded fall back to the
    fingerprint.
    """
    path = state_root / "holdout-peeks.jsonl"
    if not path.exists():
        return []
    current = set(holdout_ids)
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    out = []
    for row in rows:
        if row.get("objective") != objective_id:
            continue
        seen = row.get("holdout_items")
        if seen is None:
            if suite_fingerprint is not None and row.get("suite_fingerprint") == suite_fingerprint:
                out.append(row)
            continue
        if current and len(current & set(seen)) > HOLDOUT_OVERLAP_LIMIT * len(current):
            out.append(row)
    return out


def record_holdout_peek(state_root: Path, row: Mapping[str, Any]) -> None:
    state_root.mkdir(parents=True, exist_ok=True)
    with (state_root / "holdout-peeks.jsonl").open("a") as handle:
        handle.write(json.dumps({"at": utc_now(), **row}, sort_keys=True) + "\n")


def split_is_holdout(split: str) -> bool:
    return split == HOLDOUT


def unique(values: Iterable[Any]) -> list[Any]:
    out = []
    for value in values:
        if value not in out:
            out.append(value)
    return out
