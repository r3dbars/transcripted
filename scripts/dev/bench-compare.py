#!/usr/bin/env python3
"""Turn bench-all.sh runs into one flat summary, and compare two of them.

    python3 scripts/dev/bench-compare.py --summarize build/benchmarks/<label>
    python3 scripts/dev/bench-compare.py build/benchmarks/<before> build/benchmarks/<after>
    python3 scripts/dev/bench-compare.py --self-test

bench-all.sh writes each benchmark in its own shape (launch JSON, a Home
markdown table, dictation-stop JSONL, real-usage percentiles). This flattens a
run into `summary.json`: one row per metric, all in milliseconds, with
p50/p95/p99 and a sample count. Comparing two runs prints a before/after table
so every speed claim in a PR can quote the same numbers.

A change counts as real only when it clears both a relative and an absolute
floor (default 5% and 5 ms). Anything smaller reads "same": wall clock on one
Mac is noisy, and a 2 ms "win" on a 300 ms path is not one.

The summary holds only numbers and metric names; no transcript text, paths, or
device names.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import tempfile
from pathlib import Path

PERCENTILES = ("p50", "p95", "p99")


def pct(ordered: list[float], q: float) -> float:
    """Nearest-rank percentile, same as latency-percentiles.py."""
    rank = max(1, min(len(ordered), math.ceil(q * len(ordered))))
    return ordered[rank - 1]


def stats(values: list[float]) -> dict:
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "p50": round(pct(ordered, 0.50), 1),
        "p95": round(pct(ordered, 0.95), 1),
        "p99": round(pct(ordered, 0.99), 1),
    }


def launch_metrics(path: Path, name: str) -> dict:
    if not path.is_file():
        return {}
    block = json.loads(path.read_text()).get("launchToInteractiveMs") or {}
    if "p50" not in block:
        return {}
    return {name: {"n": json.loads(path.read_text()).get("collectedSamples", 0),
                   **{p: block.get(p) for p in PERCENTILES}}}


HOME_ROW = re.compile(r"^\|\s*(\d+)\s*\|(.*)\|\s*$")
SEARCH_LINE = re.compile(
    r"meeting search @ (\d+) captures: cold index ([\d.]+)ms, cached index ([\d.]+)ms, "
    r"warm rebuild\+search avg ([\d.]+)ms")


def home_metrics(path: Path) -> dict:
    """Parse benchmark-home-recent-captures.sh's markdown table.

    Columns: captures | meetings | dictations | reps | raw load ms | avg load ms
    | best load ms | cancel ms. The loader reports averages, not percentiles, so
    p50/p95/p99 all carry the average and n is the repetition count.
    """
    if not path.is_file():
        return {}
    out = {}
    for line in path.read_text().splitlines():
        search = SEARCH_LINE.search(line)
        if search:
            captures = search.group(1)
            for label, value in (("cold_index_ms", search.group(2)), ("cached_index_ms", search.group(3)),
                                 ("warm_search_ms", search.group(4))):
                out[f"home.search.{label}.{captures}_captures"] = {
                    "n": 1, **{p: round(float(value), 1) for p in PERCENTILES}}
            continue
        match = HOME_ROW.match(line.strip())
        if not match:
            continue
        cells = [c.strip() for c in match.group(2).split("|")]
        if len(cells) < 7:
            continue
        captures = match.group(1)
        try:
            reps = int(cells[2])
            avg_load = float(cells[4])
            cancel = float(cells[6])
        except ValueError:
            continue
        for metric, value in ((f"home.load_ms.{captures}_captures", avg_load),
                              (f"home.cancel_ms.{captures}_captures", cancel)):
            out[metric] = {"n": reps, **{p: round(value, 1) for p in PERCENTILES}}
    return out


DICTATION_STOP_FIELDS = {
    "stop_to_text_s": "stop_to_text_ms",
    "stop_to_delivery_s": "stop_to_delivery_ms",
    "stop_to_saved_s": "stop_to_saved_ms",
    "decode_s": "decode_ms",
}


def dictation_stop_metrics(path: Path) -> dict:
    if not path.is_file():
        return {}
    grouped: dict[str, list[float]] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("record_type") != "case_result":
            continue
        case = re.sub(r"[^a-z0-9_]", "_", str(row.get("case_id", "case")).lower())
        for field, metric in DICTATION_STOP_FIELDS.items():
            value = row.get(field)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                grouped.setdefault(f"dictation_stop.{metric}.{case}", []).append(value * 1000.0)
    return {name: stats(values) for name, values in grouped.items()}


def real_usage_metrics(path: Path) -> dict:
    if not path.is_file():
        return {}
    out = {}
    events = json.loads(path.read_text()).get("events") or {}
    for event, block in events.items():
        for key, s in (block.get("keys") or {}).items():
            # Only millisecond keys compare cleanly across runs.
            if not key.endswith("_ms"):
                continue
            out[f"usage.{event}.{key}"] = {"n": s.get("n", 0), **{p: s.get(p) for p in PERCENTILES}}
    return out


def summarize(run_dir: Path) -> dict:
    metrics: dict = {}
    metrics.update(launch_metrics(run_dir / "launch-warm.json", "launch.warm_ms"))
    metrics.update(launch_metrics(run_dir / "launch-cold.json", "launch.cold_ms"))
    metrics.update(home_metrics(run_dir / "home-recent-captures.txt"))
    metrics.update(dictation_stop_metrics(run_dir / "dictation-stop.jsonl"))
    metrics.update(real_usage_metrics(run_dir / "real-usage-percentiles.json"))
    return {"run": run_dir.name, "metrics": dict(sorted(metrics.items()))}


def load_summary(path: Path) -> dict:
    if path.is_dir():
        summary_file = path / "summary.json"
        if summary_file.is_file():
            return json.loads(summary_file.read_text())
        return summarize(path)
    return json.loads(path.read_text())


def verdict(before: float | None, after: float | None, min_pct: float, min_ms: float) -> str:
    if before is None or after is None:
        return "n/a"
    delta = after - before
    if abs(delta) < min_ms or (before > 0 and abs(delta) / before * 100 < min_pct):
        return "same"
    return "faster" if delta < 0 else "SLOWER"


def fmt_change(before, after) -> str:
    if before is None or after is None:
        return "n/a"
    delta = after - before
    if before > 0:
        return f"{delta:+.1f} ({delta / before * 100:+.0f}%)"
    return f"{delta:+.1f}"


def compare(before: dict, after: dict, min_pct: float, min_ms: float) -> tuple[str, int]:
    rows = ["| metric | n before/after | p50 before | p50 after | p50 change | p95 before | p95 after | p95 change | verdict |",
            "|---|---|---:|---:|---|---:|---:|---|---|"]
    slower = 0
    b_metrics, a_metrics = before.get("metrics", {}), after.get("metrics", {})
    for name in sorted(set(b_metrics) | set(a_metrics)):
        b, a = b_metrics.get(name, {}), a_metrics.get(name, {})
        # p95 decides the verdict: users feel the tail, and it's what the
        # article and performance-budget.rb both gate on.
        v50 = verdict(b.get("p50"), a.get("p50"), min_pct, min_ms)
        v95 = verdict(b.get("p95"), a.get("p95"), min_pct, min_ms)
        overall = "SLOWER" if "SLOWER" in (v50, v95) else ("faster" if "faster" in (v50, v95) else v95)
        if overall == "SLOWER":
            slower += 1
        cell = lambda d, k: "—" if d.get(k) is None else f"{d[k]:.1f}"
        rows.append(f"| {name} | {b.get('n', 0)}/{a.get('n', 0)} | {cell(b, 'p50')} | {cell(a, 'p50')} | "
                    f"{fmt_change(b.get('p50'), a.get('p50'))} | {cell(b, 'p95')} | {cell(a, 'p95')} | "
                    f"{fmt_change(b.get('p95'), a.get('p95'))} | {overall} |")
    header = f"Before: `{before.get('run', '?')}`  After: `{after.get('run', '?')}`  (same = under {min_pct:g}% or {min_ms:g} ms)\n\n"
    return header + "\n".join(rows), slower


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        before, after = root / "before", root / "after"
        for run, launch, load, stop in ((before, 300.0, 120.0, 0.40), (after, 200.0, 121.0, 0.60)):
            run.mkdir()
            (run / "launch-warm.json").write_text(json.dumps({
                "collectedSamples": 20,
                "launchToInteractiveMs": {"p50": launch, "p95": launch + 50, "p99": launch + 80}}))
            (run / "home-recent-captures.txt").write_text(
                "| captures | meetings | dictations | reps | raw load ms | avg load ms | best load ms | cancel ms |\n"
                "|---:|---:|---:|---:|---|---:|---:|---:|\n"
                f"| 1000 | 500 | 500 | 5 | {load}, {load} | {load} | {load - 5} | 2.0 |\n"
                "meeting search @ 1000 captures: cold index 80.0ms, cached index 9.5ms, "
                "warm rebuild+search avg 12.0ms\n")
            rows = [{"record_type": "run_start"}]
            rows += [{"record_type": "case_result", "case_id": "short", "stop_to_text_s": stop,
                      "decode_s": stop / 2} for _ in range(3)]
            (run / "dictation-stop.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        b, a = summarize(before), summarize(after)
        assert b["metrics"]["launch.warm_ms"]["p50"] == 300.0, b
        assert b["metrics"]["home.load_ms.1000_captures"]["n"] == 5, b
        assert b["metrics"]["home.search.cold_index_ms.1000_captures"]["p50"] == 80.0, b
        assert b["metrics"]["dictation_stop.stop_to_text_ms.short"]["p50"] == 400.0, b
        table, slower = compare(b, a, 5.0, 5.0)
        assert "| launch.warm_ms | 20/20 |" in table and "| faster |" in table.split("launch.warm_ms")[1].splitlines()[0], table
        assert "| same |" in table.split("home.load_ms.1000_captures")[1].splitlines()[0], table
        assert "| SLOWER |" in table.split("dictation_stop.stop_to_text_ms.short")[1].splitlines()[0], table
        assert slower == 2, (slower, table)  # stop_to_text and decode both got slower
        assert verdict(100.0, 103.0, 5.0, 5.0) == "same"
        assert verdict(1000.0, 1040.0, 5.0, 5.0) == "same"
        assert verdict(10.0, 4.0, 5.0, 5.0) == "faster"
        assert summarize(root / "missing")["metrics"] == {}
    print("bench-compare self-test: ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs", nargs="*", help="run dirs or summary.json files: BEFORE AFTER")
    parser.add_argument("--summarize", metavar="RUN_DIR", help="write RUN_DIR/summary.json and print it")
    parser.add_argument("--min-pct", type=float, default=5.0, help="relative noise floor in percent (default 5)")
    parser.add_argument("--min-ms", type=float, default=5.0, help="absolute noise floor in ms (default 5)")
    parser.add_argument("--fail-on-slower", action="store_true", help="exit 1 when any metric got slower")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if args.summarize:
        run_dir = Path(args.summarize)
        summary = summarize(run_dir)
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        print(f"{len(summary['metrics'])} metrics -> {run_dir / 'summary.json'}")
        return 0
    if len(args.runs) != 2:
        parser.error("give two runs (BEFORE AFTER), or --summarize RUN_DIR, or --self-test")
    table, slower = compare(load_summary(Path(args.runs[0])), load_summary(Path(args.runs[1])),
                            args.min_pct, args.min_ms)
    print(table)
    if slower:
        print(f"\n{slower} metric(s) slower than before.")
    return 1 if (slower and args.fail_on_slower) else 0


if __name__ == "__main__":
    sys.exit(main())
