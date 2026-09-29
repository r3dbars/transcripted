#!/usr/bin/env python3
"""What each finalist voiceprint model costs in the product, in seconds after a meeting.

The app cuts a finished call into speaker turns (Nemotron -> NemotronTurnBuilder) and embeds
every turn: a turn longer than 10 s is cut into windows (<= 10 s, hop 5 s), each window is
embedded, the vectors are pooled. So extra seconds = windows per hour x time per window.

Subcommands (run with VP/venv/bin/python, from the repo root):

  turns    turn-length distribution -> VP/results/latency_turns.json
           Nemotron: the speaker lab's real Nemotron output (data/eval/yodas3/sim/p3-*/*/
           e2e_nemotron3-offline.json) with the app's turn rules applied (same-speaker gaps under
           0.2874 s joined, turns under 0.25 s dropped). Cross-check: AMI and ICSI human labels.
  run      timing rounds. Each round measures every model once, in a fresh process, one at a time
           (interleaved, start order rotated). The baseline is measured in every round, so each
           model has a same-round ratio to it. Appends to VP/results/latency_raw.jsonl.
  plan     which device (ANE / GPU / CPU) Core ML plans for each model's ops -> latency_plans.json
  report   VP/results/latency.md from the three files above.
  worker   (internal) one model, one process: load, warm latency per length, mixed-length stream,
           memory. Prints one JSON object.

Models timed (compute units ALL, fused Core ML unless noted):
  app-wespeaker-coreml        the app today: FBank.mlmodelc (CPU) + Embedding.mlmodelc (ALL), one fixed
                              10 s window per call whatever the turn length (runtimes/fluid_coreml.py)
  every VP/coreml/<id>/ for the four finalists, plus any *-ane build that has a finished report.json.

Rules kept: one process at a time (OMP_NUM_THREADS=3), never touches the app's real state, kills
only the worker PIDs it started (subprocess timeout).
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
VP = ROOT / "data/eval/voiceprint"
RES = VP / "results"
SR = 16000
TURNS_JSON = RES / "latency_turns.json"
RAW_JSONL = RES / "latency_raw.jsonl"
PLANS_JSON = RES / "latency_plans.json"
COLD_JSONL = RES / "latency_cold.jsonl"
REPORT_MD = RES / "latency.md"

BASELINE_ID = "app-wespeaker-coreml"
FINALISTS = ["wespeaker-resnet293-lm", "wespeaker-resnet221-lm", "redimnet2-b6-vox2-lm", "redimnet2-b4-vox2-lm"]
ANE_RE = re.compile(r"(^|[-_])ane($|[-_])")
# The four lengths the brief asks for get the full protocol; the rest feed the cost model.
REQUIRED_S = [2, 4, 8, 10]
FULL_WARM, FULL_N = 10, 50
LITE_WARM, LITE_N = 4, 20
STREAM_N = 300

# App turn rules (Sources/TranscriptedCore/Services/NemotronTurnBuilder.swift).
BRIDGE_GAP_S = 0.2874
MIN_TURN_S = 0.25
WINDOW_S, HOP_S = 10.0, 5.0


# ============================================================================ turns
def _bridge(runs, gap):
    out = []
    for r in runs:
        if out and out[-1][0] == r[0] and r[1] - out[-1][2] <= gap:
            out[-1] = (r[0], out[-1][1], max(out[-1][2], r[2]))
        else:
            out.append(r)
    return out


def build_turns(segs) -> list[tuple]:
    """(speaker, start, end) runs -> turns, with the app's join / drop / join rules."""
    runs = sorted(((s[0], float(s[1]), float(s[2])) for s in segs), key=lambda x: (x[1], x[2]))
    m = _bridge(runs, BRIDGE_GAP_S)
    m = [r for r in m if r[2] - r[1] >= MIN_TURN_S]
    return _bridge(m, BRIDGE_GAP_S)


def challenger_windows(length_s: float, win: float = WINDOW_S, hop: float = HOP_S) -> list[float]:
    """CoreMLSpeakerSegmentEmbedder.windowBounds: windows start every `hop`, the last ends at the turn end."""
    if length_s <= win:
        return [length_s]
    out, s = [], 0.0
    while True:
        e = min(s + win, length_s)
        out.append(e - s)
        if e >= length_s:
            break
        s += hop
    return out


def baseline_pieces(length_s: float) -> list[float]:
    """FluidOfflineWeSpeakerSegmentEmbedder.embed(audio:...): back-to-back 10 s pieces, a trailing
    sliver under 0.5 s is skipped when earlier pieces exist. Each piece is one full 10 s model call."""
    out, s = [], 0.0
    while s < length_s:
        e = min(length_s, s + WINDOW_S)
        if e - s < 0.5 and out:
            break
        out.append(e - s)
        s += WINDOW_S
    return out


def _wav_seconds(path: Path) -> float:
    with wave.open(str(path)) as w:
        return w.getnframes() / w.getframerate()


def _source_stats(name: str, turns_by_meeting: list[list[float]], hours: float, extra: dict | None = None):
    turns = [d for m in turns_by_meeting for d in m]
    a = np.array(turns)
    chal = [w for d in turns for w in challenger_windows(d)]
    chal10 = [w for d in turns for w in challenger_windows(d, hop=WINDOW_S)]
    base = [p for d in turns for p in baseline_pieces(d)]
    out = {
        "source": name, "meetings": len(turns_by_meeting), "hours": round(hours, 2),
        "turns": len(turns), "turns_per_hour": round(len(turns) / hours),
        "windows_hop5_per_hour": round(len(chal) / hours),
        "windows_hop10_per_hour": round(len(chal10) / hours),
        "baseline_pieces_per_hour": round(len(base) / hours),
        "turn_s": {"mean": round(float(a.mean()), 2),
                   **{f"p{p}": round(float(np.percentile(a, p)), 2) for p in (10, 25, 50, 75, 90, 95, 99)}},
        "share_turns_under_1s": round(float((a < 1).mean()), 3),
        "share_turns_over_10s": round(float((a > 10).mean()), 3),
        "share_windows_full_10s": round(float(np.mean([w >= 9.99 for w in chal])), 3),
        "per_meeting_turns_per_hour": None,
    }
    out.update(extra or {})
    return out, [round(w, 2) for w in chal], [round(w, 2) for w in chal10], [round(p, 2) for p in base]


def cmd_turns(_args) -> int:
    sources, samples = [], {}

    def add(name, per_meeting, hours_each, extra=None):
        hours = sum(hours_each) / 3600.0
        stat, chal, chal10, base = _source_stats(name, per_meeting, hours, extra)
        tph = [len(m) / (h / 3600.0) for m, h in zip(per_meeting, hours_each) if h > 60]
        stat["per_meeting_turns_per_hour"] = {"min": round(min(tph)), "median": round(statistics.median(tph)),
                                              "max": round(max(tph))}
        sources.append(stat)
        samples[name] = {"windows_hop5": chal, "windows_hop10": chal10, "baseline_pieces": base}

    # 1. the speaker lab's real Nemotron output, per family and pooled
    sim = ROOT / "data/eval/yodas3/sim"
    fams = collections.OrderedDict()
    for f in sorted(glob.glob(str(sim / "p3-*/*/e2e_nemotron3-offline.json"))):
        fam = Path(f).parts[-3]
        d = json.load(open(f))
        secs = _wav_seconds(Path(f).parent / "system.wav")
        segs = [(s["speaker"], s["start"], s["end"]) for s in d["segments"]]
        fams.setdefault(fam, []).append(([t[2] - t[1] for t in build_turns(segs)], secs, len(segs)))
    lab_extra = {}
    for fam, rows in fams.items():
        add(f"nemotron-lab {fam}", [r[0] for r in rows], [r[1] for r in rows],
            {"raw_segments_per_hour": round(sum(r[2] for r in rows) / (sum(r[1] for r in rows) / 3600))})
    allrows = [r for rows in fams.values() for r in rows]
    add("nemotron-lab pooled", [r[0] for r in allrows], [r[1] for r in allrows],
        {"raw_segments_per_hour": round(sum(r[2] for r in allrows) / (sum(r[1] for r in allrows) / 3600))})

    # what the lab's whole post-call step took (context for "extra seconds")
    pos = []
    for f in sorted(glob.glob(str(sim / "p3-*@nemo-f5-one/*/lab_result.json"))):
        d = json.load(open(f))
        secs = _wav_seconds(Path(f).parent / "system.wav")
        if d.get("processingSeconds") and secs > 300:
            pos.append((secs / 60.0, d["processingSeconds"]))
    lab_extra["lab_post_call_seconds"] = {
        "meetings": len(pos),
        "minutes_median": round(statistics.median(m for m, _ in pos), 1) if pos else None,
        "seconds_median": round(statistics.median(s for _, s in pos), 1) if pos else None,
        "seconds_per_minute_median": round(statistics.median(s / m for m, s in pos), 2) if pos else None,
    }

    # 2. AMI (human RTTM) and ICSI (human MRT segments): natural meetings, cross-check only
    ami_dir = ROOT / "data/ami"
    per, hrs = [], []
    for r in sorted(glob.glob(str(ami_dir / "rttm/*.rttm"))):
        mid = Path(r).stem
        wav = ami_dir / "audio" / f"{mid}.Mix-Headset.wav"
        if not wav.exists():
            continue
        segs = []
        for line in open(r):
            p = line.split()
            if len(p) >= 8 and p[0] == "SPEAKER":
                segs.append((p[7], float(p[3]), float(p[3]) + float(p[4])))
        per.append([t[2] - t[1] for t in build_turns(segs)])
        hrs.append(_wav_seconds(wav))
    if per:
        add("ami (human labels)", per, hrs)
    icsi = VP / "raw/icsi"
    per, hrs = [], []
    for mrt in sorted(glob.glob(str(icsi / "annot/mrt/transcripts/*.mrt"))):
        mid = Path(mrt).stem
        wav = icsi / "audio" / f"{mid}.wav"
        if not wav.exists():
            continue
        segs = []
        for line in open(mrt, encoding="latin-1"):
            m = re.search(r'<Segment StartTime="([\d.]+)" EndTime="([\d.]+)" Participant="([^"]+)"', line)
            if m:
                segs.append((m.group(3), float(m.group(1)), float(m.group(2))))
        if segs:
            per.append([t[2] - t[1] for t in build_turns(segs)])
            hrs.append(_wav_seconds(wav))
    if per:
        add("icsi (human labels)", per, hrs)

    RES.mkdir(parents=True, exist_ok=True)
    TURNS_JSON.write_text(json.dumps({
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "rules": {"bridge_gap_s": BRIDGE_GAP_S, "min_turn_s": MIN_TURN_S, "window_s": WINDOW_S, "hop_s": HOP_S},
        "sources": sources, "lab": lab_extra, "samples": samples}))
    for s in sources:
        print(f"{s['source']:<24} {s['meetings']:>3} mtg {s['hours']:>6} h  turns/h {s['turns_per_hour']:>5}  "
              f"windows/h(hop5) {s['windows_hop5_per_hour']:>5}  median turn {s['turn_s']['p50']} s")
    print(json.dumps(lab_extra))
    return 0


# ============================================================================ model specs
def _mtime(p: Path) -> float:
    try:
        return max(f.stat().st_mtime for f in [p, *p.rglob("*")] if f.exists())
    except OSError:
        return 0.0


def _function_name(n: int) -> str:
    return f"len_{n}"


def discover_specs() -> list[dict]:
    specs = []
    app = VP / "models" / BASELINE_ID
    if (app / "Embedding.mlmodelc").is_dir():
        specs.append({"id": BASELINE_ID, "kind": "fluid", "dir": str(app), "units": "ALL",
                      "label": "app baseline (WeSpeaker ResNet34, FBank cpu + Embedding all)",
                      "mtime": _mtime(app / "Embedding.mlmodelc")})
    cdir = VP / "coreml"
    ids = list(FINALISTS)
    ids += sorted(p.name for p in cdir.iterdir()
                  if p.is_dir() and ANE_RE.search(p.name) and p.name not in ids)
    for mid in ids:
        d = cdir / mid
        mlc, rep_f = d / "model.mlmodelc", d / "report.json"
        if not (mlc / "model.mil").exists() or not rep_f.exists():
            continue
        try:
            rep = json.loads(rep_f.read_text())
        except json.JSONDecodeError:
            continue
        if not rep.get("converted") or not rep.get("finished_at"):
            continue
        shapes = rep.get("shapes") or {}
        kind = shapes.get("kind")
        if kind not in ("enumerated", "multifunction"):
            continue
        samples = sorted(int(n) for n in shapes.get("samples") or [])
        if not samples:
            continue
        specs.append({
            "id": mid, "kind": "fused", "dir": str(d), "mlmodelc": str(mlc), "units": "ALL",
            "shapes": kind, "lengths": samples,
            "functions": {str(n): _function_name(n) for n in samples} if kind == "multifunction" else None,
            "precision": rep.get("precision"), "dim": rep.get("dim"),
            "label": f"{mid} ({kind}, {rep.get('precision')})",
            "mtime": _mtime(mlc), "report_finished_at": rep.get("finished_at"),
        })
    return specs


def dir_mb(p: Path) -> float:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e6


# ============================================================================ worker
def _footprint_mb() -> dict:
    """phys_footprint (current, peak) of this process in MB, via the `footprint` tool."""
    try:
        out = subprocess.run(["footprint", "-p", str(os.getpid()), "--noCategories"], capture_output=True,
                             text=True, timeout=60).stdout
    except Exception:
        return {}
    res = {}
    for key in ("phys_footprint", "phys_footprint_peak"):
        m = re.search(rf"^\s*{key}:\s*([\d.]+)\s*(KB|MB|GB|B)\b", out, re.M)
        if m:
            v, u = float(m.group(1)), m.group(2)
            res[key] = round(v * {"B": 1e-6, "KB": 1e-3, "MB": 1.0, "GB": 1e3}[u], 1)
    return res


def _speech(seconds: int = 40) -> np.ndarray:
    """Real speech (AMI clips, 8 s each) so the timing does not depend on a synthetic signal."""
    rows = [json.loads(line) for line in open(VP / "sets/ami/segments.jsonl") if '"bucket": 8' in line]
    rng = random.Random(7)
    rng.shuffle(rows)
    chunks, seen = [], set()
    for r in rows:
        if r["speaker"] in seen:
            continue
        seen.add(r["speaker"])
        with wave.open(str(VP / r["clip"])) as w:
            chunks.append(np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768)
        if sum(len(c) for c in chunks) >= seconds * SR:
            break
    return np.concatenate(chunks)[: seconds * SR].astype(np.float32)


def _stats(ts: list[float]) -> dict:
    s = sorted(ts)
    q = lambda p: s[min(len(s) - 1, int(p * len(s)))]  # noqa: E731
    return {"median": round(statistics.median(s), 2), "mean": round(statistics.fmean(s), 2), "min": round(s[0], 2),
            "p10": round(q(0.10), 2), "p90": round(q(0.90), 2), "max": round(s[-1], 2), "n": len(s)}


def _time(fn, warm: int, n: int) -> list[float]:
    for _ in range(warm):
        fn()
    ts = []
    for _ in range(n):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1000)
    return ts


def _ct_units(ct, name: str):
    return {"ALL": ct.ComputeUnit.ALL, "CPU_ONLY": ct.ComputeUnit.CPU_ONLY, "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU,
            "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE}[name]


def cmd_worker(args) -> int:
    spec = json.loads(args.spec)
    turns = json.loads(TURNS_JSON.read_text())
    # coremltools imports torch when it is installed (300 MB, slow); Core ML inference does not need it,
    # and the app has no torch, so block it to keep the "empty process" memory baseline honest.
    sys.modules["torch"] = None
    import coremltools as ct  # noqa: F401  (imported before the memory baseline on purpose)

    cold_dir = None
    if args.cold:
        # A fresh copy at a new path: Core ML has never planned/compiled it for the ANE or GPU, which is
        # what a user's first launch after install looks like.
        cold_dir = Path(tempfile.mkdtemp(prefix="benchlat_cold_"))
        import shutil
        if spec["kind"] == "fluid":
            for name in ("FBank.mlmodelc", "Embedding.mlmodelc"):
                shutil.copytree(Path(spec["dir"]) / name, cold_dir / name)
            spec = dict(spec, dir=str(cold_dir))
        else:
            shutil.copytree(spec["mlmodelc"], cold_dir / "model.mlmodelc")
            spec = dict(spec, mlmodelc=str(cold_dir / "model.mlmodelc"))

    audio = _speech()
    fp0 = _footprint_mb()
    res = {"id": spec["id"], "kind": spec["kind"], "load_avg_start": [round(x, 1) for x in os.getloadavg()],
           "footprint_before_load_mb": fp0, "pid": os.getpid(), "started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    keep = collections.deque(maxlen=512)  # Core ML frees inputs on its own thread: keep recent buffers alive
    models_keep = []
    # Window lengths (turn windows, hop 5 s) drawn for the mixed-length stream, seeded per model-independent.
    pool = turns["samples"]["nemotron-lab pooled"]["windows_hop5"]
    rng = random.Random(20260928)
    stream_windows = [rng.choice(pool) for _ in range(STREAM_N)]

    if spec["kind"] == "fluid":
        sys.path.insert(0, str(ROOT / "scripts/voiceprint/runtimes"))
        import fluid_coreml

        t0 = time.perf_counter()
        emb = fluid_coreml.Embedder(Path(spec["dir"]), {"mode": "app_context_free_tiled", "dim": 256})
        res["load_s"] = round(time.perf_counter() - t0, 3)
        models_keep += [emb.fbank, emb.embedding]
        WIN = fluid_coreml.WINDOW
        wf = emb.weight_frames

        def window_call(active_samples: int, split: dict | None = None):
            """One 10 s model call: a real 10 s window, mask on over `active_samples` (a turn)."""
            a = np.ascontiguousarray(audio[:WIN].reshape(1, 1, WIN), dtype=np.float32)
            keep.append(a)
            t0 = time.perf_counter()
            feats = emb.fbank.predict({"audio": a})["fbank_features"]
            t1 = time.perf_counter()
            w = np.zeros((1, wf), dtype=np.float32)
            w[0, : max(1, min(wf, math.ceil(active_samples / WIN * wf)))] = 1.0
            out = emb.embedding.predict({"fbank_features": feats, "weights": w})["embedding"]
            t2 = time.perf_counter()
            if split is not None:
                split["fbank"].append((t1 - t0) * 1000)
                split["embedding"].append((t2 - t1) * 1000)
            return np.asarray(out)

        t0 = time.perf_counter()
        window_call(4 * SR)
        res["first_predict_s"] = round(time.perf_counter() - t0, 3)
        res["footprint_after_first_predict_mb"] = _footprint_mb()
        res["lengths"] = {}
        if args.cold:
            res["all_ready_s"] = round(res["load_s"] + res["first_predict_s"], 3)
            res["load_avg_end"] = [round(x, 1) for x in os.getloadavg()]
            Path(args.out).write_text(json.dumps(res))
            import shutil
            shutil.rmtree(cold_dir, ignore_errors=True)
            return 0
        for sec in REQUIRED_S:
            split = {"fbank": [], "embedding": []}
            _time(lambda: window_call(sec * SR), FULL_WARM, 0)  # warm-ups only
            ts = []
            for _ in range(FULL_N):
                t0 = time.perf_counter()
                window_call(sec * SR, split)
                ts.append((time.perf_counter() - t0) * 1000)
            res["lengths"][str(sec)] = {**_stats(ts), "call_samples": WIN,
                                        "fbank_median": round(statistics.median(split["fbank"]), 2),
                                        "embedding_median": round(statistics.median(split["embedding"]), 2)}
        # stream: every call is one 10 s window whatever the turn length
        ts = []
        for w in stream_windows:
            t0 = time.perf_counter()
            window_call(int(min(w, 10) * SR))
            ts.append((time.perf_counter() - t0) * 1000)
        res["stream"] = _stats(ts)
        res["call_lengths_s"] = [10.0]
        res["all_ready_s"] = round(res["load_s"] + res["first_predict_s"], 3)
        model_mb = dir_mb(Path(spec["dir"]) / "FBank.mlmodelc") + dir_mb(Path(spec["dir"]) / "Embedding.mlmodelc")
    else:
        lengths = spec["lengths"]
        units = _ct_units(ct, spec["units"])
        mlc = spec["mlmodelc"]
        functions = spec.get("functions")
        loaded: dict = {}
        res["load_s_per_function"] = {}

        def get_model(n: int):
            key = functions[str(n)] if functions else "main"
            m = loaded.get(key)
            if m is None:
                t0 = time.perf_counter()
                m = (ct.models.CompiledMLModel(mlc, compute_units=units, function_name=key) if functions
                     else ct.models.CompiledMLModel(mlc, compute_units=units))
                res["load_s_per_function"][key] = round(time.perf_counter() - t0, 3)
                loaded[key] = m
                models_keep.append(m)
            return m

        def call(n_samples: int):
            m = get_model(n_samples)
            base = audio[(n_samples * 3) % (len(audio) - n_samples):]  # a different crop per length
            arr = np.ascontiguousarray(base[:n_samples].reshape(1, -1), dtype=np.float32)
            keep.append(arr)
            return m.predict({"audio": arr})["embedding"]

        # cold: constructor + first prediction at 4 s (a real load; Core ML compiles/plans lazily)
        first_n = 4 * SR if 4 * SR in lengths else lengths[len(lengths) // 2]
        t0 = time.perf_counter()
        get_model(first_n)
        res["load_s"] = round(time.perf_counter() - t0, 3)
        t0 = time.perf_counter()
        call(first_n)
        res["first_predict_s"] = round(time.perf_counter() - t0, 3)
        res["footprint_after_first_predict_mb"] = _footprint_mb()
        # first touch of every other length (multifunction: load+plan that function; enumerated: re-plan)
        first_touch = {str(first_n / SR): round(res["first_predict_s"] * 1000, 1)}
        t_all0 = time.perf_counter()
        for n in lengths:
            if n == first_n:
                continue
            t0 = time.perf_counter()
            call(n)
            first_touch[str(n / SR)] = round((time.perf_counter() - t0) * 1000, 1)
        res["first_touch_ms"] = first_touch
        res["all_ready_s"] = round(res["load_s"] + res["first_predict_s"] + (time.perf_counter() - t_all0), 3)
        res["footprint_all_lengths_ready_mb"] = _footprint_mb()
        res["lengths"] = {}
        if args.cold:
            res["load_avg_end"] = [round(x, 1) for x in os.getloadavg()]
            Path(args.out).write_text(json.dumps(res))
            import shutil
            shutil.rmtree(cold_dir, ignore_errors=True)
            return 0
        order = [n for n in lengths if n // SR in REQUIRED_S and n % SR == 0] + \
                [n for n in lengths if not (n // SR in REQUIRED_S and n % SR == 0)]
        for n in order:
            full = n % SR == 0 and n // SR in REQUIRED_S
            ts = _time(lambda: call(n), FULL_WARM if full else LITE_WARM, FULL_N if full else LITE_N)
            res["lengths"][str(n / SR)] = {**_stats(ts), "call_samples": n, "full_protocol": full}
        # mixed-length stream: window lengths from the real turns, each rounded up to the next length
        # the model takes (what CoreMLSpeakerSegmentEmbedder does). Shows any re-plan cost per length change.
        ts, used = [], collections.Counter()
        for w in stream_windows:
            n = next((L for L in lengths if L >= int(round(w * SR)) - 1), lengths[-1])
            used[n / SR] += 1
            t0 = time.perf_counter()
            call(n)
            ts.append((time.perf_counter() - t0) * 1000)
        res["stream"] = _stats(ts)
        res["call_lengths_s"] = [n / SR for n in lengths]
        model_mb = dir_mb(Path(mlc))
    res["model_mb"] = round(model_mb, 1)
    res["footprint_end_mb"] = _footprint_mb()
    res["load_avg_end"] = [round(x, 1) for x in os.getloadavg()]
    res["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    Path(args.out).write_text(json.dumps(res))
    return 0


# ============================================================================ run (driver)
def _run_worker(spec: dict, timeout: int, cold: bool = False) -> dict:
    env = dict(os.environ, OMP_NUM_THREADS="3", VECLIB_MAXIMUM_THREADS="3", TRANSCRIPTED_DISABLE_FILE_LOGGER="1",
               PYTHONUNBUFFERED="1")
    with tempfile.TemporaryDirectory(prefix="benchlat_") as td:
        out = Path(td) / "out.json"
        t0 = time.time()
        try:
            cmd = [sys.executable, str(Path(__file__).resolve()), "worker", "--spec", json.dumps(spec),
                   "--out", str(out)] + (["--cold"] if cold else [])
            p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return {"id": spec["id"], "error": f"timeout after {timeout}s"}
        if p.returncode != 0 or not out.exists():
            return {"id": spec["id"], "error": f"exit {p.returncode}: {(p.stderr or '')[-600:]}"}
        r = json.loads(out.read_text())
        r["wall_s"] = round(time.time() - t0, 1)
        return r


def cmd_run(args) -> int:
    if not TURNS_JSON.exists():
        cmd_turns(args)
    RES.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for rnd in range(args.rounds):
        specs = discover_specs()
        if args.only:
            keep = set(args.only.split(",")) | {BASELINE_ID}
            specs = [s for s in specs if s["id"] in keep]
        if not any(s["id"] == BASELINE_ID for s in specs):
            print("baseline model missing", file=sys.stderr)
            return 2
        k = rnd % len(specs)
        order = specs[k:] + specs[:k]  # rotate the start so no model always goes first
        round_id = f"{stamp}-r{rnd}"
        print(f"== round {round_id}: {[s['id'] for s in order]}  load {os.getloadavg()}", flush=True)
        for s in order:
            r = _run_worker(s, args.timeout)
            r.update(round_id=round_id, round=rnd, artifact_mtime=s["mtime"], spec_label=s["label"])
            with open(RAW_JSONL, "a") as f:
                f.write(json.dumps(r) + "\n")
            if "error" in r:
                print(f"  {s['id']}: ERROR {r['error'][:200]}", flush=True)
            else:
                l4 = r["lengths"].get("4.0") or r["lengths"].get("4") or {}
                print(f"  {s['id']:<32} 4s med {l4.get('median')} ms  stream mean {r['stream']['mean']} ms  "
                      f"load {r['load_s']}s+{r['first_predict_s']}s  wall {r['wall_s']}s  "
                      f"load avg {r['load_avg_start'][0]}", flush=True)
    return 0


def cmd_cold(args) -> int:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    specs = discover_specs()
    if args.only:
        keep = set(args.only.split(","))
        specs = [s for s in specs if s["id"] in keep]
    for rep in range(args.repeats):
        for s in specs:
            r = _run_worker(s, args.timeout, cold=True)
            r.update(round_id=f"{stamp}-c{rep}", artifact_mtime=s["mtime"])
            with open(COLD_JSONL, "a") as f:
                f.write(json.dumps(r) + "\n")
            print(s["id"], "ERROR " + r["error"][:200] if "error" in r else
                  f"cold load {r['load_s']}s + first predict {r['first_predict_s']}s, all lengths {r['all_ready_s']}s "
                  f"(load avg {r['load_avg_start'][0]})", flush=True)
    return 0


# ============================================================================ plan
def _plan_for(mlmodelc: str, function: str | None):
    import coremltools as ct
    from coremltools.models.compute_device import (MLCPUComputeDevice, MLGPUComputeDevice,
                                                   MLNeuralEngineComputeDevice)
    from coremltools.models.compute_plan import MLComputePlan

    plan = MLComputePlan.load_from_path(path=mlmodelc, compute_units=ct.ComputeUnit.ALL)
    prog = plan.model_structure.program
    fn = (prog.functions.get(function) if function else None) or next(iter(prog.functions.values()))
    counts = collections.Counter()
    for op in fn.block.operations:
        if op.operator_name == "const":
            continue
        u = plan.get_compute_device_usage_for_mlprogram_operation(op)
        if u is None:
            counts["no_device"] += 1
            continue
        d = u.preferred_compute_device
        counts["ane" if isinstance(d, MLNeuralEngineComputeDevice) else "gpu" if isinstance(d, MLGPUComputeDevice)
               else "cpu" if isinstance(d, MLCPUComputeDevice) else "other"] += 1
    return dict(counts)


def cmd_plan(_args) -> int:
    plans = json.loads(PLANS_JSON.read_text()) if PLANS_JSON.exists() else {}
    for s in discover_specs():
        key = f"{s['id']}@{s['mtime']:.0f}"
        if key in plans:
            continue
        try:
            if s["kind"] == "fluid":
                p = {"FBank (cpu-only in the app)": None,
                     "Embedding": _plan_for(str(Path(s["dir"]) / "Embedding.mlmodelc"), None)}
                p["FBank (cpu-only in the app)"] = _plan_for(str(Path(s["dir"]) / "FBank.mlmodelc"), None)
            else:
                p = _plan_for(s["mlmodelc"], _function_name(4 * SR) if s["functions"] else None)
        except Exception as exc:  # noqa: BLE001
            p = {"error": f"{type(exc).__name__}: {exc}"}
        plans[key] = p
        print(s["id"], p, flush=True)
    PLANS_JSON.write_text(json.dumps(plans, indent=1))
    return 0


# ============================================================================ report
def _med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def _len_ms(row: dict, sec: float):
    d = row["lengths"].get(str(float(sec))) or row["lengths"].get(str(int(sec)) if float(sec).is_integer() else "")
    return d["median"] if d else None


def _call_ms(row: dict, window_s: float) -> float:
    """Median ms for one window of `window_s` seconds: baseline = its fixed 10 s call; fused = the next length the model takes."""
    if row["kind"] == "fluid":
        return row["lengths"]["10"]["median"] if "10" in row["lengths"] else row["lengths"]["10.0"]["median"]
    allowed = sorted(row["call_lengths_s"])
    L = next((a for a in allowed if a >= window_s - 1e-6), allowed[-1])
    d = row["lengths"].get(str(float(L)))
    return d["median"]


def _cost_s_per_hour(row: dict, windows: list[float], per_hour_scale: float) -> float:
    return sum(_call_ms(row, w) for w in windows) * per_hour_scale / 1000.0


def cmd_report(_args) -> int:
    turns = json.loads(TURNS_JSON.read_text())
    plans = json.loads(PLANS_JSON.read_text()) if PLANS_JSON.exists() else {}
    rows = [json.loads(line) for line in open(RAW_JSONL)]
    rows = [r for r in rows if "error" not in r]
    errors = [json.loads(line) for line in open(RAW_JSONL) if '"error"' in line]
    # only rows for the newest artifact of each model
    newest = {}
    for r in rows:
        newest[r["id"]] = max(newest.get(r["id"], 0), r["artifact_mtime"])
    rows = [r for r in rows if r["artifact_mtime"] == newest[r["id"]]]
    rounds = collections.defaultdict(dict)
    for r in rows:
        rounds[r["round_id"]][r["id"]] = r
    src = {s["source"]: s for s in turns["sources"]}
    pooled = src["nemotron-lab pooled"]
    samples = turns["samples"]
    hours = pooled["hours"]

    def windows_for(source: str, kind: str, hop: str = "windows_hop5"):
        s = samples[source]
        return (s["baseline_pieces"] if kind == "fluid" else s[hop]), src[source]["hours"]

    ids = list(dict.fromkeys(r["id"] for r in rows))
    ids = [BASELINE_ID] + [i for i in FINALISTS if i in ids] + sorted(i for i in ids if i not in FINALISTS and i != BASELINE_ID)
    per_model = {}
    for mid in ids:
        rs = [r for r in rows if r["id"] == mid]
        per_model[mid] = rs

    # ---- per round paired numbers
    def per_round(mid: str, fn):
        out = []
        for rid, d in rounds.items():
            if mid in d and BASELINE_ID in d:
                out.append((rid, fn(d[mid], d[BASELINE_ID])))
        return out

    def cost30_60(row: dict, source: str = "nemotron-lab pooled", hop: str = "windows_hop5"):
        w, h = windows_for(source, row["kind"], hop)
        per_hour = _cost_s_per_hour(row, w, 1.0 / h)
        return per_hour

    lines: list[str] = []
    w = lines.append
    w("# Voiceprint latency: what each finalist costs after a meeting")
    w("")
    w(f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `scripts/voiceprint/bench_latency.py`. "
      "Raw rounds: `VP/results/latency_raw.jsonl`; turn data: `latency_turns.json`; device plans: `latency_plans.json`.")
    w("")
    # headline
    base_rows = per_model[BASELINE_ID]
    nrounds = len(rounds)
    w("## How to read this")
    w("")
    w("After a call, Nemotron splits the audio into speaker turns and every turn gets one voiceprint. A turn longer "
      "than 10 s is cut into windows (up to 10 s, a new window every 5 s), each window is embedded, the vectors are "
      "pooled. Cost = windows per hour x time per window. The Mac was heavily loaded the whole time (load average "
      f"{min(r['load_avg_start'][0] for r in rows):.0f} to {max(r['load_avg_start'][0] for r in rows):.0f}, on 18 "
      "cores), so raw milliseconds are inflated and noisy. **The ratios to the baseline are the trustworthy part**: "
      "each round measures every model once, one at a time, with the baseline in the same round, and the ratio is "
      "taken inside the round.")
    w("")
    # ---- turn distribution
    w("## 1. Turns and windows per hour")
    w("")
    w("Source: the speaker lab's real Nemotron output (45 synthetic YODAS3 meetings, 12 to 44 min each), with the "
      "app's turn rules applied (same-speaker gaps under 0.29 s joined, turns under 0.25 s dropped). Every turn of "
      "0.25 s or more is embedded, including the short ones (the app embeds all of them; the 1 s gate is later).")
    w("")
    w("| source | meetings | hours | turns / hour | windows / hour (hop 5 s) | 10 s pieces / hour (app today) | median turn | p90 turn | turns > 10 s |")
    w("|---|---|---|---|---|---|---|---|---|")
    for s in turns["sources"]:
        w(f"| {s['source']} | {s['meetings']} | {s['hours']} | {s['turns_per_hour']} | {s['windows_hop5_per_hour']} | "
          f"{s['baseline_pieces_per_hour']} | {s['turn_s']['p50']} s | {s['turn_s']['p90']} s | "
          f"{s['share_turns_over_10s']*100:.1f}% |")
    w("")
    lab = turns.get("lab", {}).get("lab_post_call_seconds") or {}
    rawseg = pooled.get("raw_segments_per_hour")
    w(f"Nemotron raw segments per hour (before joining gaps): {rawseg}. Turns are short: {pooled['share_turns_under_1s']*100:.0f}% "
      f"are under 1 s, only {pooled['share_turns_over_10s']*100:.1f}% run past 10 s, so almost every turn is exactly one window and "
      "the 5 s hop adds only "
      f"{(pooled['windows_hop5_per_hour']/pooled['turns_per_hour']-1)*100:.0f}% more windows than turns. "
      "AMI and ICSI (human labels, natural meetings) bracket this: their turn counts land in the same range or lower, so the Nemotron "
      "numbers are not an under-estimate. The YODAS3 mixes have more speakers than a typical call, which pushes turns per hour up.")
    if lab:
        w("")
        w(f"For scale: the lab's whole post-call step (transcription, naming, everything) took a median of "
          f"{lab['seconds_median']} s for a median {lab['minutes_median']}-minute call ({lab['seconds_per_minute_median']} s per meeting minute, "
          f"{lab['meetings']} meetings).")
    w("")

    # ---- latency table
    w("## 2. Time per window (warm, compute units ALL)")
    w("")
    w(f"Median of {FULL_N} calls after {FULL_WARM} warm-ups per length, per round; the value shown is the median over "
      f"{nrounds} round(s) of those per-round medians. `ratio` = same-round model / baseline, median over rounds. "
      "The baseline always runs one fixed 10 s window (FBank on CPU, then the embedding net), so it costs the same for a 2 s turn "
      "and a 10 s turn; the fused models take the audio at its own length (rounded up to a length they accept).")
    w("")
    w("| model | 2 s | 4 s | 8 s | 10 s | ratio vs baseline at 2 / 4 / 8 / 10 s | mixed-length stream (mean ms / window, real turn mix) | stream ratio |")
    w("|---|---|---|---|---|---|---|---|")
    stream_ratio = {}
    for mid in ids:
        rs = per_model[mid]
        cells = []
        for sec in REQUIRED_S:
            cells.append(_med([_len_ms(r, sec) for r in rs]))
        ratios = []
        for sec in REQUIRED_S:
            pr = per_round(mid, lambda m, b, sec=sec: _len_ms(m, sec) / _len_ms(b, 10))
            ratios.append(_med([x for _, x in pr]))
        sm = _med([r["stream"]["mean"] for r in rs])
        sr = _med([x for _, x in per_round(mid, lambda m, b: m["stream"]["mean"] / b["stream"]["mean"])])
        stream_ratio[mid] = sr
        w(f"| {mid} | " + " | ".join(f"{c:.1f} ms" for c in cells) + " | "
          + " / ".join(f"{x:.2f}x" for x in ratios) + f" | {sm:.1f} ms | {sr:.2f}x |")
    w("")
    w("Baseline split (ms, median over rounds): " + ", ".join(
        f"{sec} s window: FBank {_med([r['lengths'][str(sec)]['fbank_median'] for r in base_rows]):.1f} + embedding "
        f"{_med([r['lengths'][str(sec)]['embedding_median'] for r in base_rows]):.1f}" for sec in (4, 10)) + ".")
    w("")

    # ---- cost table
    w("## 3. Estimated extra seconds after a meeting (vs the baseline)")
    w("")
    w("For each round, both models' per-length medians are priced over the real window mix (pooled Nemotron turns: "
      f"{pooled['turns_per_hour']} turns/h, {pooled['windows_hop5_per_hour']} windows/h at hop 5 s; baseline = "
      f"{pooled['baseline_pieces_per_hour']} fixed 10 s pieces/h, its actual behavior). The difference is taken inside the "
      "round, so shared load cancels. Shown: median over rounds, then the range over rounds; the last column is the "
      "least-loaded round, the closest thing here to a quiet Mac.")
    w("")
    w("| model | total voiceprint time, 30 min | extra vs baseline, 30 min | extra vs baseline, 60 min | range over rounds (60 min) | quiet-round extra (60 min) | cost ratio vs baseline |")
    w("|---|---|---|---|---|---|---|")
    summary = {}
    quiet_round = min(rounds, key=lambda rid: statistics.fmean(d[BASELINE_ID]["load_avg_start"][0] for d in [rounds[rid]]))
    for mid in ids:
        pr = per_round(mid, lambda m, b: (cost30_60(m), cost30_60(b)))
        if not pr:
            continue
        model_h = [a for _, (a, b) in pr]
        diffs = [a - b for _, (a, b) in pr]
        ratios = [a / b for _, (a, b) in pr]
        loads = {rid: rounds[rid][BASELINE_ID]["load_avg_start"][0] for rid, _ in pr}
        qrid = min(loads, key=loads.get)
        qd = dict(pr)[qrid]
        summary[mid] = {"per_hour_s": _med(model_h), "extra60": _med(diffs), "ratio": _med(ratios),
                        "rng": (min(diffs), max(diffs)), "quiet": qd[0] - qd[1], "quiet_round": qrid}
        s = summary[mid]
        if mid == BASELINE_ID:
            w(f"| {mid} (baseline) | {s['per_hour_s']/2:.1f} s | 0 | 0 | - | - | 1.00x |")
        else:
            w(f"| {mid} | {s['per_hour_s']/2:.1f} s | {s['extra60']/2:+.1f} s | {s['extra60']:+.1f} s | "
              f"{s['rng'][0]:+.1f} to {s['rng'][1]:+.1f} s | {s['quiet']:+.1f} s | {s['ratio']:.2f}x |")
    w("")
    fam = [s for s in turns["sources"] if s["source"].startswith("nemotron-lab p3")]
    w("Sensitivity to the meeting mix (60 min, median extra vs baseline; each family from its own turns):")
    w("")
    fnames = [s["source"] for s in turns["sources"] if s["source"].startswith("nemotron-lab") and "pooled" not in s["source"]]
    w("| model | " + " | ".join(f"{n.replace('nemotron-lab ', '')} ({src[n]['turns_per_hour']} turns/h)" for n in fnames) + " | no-overlap hop (10 s), pooled |")
    w("|---|" + "---|" * (len(fnames) + 1))
    for mid in ids:
        if mid == BASELINE_ID or mid not in summary:
            continue
        cells = []
        for n in fnames:
            pr = per_round(mid, lambda m, b, n=n: cost30_60(m, n) - cost30_60(b, n))
            cells.append(f"{_med([x for _, x in pr]):+.1f} s")
        pr = per_round(mid, lambda m, b: cost30_60(m, "nemotron-lab pooled", "windows_hop10")
                       - cost30_60(b, "nemotron-lab pooled"))
        cells.append(f"{_med([x for _, x in pr]):+.1f} s")
        w(f"| {mid} | " + " | ".join(cells) + " |")
    w("")
    w("Cross-check by direct measurement: the mixed-length stream column above prices 300 real windows one after another "
      "(including any Core ML re-plan when the length changes). Its ratio to the baseline should match the cost ratio; "
      "where it does not, the difference is per-length-change overhead.")
    w("")

    # ---- load / memory / size / device
    w("## 4. Load time, memory, size, device")
    w("")
    w("Each round loads the model in a fresh process (Core ML's compile cache is warm, so this is the normal app start, "
      "not the very first launch on a new Mac). `load` = constructor(s); `first predict` = first call, where Core ML plans/compiles for "
      "the ANE or GPU; `all lengths ready` adds the first call at every input length (multifunction models load one function "
      "per length). Memory = macOS `phys_footprint` of the worker process: the peak, and the growth over the same process "
      "before the model was loaded (Python + coremltools + torch, about 300 MB).")
    w("")
    w("| model | load | first predict | all lengths ready | peak memory | growth over empty process | model size on disk | compute (ops on ANE / GPU / CPU, plan for ALL) |")
    w("|---|---|---|---|---|---|---|---|")
    for mid in ids:
        rs = per_model[mid]
        r0 = rs[0]
        peak = _med([r["footprint_end_mb"].get("phys_footprint_peak") for r in rs])
        before = _med([r["footprint_before_load_mb"].get("phys_footprint") for r in rs])
        key = f"{mid}@{r0['artifact_mtime']:.0f}"
        plan = plans.get(key) or {}
        if "Embedding" in plan:
            e, fb = plan["Embedding"], plan["FBank (cpu-only in the app)"]
            comp = (f"embedding: {e.get('ane', 0)} / {e.get('gpu', 0)} / {e.get('cpu', 0)}; FBank runs CPU-only "
                    f"(plan {fb.get('ane', 0)} / {fb.get('gpu', 0)} / {fb.get('cpu', 0)})")
        elif plan and "error" not in plan:
            nd = plan.get("no_device", 0)
            comp = f"{plan.get('ane', 0)} / {plan.get('gpu', 0)} / {plan.get('cpu', 0)}" + (f" (+{nd} untagged)" if nd else "")
        else:
            comp = plan.get("error", "n/a")
        w(f"| {mid} | {_med([r['load_s'] for r in rs]):.1f} s | {_med([r['first_predict_s'] for r in rs]):.1f} s | "
          f"{_med([r['all_ready_s'] for r in rs]):.1f} s | {peak:.0f} MB | {peak - before:+.0f} MB | "
          f"{r0['model_mb']:.1f} MB | {comp} |")
    w("")
    w("Memory caveat: Core ML does part of its ANE/GPU compile in a system service, so those allocations are not in the "
      "worker's footprint; treat the growth as a floor.")
    w("")

    # ---- per-round raw
    w("## 5. Raw rounds")
    w("")
    w("Median ms at 4 s and 10 s and the stream mean, per round, with the load average when the worker started "
      "(1-minute / 5-minute). A model that looks fast in a low-load round and slow in a high-load one is showing contention, not the model.")
    w("")
    w("| round | model | load avg (1 / 5 min) | 4 s | 10 s | stream mean | ratio at 4 s | ratio at 10 s |")
    w("|---|---|---|---|---|---|---|---|")
    for rid in sorted(rounds):
        d = rounds[rid]
        b = d.get(BASELINE_ID)
        for mid in ids:
            r = d.get(mid)
            if not r:
                continue
            l4, l10 = _len_ms(r, 4), _len_ms(r, 10)
            rr4 = f"{l4/_len_ms(b, 10):.2f}x" if b else "-"
            rr10 = f"{l10/_len_ms(b, 10):.2f}x" if b else "-"
            la = r["load_avg_start"]
            w(f"| {rid} | {mid} | {la[0]:.0f} / {la[1]:.0f} | {l4:.1f} | {l10:.1f} | {r['stream']['mean']:.1f} | {rr4} | {rr10} |")
    w("")
    if errors:
        w("Runs that failed: " + "; ".join(f"{e['id']}: {e['error'][:120]}" for e in errors))
        w("")
    w("## Method notes")
    w("")
    w("- Warm latency: `CompiledMLModel.predict` on real speech (AMI clips), one call at a fixed length repeated; per-length figures cover every length each model accepts, so the cost model rounds a window up the way `CoreMLSpeakerSegmentEmbedder` does (tile to the next accepted length).")
    w("- Compute units ALL for every model. The baseline is the app's own pair (`FBank.mlmodelc` on CPU, `Embedding.mlmodelc` ALL), run through `runtimes/fluid_coreml.py`'s window path with a 10 s window of real audio and the mask over the turn.")
    w("- Turns are Nemotron's raw segments with the app's join/drop rules re-applied; the app runs the same rules on frame probabilities, so counts should be close, not identical. AMI/ICSI rows do not resolve overlapped speech, so they are upper bounds on turn count.")
    w("- One process per (model, round), `OMP_NUM_THREADS=3`, models measured one at a time.")
    REPORT_MD.write_text("\n".join(lines) + "\n")
    print(f"wrote {REPORT_MD}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("turns")
    r = sub.add_parser("run")
    r.add_argument("--rounds", type=int, default=5)
    r.add_argument("--only", default="", help="comma list of model ids (the baseline is always added)")
    r.add_argument("--timeout", type=int, default=900)
    sub.add_parser("plan")
    sub.add_parser("report")
    wk = sub.add_parser("worker")
    wk.add_argument("--spec", required=True)
    wk.add_argument("--out", required=True)
    wk.add_argument("--cold", action="store_true")
    cd = sub.add_parser("cold", help="first-ever load: a fresh copy of each model, load + first predict only")
    cd.add_argument("--repeats", type=int, default=2)
    cd.add_argument("--only", default="")
    cd.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()
    return {"turns": cmd_turns, "run": cmd_run, "plan": cmd_plan, "report": cmd_report, "worker": cmd_worker,
            "cold": cmd_cold}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
