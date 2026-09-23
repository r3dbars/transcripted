#!/usr/bin/env python3
"""Transcripted hill-climb lab: tune app knobs against scored, held-out evals.

    python3 scripts/hillclimb/hillclimb.py validate
    python3 scripts/hillclimb/hillclimb.py knobs [--area speaker] [--json]
    python3 scripts/hillclimb/hillclimb.py split SUITE
    python3 scripts/hillclimb/hillclimb.py calibrate OBJECTIVE
    python3 scripts/hillclimb/hillclimb.py climb OBJECTIVE --budget 40 [--confirm]
    python3 scripts/hillclimb/hillclimb.py confirm --campaign DIR
    python3 scripts/hillclimb/hillclimb.py leaderboard [--json]
    python3 scripts/hillclimb/hillclimb.py --self-test

A dry run on any machine (no Mac needed) uses the synthetic demo config:
    python3 scripts/hillclimb/hillclimb.py --config-dir scripts/hillclimb/fixtures/demo \\
        climb demo-latency --budget 40 --confirm

See docs/hill-climb-lab.md.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import platform
import sys
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from hc_benches import BenchError, CommandBench, SyntheticBench, load_benches  # noqa: E402
from hc_engine import (  # noqa: E402
    Evaluator,
    Ledger,
    config_hash,
    diff_from,
    holdout_peeks,
    record_holdout_peek,
)
from hc_registry import Registry, RegistryError, load_registry  # noqa: E402
from hc_search import calibrate, climb, confirm_on_holdout  # noqa: E402
from hc_splits import SPLITS, Suite, check_split_health  # noqa: E402

REPO_ROOT = HERE.parents[1]
DEFAULT_CONFIG_DIR = REPO_ROOT / "config" / "hillclimb"


def default_state_dir() -> Path:
    override = os.environ.get("TRANSCRIPTED_HILLCLIMB_STATE_DIR")
    if override:
        return Path(override).expanduser()
    if platform.system() == "Darwin":
        return Path.home() / "Library/Application Support/Transcripted Lab/HillClimb"
    return REPO_ROOT / "build" / "hillclimb"


class Lab:
    def __init__(self, config_dir: Path, state_dir: Path):
        self.config_dir = config_dir
        self.state_dir = state_dir
        self.registry: Registry = load_registry(config_dir / "knobs.json", config_dir / "objectives.json")
        self.benches = load_benches(config_dir / "benches.json")
        self._suites: dict[str, Suite] = {}

    def suite(self, suite_id: str) -> Suite:
        if suite_id not in self._suites:
            path = self.config_dir / "suites" / f"{suite_id}.json"
            if not path.exists():
                raise RegistryError(f"suite {suite_id} has no file at {path}")
            raw = json.loads(path.read_text())
            items_file = raw.get("items_file")
            if items_file:
                # Real corpora live on the Mac, outside git. The suite file keeps
                # the salt and split rule; the item list comes from the local file.
                local = Path(os.path.expandvars(items_file)).expanduser()
                if not local.is_absolute():
                    local = REPO_ROOT / local
                if not local.exists():
                    raise RegistryError(f"suite {suite_id}: items_file {local} not found on this machine")
                raw = {**raw, "items": json.loads(local.read_text())["items"]}
            self._suites[suite_id] = Suite.from_dict(raw)
        return self._suites[suite_id]

    def bench(self, bench_id: str, work_root: Path):
        if bench_id not in self.benches:
            raise RegistryError(f"unknown bench {bench_id}")
        spec = self.benches[bench_id]
        if spec["kind"] == "synthetic":
            spans = {
                k.id: float(k.maximum - k.minimum)
                for k in self.registry.knobs.values()
                if k.type in ("int", "float")
            }
            return SyntheticBench(bench_id, spec["synthetic"], spans)
        return CommandBench(
            bench_id,
            spec["command"],
            repo_root=REPO_ROOT,
            timeout_seconds=float(spec.get("timeout_seconds", 3600)),
            env_for=self.registry.env_for,
            work_root=work_root,
        )

    def validate(self) -> list[str]:
        problems = []
        for objective in self.registry.objectives.values():
            if objective.bench not in self.benches:
                problems.append(f"objective {objective.id}: unknown bench {objective.bench}")
            suite_path = self.config_dir / "suites" / f"{objective.suite}.json"
            if not suite_path.exists():
                problems.append(f"objective {objective.id}: no suite file {suite_path.name}")
                continue
            raw = json.loads(suite_path.read_text())
            if raw.get("items_file"):
                continue  # items live on the Mac; checked when the suite loads there
            try:
                problems += check_split_health(self.suite(objective.suite))
            except (RegistryError, ValueError) as error:
                problems.append(str(error))
        return problems


def new_campaign_dir(lab: Lab, objective_id: str, seed: int, kind: str = "climb") -> Path:
    stamp = _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = lab.state_dir / objective_id
    for attempt in range(100):
        suffix = f"-{attempt}" if attempt else ""
        root = base / f"{stamp}-{kind}-s{seed}{suffix}"
        try:
            root.mkdir(parents=True, exist_ok=False)
            return root
        except FileExistsError:
            continue
    raise RuntimeError(f"could not create a campaign directory under {base}")


def git_revision() -> str:
    head = REPO_ROOT / ".git" / "HEAD"
    try:
        ref = head.read_text().strip()
        if ref.startswith("ref: "):
            return (REPO_ROOT / ".git" / ref[5:]).read_text().strip()[:12]
        return ref[:12]
    except OSError:
        return "unknown"


def cmd_validate(lab: Lab, args) -> int:
    problems = lab.validate()
    for problem in problems:
        print(f"FAIL {problem}")
    counts = {}
    for knob in lab.registry.knobs.values():
        counts[knob.status] = counts.get(knob.status, 0) + 1
    print(
        f"{len(lab.registry.knobs)} knobs ({', '.join(f'{v} {k}' for k, v in sorted(counts.items()))}), "
        f"{len(lab.registry.objectives)} objectives, {len(lab.benches)} benches"
    )
    return 1 if problems else 0


def cmd_knobs(lab: Lab, args) -> int:
    knobs = [k for k in lab.registry.knobs.values() if not args.area or k.area == args.area]
    if args.json:
        print(json.dumps([k.__dict__ for k in knobs], indent=2, default=list))
        return 0
    for knob in knobs:
        span = (
            f"{knob.minimum}..{knob.maximum} step {knob.step}"
            if knob.type in ("int", "float")
            else "|".join(map(str, knob.choices)) if knob.type == "enum" else "bool"
        )
        via = ",".join(f"{a['via']}:{a['name']}" for a in knob.apply) or "-"
        print(f"{knob.status:10} {knob.id:48} default={knob.default!s:10} {span:28} {via}")
    return 0


def cmd_split(lab: Lab, args) -> int:
    suite = lab.suite(args.suite)
    print(f"suite {suite.id} fingerprint {suite.fingerprint()} salt {suite.salt!r}")
    for split in SPLITS:
        ids = [str(i["id"]) for i in suite.items_in(split)]
        print(f"{split:8} {len(ids):4}  {', '.join(ids[:12])}{' ...' if len(ids) > 12 else ''}")
    return 0


def _setup(lab: Lab, objective_id: str, campaign: Path, repetitions: int | None):
    if objective_id not in lab.registry.objectives:
        raise RegistryError(f"unknown objective {objective_id}")
    objective = lab.registry.objectives[objective_id]
    suite = lab.suite(objective.suite)
    problems = check_split_health(suite)
    if problems:
        raise RegistryError("; ".join(problems))
    ledger = Ledger(campaign)
    bench = lab.bench(objective.bench, campaign / "work")
    evaluator = Evaluator(lab.registry, objective, suite, bench, ledger, repetitions=repetitions)
    return objective, suite, ledger, evaluator


def cmd_calibrate(lab: Lab, args) -> int:
    campaign = new_campaign_dir(lab, args.objective, args.seed, "calibrate")
    objective, suite, ledger, evaluator = _setup(lab, args.objective, campaign, args.repetitions)
    config = lab.registry.defaults([k.id for k in lab.registry.searchable_knobs(objective)])
    report = calibrate(objective, evaluator, config, seed=args.seed)
    ledger.write_json("calibration.json", report)
    print(json.dumps({k: v for k, v in report.items() if k != "verdict"}, indent=2))
    if report["false_win"]:
        print("A/A run called itself a win: the bench is too noisy for this min_effect. Add repetitions or items.")
    return 0 if report["healthy"] else 1


def _confirm(lab: Lab, objective, suite, ledger, evaluator, best: dict, args, campaign: Path) -> int:
    peeks = holdout_peeks(lab.state_dir, objective.id, suite.fingerprint())
    if len(peeks) >= objective.holdout_peek_budget and not args.force_holdout:
        print(
            f"Holdout budget spent: {len(peeks)} of {objective.holdout_peek_budget} checks already used "
            f"for {objective.id} on suite {suite.fingerprint()}. Grow the suite (new items change the "
            f"fingerprint) instead of peeking again."
        )
        return 3
    defaults = lab.registry.defaults(list(best))
    if config_hash(defaults) == config_hash(best):
        print("Nothing to confirm: the best config is the shipped defaults.")
        return 0
    confirmation = confirm_on_holdout(lab.registry, objective, evaluator, ledger, best, seed=args.seed)
    record_holdout_peek(
        lab.state_dir,
        {
            "objective": objective.id,
            "suite_fingerprint": suite.fingerprint(),
            "campaign": str(campaign),
            "config_hash": config_hash(best),
            "confirmed": confirmation.confirmed,
        },
    )
    payload = {
        "objective": objective.id,
        "suite_fingerprint": suite.fingerprint(),
        "confirmed": confirmation.confirmed,
        "changes": confirmation.changes,
        "reasons": confirmation.reasons,
        "verdict": confirmation.verdict,
        "baseline_trial": confirmation.baseline_trial.trial_id,
        "candidate_trial": confirmation.candidate_trial.trial_id,
        "apply": {
            knob_id: {
                "source": lab.registry.knobs[knob_id].source,
                "from": change[0],
                "to": change[1],
            }
            for knob_id, change in confirmation.changes.items()
        },
    }
    ledger.write_json("confirmation.json", payload)
    if confirmation.confirmed:
        ledger.write_json("recommendation.json", payload)
        print("CONFIRMED on holdout. Recommendation written to", campaign / "recommendation.json")
    else:
        print("NOT confirmed on holdout:", "; ".join(confirmation.reasons))
    return 0


def cmd_climb(lab: Lab, args) -> int:
    campaign = new_campaign_dir(lab, args.objective, args.seed)
    objective, suite, ledger, evaluator = _setup(lab, args.objective, campaign, args.repetitions)
    ledger.write_json(
        "campaign.json",
        {
            "objective": objective.id,
            "suite": suite.id,
            "suite_fingerprint": suite.fingerprint(),
            "bench": objective.bench,
            "budget": args.budget,
            "seed": args.seed,
            "git_revision": git_revision(),
            "repetitions": evaluator.repetitions,
            "only_knobs": args.knobs or [],
        },
    )
    result = climb(
        lab.registry,
        objective,
        evaluator,
        ledger,
        budget=args.budget,
        seed=args.seed,
        only_knobs=args.knobs,
    )
    changes = diff_from(result.start, result.best)
    ledger.write_json(
        "climb-result.json",
        {
            "start": result.start,
            "best": result.best,
            "changes": changes,
            "trials_used": result.trials_used,
            "accepted_moves": result.accepted_moves,
            "stopped_because": result.stopped_because,
        },
    )
    print(f"campaign {campaign}")
    print(f"{result.trials_used} candidate trials, stopped: {result.stopped_because}")
    for move in result.accepted_moves:
        p = move["primary"]
        print(f"  move {move['move']}: {move['knob']} {move['from']} -> {move['to']}  {p['mean']:+.4f} (CI {p['ci_low']:+.4f}..{p['ci_high']:+.4f})")
    if not changes:
        print("No change beat the shipped defaults on dev.")
    if args.confirm and changes:
        return _confirm(lab, objective, suite, ledger, evaluator, result.best, args, campaign)
    return 0


def cmd_confirm(lab: Lab, args) -> int:
    campaign = Path(args.campaign).expanduser()
    meta = json.loads((campaign / "campaign.json").read_text())
    best = json.loads((campaign / "climb-result.json").read_text())["best"]
    objective, suite, ledger, evaluator = _setup(lab, meta["objective"], campaign, args.repetitions)
    if suite.fingerprint() != meta["suite_fingerprint"]:
        print("Suite changed since this campaign ran; re-run the climb on the new suite.")
        return 2
    return _confirm(lab, objective, suite, ledger, evaluator, best, args, campaign)


def collect_leaderboard(state_dir: Path) -> list[dict[str, Any]]:
    rows = []
    for meta_path in sorted(state_dir.glob("*/*/campaign.json")):
        campaign = meta_path.parent
        meta = json.loads(meta_path.read_text())
        climb_path = campaign / "climb-result.json"
        if not climb_path.exists():
            continue
        result = json.loads(climb_path.read_text())
        confirmation = campaign / "confirmation.json"
        holdout = json.loads(confirmation.read_text()) if confirmation.exists() else None
        dev_gain = sum(m["primary"]["mean"] for m in result["accepted_moves"])
        holdout_gain = holdout["verdict"]["primary"]["mean"] if holdout else None
        rows.append(
            {
                "objective": meta["objective"],
                "campaign": campaign.name,
                "git_revision": meta.get("git_revision"),
                "trials": result["trials_used"],
                "changes": result["changes"],
                "dev_gain": round(dev_gain, 4),
                "holdout": None if holdout is None else ("confirmed" if holdout["confirmed"] else "rejected"),
                "holdout_gain": None if holdout_gain is None else round(holdout_gain, 4),
            }
        )
    rows.sort(key=lambda r: (r["objective"], r["holdout"] != "confirmed", -(r["holdout_gain"] or r["dev_gain"])))
    return rows


def cmd_leaderboard(lab: Lab, args) -> int:
    rows = collect_leaderboard(lab.state_dir)
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    if not rows:
        print(f"No campaigns yet under {lab.state_dir}")
        return 0
    lines = [
        "| objective | campaign | holdout | holdout gain | dev gain | trials | changes |",
        "|---|---|---|---:|---:|---:|---|",
    ]
    for r in rows:
        changes = ", ".join(f"{k}: {v[0]}→{v[1]}" for k, v in r["changes"].items()) or "none"
        gain = "" if r["holdout_gain"] is None else f"{r['holdout_gain']:+.4f}"
        lines.append(
            f"| {r['objective']} | {r['campaign']} | {r['holdout'] or 'not run'} | {gain} | "
            f"{r['dev_gain']:+.4f} | {r['trials']} | {changes} |"
        )
    text = "\n".join(lines)
    print(text)
    (lab.state_dir / "LEADERBOARD.md").write_text("# Hill-climb leaderboard\n\n" + text + "\n")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config-dir", type=Path, default=DEFAULT_CONFIG_DIR)
    parser.add_argument("--state-dir", type=Path, default=None)
    parser.add_argument("--self-test", action="store_true", help="run the lab's own unit tests")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("validate", help="check knobs, objectives, benches and suites")
    knobs = sub.add_parser("knobs", help="list the knob registry")
    knobs.add_argument("--area")
    knobs.add_argument("--json", action="store_true")
    split = sub.add_parser("split", help="show a suite's dev/holdout split")
    split.add_argument("suite")

    for name, helptext in (
        ("calibrate", "A/A noise check: defaults vs defaults"),
        ("climb", "hill-climb one objective on the dev split"),
    ):
        p = sub.add_parser(name, help=helptext)
        p.add_argument("objective")
        p.add_argument("--seed", type=int, default=0)
        p.add_argument("--repetitions", type=int, default=None)
        if name == "climb":
            p.add_argument("--budget", type=int, default=30, help="max candidate trials")
            p.add_argument("--knobs", nargs="*", help="only search these knob ids")
            p.add_argument("--confirm", action="store_true", help="check the winner on holdout right away")
            p.add_argument("--force-holdout", action="store_true", help="ignore the holdout peek budget (logged)")

    confirm = sub.add_parser("confirm", help="check a finished climb's winner on the locked holdout")
    confirm.add_argument("--campaign", required=True)
    confirm.add_argument("--seed", type=int, default=0)
    confirm.add_argument("--repetitions", type=int, default=None)
    confirm.add_argument("--force-holdout", action="store_true")

    board = sub.add_parser("leaderboard", help="every campaign, best first")
    board.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        import unittest

        loader = unittest.defaultTestLoader
        suite = unittest.TestSuite()
        # benches/ has no __init__.py on purpose (adapters run as scripts), so
        # discovery does not recurse into it; load its tests explicitly.
        for folder in (HERE, HERE / "benches"):
            if folder.is_dir():
                sys.path.insert(0, str(folder))
                suite.addTests(loader.discover(str(folder), pattern="test_*.py", top_level_dir=str(folder)))
        outcome = unittest.TextTestRunner(verbosity=1).run(suite)
        return 0 if outcome.wasSuccessful() else 1
    if not args.command:
        parser.print_help()
        return 0
    state_dir = args.state_dir or default_state_dir()
    try:
        lab = Lab(args.config_dir, state_dir)
        handler = {
            "validate": cmd_validate,
            "knobs": cmd_knobs,
            "split": cmd_split,
            "calibrate": cmd_calibrate,
            "climb": cmd_climb,
            "confirm": cmd_confirm,
            "leaderboard": cmd_leaderboard,
        }[args.command]
        return handler(lab, args)
    except (RegistryError, BenchError, ValueError, FileNotFoundError) as error:
        print(f"hillclimb: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
