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
from hc_engine import Evaluator, Ledger, Trial, decide, holdout_peeks  # noqa: E402
from hc_registry import Knob, Objective, RegistryError, load_registry  # noqa: E402
from hc_search import calibrate, climb, replay_decisions  # noqa: E402
from hc_splits import DEV, HOLDOUT, Suite, check_split_health  # noqa: E402
from hc_stats import (  # noqa: E402
    bootstrap_mean_ci,
    improvement,
    null_accept_rate,
    paired_compare,
    percentile,
    sign_flip_pvalue,
)

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
            peeks = [json.loads(line) for line in (Path(state) / "holdout-peeks.jsonl").read_text().splitlines()]
            self.assertEqual([p["status"] for p in peeks], ["started", "finished", "started", "finished"])
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


class SmallSampleTests(unittest.TestCase):
    """Review S4/S5/S7: small or correlated samples must not look like wins."""

    def test_sign_flip_is_exact_for_small_n(self):
        self.assertEqual(sign_flip_pvalue([1.0] * 4), 1 / 16)
        self.assertEqual(sign_flip_pvalue([1.0] * 5), 1 / 32)
        self.assertEqual(sign_flip_pvalue([0.0, 0.0, 0.0]), 1.0)
        # Shifting the null turns "is it better" into "is it no worse than -m".
        self.assertLess(sign_flip_pvalue([0.0] * 8, shift=-0.01), 0.01)

    def test_sign_flip_holds_its_level_under_the_null(self):
        import random

        rng = random.Random(3)
        hits = sum(
            sign_flip_pvalue([rng.gauss(0, 1) for _ in range(12)], seed=k) < 0.05 for k in range(400)
        )
        self.assertLess(hits / 400, 0.08)

    def test_four_items_can_never_win(self):
        items = {f"i{k}": 1.0 for k in range(4)}
        acc = {k: 0.9 for k in items}
        verdict = decide(objective(), trial(items, acc=acc), trial({k: 0.5 for k in items}, acc=acc))
        self.assertFalse(verdict.accept)
        self.assertIn("not significant", " ".join(verdict.reasons))

    def test_one_item_can_never_win(self):
        verdict = decide(objective(), trial({"a": 1.0}, acc={"a": 0.9}), trial({"a": 0.5}, acc={"a": 0.9}))
        self.assertFalse(verdict.accept)

    def test_clusters_count_once(self):
        items = {f"i{k}": 1.0 for k in range(20)}
        acc = {k: 0.9 for k in items}
        fast = {k: 0.8 for k in items}
        clusters = {k: f"c{int(k[1:]) % 3}" for k in items}  # 20 items, 3 real units
        verdict = decide(objective(), trial(items, acc=acc), trial(fast, acc=acc), clusters=clusters)
        self.assertFalse(verdict.accept)
        self.assertEqual(verdict.primary["n"], 3)
        self.assertEqual(verdict.primary["items"], 20)

    def test_guardrail_with_no_data_rejects(self):
        items = {f"i{k}": 1.0 + k * 0.1 for k in range(20)}
        verdict = decide(objective(), trial(items), trial({k: v * 0.8 for k, v in items.items()}))
        self.assertFalse(verdict.accept)
        self.assertFalse(verdict.inconclusive)
        self.assertIn("guardrail acc: measured on 0 units", " ".join(verdict.reasons))

    def test_guardrail_on_a_few_items_rejects(self):
        items = {f"i{k}": 1.0 + k * 0.1 for k in range(20)}
        some = {k: 0.9 for k in list(items)[:6]}
        inc = trial(items, acc={k: 0.9 for k in items})
        cand = trial({k: v * 0.8 for k, v in items.items()}, acc={k: 0.9 for k in items})
        # Both sides measured the guardrail on only 6 of 20 items.
        for t in (inc, cand):
            for row in t.repetitions[0]["items"]:
                if row["id"] not in some:
                    row["metrics"].pop("acc")
        verdict = decide(objective(), inc, cand)
        self.assertFalse(verdict.accept)
        self.assertIn("need at least 10", " ".join(verdict.reasons))

    def test_guardrail_margin_must_be_positive(self):
        with self.assertRaises(RegistryError):
            objective(guardrails=[{"id": "acc", "direction": "higher", "compare": "difference", "max_regression": 0}])

    def test_rebuild_between_repetitions_is_not_comparable(self):
        items = {f"i{k}": 1.0 + k * 0.1 for k in range(20)}
        acc = {k: 0.9 for k in items}
        inc = trial(items, acc=acc)
        cand = trial({k: v * 0.8 for k, v in items.items()}, acc=acc)
        for t, rev in ((inc, "b"), (cand, "a")):
            second = json.loads(json.dumps(t.repetitions[0]))
            second["environment"] = {"app_revision": rev}
            t.repetitions.append(second)
        verdict = decide(objective(), inc, cand)
        self.assertFalse(verdict.accept)
        self.assertIn("changed between repetitions", " ".join(verdict.reasons))

    def test_null_accept_rate_is_small_at_real_sizes(self):
        self.assertEqual(null_accept_rate(3, sd=0.1, min_effect=0.05, alpha=0.05, trials=200), 0.0)
        self.assertLessEqual(null_accept_rate(12, sd=0.1, min_effect=0.05, alpha=0.05, trials=300), 0.06)

    def test_suite_below_minimum_units_refuses_to_climb(self):
        with tempfile.TemporaryDirectory() as state:
            config = Path(state) / "cfg"
            config.mkdir()
            for name in ("knobs.json", "objectives.json", "benches.json"):
                (config / name).write_text((DEMO / name).read_text())
            (config / "suites").mkdir()
            raw = json.loads((DEMO / "suites" / "demo-clips.json").read_text())
            raw["items"] = raw["items"][:14]  # 13 dev, 1 holdout
            (config / "suites" / "demo-clips.json").write_text(json.dumps(raw))
            err = io.StringIO()
            from contextlib import redirect_stderr

            with redirect_stdout(io.StringIO()) as out, redirect_stderr(err):
                code = hillclimb.main(["--config-dir", str(config), "--state-dir", state, "climb", "demo-latency"])
                vcode = hillclimb.main(["--config-dir", str(config), "--state-dir", state, "validate"])
            self.assertEqual(code, 2)
            self.assertIn("independent units", err.getvalue())
            self.assertEqual(vcode, 0)  # well-formed config, just blocked
            self.assertIn("BLOCKED", out.getvalue())

    def test_guardrail_item_field_missing_blocks(self):
        obj = objective(
            guardrails=[
                {"id": "acc", "direction": "higher", "compare": "difference", "max_regression": 0.01,
                 "requires_item_field": "truth"}
            ]
        )
        suite = Suite.from_dict(
            {"id": "s", "salt": "x", "holdout_fraction": 0.3, "items": [{"id": f"m{k}"} for k in range(40)]}
        )
        problems = hillclimb.readiness_problems(obj, suite)
        self.assertTrue(any("needs item field 'truth'" in p for p in problems), problems)

    def test_real_speaker_suite_is_blocked_by_clusters(self):
        lab = hillclimb.Lab(REAL, Path(tempfile.mkdtemp()))
        objective_ = lab.registry.objectives["speaker-naming-across-calls"]
        problems = hillclimb.readiness_problems(objective_, lab.suite(objective_.suite))
        self.assertTrue(any("independent units" in p for p in problems), problems)
        self.assertTrue(objective_.post_confirm_checks)

    def test_clusters_never_straddle_the_holdout(self):
        items = [{"id": f"a{k}", "cluster": f"c{k // 4}"} for k in range(80)]
        suite = Suite.from_dict({"id": "s", "salt": "x", "holdout_fraction": 0.3, "items": items})
        self.assertEqual(check_split_health(suite), [])
        pinned = [{"id": "a", "cluster": "c", "split": DEV}, {"id": "b", "cluster": "c", "split": HOLDOUT}]
        bad = Suite.from_dict({"id": "s", "salt": "x", "holdout_fraction": 0.3, "items": pinned})
        self.assertTrue(any("both sides" in p for p in check_split_health(bad)))


class HoldoutHygieneTests(unittest.TestCase):
    """Review S6/M4: the holdout budget can't be reset by adding an item."""

    def _demo_copy(self, root: Path) -> Path:
        config = root / "cfg"
        (config / "suites").mkdir(parents=True)
        for name in ("knobs.json", "objectives.json", "benches.json"):
            (config / name).write_text((DEMO / name).read_text())
        (config / "suites" / "demo-clips.json").write_text((DEMO / "suites" / "demo-clips.json").read_text())
        return config

    def test_adding_one_item_does_not_reset_the_budget(self):
        with tempfile.TemporaryDirectory() as state:
            config = self._demo_copy(Path(state))
            args = ["--config-dir", str(config), "--state-dir", state]
            with redirect_stdout(io.StringIO()):
                codes = [hillclimb.main(args + ["climb", "demo-naming", "--budget", "20", "--confirm", "--seed", str(s)]) for s in range(2)]
            self.assertEqual(codes, [0, 0])
            suite_path = config / "suites" / "demo-clips.json"
            raw = json.loads(suite_path.read_text())
            raw["items"].append({"id": "clip-new", "synthetic_base": 1.0})
            suite_path.write_text(json.dumps(raw))
            with redirect_stdout(io.StringIO()) as out:
                code = hillclimb.main(args + ["climb", "demo-naming", "--budget", "20", "--confirm", "--seed", "9"])
            self.assertEqual(code, 3, out.getvalue())

    def test_forced_peek_is_recorded(self):
        with tempfile.TemporaryDirectory() as state:
            args = ["--config-dir", str(DEMO), "--state-dir", state]
            with redirect_stdout(io.StringIO()):
                for s in range(3):
                    hillclimb.main(args + ["climb", "demo-naming", "--budget", "20", "--confirm", "--force-holdout", "--seed", str(s)])
            rows = [json.loads(line) for line in (Path(state) / "holdout-peeks.jsonl").read_text().splitlines()]
            rows = [r for r in rows if r["status"] == "started"]
            self.assertEqual([r["forced"] for r in rows], [False, False, True])
            self.assertTrue(all(r["holdout_items"] for r in rows))

    def test_holdout_per_item_values_stay_out_of_the_ledger(self):
        with tempfile.TemporaryDirectory() as state:
            args = ["--config-dir", str(DEMO), "--state-dir", state]
            with redirect_stdout(io.StringIO()):
                hillclimb.main(args + ["climb", "demo-naming", "--budget", "20", "--confirm"])
            trials = [
                json.loads(line)
                for path in Path(state).glob("demo-naming/*/trials.jsonl")
                for line in path.read_text().splitlines()
            ]
            holdout = [t for t in trials if t["split"] == HOLDOUT]
            self.assertTrue(holdout)
            self.assertTrue(all(t["per_item"] == "sealed" for t in holdout))
            self.assertTrue(all(isinstance(t["per_item"], dict) for t in trials if t["split"] == DEV))
            rec = json.loads(next(Path(state).glob("demo-naming/*/confirmation.json")).read_text())
            self.assertGreaterEqual(rec["holdout"]["units"], 8)

    def test_a_crashed_holdout_check_still_counts(self):
        # Review N3: the peek is written before the holdout run starts.
        import hc_search

        with tempfile.TemporaryDirectory() as state:
            args = ["--config-dir", str(DEMO), "--state-dir", state]
            real = hillclimb.confirm_on_holdout

            def crash(*a, **k):
                raise KeyboardInterrupt

            hillclimb.confirm_on_holdout = crash
            try:
                with redirect_stdout(io.StringIO()), self.assertRaises(KeyboardInterrupt):
                    hillclimb.main(args + ["climb", "demo-naming", "--budget", "20", "--confirm"])
            finally:
                hillclimb.confirm_on_holdout = real
            rows = [json.loads(line) for line in (Path(state) / "holdout-peeks.jsonl").read_text().splitlines()]
            self.assertEqual([r["status"] for r in rows], ["started"])
            lab = hillclimb.Lab(DEMO, Path(state))
            holdout = [str(i["id"]) for i in lab.suite("demo-clips").items_in(HOLDOUT)]
            self.assertEqual(len(holdout_peeks(Path(state), "demo-naming", holdout)), 1)
            self.assertIs(hc_search.confirm_on_holdout, real)

    def test_legacy_peek_rows_count_by_fingerprint(self):
        with tempfile.TemporaryDirectory() as state:
            (Path(state) / "holdout-peeks.jsonl").write_text(
                json.dumps({"objective": "o", "suite_fingerprint": "f"}) + "\n"
            )
            self.assertEqual(len(holdout_peeks(Path(state), "o", ["a"], "f")), 1)
            self.assertEqual(len(holdout_peeks(Path(state), "o", ["a"], "g")), 0)


class ResumeTests(unittest.TestCase):
    """Review M1/M3: checkpoints, resume, and pooled re-measures."""

    def test_replay_rebuilds_incumbent_and_budget(self):
        decisions = [
            {"kind": "decision", "knob": "k", "from": 1, "to": 2, "scale": 1.0, "accept": False, "primary": {}, "candidate_trial": "t2"},
            {"kind": "remeasure", "knob": "k", "from": 1, "to": 0, "scale": 1.0},
            {"kind": "decision", "knob": "k", "from": 1, "to": 0, "scale": 1.0, "accept": True, "primary": {"mean": 0.1}, "candidate_trial": "t6"},
            {"kind": "decision", "knob": "j", "from": "a", "to": "b", "scale": 0.5, "accept": False, "primary": {}, "candidate_trial": "t8"},
        ]
        state = replay_decisions({"k": 1, "j": "a"}, decisions)
        self.assertEqual(state.incumbent, {"k": 0, "j": "a"})
        self.assertEqual(state.trials_used, 4)
        self.assertEqual(state.scale, 0.5)
        self.assertEqual(len(state.accepted_moves), 1)
        self.assertEqual(len(state.tried), 4)

    def test_interrupted_climb_resumes(self):
        with tempfile.TemporaryDirectory() as state:
            args = ["--config-dir", str(DEMO), "--state-dir", state]
            with redirect_stdout(io.StringIO()):
                hillclimb.main(args + ["climb", "demo-latency", "--budget", "4"])
            campaign = next(Path(state).glob("demo-latency/*-climb-*"))
            first = json.loads((campaign / "climb-result.json").read_text())
            self.assertEqual(first["status"], "finished")
            with redirect_stdout(io.StringIO()) as out:
                code = hillclimb.main(args + ["climb", "demo-latency", "--budget", "40", "--resume", str(campaign)])
            self.assertEqual(code, 0, out.getvalue())
            self.assertIn("resuming", out.getvalue())
            final = json.loads((campaign / "climb-result.json").read_text())
            self.assertGreater(final["trials_used"], first["trials_used"])
            self.assertEqual(final["best"]["demo.encoder"], "all")

    def test_pooled_trial_keeps_every_repetition(self):
        a, b = trial({"x": 1.0}), trial({"x": 2.0})
        pooled = Trial.pooled(a, b)
        self.assertEqual(len(pooled.repetitions), 2)
        self.assertEqual(pooled.per_item("lat", "median"), {"x": 1.5})


class MalformedResultTests(unittest.TestCase):
    def test_non_object_results_become_problems_not_crashes(self):
        self.assertTrue(validate_result([1, 2], ["a"]))
        bad = {"schema": RESULT_SCHEMA, "items": [{"id": "a", "metrics": [1], "gates": "x", "error": 3}]}
        problems = validate_result(bad, ["a"])
        self.assertTrue(any("metrics must be an object" in p for p in problems), problems)
        self.assertTrue(any("gates must be an object" in p for p in problems), problems)

    def test_holdout_runs_write_to_the_sealed_folder(self):
        script = textwrap.dedent(
            """
            import json, sys
            req = json.load(open(sys.argv[1]))
            out = {"schema": "%s", "bench": "fake", "environment": {"app_revision": "r"},
                   "items": [{"id": i["id"], "metrics": {"lat": 1.0}, "gates": {}, "error": None} for i in req["items"]]}
            json.dump(out, open(req["result_path"], "w"))
            """ % RESULT_SCHEMA
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bench.py"
            path.write_text(script)
            bench = CommandBench(
                "fake", [sys.executable, str(path), "{request}"], repo_root=Path(tmp), timeout_seconds=30,
                env_for=lambda knobs: {}, work_root=Path(tmp) / "w",
            )
            result = bench.run({"trial_id": "t1", "repetition": 0, "split": HOLDOUT, "knobs": {}, "items": [{"id": "a"}]})
            self.assertIn("holdout-sealed", result["work_dir"])

    def test_bench_that_writes_a_list_is_a_bench_error(self):
        from hc_benches import BenchError

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bench.py"
            path.write_text("import json,sys\nreq=json.load(open(sys.argv[1]))\njson.dump([1], open(req['result_path'],'w'))\n")
            bench = CommandBench(
                "fake", [sys.executable, str(path), "{request}"], repo_root=Path(tmp), timeout_seconds=30,
                env_for=lambda knobs: {}, work_root=Path(tmp) / "w",
            )
            with self.assertRaises(BenchError):
                bench.run({"trial_id": "t1", "repetition": 0, "split": DEV, "knobs": {}, "items": [{"id": "a"}]})


if __name__ == "__main__":
    unittest.main()
