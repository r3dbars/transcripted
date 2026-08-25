#!/usr/bin/env python3
"""Compute latency percentiles from a Transcripted events.jsonl log.

performance-budget.rb scores a handful of p95 gates and fails the build. This is
the exploratory counterpart: it reports the full distribution (p50/p90/p95/p99)
for every numeric latency key actually present in the log, so you can see which
stage owns the tail instead of only whether a gate passed.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

DEFAULT_EVENTS_PATH = str(
    Path.home() / "Library/Application Support/Transcripted/logs/events.jsonl"
)

# Numeric context keys are emitted as strings; anything non-numeric (including
# the sanitizer's redaction placeholder) is skipped rather than counted as zero.
LATENCY_SUFFIXES = ("_ms", "_s", "_seconds", "rtf")


def parse_ts(raw: str):
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except Exception:
        return None


def numeric(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def pct(ordered, q):
    """Nearest-rank percentile — never invents a value between two samples."""
    rank = max(1, min(len(ordered), math.ceil(q * len(ordered))))
    return ordered[rank - 1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("events", nargs="?", default=DEFAULT_EVENTS_PATH,
                        help=f"events.jsonl path (default: {DEFAULT_EVENTS_PATH})")
    parser.add_argument("--since", help="ISO8601 lower bound on event timestamp")
    parser.add_argument("--event", action="append", dest="events_filter",
                        help="Only score this event name (repeatable)")
    parser.add_argument("--min-samples", type=int, default=5,
                        help="Skip keys with fewer samples than this (default: 5)")
    parser.add_argument("--json", dest="json_out", help="Write the full report as JSON here")
    args = parser.parse_args()

    since = parse_ts(args.since) if args.since else None
    if args.since and since is None:
        print(f"Could not parse --since {args.since!r}", file=sys.stderr)
        return 2

    values: dict[tuple[str, str], list[float]] = defaultdict(list)
    redacted: dict[tuple[str, str], int] = defaultdict(int)
    event_counts: dict[str, int] = defaultdict(int)
    skipped = 0

    with open(args.events, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue

            name = entry.get("event") or entry.get("name") or "?"
            if args.events_filter and name not in args.events_filter:
                continue
            if since is not None:
                ts = parse_ts(entry.get("timestamp", ""))
                if ts is None or ts < since:
                    continue

            event_counts[name] += 1
            context = entry.get("context") or {}
            if not isinstance(context, dict):
                continue
            for key, raw in context.items():
                if not key.endswith(LATENCY_SUFFIXES):
                    continue
                parsed = numeric(raw)
                if parsed is None:
                    # Distinguish "sanitizer removed it" from "not emitted" —
                    # a redacted timing key is an observability gap, not noise.
                    if isinstance(raw, str) and "redact" in raw.lower():
                        redacted[(name, key)] += 1
                    continue
                values[(name, key)].append(parsed)

    if not values and not redacted:
        print("No latency keys found.", file=sys.stderr)
        return 1

    report: dict[str, dict] = {}
    for (name, key), samples in sorted(values.items()):
        if len(samples) < args.min_samples:
            continue
        ordered = sorted(samples)
        report.setdefault(name, {"samples": event_counts[name], "keys": {}})
        report[name]["keys"][key] = {
            "n": len(ordered),
            "min": round(ordered[0], 3),
            "p50": round(pct(ordered, 0.50), 3),
            "p90": round(pct(ordered, 0.90), 3),
            "p95": round(pct(ordered, 0.95), 3),
            "p99": round(pct(ordered, 0.99), 3),
            "max": round(ordered[-1], 3),
            "mean": round(statistics.fmean(ordered), 3),
        }

    for name, block in report.items():
        print(f"\n=== {name}  ({block['samples']} events) ===")
        print(f"{'key':<36} {'n':>5} {'p50':>10} {'p90':>10} {'p95':>10} {'p99':>10} {'max':>10}")
        # Sort by p99 so the stage owning the tail is always the first row.
        rows = sorted(block["keys"].items(), key=lambda kv: kv[1]["p99"], reverse=True)
        for key, stats in rows:
            print(f"{key:<36} {stats['n']:>5} {stats['p50']:>10.1f} {stats['p90']:>10.1f} "
                  f"{stats['p95']:>10.1f} {stats['p99']:>10.1f} {stats['max']:>10.1f}")

    if redacted:
        print("\n=== redacted timing keys (present but unreadable locally) ===")
        for (name, key), count in sorted(redacted.items(), key=lambda kv: -kv[1]):
            print(f"  {count:>5}x  {name}.{key}")

    if skipped:
        print(f"\n({skipped} unparseable lines skipped)")

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump({"events": report,
                       "redactedKeys": {f"{n}.{k}": c for (n, k), c in redacted.items()}},
                      handle, indent=2, sort_keys=True)
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
