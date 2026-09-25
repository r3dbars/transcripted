#!/usr/bin/env python3
"""Hill-climb bench `stt-shootout`: one speech model over a suite of recordings.

    python3 scripts/stt-shootout/hillclimb_bench.py --request REQUEST.json
    python3 scripts/stt-shootout/hillclimb_bench.py --self-test

Speaks the request/result protocol of the hill-climb lab
(scripts/hillclimb/hc_benches.py, schema transcripted.hillclimb.*.v1). For
each suite item ({"id", "audio", "truth"}, truth = .txt or human .vtt) it runs
the shootout (run.sh) on that file with the model the `stt.engine` knob picks
(default parakeet-v3, see `run.sh --list-engines`) and reports:

    full_s            seconds to transcribe the whole item, model loaded
    speed_x_realtime  audio seconds per processing second (higher is faster)
    rtf               full_s / audio seconds (lower is faster)
    clip_latency_s    10 s clip, model loaded, median of the warm runs
    first_clip_s      the first clip run after loading
    load_s            model load
    peak_memory_mb    peak footprint (a lower bound for Core ML engines)
    word_error_rate   vs the item's truth file (Whisper English normalizer)

Gates: engine_failed (the model didn't run: missing, crashed, timed out) and
empty_text (it ran but produced no words). A gated item carries no metrics.

bench_options: work (default ~/stt-shootout), latency_runs (default 3),
item_timeout_s (default 7200), locale (Apple Speech, default en-US).
The result holds numbers, ids and short error strings only; transcripts stay
in the shootout's work folder on the Mac.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]
RESULT_SCHEMA = "transcripted.hillclimb.result.v1"
BENCH_ID = "stt-shootout"
ENGINE_KNOB = "stt.engine"
DEFAULT_ENGINE = "parakeet-v3"
GATES = ("engine_failed", "empty_text")

METRICS = {
    "full_s": "full_seconds",
    "speed_x_realtime": "speed_x_realtime",
    "rtf": "rtf",
    "clip_latency_s": "clip_warm_seconds",
    "first_clip_s": "clip_cold_seconds",
    "load_s": "load_seconds",
    "peak_memory_mb": "peak_memory_mb",
    "word_error_rate": "wer",
}


def short(text: str, limit: int = 200) -> str:
    text = " ".join(str(text).split()).replace(str(Path.home()), "~")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def item_result(item_id: str, row: dict | None, error: str | None) -> dict:
    gates = {gate: 0 for gate in GATES}
    if row is None or row.get("status") != "ok":
        gates["engine_failed"] = 1
        return {"id": item_id, "metrics": {}, "gates": gates,
                "error": short(error or (row or {}).get("error") or "no result")}
    if not row.get("wer_hypothesis_words", 1):
        gates["empty_text"] = 1
        return {"id": item_id, "metrics": {}, "gates": gates, "error": "the model returned no words"}
    metrics = {}
    for name, key in METRICS.items():
        value = row.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            metrics[name] = float(value)
    return {"id": item_id, "metrics": metrics, "gates": gates, "error": None}


def run_item(item: dict, engine: str, options: dict) -> dict:
    item_id = str(item["id"])
    audio = Path(str(item.get("audio") or "")).expanduser()
    if not audio.is_file():
        return item_result(item_id, None, "audio file missing")
    with tempfile.TemporaryDirectory(prefix="stt-hc-") as tmp:
        report = Path(tmp) / "report.json"
        cmd = ["bash", str(HERE / "run.sh"), "--audio", str(audio), "--engines", engine, "--rerun",
               "--work", str(Path(options.get("work") or "~/stt-shootout").expanduser()),
               "--latency-runs", str(int(options.get("latency_runs", 3))),
               "--locale", str(options.get("locale", "en-US")),
               "--timeout", str(float(options.get("item_timeout_s", 7200))),
               "--json-out", str(report)]
        if item.get("truth"):
            cmd += ["--reference", str(Path(str(item["truth"])).expanduser())]
        try:
            run = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=float(options.get("item_timeout_s", 7200)) + 3600)
        except subprocess.TimeoutExpired:
            return item_result(item_id, None, "timed out")
        if run.returncode != 0 or not report.exists():
            return item_result(item_id, None, f"shootout exited {run.returncode}: {run.stderr.strip()[-160:]}")
        rows = json.loads(report.read_text()).get("results") or []
    return item_result(item_id, next((r for r in rows if r.get("engine") == engine), None), None)


def environment() -> dict:
    revision = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
    return {"app_revision": revision or None, "host": platform.node().split(".")[0],
            "os": platform.platform(), "bench": BENCH_ID}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--request", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.request:
        parser.error("--request is required")

    request = json.loads(args.request.read_text())
    engine = str((request.get("knobs") or {}).get(ENGINE_KNOB) or DEFAULT_ENGINE)
    options = request.get("bench_options") or {}
    items = [run_item(item, engine, options) for item in request.get("items") or []]
    result = {"schema": RESULT_SCHEMA, "bench": BENCH_ID, "environment": environment() | {"engine": engine},
              "items": items}
    Path(request["result_path"]).write_text(json.dumps(result, indent=2, sort_keys=True))


def self_test() -> None:
    ok = item_result("a", {"status": "ok", "full_seconds": 12.0, "rtf": 0.01, "wer": 0.08,
                           "wer_hypothesis_words": 900, "clip_warm_seconds": 0.2, "english_only": True}, None)
    assert ok["error"] is None and ok["metrics"]["word_error_rate"] == 0.08 and ok["gates"]["engine_failed"] == 0
    assert "english_only" not in ok["metrics"]
    failed = item_result("b", {"status": "failed", "error": "exited 1"}, None)
    assert failed["gates"]["engine_failed"] == 1 and failed["metrics"] == {}
    empty = item_result("c", {"status": "ok", "wer_hypothesis_words": 0}, None)
    assert empty["gates"]["empty_text"] == 1
    missing = run_item({"id": "d", "audio": "/nonexistent.wav"}, DEFAULT_ENGINE, {})
    assert missing["gates"]["engine_failed"] == 1
    print("self-test ok")


if __name__ == "__main__":
    main()
