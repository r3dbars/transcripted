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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from hc_benches import REQUEST_SCHEMA, Bench, BenchError, validate_result
from hc_registry import Objective, Registry
from hc_splits import HOLDOUT, Suite, item_ids
from hc_stats import aggregate, paired_compare

ITEM_ERROR_GATE = "item_error"


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

    def environment(self) -> dict[str, Any]:
        """Fields that must match for two trials to be comparable."""
        if not self.repetitions:
            return {}
        env = self.repetitions[0].get("environment", {})
        return {k: env.get(k) for k in ("app_revision", "host", "os") if k in env}

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
            "per_item": {
                spec.id: self.per_item(spec.id, spec.aggregate) for spec in objective.metrics()
            },
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


def decide(objective: Objective, incumbent: Trial, candidate: Trial, *, seed: int = 0) -> Verdict:
    """Accept only a clear, safe win.

    Rules, in order. Any failure rejects:
      1. Both trials ran under the same app build, host and OS.
      2. No hard gate (or item error) fires more often than for the incumbent.
      3. The candidate measured every item the incumbent measured.
      4. Primary metric: the bootstrap CI lower bound on improvement is above
         zero and the point estimate clears min_effect.
      5. Guardrails: the CI lower bound never shows a regression larger than
         the guardrail's max_regression.
    """
    reasons: list[str] = []
    ok = True
    # Failures that more data could flip. Anything else is a firm rejection.
    noise_only = True
    inc_env, cand_env = incumbent.environment(), candidate.environment()
    if inc_env != cand_env:
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
    primary = paired_compare(
        spec.id,
        incumbent.per_item(spec.id, spec.aggregate),
        candidate.per_item(spec.id, spec.aggregate),
        direction=spec.direction,
        compare=spec.compare,
        seed=seed,
    )
    lost = [i for i in primary.missing_items if i in incumbent.per_item(spec.id, spec.aggregate)]
    if lost:
        ok = noise_only = False
        reasons.append(f"candidate lost items: {lost}")
    if primary.n == 0:
        ok = noise_only = False
        reasons.append("no paired items to compare")
    elif primary.ci_low <= 0:
        ok = False
        noise_only = noise_only and primary.mean >= spec.min_effect
        reasons.append(
            f"{spec.id}: improvement {primary.mean:+.4f} not significant (CI low {primary.ci_low:+.4f})"
        )
    elif primary.mean < spec.min_effect:
        ok = noise_only = False
        reasons.append(f"{spec.id}: improvement {primary.mean:+.4f} below min_effect {spec.min_effect}")

    guard_rows = []
    for guard in objective.guardrails:
        comparison = paired_compare(
            guard.id,
            incumbent.per_item(guard.id, guard.aggregate),
            candidate.per_item(guard.id, guard.aggregate),
            direction=guard.direction,
            compare=guard.compare,
            seed=seed + 1,
        )
        row = comparison.as_dict()
        row["max_regression"] = guard.max_regression
        guard_rows.append(row)
        if comparison.n and comparison.ci_low < -guard.max_regression:
            ok = False
            noise_only = noise_only and comparison.mean >= -guard.max_regression
            reasons.append(
                f"guardrail {guard.id}: could regress {comparison.ci_low:+.4f} (limit -{guard.max_regression})"
            )
    if ok:
        reasons.append(f"{spec.id}: {primary.mean:+.4f} (CI {primary.ci_low:+.4f}..{primary.ci_high:+.4f})")
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
                    "environment": result.get("environment", {}),
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


def holdout_peeks(state_root: Path, objective_id: str, suite_fingerprint: str) -> list[dict]:
    """Every holdout evaluation ever run for this objective and suite version."""
    path = state_root / "holdout-peeks.jsonl"
    if not path.exists():
        return []
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return [r for r in rows if r.get("objective") == objective_id and r.get("suite_fingerprint") == suite_fingerprint]


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
