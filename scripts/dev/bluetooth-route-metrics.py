#!/usr/bin/env python3
"""Bluetooth dictation route health metrics from events.jsonl.

Measures the signals the 2026-08-24 Bluetooth audit used as evidence, so the
per-session system-input-override removal can be judged against its pre-fix
baseline with one command:

    python3 scripts/dev/bluetooth-route-metrics.py                # today (UTC)
    python3 scripts/dev/bluetooth-route-metrics.py --date 2026-08-24
    python3 scripts/dev/bluetooth-route-metrics.py --since 2026-08-25  # every day from there

Timestamps in events.jsonl are UTC; debug.log is local wall-clock. This script
reads only events.jsonl, so give it UTC dates.

Post-fix expectations (vs the 2026-08-24 pre-fix baseline printed below):
- dictation_system_input_auto_selected / dictation_input_device_override_failed: 0
  (the Mac-wide write no longer exists; nonzero means the invariant regressed)
- default_input_device_changed: near 0 while the persistent preference is off
  (only genuine user/OS switches remain)
- prewarm_deferred_for_bluetooth_fallback: 0 (deferral deleted)
- bluetooth-route start latency: converging toward the built-in-route class
- audio_route_not_settled / retries: sharply reduced; what remains is the
  -10868 AVAudioEngine.start() TOCTOU race, tracked for a dedicated follow-up
  if it persists (see the audit plan, step 7).
"""

import argparse
import json
import statistics
import sys
from pathlib import Path

DEFAULT_EVENTS = Path.home() / "Library/Application Support/Transcripted/logs/events.jsonl"

CHURN_EVENTS = [
    "dictation_system_input_auto_selected",
    "dictation_system_input_override_failed",
    "dictation_input_device_override_settled",
    "default_input_device_changed",
    "prewarm_deferred_for_bluetooth_fallback",
    "dictation_persistent_input_external_selection_preserved",
]
FAILURE_EVENTS = [
    "audio_route_not_settled",
    "audio_format_unavailable",
    "prewarm_invalid_format",
    "dictation_fast_start_fell_back_to_wait",
    "dictation_recording_retry",
]
START_EVENTS = ["dictation_recording_fast_start", "dictation_started_after_wait"]

# Measured on this machine for UTC day 2026-08-24, pre-fix (worktree audit).
BASELINE = {
    "date": "2026-08-24 (pre-fix)",
    "dictation_system_input_auto_selected": 43,
    "dictation_input_device_override_settled": 39,
    "default_input_device_changed": 25,
    "route_not_settled_family": 24,
    "bt_start_median_ms": 469.5,
    "built_in_start_median_ms": 83.5,
    "worst_start_ms": "1089-1523 (after fell-back-to-wait)",
}


def is_bluetooth_route(context):
    route = context.get("route_shape", "")
    return "bluetooth" in route or context.get("default_output_class") == "bluetooth"


def summarize(values):
    if not values:
        return "n=0"
    ms = sorted(values)
    p90 = ms[min(len(ms) - 1, int(round(0.9 * (len(ms) - 1))))]
    return (
        f"n={len(ms)} median={statistics.median(ms):.0f}ms "
        f"p90={p90:.0f}ms max={ms[-1]:.0f}ms"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--date", help="UTC day YYYY-MM-DD (default: today UTC)")
    parser.add_argument("--since", help="UTC day YYYY-MM-DD; report each day from there")
    parser.add_argument("--events", default=str(DEFAULT_EVENTS), help="path to events.jsonl")
    args = parser.parse_args()

    events_path = Path(args.events)
    if not events_path.exists():
        sys.exit(f"events log not found: {events_path}")

    if args.since:
        prefix_filter = None
        since = args.since
    else:
        from datetime import datetime, timezone

        prefix_filter = args.date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
        since = None

    days = {}
    with events_path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            day = str(record.get("timestamp", ""))[:10]
            if prefix_filter is not None and day != prefix_filter:
                continue
            if since is not None and day < since:
                continue
            event = record.get("event", "")
            context = record.get("context") or {}
            if not isinstance(context, dict):
                context = {}
            bucket = days.setdefault(day, {"counts": {}, "bt_starts": [], "other_starts": [], "hfp_true": 0})
            if event in CHURN_EVENTS or event in FAILURE_EVENTS:
                bucket["counts"][event] = bucket["counts"].get(event, 0) + 1
            if event in START_EVENTS:
                raw = context.get("request_to_recording_ms")
                try:
                    latency = float(raw)
                except (TypeError, ValueError):
                    latency = None
                if latency is not None:
                    key = "bt_starts" if is_bluetooth_route(context) else "other_starts"
                    bucket[key].append(latency)
            if context.get("hfp_suspected") == "true":
                bucket["hfp_true"] += 1

    if not days:
        print("no matching events found for the requested window")
        return

    print(f"Baseline {BASELINE['date']}: "
          f"auto_selected={BASELINE['dictation_system_input_auto_selected']} "
          f"override_settled={BASELINE['dictation_input_device_override_settled']} "
          f"default_input_changed={BASELINE['default_input_device_changed']} "
          f"route_not_settled_family={BASELINE['route_not_settled_family']}")
    print(f"Baseline start latency: bluetooth-route median {BASELINE['bt_start_median_ms']}ms "
          f"vs built-in {BASELINE['built_in_start_median_ms']}ms; worst {BASELINE['worst_start_ms']}")
    print()

    for day in sorted(days):
        bucket = days[day]
        print(f"== {day} (UTC) ==")
        for event in CHURN_EVENTS + FAILURE_EVENTS:
            count = bucket["counts"].get(event, 0)
            if count:
                print(f"  {event}: {count}")
        zero_invariants = [
            e for e in ("dictation_system_input_auto_selected", "dictation_system_input_override_failed")
            if bucket["counts"].get(e, 0)
        ]
        if zero_invariants:
            print("  !! REGRESSION: per-session Mac-wide input writes are back:", ", ".join(zero_invariants))
        else:
            print("  invariant holds: zero per-session Mac-wide input writes")
        print(f"  starts (bluetooth-involved route): {summarize(bucket['bt_starts'])}")
        print(f"  starts (other routes):             {summarize(bucket['other_starts'])}")
        print(f"  events carrying hfp_suspected=true: {bucket['hfp_true']}")
        print()


if __name__ == "__main__":
    main()
