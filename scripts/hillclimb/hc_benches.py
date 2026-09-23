"""Bench adapters and the request/result protocol.

A bench is anything that can take a knob config plus a list of suite items and
return per-item metrics. The climber never knows how a number was produced; it
only speaks this protocol, so other labs (the speaker bake-off, the speech
model shootout, a future live-app driver) plug in by writing one result file.

Request (written by the climber, path passed as {request}):
    {"schema": "transcripted.hillclimb.request.v1", "trial_id", "objective",
     "suite", "split", "repetition", "knobs": {id: value}, "items": [...],
     "bench_options": {...}, "result_path"}

Result (written by the bench at {result}):
    {"schema": "transcripted.hillclimb.result.v1", "bench",
     "environment": {"app_revision", "host", "os", ...},
     "items": [{"id", "metrics": {name: number}, "gates": {name: count},
                "error": null | "text"}]}
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

REQUEST_SCHEMA = "transcripted.hillclimb.request.v1"
RESULT_SCHEMA = "transcripted.hillclimb.result.v1"
BENCH_KINDS = ("command", "synthetic")


class BenchError(RuntimeError):
    pass


def validate_result(result: Mapping[str, Any], expected_ids: Sequence[str]) -> list[str]:
    """Return protocol problems; an empty list means the result is usable."""
    problems = []
    if result.get("schema") != RESULT_SCHEMA:
        problems.append(f"schema must be {RESULT_SCHEMA}, got {result.get('schema')!r}")
    items = result.get("items")
    if not isinstance(items, list):
        return problems + ["items must be a list"]
    seen = set()
    for item in items:
        item_id = item.get("id") if isinstance(item, dict) else None
        if not item_id:
            problems.append("every result item needs an id")
            continue
        if item_id in seen:
            problems.append(f"duplicate result item {item_id}")
        seen.add(item_id)
        for name, value in (item.get("metrics") or {}).items():
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                problems.append(f"item {item_id} metric {name} is not a finite number")
        for name, value in (item.get("gates") or {}).items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                problems.append(f"item {item_id} gate {name} must be a non-negative int")
    unexpected = seen - set(expected_ids)
    if unexpected:
        problems.append(f"result has items that were not requested: {sorted(unexpected)}")
    return problems


class Bench:
    id: str

    def run(self, request: Mapping[str, Any]) -> dict:
        raise NotImplementedError


class CommandBench(Bench):
    """Runs an external command that speaks the protocol."""

    def __init__(
        self,
        bench_id: str,
        argv: Sequence[str],
        *,
        repo_root: Path,
        timeout_seconds: float,
        env_for: Callable[[Mapping[str, Any]], Mapping[str, str]],
        work_root: Path,
    ):
        if not argv:
            raise BenchError(f"bench {bench_id}: command is empty")
        self.id = bench_id
        self.argv = list(argv)
        self.repo_root = repo_root
        self.timeout_seconds = timeout_seconds
        self.env_for = env_for
        self.work_root = work_root

    def run(self, request: Mapping[str, Any]) -> dict:
        self.work_root.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=f"{request['trial_id']}-r{request['repetition']}-", dir=self.work_root))
        request_path = work / "request.json"
        result_path = work / "result.json"
        payload = dict(request)
        payload["result_path"] = str(result_path)
        request_path.write_text(json.dumps(payload, indent=2, sort_keys=True))
        substitutions = {
            "{request}": str(request_path),
            "{result}": str(result_path),
            "{repo}": str(self.repo_root),
            "{work}": str(work),
        }
        argv = []
        for arg in self.argv:
            for token, replacement in substitutions.items():
                arg = arg.replace(token, replacement)
            argv.append(arg)
        env = dict(os.environ)
        env.update(self.env_for(request["knobs"]))
        env["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        env["TRANSCRIPTED_HILLCLIMB_REQUEST"] = str(request_path)
        env["TRANSCRIPTED_HILLCLIMB_RESULT"] = str(result_path)
        started = time.monotonic()
        try:
            completed = subprocess.run(
                argv,
                cwd=self.repo_root,
                env=env,
                capture_output=True,
                text=True,
                timeout=self.timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise BenchError(f"bench {self.id} timed out after {self.timeout_seconds}s") from error
        except OSError as error:
            raise BenchError(f"bench {self.id} could not start: {error}") from error
        (work / "stdout.log").write_text(completed.stdout[-200_000:])
        (work / "stderr.log").write_text(completed.stderr[-200_000:])
        if completed.returncode != 0:
            tail = completed.stderr.strip().splitlines()[-5:]
            raise BenchError(f"bench {self.id} exited {completed.returncode}: {' | '.join(tail)}")
        if not result_path.exists():
            raise BenchError(f"bench {self.id} wrote no result file at {result_path}")
        try:
            result = json.loads(result_path.read_text())
        except json.JSONDecodeError as error:
            raise BenchError(f"bench {self.id} wrote invalid JSON: {error}") from error
        result.setdefault("environment", {})
        result["environment"].setdefault("bench_wall_seconds", round(time.monotonic() - started, 3))
        result["work_dir"] = str(work)
        return result


class SyntheticBench(Bench):
    """A known response surface with noise, for self-tests and dry runs.

    Each metric is  base_item * (1 + sum_k weight_k * ((x_k - optimum_k) / span_k)^2)
    plus multiplicative noise, so the true optimum is known and a correct
    climber must find it. Gates fire when a knob crosses a danger line, which
    models "faster but starts merging different people".
    """

    def __init__(self, bench_id: str, options: Mapping[str, Any], spans: Mapping[str, float]):
        self.id = bench_id
        self.metrics = options["metrics"]
        self.gates = options.get("gates", [])
        self.noise = float(options.get("noise", 0.02))
        self.seed = str(options.get("seed", "synthetic"))
        self.spans = spans

    def _surface(self, spec: Mapping[str, Any], knobs: Mapping[str, Any], item_base: float) -> float:
        penalty = 0.0
        for knob_id, weight in spec.get("weights", {}).items():
            value = knobs.get(knob_id)
            if value is None:
                continue
            optimum = spec["optimum"][knob_id]
            if isinstance(value, bool) or isinstance(optimum, str):
                penalty += weight * (0.0 if value == optimum else 1.0)
            else:
                span = self.spans.get(knob_id, 1.0) or 1.0
                penalty += weight * ((float(value) - float(optimum)) / span) ** 2
        if spec.get("direction", "lower") == "lower":
            return item_base * (1.0 + penalty)
        return max(0.0, item_base - penalty)

    def run(self, request: Mapping[str, Any]) -> dict:
        knobs = request["knobs"]
        items_out = []
        for item in request["items"]:
            item_id = str(item["id"])
            seed_text = f"{self.seed}|{request['trial_id']}|{request['repetition']}|{item_id}"
            rng = random.Random(int(hashlib.sha256(seed_text.encode()).hexdigest()[:16], 16))
            base = float(item.get("synthetic_base", 1.0))
            metrics = {}
            for spec in self.metrics:
                value = self._surface(spec, knobs, base * float(spec.get("scale", 1.0)))
                value *= 1.0 + rng.gauss(0.0, float(spec.get("noise", self.noise)))
                metrics[spec["id"]] = max(0.0, value)
            gates = {}
            for gate in self.gates:
                value = knobs.get(gate["knob"])
                fired = value is not None and (
                    (gate.get("above") is not None and value > gate["above"])
                    or (gate.get("below") is not None and value < gate["below"])
                )
                gates[gate["id"]] = 1 if fired else 0
            items_out.append({"id": item_id, "metrics": metrics, "gates": gates, "error": None})
        return {
            "schema": RESULT_SCHEMA,
            "bench": self.id,
            "environment": {"app_revision": "synthetic", "host": "synthetic", "os": "synthetic"},
            "items": items_out,
        }


def load_benches(path: Path) -> dict[str, Mapping[str, Any]]:
    raw = json.loads(path.read_text())
    benches = {}
    for bench in raw.get("benches", ()):
        bench_id = bench.get("id")
        if not bench_id:
            raise BenchError("every bench needs an id")
        if bench.get("kind") not in BENCH_KINDS:
            raise BenchError(f"bench {bench_id}: kind must be one of {BENCH_KINDS}")
        if bench["kind"] == "command" and not bench.get("command"):
            raise BenchError(f"bench {bench_id}: command benches need a command list")
        if bench_id in benches:
            raise BenchError(f"duplicate bench {bench_id}")
        benches[bench_id] = bench
    return benches
