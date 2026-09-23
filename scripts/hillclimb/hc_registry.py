"""Knob and objective registries.

A knob is one tunable setting: its type, legal range, shipped default, how a
bench applies it without rebuilding the app, and which objectives it can move.
An objective is one user outcome we climb on: the bench that measures it, the
suite it runs on, the primary metric, guardrails that must not regress, and
hard gates that veto a candidate outright.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

from hc_stats import AGGREGATES, COMPARISONS, DIRECTIONS

KNOB_TYPES = ("float", "int", "bool", "enum")
# live: a bench can override it today. needs-seam: hardcoded in the app; the
# registry documents it so the seam can be added, but the climber skips it.
KNOB_STATUSES = ("live", "needs-seam", "bench-only")
APPLY_VIAS = ("env", "defaults", "bench-flag", "request")
KNOB_ID = re.compile(r"^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$")


class RegistryError(ValueError):
    pass


@dataclass(frozen=True)
class Knob:
    id: str
    area: str
    title: str
    type: str
    default: Any
    status: str
    apply: tuple[Mapping[str, str], ...]
    affects: tuple[str, ...]
    minimum: float | None = None
    maximum: float | None = None
    step: float | None = None
    choices: tuple[Any, ...] = ()
    source: str = ""
    risk: str = ""
    notes: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "Knob":
        knob_id = str(raw.get("id", ""))
        where = f"knob {knob_id or '?'}"
        if not KNOB_ID.match(knob_id):
            raise RegistryError(f"{where}: id must look like area.name (lowercase, dotted)")
        kind = raw.get("type")
        if kind not in KNOB_TYPES:
            raise RegistryError(f"{where}: type must be one of {KNOB_TYPES}")
        status = raw.get("status")
        if status not in KNOB_STATUSES:
            raise RegistryError(f"{where}: status must be one of {KNOB_STATUSES}")
        apply = tuple(dict(entry) for entry in raw.get("apply", ()))
        for entry in apply:
            if entry.get("via") not in APPLY_VIAS or not entry.get("name"):
                raise RegistryError(f"{where}: every apply entry needs via in {APPLY_VIAS} and a name")
        if status == "live" and not apply:
            raise RegistryError(f"{where}: a live knob needs at least one apply entry")
        affects = tuple(raw.get("affects", ()))
        if not affects:
            raise RegistryError(f"{where}: affects must name at least one objective")
        knob = cls(
            id=knob_id,
            area=str(raw.get("area", knob_id.split(".")[0])),
            title=str(raw.get("title", knob_id)),
            type=kind,
            default=raw.get("default"),
            status=status,
            apply=apply,
            affects=affects,
            minimum=raw.get("min"),
            maximum=raw.get("max"),
            step=raw.get("step"),
            choices=tuple(raw.get("choices", ())),
            source=str(raw.get("source", "")),
            risk=str(raw.get("risk", "")),
            notes=str(raw.get("notes", "")),
        )
        knob.validate_value(knob.default, label="default")
        if kind in ("float", "int"):
            if knob.minimum is None or knob.maximum is None or knob.step is None:
                raise RegistryError(f"{where}: numeric knobs need min, max and step")
            if not knob.minimum < knob.maximum:
                raise RegistryError(f"{where}: min must be below max")
            if knob.step <= 0:
                raise RegistryError(f"{where}: step must be positive")
        if kind == "enum" and len(knob.choices) < 2:
            raise RegistryError(f"{where}: enum knobs need at least two choices")
        return knob

    def validate_value(self, value: Any, *, label: str = "value") -> None:
        where = f"knob {self.id} {label}"
        if self.type == "bool":
            if not isinstance(value, bool):
                raise RegistryError(f"{where}: expected bool, got {value!r}")
        elif self.type == "enum":
            if value not in self.choices:
                raise RegistryError(f"{where}: {value!r} not in {list(self.choices)}")
        elif self.type == "int":
            if isinstance(value, bool) or not isinstance(value, int):
                raise RegistryError(f"{where}: expected int, got {value!r}")
            self._check_range(value, where)
        else:
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise RegistryError(f"{where}: expected finite number, got {value!r}")
            self._check_range(value, where)

    def _check_range(self, value: float, where: str) -> None:
        if self.minimum is not None and value < self.minimum:
            raise RegistryError(f"{where}: {value} below min {self.minimum}")
        if self.maximum is not None and value > self.maximum:
            raise RegistryError(f"{where}: {value} above max {self.maximum}")

    def neighbors(self, value: Any, scale: float = 1.0) -> list[Any]:
        """Values one step away from `value`, clipped to the legal range."""
        if self.type == "bool":
            return [not value]
        if self.type == "enum":
            return [choice for choice in self.choices if choice != value]
        step = self.step * scale
        if self.type == "int":
            step = max(1, int(round(step)))
        out = []
        for candidate in (value - step, value + step):
            clipped = min(max(candidate, self.minimum), self.maximum)
            if self.type == "int":
                clipped = int(round(clipped))
            else:
                clipped = round(float(clipped), 6)
            if clipped != value and clipped not in out:
                out.append(clipped)
        return out

    def env_assignments(self, value: Any) -> dict[str, str]:
        out = {}
        for entry in self.apply:
            if entry["via"] == "env":
                out[entry["name"]] = encode_value(value)
        return out


def encode_value(value: Any) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, float):
        return repr(round(value, 6))
    return str(value)


@dataclass(frozen=True)
class MetricSpec:
    id: str
    direction: str
    compare: str
    aggregate: str = "median"
    # Primary metric: smallest improvement worth shipping.
    min_effect: float = 0.0
    # Guardrail: largest regression tolerated before a candidate is rejected.
    max_regression: float = 0.0
    unit: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], where: str) -> "MetricSpec":
        if raw.get("direction") not in DIRECTIONS:
            raise RegistryError(f"{where}: direction must be one of {DIRECTIONS}")
        if raw.get("compare") not in COMPARISONS:
            raise RegistryError(f"{where}: compare must be one of {COMPARISONS}")
        aggregate = raw.get("aggregate", "median")
        if aggregate not in AGGREGATES:
            raise RegistryError(f"{where}: aggregate must be one of {AGGREGATES}")
        if not raw.get("id"):
            raise RegistryError(f"{where}: metric needs an id")
        return cls(
            id=str(raw["id"]),
            direction=raw["direction"],
            compare=raw["compare"],
            aggregate=aggregate,
            min_effect=float(raw.get("min_effect", 0.0)),
            max_regression=float(raw.get("max_regression", 0.0)),
            unit=str(raw.get("unit", "")),
        )


@dataclass(frozen=True)
class Objective:
    id: str
    title: str
    bench: str
    suite: str
    primary: MetricSpec
    guardrails: tuple[MetricSpec, ...]
    hard_gates: tuple[str, ...]
    knobs: tuple[str, ...]
    repetitions: int
    interleave: bool
    holdout_peek_budget: int
    bench_options: Mapping[str, Any] = field(default_factory=dict)
    notes: str = ""

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "Objective":
        objective_id = str(raw.get("id", ""))
        where = f"objective {objective_id or '?'}"
        for key in ("id", "bench", "suite", "primary", "knobs"):
            if key not in raw:
                raise RegistryError(f"{where}: missing {key!r}")
        repetitions = int(raw.get("repetitions", 1))
        if repetitions < 1:
            raise RegistryError(f"{where}: repetitions must be >= 1")
        budget = int(raw.get("holdout_peek_budget", 3))
        if budget < 1:
            raise RegistryError(f"{where}: holdout_peek_budget must be >= 1")
        primary = MetricSpec.from_dict(raw["primary"], f"{where} primary")
        if primary.min_effect <= 0:
            raise RegistryError(f"{where}: primary min_effect must be > 0 so noise never ships")
        return cls(
            id=objective_id,
            title=str(raw.get("title", objective_id)),
            bench=str(raw["bench"]),
            suite=str(raw["suite"]),
            primary=primary,
            guardrails=tuple(
                MetricSpec.from_dict(g, f"{where} guardrail") for g in raw.get("guardrails", ())
            ),
            hard_gates=tuple(raw.get("hard_gates", ())),
            knobs=tuple(raw["knobs"]),
            repetitions=repetitions,
            interleave=bool(raw.get("interleave", False)),
            holdout_peek_budget=budget,
            bench_options=dict(raw.get("bench_options", {})),
            notes=str(raw.get("notes", "")),
        )

    def metrics(self) -> list[MetricSpec]:
        return [self.primary, *self.guardrails]


@dataclass
class Registry:
    knobs: dict[str, Knob]
    objectives: dict[str, Objective]

    def defaults(self, knob_ids: Sequence[str] | None = None) -> dict[str, Any]:
        ids = knob_ids if knob_ids is not None else list(self.knobs)
        return {knob_id: self.knobs[knob_id].default for knob_id in ids}

    def searchable_knobs(self, objective: Objective) -> list[Knob]:
        return [self.knobs[k] for k in objective.knobs if self.knobs[k].status != "needs-seam"]

    def validate_config(self, config: Mapping[str, Any]) -> None:
        for knob_id, value in config.items():
            if knob_id not in self.knobs:
                raise RegistryError(f"unknown knob {knob_id}")
            self.knobs[knob_id].validate_value(value)

    def env_for(self, config: Mapping[str, Any]) -> dict[str, str]:
        env: dict[str, str] = {}
        for knob_id, value in config.items():
            env.update(self.knobs[knob_id].env_assignments(value))
        return env


def load_registry(knobs_path: Path, objectives_path: Path) -> Registry:
    knobs_raw = json.loads(knobs_path.read_text())
    objectives_raw = json.loads(objectives_path.read_text())
    knobs: dict[str, Knob] = {}
    for raw in knobs_raw.get("knobs", ()):
        knob = Knob.from_dict(raw)
        if knob.id in knobs:
            raise RegistryError(f"duplicate knob {knob.id}")
        knobs[knob.id] = knob
    objectives: dict[str, Objective] = {}
    for raw in objectives_raw.get("objectives", ()):
        objective = Objective.from_dict(raw)
        if objective.id in objectives:
            raise RegistryError(f"duplicate objective {objective.id}")
        objectives[objective.id] = objective
    registry = Registry(knobs, objectives)
    cross_check(registry)
    return registry


def cross_check(registry: Registry) -> None:
    env_owners: dict[str, str] = {}
    for knob in registry.knobs.values():
        for objective_id in knob.affects:
            if objective_id not in registry.objectives:
                raise RegistryError(f"knob {knob.id} affects unknown objective {objective_id}")
        for name in knob.env_assignments(knob.default):
            if name in env_owners:
                raise RegistryError(f"env var {name} claimed by both {env_owners[name]} and {knob.id}")
            env_owners[name] = knob.id
    for objective in registry.objectives.values():
        for knob_id in objective.knobs:
            if knob_id not in registry.knobs:
                raise RegistryError(f"objective {objective.id} searches unknown knob {knob_id}")
            if objective.id not in registry.knobs[knob_id].affects:
                raise RegistryError(
                    f"objective {objective.id} searches {knob_id}, but that knob does not list it in affects"
                )
