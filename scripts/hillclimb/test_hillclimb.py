#!/usr/bin/env python3
"""Unit tests for the hill-climb lab. Run: python3 scripts/hillclimb/hillclimb.py --self-test"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import hillclimb  # noqa: E402
from hc_benches import RESULT_SCHEMA, CommandBench, validate_result  # noqa: E402
from hc_engine import Evaluator, Ledger, Trial, decide  # noqa: E402
from hc_registry import Knob, Objective, RegistryError, load_registry  # noqa: E402
from hc_search import calibrate, climb  # noqa: E402
from hc_splits import DEV, HOLDOUT, Suite  # noqa: E402
from hc_stats import bootstrap_mean_ci, improvement, paired_compare, percentile  # noqa: E402

DEMO = HERE / "fixtures" / "demo"
REAL = HERE.parents[1] / "config" / "hillclimb"


def objective(**overrides) -> Objective:
    raw = {
        "id": "o",
        "bench": "b",
        "suite": "s",
        "primary": {"id": "lat", "direction": "lower", "compare": "log_ratio", "min_effect": 0.02},
        "guardrails": [{"id": "acc", "direction": "higher", "compare": "difference", "aggregate": "mean", "max_regression": 0.01}],
        "hard_gates": ["false_name"],
        "knobs": [],
        "repetitions": 1,
    }
    raw.update(overrides)
    return Objective.from_dict(raw)


def trial(values: dict, *, acc: dict | None = None, gates: dict | None = None, env: dict | None = None) -> Trial:
    items = []
    for item_id, lat in values.items():
        metrics = {"lat": lat}
        if acc is not None:
            metrics["acc"] = acc[item_id]
        items.append({"id": item_id, "metrics": metrics, "gates": (gates or {}).get(item_id, {}), "error": None})
    t = Trial("t", {}, DEV)
    t.repetitions.append({"environment": env or {"app_revision": "a"}, "items": items})
    return t


class StatsTests(unittest.TestCase):
    def test_percentile_interpolates(self):
        self.assertEqual(percentile([1, 2, 3, 4], 50), 2.5)
        self.assertEqual(percentile([5], 99), 5)

    def test_improvement_sign_is_user_facing(self):
        self.assertGreater(improvement(2.0, 1.0, "lower", "log_ratio"), 0)
        self.assertLess(improvement(0.8, 0.7, "higher", "difference"), 0)

    def test_bootstrap_is_deterministic(self):
        data = [0.1, 0.2, -0.05, 0.3, 0.15]
        self.assertEqual(bootstrap_mean_ci(data, seed=3), bootstrap_mean_ci(data, seed=3))

    def test_paired_compare_reports_missing_items(self):
        result = paired_compare("m", {"a": 1, "b": 1}, {"a": 0.5}, direction="lower", compare="log_ratio")
        self.assertEqual(result.missing_items, ["b"])
        self.assertEqual(result.n, 1)


class SplitTests(unittest.TestCase):
    def suite(self, n=50, **extra):
        items = [{"id": f"i{k}"} for k in range(n)]
        return Suite.from_dict({"id": "s", "salt": "x", "holdout_fraction": 0.3, "items": items, **extra})

    def test_adding_items_never_moves_existing_ones(self):
        small, big = self.suite(50), self.suite(80)
        small_holdout = {i["id"] for i in small.items_in(HOLDOUT)}
        big_holdout = {i["id"] for i in big.items_in(HOLDOUT)}
        self.assertTrue(small_holdout <= big_holdout)
        self.assertNotEqual(small.fingerprint(), big.fingerprint())

    def test_pinned_split_wins(self):
        suite = Suite.from_dict({"id": "s", "salt": "x", "holdout_fraction": 0.5, "items": [{"id": "a", "split": HOLDOUT}, {"id": "b", "split": DEV}]})
        self.assertEqual([i["id"] for i in suite.items_in(HOLDOUT)], ["a"])

    def test_duplicate_ids_rejected(self):
        with self.assertRaises(ValueError):
            Suite.from_dict({"id": "s", "salt": "x", "holdout_fraction": 0.5, "items": [{"id": "a"}, {"id": "a"}]})


class RegistryTests(unittest.TestCase):
    def test_numeric_knob_neighbors_clip_to_range(self):
        knob = Knob.from_dict({"id": "a.b", "type": "float", "default": 0.9, "min": 0.5, "max": 0.95, "step": 0.1,
                               "status": "live", "apply": [{"via": "env", "name": "X"}], "affects": ["o"]})
        self.assertEqual(knob.neighbors(0.9), [0.8, 0.95])

    def test_default_outside_range_rejected(self):
        with self.assertRaises(RegistryError):
            Knob.from_dict({"id": "a.b", "type": "int", "default": 12, "min": 1, "max": 9, "step": 1,
                            "status": "live", "apply": [{"via": "env", "name": "X"}], "affects": ["o"]})

    def test_live_knob_needs_a_way_in(self):
        with self.assertRaises(RegistryError):
            Knob.from_dict({"id": "a.b", "type": "bool", "default": False, "status": "live", "apply": [], "affects": ["o"]})

    def test_primary_needs_positive_min_effect(self):
        with self.assertRaises(RegistryError):
            objective(primary={"id": "lat", "direction": "lower", "compare": "log_ratio", "min_effect": 0})

    def test_demo_registry_loads(self):
        registry = load_registry(DEMO / "knobs.json", DEMO / "objectives.json")
        self.assertIn("demo-latency", registry.objectives)
        names = [k.id for k in registry.searchable_knobs(registry.objectives["demo-naming"])]
        self.assertNotIn("demo.unbuilt", names)

    def test_real_registry_loads_and_validates(self):
        if not (REAL / "knobs.json").exists():
            self.skipTest("real registry not written yet")
        out = io.StringIO()
        with redirect_stdout(out):
            code = hillclimb.main(["--config-dir", str(REAL), "--state-dir", tempfile.mkdtemp(), "validate"])
        self.assertEqual(code, 0, out.getvalue())


class DecideTests(unittest.TestCase):
    items = {f"i{k}": 1.0 + k * 0.1 for k in range(20)}
    acc = {f"i{k}": 0.9 for k in range(20)}

    def test_clear_win_accepted(self):
        inc = trial(self.items, acc=self.acc)
        cand = trial({k: v * 0.8 for k, v in self.items.items()}, acc=self.acc)
        verdict = decide(objective(), inc, cand)
        self.assertTrue(verdict.accept, verdict.reasons)

    def test_new_hard_gate_vetoes_any_speedup(self):
        inc = trial(self.items, acc=self.acc)
        cand = trial({k: v * 0.5 for k, v in self.items.items()}, acc=self.acc, gates={"i3": {"false_name": 1}})
        verdict = decide(objective(), inc, cand)
        self.assertFalse(verdict.accept)
        self.assertFalse(verdict.inconclusive)

    def test_guardrail_regression_rejects(self):
        inc = trial(self.items, acc=self.acc)
        cand = trial({k: v * 0.8 for k, v in self.items.items()}, acc={k: 0.85 for k in self.acc})
        self.assertFalse(decide(objective(), inc, cand).accept)

    def test_lost_items_reject(self):
        inc = trial(self.items, acc=self.acc)
        fewer = dict(list(self.items.items())[:10])
        cand = trial({k: v * 0.8 for k, v in fewer.items()}, acc={k: 0.9 for k in fewer})
        self.assertFalse(decide(objective(), inc, cand).accept)

    def test_different_builds_are_not_comparable(self):
        inc = trial(self.items, acc=self.acc, env={"app_revision": "a"})
        cand = trial({k: v * 0.8 for k, v in self.items.items()}, acc=self.acc, env={"app_revision": "b"})
        self.assertFalse(decide(objective(), inc, cand).accept)

    def test_tiny_win_below_min_effect_rejected(self):
        inc = trial(self.items, acc=self.acc)
        cand = trial({k: v * 0.995 for k, v in self.items.items()}, acc=self.acc)
        verdict = decide(objective(), inc, cand)
        self.assertFalse(verdict.accept)
        self.assertFalse(verdict.inconclusive)

    def test_noisy_promising_result_is_inconclusive_not_accepted(self):
        inc = trial(self.items, acc=self.acc)
        noisy = {k: v * (0.6 if n % 2 else 1.3) for n, (k, v) in enumerate(self.items.items())}
        verdict = decide(objective(), inc, trial(noisy, acc=self.acc))
        self.assertFalse(verdict.accept)
        self.assertTrue(verdict.inconclusive, verdict.reasons)


class ClimbTests(unittest.TestCase):
    def lab(self, state):
        return hillclimb.Lab(DEMO, Path(state))

    def evaluator(self, lab, objective_id, state):
        objective = lab.registry.objectives[objective_id]
        ledger = Ledger(Path(state) / "c")
        bench = lab.bench(objective.bench, Path(state) / "w")
        return objective, ledger, Evaluator(lab.registry, objective, lab.suite(objective.suite), bench, ledger)

    def test_climb_finds_known_optimum_without_crossing_gate(self):
        with tempfile.TemporaryDirectory() as state:
            lab = self.lab(state)
            objective, ledger, evaluator = self.evaluator(lab, "demo-naming", state)
            result = climb(lab.registry, objective, evaluator, ledger, budget=30)
            self.assertAlmostEqual(result.best["demo.match_threshold"], 0.65)
            self.assertNotIn("demo.unbuilt", result.best)

    def test_latency_climb_takes_all_three_real_wins(self):
        with tempfile.TemporaryDirectory() as state:
            lab = self.lab(state)
            objective, ledger, evaluator = self.evaluator(lab, "demo-latency", state)
            result = climb(lab.registry, objective, evaluator, ledger, budget=40)
            self.assertEqual(result.best["demo.encoder"], "all")
            self.assertTrue(result.best["demo.prewarm"])
            self.assertGreaterEqual(result.best["demo.chunk_seconds"], 10.0)  # never into the lost_text zone

    def test_a_a_calibration_is_not_a_win(self):
        with tempfile.TemporaryDirectory() as state:
            lab = self.lab(state)
            objective, ledger, evaluator = self.evaluator(lab, "demo-latency", state)
            report = calibrate(objective, evaluator, lab.registry.defaults(list(objective.knobs[:3])))
            self.assertFalse(report["false_win"])

    def test_holdout_budget_is_enforced(self):
        with tempfile.TemporaryDirectory() as state:
            args = ["--config-dir", str(DEMO), "--state-dir", state]
            with redirect_stdout(io.StringIO()):
                codes = [hillclimb.main(args + ["climb", "demo-naming", "--budget", "20", "--confirm", "--seed", str(s)]) for s in range(3)]
            self.assertEqual(codes, [0, 0, 3])  # budget is 2 for demo-naming
            peeks = (Path(state) / "holdout-peeks.jsonl").read_text().splitlines()
            self.assertEqual(len(peeks), 2)
            with redirect_stdout(io.StringIO()) as out:
                hillclimb.main(args + ["leaderboard", "--json"])
            rows = json.loads(out.getvalue())
            self.assertEqual(sum(r["holdout"] == "confirmed" for r in rows), 2)


class ProtocolTests(unittest.TestCase):
    def test_validate_result_catches_bad_rows(self):
        bad = {"schema": RESULT_SCHEMA, "items": [{"id": "a", "metrics": {"x": float("nan")}}, {"id": "zzz"}]}
        problems = validate_result(bad, ["a"])
        self.assertTrue(any("finite" in p for p in problems))
        self.assertTrue(any("not requested" in p for p in problems))

    def test_command_bench_round_trip(self):
        script = textwrap.dedent(
            """
            import json, os, sys
            req = json.load(open(sys.argv[1]))
            speed = 0.5 if os.environ.get("FAST") == "1" else 1.0
            out = {"schema": "%s", "bench": "fake", "environment": {"app_revision": "r"},
                   "items": [{"id": i["id"], "metrics": {"lat": speed}, "gates": {}, "error": None} for i in req["items"]]}
            json.dump(out, open(req["result_path"], "w"))
            """ % RESULT_SCHEMA
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bench.py"
            path.write_text(script)
            bench = CommandBench(
                "fake", [sys.executable, str(path), "{request}"], repo_root=Path(tmp), timeout_seconds=30,
                env_for=lambda knobs: {"FAST": "1" if knobs.get("fast") else "0"}, work_root=Path(tmp) / "w",
            )
            request = {"trial_id": "t1", "repetition": 0, "knobs": {"fast": True}, "items": [{"id": "a"}, {"id": "b"}]}
            result = bench.run(request)
            self.assertEqual(validate_result(result, ["a", "b"]), [])
            self.assertEqual(result["items"][0]["metrics"]["lat"], 0.5)


if __name__ == "__main__":
    unittest.main()
