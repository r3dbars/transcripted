"""The climb itself: coordinate ascent with step shrinking, then a holdout check.

Why coordinate ascent: every step changes one knob, so every accepted move has
a one-line explanation ("raising X from a to b cut p50 stop-to-text by 9%"),
and the ledger reads like a lab notebook. It is also cheap: each trial on the
Mac costs real minutes, and most knobs here are close to separable.

Guards against fooling ourselves:
  - candidates are judged on the dev split only;
  - a win needs a significant paired improvement (sign-flip p < 0.05) above
    the objective's min_effect, proven non-inferiority on every guardrail,
    and no new hard-gate failure;
  - the final config is checked once on the locked holdout, and holdout
    checks are counted per objective and suite version, with a hard budget.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping, Sequence

from hc_engine import (
    DEV_ALPHA,
    HOLDOUT_ALPHA,
    Evaluator,
    Ledger,
    Trial,
    config_hash,
    decide,
    diff_from,
)
from hc_registry import Knob, Objective, Registry
from hc_splits import DEV, HOLDOUT


@dataclass
class ClimbResult:
    start: dict[str, Any]
    best: dict[str, Any]
    trials_used: int
    accepted_moves: list[dict[str, Any]] = field(default_factory=list)
    stopped_because: str = ""
    # Where the climb stands right now; checkpointed after every decision so a
    # crash or Ctrl-C can resume instead of starting over.
    incumbent: dict[str, Any] = field(default_factory=dict)
    scale: float = 1.0
    tried: set[str] = field(default_factory=set)


def replay_decisions(start: Mapping[str, Any], decisions: Sequence[Mapping[str, Any]]) -> ClimbResult:
    """Rebuild a climb's state from its decisions.jsonl, for --resume."""
    incumbent = dict(start)
    result = ClimbResult(start=dict(start), best=dict(start), trials_used=0, incumbent=dict(start))
    result.tried.add(config_hash(incumbent))
    for row in decisions:
        kind = row.get("kind")
        if kind == "remeasure":
            result.trials_used += 1
            continue
        if kind != "decision":
            continue
        candidate = {**incumbent, row["knob"]: row["to"]}
        result.tried.add(config_hash(candidate))
        result.trials_used += 1
        result.scale = float(row.get("scale", result.scale))
        if row.get("accept"):
            result.accepted_moves.append(
                {
                    "move": len(result.accepted_moves) + 1,
                    "knob": row["knob"],
                    "from": row["from"],
                    "to": row["to"],
                    "primary": row["primary"],
                    "trial": row["candidate_trial"],
                }
            )
            incumbent = candidate
    result.incumbent = incumbent
    result.best = dict(incumbent)
    return result


def climb(
    registry: Registry,
    objective: Objective,
    evaluator: Evaluator,
    ledger: Ledger,
    *,
    budget: int,
    start: Mapping[str, Any] | None = None,
    seed: int = 0,
    min_scale: float = 0.25,
    only_knobs: list[str] | None = None,
    resume: ClimbResult | None = None,
    on_progress: Callable[[ClimbResult], None] | None = None,
) -> ClimbResult:
    knobs: list[Knob] = registry.searchable_knobs(objective)
    if only_knobs:
        knobs = [k for k in knobs if k.id in only_knobs]
    if not knobs:
        raise ValueError(f"objective {objective.id} has no searchable knobs")
    if resume is not None:
        result = resume
        incumbent = dict(resume.incumbent)
        # Resuming continues from wherever the pass stood, with fresh shuffles.
        seed = seed + 7919 * (resume.trials_used + 1)
    else:
        incumbent = dict(start) if start else registry.defaults([k.id for k in knobs])
        result = ClimbResult(start=dict(incumbent), best=dict(incumbent), trials_used=0, incumbent=dict(incumbent))
        result.tried.add(config_hash(incumbent))
    rng = random.Random(seed)
    tried = result.tried
    scale = result.scale

    def checkpoint() -> None:
        result.incumbent = dict(incumbent)
        result.best = dict(incumbent)
        result.scale = scale
        if on_progress is not None:
            on_progress(result)

    while True:
        order = list(knobs)
        rng.shuffle(order)
        improved = False
        for knob in order:
            for value in knob.neighbors(incumbent[knob.id], scale):
                candidate = {**incumbent, knob.id: value}
                key = config_hash(candidate)
                if key in tried:
                    continue
                if result.trials_used >= budget:
                    result.stopped_because = "budget spent"
                    checkpoint()
                    return result
                tried.add(key)
                inc_trial, cand_trial = evaluator.evaluate_pair(incumbent, candidate, DEV)
                result.trials_used += 1
                verdict = decide(
                    objective, inc_trial, cand_trial,
                    seed=seed + result.trials_used, clusters=evaluator.clusters, alpha=DEV_ALPHA,
                )
                if verdict.inconclusive and objective.interleave and result.trials_used < budget:
                    # One more batch of repetitions, pooled with the first.
                    # This is a second look at exactly the near-misses, so it
                    # is judged at half the significance level (Bonferroni over
                    # the two looks). Deterministic benches would just repeat
                    # themselves, so only timing benches get this.
                    _log(ledger, "remeasure", inc_trial, cand_trial, knob, incumbent[knob.id], value, scale, verdict)
                    more_inc, more_cand = evaluator.evaluate_pair(incumbent, candidate, DEV)
                    inc_trial = Trial.pooled(inc_trial, more_inc)
                    cand_trial = Trial.pooled(cand_trial, more_cand)
                    result.trials_used += 1
                    verdict = decide(
                        objective, inc_trial, cand_trial,
                        seed=seed + result.trials_used, clusters=evaluator.clusters, alpha=DEV_ALPHA / 2,
                    )
                _log(ledger, "decision", inc_trial, cand_trial, knob, incumbent[knob.id], value, scale, verdict)
                if verdict.accept:
                    result.accepted_moves.append(
                        {
                            "move": len(result.accepted_moves) + 1,
                            "knob": knob.id,
                            "from": incumbent[knob.id],
                            "to": value,
                            "primary": verdict.primary,
                            "trial": cand_trial.trial_id,
                        }
                    )
                    incumbent = candidate
                    improved = True
                checkpoint()
                if verdict.accept:
                    break
        if not improved:
            if scale / 2 >= min_scale and any(k.type in ("int", "float") for k in knobs):
                scale /= 2
                continue
            result.stopped_because = "no neighbor beats the incumbent"
            checkpoint()
            return result


def _log(ledger: Ledger, kind: str, inc: Trial, cand: Trial, knob: Knob, old: Any, new: Any, scale: float, verdict) -> None:
    ledger.append(
        "decisions",
        {
            "kind": kind,
            "split": DEV,
            "incumbent_trial": inc.trial_id,
            "candidate_trial": cand.trial_id,
            "knob": knob.id,
            "from": old,
            "to": new,
            "scale": scale,
            **verdict.as_record(),
        },
    )


@dataclass
class Confirmation:
    confirmed: bool
    reasons: list[str]
    baseline_trial: Trial
    candidate_trial: Trial
    changes: dict[str, list[Any]]
    verdict: dict[str, Any]


def confirm_on_holdout(
    registry: Registry,
    objective: Objective,
    evaluator: Evaluator,
    ledger: Ledger,
    candidate: Mapping[str, Any],
    *,
    seed: int = 0,
) -> Confirmation:
    """Shipped defaults vs the candidate, once, on the locked holdout."""
    baseline = registry.defaults(list(candidate))
    base_trial, cand_trial = evaluator.evaluate_pair(baseline, candidate, HOLDOUT)
    verdict = decide(
        objective, base_trial, cand_trial, seed=seed, clusters=evaluator.clusters, alpha=HOLDOUT_ALPHA
    )
    ledger.append(
        "decisions",
        {
            "kind": "holdout",
            "split": HOLDOUT,
            "incumbent_trial": base_trial.trial_id,
            "candidate_trial": cand_trial.trial_id,
            **verdict.as_record(),
        },
    )
    return Confirmation(
        confirmed=verdict.accept,
        reasons=verdict.reasons,
        baseline_trial=base_trial,
        candidate_trial=cand_trial,
        changes=diff_from(baseline, candidate),
        verdict=verdict.as_record(),
    )


def calibrate(
    objective: Objective, evaluator: Evaluator, config: Mapping[str, Any], *, seed: int = 0
) -> dict[str, Any]:
    """A/A test: the same config twice. A healthy setup must NOT call this a win.

    Reports how big a "win" pure noise produces, so min_effect can be set
    above it. If the A/A run is accepted, the bench is too noisy to climb.
    """
    first, second = evaluator.evaluate_pair(config, config, DEV) if objective.interleave else (
        evaluator.evaluate(config, DEV),
        evaluator._finish(_rerun(evaluator, config)),
    )
    verdict = decide(objective, first, second, seed=seed, clusters=evaluator.clusters)
    noise = abs(verdict.primary["ci_low"]), abs(verdict.primary["ci_high"])
    return {
        "false_win": verdict.accept,
        "primary_noise_band": max(noise),
        "min_effect": objective.primary.min_effect,
        "healthy": (not verdict.accept) and max(noise) < objective.primary.min_effect,
        "verdict": verdict.as_record(),
    }


def _rerun(evaluator: Evaluator, config: Mapping[str, Any]) -> Trial:
    trial = evaluator._new_trial(config, DEV)
    for rep in range(evaluator.repetitions):
        evaluator._run_rep(trial, rep)
    return trial
