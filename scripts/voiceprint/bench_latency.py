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
  cold     first-ever load: a content-changed copy of each model (Core ML has never planned it), load + first predict at
           every length -> VP/results/latency_cold.jsonl. Run it while no timing round is running.
  plan     which device (ANE / GPU / CPU) Core ML plans for each model's ops -> latency_plans.json
  report   VP/results/latency.md from the files above. Rounds are split into calm and contended by how the baseline
           (identical work every call, CPU-bound FBank) behaved; the headline uses the calm ones.
  worker   (internal) one model, one process: load, warm latency per length, a 300-window stream with real turn
           lengths in arrival order and grouped by length, memory. Writes one JSON object.

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
        # A fresh, content-changed copy: Core ML caches its ANE/GPU plans by model content, so a plain copy would hit the
        # cache of the original. Appending a random number of trailing newlines to each model.mil (harmless to the parser)
        # makes the bundle new to Core ML, which is what a user's first launch after install looks like.
        cold_dir = Path(tempfile.mkdtemp(prefix="benchlat_cold_"))
        import shutil

        def fresh_copy(src: str, dst: Path):
            shutil.copytree(src, dst, copy_function=shutil.copyfile)
            for mil in dst.rglob("model.mil"):
                with open(mil, "ab") as f:
                    f.write(b"\n" * (1 + int.from_bytes(os.urandom(2), "big")))

        if spec["kind"] == "fluid":
            for name in ("FBank.mlmodelc", "Embedding.mlmodelc"):
                fresh_copy(str(Path(spec["dir"]) / name), cold_dir / name)
            spec = dict(spec, dir=str(cold_dir))
        else:
            fresh_copy(spec["mlmodelc"], cold_dir / "model.mlmodelc")
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
        call_ns = [next((L for L in lengths if L >= int(round(w * SR)) - 1), lengths[-1]) for w in stream_windows]
        ts, calls = [], []
        for n in call_ns:
            t0 = time.perf_counter()
            call(n)
            ts.append((time.perf_counter() - t0) * 1000)
            calls.append([n / SR, round(ts[-1], 2)])
        res["stream"] = _stats(ts)
        res["stream_calls"] = calls  # (call length s, ms) in arrival order
        # Same windows, grouped by call length: an app can sort windows by length so each length is
        # planned once. Shows how much of the stream cost is length-change overhead.
        ts_g, calls_g = [], []
        for n in sorted(call_ns):
            t0 = time.perf_counter()
            call(n)
            ts_g.append((time.perf_counter() - t0) * 1000)
            calls_g.append([n / SR, round(ts_g[-1], 2)])
        res["stream_grouped"] = _stats(ts_g)
        res["stream_grouped_calls"] = calls_g
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


def _lookup(row: dict, sec: float):
    return row["lengths"].get(str(float(sec))) or row["lengths"].get(str(int(sec)) if float(sec).is_integer() else "")


def _len_stat(row: dict, sec: float, stat: str = "median"):
    d = _lookup(row, sec)
    return d[stat] if d else None


def _call_ms(row: dict, window_s: float, stat: str = "median") -> float:
    """ms for one window of `window_s` seconds. Baseline: its fixed 10 s call whatever the length.
    Fused: the next length the model accepts (CoreMLSpeakerSegmentEmbedder tiles up to it)."""
    if row["kind"] == "fluid":
        # one fixed 10 s call whatever the turn length: the four measured "lengths" are identical work, so pool them
        vals = [_len_stat(row, sec, stat) for sec in REQUIRED_S]
        return min(vals) if stat == "p10" else statistics.median(vals)
    allowed = sorted(row["call_lengths_s"])
    L = next((a for a in allowed if a >= window_s - 1e-6), allowed[-1])
    return _len_stat(row, L, stat)


def _is_multifunction(row: dict) -> bool:
    return len(row.get("load_s_per_function") or {}) > 1


def _stream_split(row: dict) -> dict | None:
    """From the stream (arrival order) and the same windows grouped by length: mean ms per window when each
    call is priced at its length's median in each run, and the difference (the length-change overhead)."""
    if "stream_calls" not in row or "stream_grouped_calls" not in row:
        return None
    by, byg = collections.defaultdict(list), collections.defaultdict(list)
    for length, ms in row["stream_calls"]:
        by[length].append(ms)
    for length, ms in row["stream_grouped_calls"]:
        byg[length].append(ms)
    calls = [length for length, _ in row["stream_calls"]]
    arrive = statistics.fmean(statistics.median(by[c]) for c in calls)
    grouped = statistics.fmean(statistics.median(byg[c]) for c in calls)
    return {"as_arrive": arrive, "grouped": grouped, "overhead": arrive - grouped}


def _fmt_range(lo: float, hi: float) -> str:
    return f"{lo:+.1f} to {hi:+.1f}"


def cmd_report(_args) -> int:
    turns = json.loads(TURNS_JSON.read_text())
    plans = json.loads(PLANS_JSON.read_text()) if PLANS_JSON.exists() else {}
    all_rows = [json.loads(line) for line in open(RAW_JSONL)]
    errors = [r for r in all_rows if "error" in r]
    rows = [r for r in all_rows if "error" not in r]
    newest: dict = {}  # only the newest artifact of each model (a rebuild replaces the old numbers)
    for r in rows:
        newest[r["id"]] = max(newest.get(r["id"], 0), r["artifact_mtime"])
    rows = [r for r in rows if r["artifact_mtime"] == newest[r["id"]]]
    rounds: dict = collections.defaultdict(dict)
    for r in rows:
        rounds[r["round_id"]][r["id"]] = r
    src = {s["source"]: s for s in turns["sources"]}
    pooled = src["nemotron-lab pooled"]
    samples = turns["samples"]

    ids = list(dict.fromkeys(r["id"] for r in rows))
    ids = [BASELINE_ID] + [i for i in FINALISTS if i in ids] + sorted(
        i for i in ids if i not in FINALISTS and i != BASELINE_ID)
    per_model = {mid: [r for r in rows if r["id"] == mid] for mid in ids}
    paired_rounds = sorted(rid for rid, d in rounds.items() if BASELINE_ID in d)
    # A round is "calm" when the baseline, which runs identical work every call, took at most twice its best
    # round's time: its FBank stage is CPU-only, so it is the canary for contention.
    base_round_ms = {rid: statistics.median(_len_stat(rounds[rid][BASELINE_ID], sec) for sec in REQUIRED_S) for rid in paired_rounds}
    calm_rounds = [rid for rid in paired_rounds if base_round_ms[rid] <= 2.0 * min(base_round_ms.values())]
    heavy_rounds = [rid for rid in paired_rounds if rid not in calm_rounds]

    def per_round(mid: str, fn, only=None):
        return [(rid, fn(rounds[rid][mid], rounds[rid][BASELINE_ID])) for rid in (only if only is not None else calm_rounds)
                if mid in rounds[rid]]

    def calm_rows(mid: str):
        return [r for r in per_model[mid] if r["round_id"] in calm_rounds]

    cold_rows = [json.loads(line) for line in open(COLD_JSONL)] if COLD_JSONL.exists() else []
    cold_rows = [r for r in cold_rows if "error" not in r]

    def plan_of(mid: str) -> dict:
        r0 = max(per_model[mid], key=lambda r: r["artifact_mtime"])
        return plans.get(f"{mid}@{r0['artifact_mtime']:.0f}") or {}

    def device_of(mid: str) -> str:
        plan = plan_of(mid)
        if "Embedding" in plan:
            e = plan["Embedding"]
            return f"GPU for the embedding net ({e.get('gpu', 0)} of {sum(e.values())} ops), CPU for FBank"
        if not plan or "error" in plan:
            return "unknown"
        n = {k: plan.get(k, 0) for k in ("ane", "gpu", "cpu")}
        tot = sum(n.values())
        main = max(n, key=n.get)
        label = {"ane": "Neural Engine", "gpu": "GPU", "cpu": "CPU"}[main]
        rest = [f"{n[k]} on {k.upper()}" for k in ("ane", "gpu", "cpu") if k != main and n[k]]
        return f"{label} ({n[main]} of {tot} ops" + (", " + ", ".join(rest) if rest else "") + ")"

    def warm_load(mid: str, key: str = "first_predict_s") -> tuple:
        rows_c = calm_rows(mid) or per_model[mid]
        vals = [r["load_s"] + r["first_predict_s"] if key == "first_predict_s" else r["all_ready_s"] for r in rows_c]
        worst = max((r["load_s"] + r["first_predict_s"]) if key == "first_predict_s" else r["all_ready_s"] for r in per_model[mid])
        return _med(vals), worst

    def cold_load(mid: str, key: str = "first_predict_s"):
        cr = [r for r in cold_rows if r["id"] == mid]
        if not cr:
            return None
        return _med([r["load_s"] + r["first_predict_s"] if key == "first_predict_s" else r["all_ready_s"] for r in cr])

    def peak_growth(mid: str, one: bool = False):
        rs = per_model[mid]
        if one:
            return _med([r["footprint_after_first_predict_mb"]["phys_footprint"] - r["footprint_before_load_mb"]["phys_footprint"] for r in rs])
        return _med([r["footprint_end_mb"]["phys_footprint_peak"] - r["footprint_before_load_mb"]["phys_footprint"] for r in rs])

    overhead_cache: dict = {}

    def switch_overhead_ms(mid: str) -> float:
        """Extra ms per window when the input length changes call to call, for a model that is one enumerated-shape graph
        (the wespeaker builds). Median over the rounds that recorded it. Multifunction builds hold one graph per length: 0."""
        if mid not in overhead_cache:
            rs = calm_rows(mid)
            if not rs or rs[0]["kind"] == "fluid" or any(_is_multifunction(r) for r in rs):
                overhead_cache[mid] = 0.0
            else:
                vals = [x["overhead"] for x in (_stream_split(r) for r in rs) if x]
                overhead_cache[mid] = max(0.0, _med(vals) or 0.0)
        return overhead_cache[mid]

    def cost_per_hour(row: dict, source: str = "nemotron-lab pooled", hop: str = "windows_hop5", stat: str = "median",
                      overhead: bool = True):
        """Voiceprint seconds per hour of meeting: every window priced at its call length's per-length latency, plus the
        measured length-change overhead for enumerated-shape models."""
        smp = samples[source]
        win = smp["baseline_pieces"] if row["kind"] == "fluid" else smp[hop]
        ms = sum(_call_ms(row, w, stat) for w in win) + (switch_overhead_ms(row["id"]) * len(win) if overhead else 0.0)
        return ms / 1000.0 / src[source]["hours"]

    def model_mean_ms(row: dict, stat: str = "median"):
        win = samples["nemotron-lab pooled"]["windows_hop5"]
        return statistics.fmean(_call_ms(row, w, stat) for w in win)

    lines: list[str] = []
    w = lines.append
    loads = [r["load_avg_start"][0] for r in rows]
    w("# Voiceprint latency: what each finalist costs after a meeting")
    w("")
    w(f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `scripts/voiceprint/bench_latency.py` ({len(paired_rounds)} interleaved rounds). "
      "Raw data: `latency_raw.jsonl`, `latency_cold.jsonl`, `latency_plans.json`, `latency_turns.json` in this folder.")
    w("")
    w("After a call, Nemotron splits the audio into speaker turns and every turn gets one voiceprint. A turn longer than 10 s is cut "
      "into windows (up to 10 s, a new window every 5 s), each window is embedded, and the vectors are averaged. So the cost is "
      "windows per hour times time per window. Everything below runs Core ML with compute units ALL on an M5 Max.")
    w("")
    w(f"**The Mac was heavily loaded the whole time** (load average {min(loads):.0f} to {max(loads):.0f} on 18 cores, because other agents were embedding datasets). "
      "Raw milliseconds are noisy and, for anything that touches the CPU, inflated. Each round times every model once, one at a time, "
      "with the baseline in the same round, and the ratio is taken inside the round; those ratios are the trustworthy part. "
      "The rounds are split into calm and contended by how the baseline behaved (see the answer below), and \"fastest 10%\" (p10) is what "
      "a call costs when nothing else is competing.")
    w("")

    # ---------------- headline
    w("## Answer: extra seconds after a meeting, vs the app's current model")
    w("")
    w(f"{len(paired_rounds)} rounds were run. {len(calm_rounds)} were calm (the baseline, which does identical work every call, ran at "
      f"{min(base_round_ms[r] for r in calm_rounds):.0f} to {max(base_round_ms[r] for r in calm_rounds):.0f} ms per call) and {len(heavy_rounds)} were contended "
      f"({min(base_round_ms[r] for r in heavy_rounds):.0f} to {max(base_round_ms[r] for r in heavy_rounds):.0f} ms per call; the CPU-only FBank stage stalls). "
      "The headline uses the calm rounds; the busy-Mac column uses all of them." if heavy_rounds else
      f"All {len(paired_rounds)} rounds were calm.")
    w("")
    w("| model | extra, 30-min meeting | extra, 60-min meeting | range over calm rounds (60 min) | busy Mac, 60 min (all rounds, mean of raw calls) | its total voiceprint time, 60 min (calm) | cost vs baseline (calm) |")
    w("|---|---|---|---|---|---|---|")
    summary = {}
    for mid in ids:
        pr = per_round(mid, lambda m, b: (cost_per_hour(m), cost_per_hour(b)))
        if not pr:
            continue
        v = [x for _, x in pr]
        d = [a - b for a, b in v]
        def busy(row):  # mean of the 300 raw arrival-order calls, priced over the hour's window count (stalls included)
            n = pooled["baseline_pieces_per_hour"] if row["kind"] == "fluid" else pooled["windows_hop5_per_hour"]
            return row["stream"]["mean"] * n / 1000.0

        hv = per_round(mid, lambda m, b: busy(m) - busy(b), only=paired_rounds)
        summary[mid] = {"total": _med([a for a, _ in v]), "extra": _med(d), "range": (min(d), max(d)),
                        "ratio": _med([a / b for a, b in v]), "base_total": _med([b for _, b in v]),
                        "heavy": _med([x for _, x in hv])}
        s_ = summary[mid]
        if mid == BASELINE_ID:
            w(f"| **{mid}** (baseline) | 0 | 0 | - | 0 | {s_['total']:.0f} s | 1.00x |")
        else:
            hh = f"{s_['heavy']:+.0f} s" if s_["heavy"] is not None else "n/a"
            w(f"| **{mid}** | {s_['extra']/2:+.1f} s | {s_['extra']:+.1f} s | {_fmt_range(*s_['range'])} s | {hh} | "
              f"{s_['total']:.0f} s | {s_['ratio']:.2f}x |")
    w("")
    w(f"How this is priced: every window of the real turn mix ({pooled['turns_per_hour']} turns and {pooled['windows_hop5_per_hour']} windows per hour, hop 5 s) "
      "is charged the time its model takes for a window of that length (the fused models take the length rounded up to one they accept; the baseline "
      f"embeds {pooled['baseline_pieces_per_hour']} fixed 10 s pieces per hour whatever the turn length), plus, for the wespeaker builds, the measured "
      "cost of the input length changing from call to call. \"Extra\" is the model's time minus the baseline's time **in the same round**, median over rounds. "
      "Negative means faster than today. The calm columns are median-call costs on the calm rounds; the busy-Mac column is the plain mean of "
      "300 raw calls in arrival order, stalls included, over all rounds. Both leave out load time, which is larger than any of the per-window "
      "differences (section 4).")
    w("")
    w("Why two views: the baseline's FBank stage runs on the CPU only, and while the Mac is busy about one call in five stalls for 100 ms or more; the ANE and "
      "GPU models stay close to their median. On a quiet Mac the models are within a few seconds of each other per hour of meeting (the calm columns). "
      "On a Mac that is busy while the meeting is processed, the baseline's mean cost per window is "
      f"{_med([r['stream']['mean'] for r in per_model[BASELINE_ID]]):.0f} ms (mean of raw calls over all rounds) and the challengers' are "
      + ", ".join(f"{_med([r['stream']['mean'] for r in per_model[mid]]):.0f} ms ({mid})" for mid in ids if mid != BASELINE_ID) + ".")
    w("")

    w("### At a glance")
    w("")
    w("Warm latency per window, calm rounds, ms at 2 / 4 / 8 / 10 s (the baseline is one fixed 10 s call for every length).")
    w("")
    w("| model | ms per window at 2 / 4 / 8 / 10 s | extra, 30 min | extra, 60 min | warm load | first-ever load | memory growth (peak) | size on disk | runs on |")
    w("|---|---|---|---|---|---|---|---|---|")
    for mid in ids:
        rs = calm_rows(mid)
        lat = " / ".join(f"{_med([_len_stat(r, sec) for r in rs]):.0f}" for sec in REQUIRED_S)
        sm = summary.get(mid)
        e30 = "0" if mid == BASELINE_ID else f"{sm['extra']/2:+.1f} s"
        e60 = "0" if mid == BASELINE_ID else f"{sm['extra']:+.1f} s"
        wl = warm_load(mid, "all")
        wl1 = warm_load(mid)
        cl = cold_load(mid, "all")
        wtxt = f"{wl1[0]:.1f} s" + (f" ({wl[0]:.0f} s for all lengths)" if wl[0] > wl1[0] * 2 else "")
        ctxt = "not run" if cl is None else (f"{cold_load(mid):.0f} s" + (f" ({cl:.0f} s all lengths)" if cl > cold_load(mid) * 2 else ""))
        w(f"| **{mid}** | {lat} | {e30} | {e60} | {wtxt} | {ctxt} | +{peak_growth(mid):.0f} MB | "
          f"{per_model[mid][0]['model_mb']:.0f} MB | {device_of(mid)} |")
    w("")

    w("### Takeaways")
    w("")
    for mid in ids:
        sm = summary.get(mid)
        wl1, wl_worst = warm_load(mid)
        wl_all, _ = warm_load(mid, "all")
        cl = cold_load(mid, "all")
        lat10 = _med([_len_stat(r, 10) for r in calm_rows(mid)])
        if mid == BASELINE_ID:
            w(f"- **{mid}** (today): {sm['total']:.0f} s of voiceprint time per 60-minute meeting, loads in under a second, +{peak_growth(mid):.0f} MB, "
              f"{device_of(mid)}. Under CPU load its FBank stage stalls, so it is the model most sensitive to a busy Mac.")
            continue
        extra = f"{sm['extra']:+.1f} s per 60-minute meeting ({sm['extra']/2:+.1f} s per 30-minute)"
        load = f"{wl1:.0f} s warm load" + (f" ({wl_all:.0f} s to have every length ready)" if wl_all > wl1 * 2 else "")
        cold = (f", {cl:.0f} s first-ever" + (" with every length" if wl_all > wl1 * 2 else "")) if cl else ""
        w(f"- **{mid}**: {extra} at the median call; {load}{cold}; +{peak_growth(mid):.0f} MB; {lat10:.0f} ms for a full 10 s window; {device_of(mid)}.")
    w("")

    # ---------------- turns
    w("## 1. Turns and windows per hour")
    w("")
    w("The primary source is the speaker lab's real Nemotron output (45 synthetic YODAS3 meetings, 12 to 44 min each, 21 hours), "
      "with the app's turn rules re-applied (same-speaker gaps under 0.29 s joined, turns under 0.25 s dropped). The app embeds every "
      "turn of 0.25 s or more, including the short ones. AMI and ICSI (human labels, real meetings) are a cross-check.")
    w("")
    w("| source | meetings | hours | turns / hour | windows / hour (hop 5 s) | fixed 10 s pieces / hour (app today) | median turn | p90 turn | turns > 10 s |")
    w("|---|---|---|---|---|---|---|---|---|")
    for s in turns["sources"]:
        w(f"| {s['source']} | {s['meetings']} | {s['hours']} | {s['turns_per_hour']} | {s['windows_hop5_per_hour']} | "
          f"{s['baseline_pieces_per_hour']} | {s['turn_s']['p50']} s | {s['turn_s']['p90']} s | {s['share_turns_over_10s']*100:.1f}% |")
    w("")
    lab = turns.get("lab", {}).get("lab_post_call_seconds") or {}
    w(f"Turns are short: {pooled['share_turns_under_1s']*100:.0f}% are under 1 s and only {pooled['share_turns_over_10s']*100:.1f}% run past 10 s, "
      f"so almost every turn is one window and the 5 s hop adds only {(pooled['windows_hop5_per_hour']/pooled['turns_per_hour']-1)*100:.0f}% "
      f"more windows than turns. The lab pool ({pooled['turns_per_hour']} turns/h) sits between AMI ({src['ami (human labels)']['turns_per_hour']}) "
      f"and ICSI ({src['icsi (human labels)']['turns_per_hour']}, seven-person research meetings, overlap not resolved so it is an upper bound); "
      "the family rows show how much the count moves with the number of speakers (A is 1 to 3 speakers, C is 5 to 8).")
    if lab:
        w("")
        w(f"For scale: the lab's whole post-call step (transcription, naming, everything) took a median {lab['seconds_median']} s for a median "
          f"{lab['minutes_median']}-minute call ({lab['seconds_per_minute_median']} s per meeting minute, {lab['meetings']} meetings).")
    w("")

    # ---------------- per-window latency
    w("## 2. Time per window")
    w("")
    w(f"Warm latency of one model call, median of {FULL_N} calls after {FULL_WARM} warm-ups at each length, per round; the cell is the median "
      f"over the {len(calm_rounds)} calm rounds, with the fastest-10% value (p10) in brackets. The baseline always runs one fixed 10 s window (FBank on CPU, then the "
      "embedding net), so a 2 s turn costs what a 10 s turn does. The fused models take the audio at its own length, rounded up to a length they accept.")
    w("")
    w("| model | 2 s | 4 s | 8 s | 10 s | ratio to baseline, 2 / 4 / 8 / 10 s (median, fastest 10%) |")
    w("|---|---|---|---|---|---|")
    for mid in ids:
        rs = calm_rows(mid)
        cells = [f"{_med([_len_stat(r, sec) for r in rs]):.1f} ms ({_med([_len_stat(r, sec, 'p10') for r in rs]):.1f})" for sec in REQUIRED_S]
        rat = []
        for sec in REQUIRED_S:
            a = _med([x for _, x in per_round(mid, lambda m, b, sec=sec: _len_stat(m, sec) / _len_stat(b, 10))])
            q = _med([x for _, x in per_round(mid, lambda m, b, sec=sec: _len_stat(m, sec, "p10") / _len_stat(b, 10, "p10"))])
            rat.append(f"{a:.2f}x ({q:.2f}x)")
        w(f"| {mid} | " + " | ".join(cells) + " | " + " / ".join(rat) + " |")
    base_rows = calm_rows(BASELINE_ID)
    w("")
    w("Baseline split (median ms over calm rounds): " + "; ".join(
        f"{sec} s turn: FBank {_med([r['lengths'][str(sec)]['fbank_median'] for r in base_rows]):.1f} + embedding "
        f"{_med([r['lengths'][str(sec)]['embedding_median'] for r in base_rows]):.1f}" for sec in (2, 10)) +
      ". FBank is CPU-only in the app, so it is what contention hits first.")
    w("")
    w("Mean cost of one window over the real turn mix (calm rounds; each window of the Nemotron pool priced at its call length):")
    w("")
    w("| model | median call | fastest 10% of calls | ratio to baseline, same round (median / fastest 10%) |")
    w("|---|---|---|---|")
    for mid in ids:
        rs = calm_rows(mid)
        a = _med([model_mean_ms(r) for r in rs])
        q = _med([model_mean_ms(r, "p10") for r in rs])
        ra = _med([x for _, x in per_round(mid, lambda m, b: model_mean_ms(m) / model_mean_ms(b))])
        rq = _med([x for _, x in per_round(mid, lambda m, b: model_mean_ms(m, "p10") / model_mean_ms(b, "p10"))])
        w(f"| {mid} | {a:.1f} ms | {q:.1f} ms | {ra:.2f}x / {rq:.2f}x |")
    w("")
    w("Direct check with real turn lengths: 300 windows drawn from the Nemotron pool, timed one after another in arrival order "
      "(so the input length changes from call to call), then the same 300 sorted by length so each length is planned once. Each call is "
      "priced at its length's median within its run; the mean is over windows. The difference is what changing length costs.")
    w("")
    w("| model | as they arrive | grouped by length | length-change overhead | applied to the estimate | mean of raw calls (arrival order) |")
    w("|---|---|---|---|---|---|")
    for mid in ids:
        rs = calm_rows(mid)
        sp = [x for x in (_stream_split(r) for r in rs) if x]
        raw_mean = _med([r["stream"]["mean"] for r in rs])
        if not sp:
            w(f"| {mid} | n/a (fixed 10 s window, length never changes) | | | 0 | {raw_mean:.1f} ms |")
            continue
        w(f"| {mid} | {_med([x['as_arrive'] for x in sp]):.1f} ms | {_med([x['grouped'] for x in sp]):.1f} ms | "
          f"{_med([x['overhead'] for x in sp]):+.1f} ms | {switch_overhead_ms(mid):.1f} ms | {raw_mean:.1f} ms |")
    w("")
    w("The enumerated wespeaker builds pay a few ms whenever the length differs from the previous call; the multifunction ReDimNet builds keep one graph per length "
      "and show none beyond noise. An app that sorts windows by length before embedding avoids the overhead. The last column is the plain mean of the raw calls, "
      "which contention tails inflate; it is shown so the loaded reality is visible.")
    w("")

    # ---------------- sensitivity
    w("## 3. How the estimate moves with the meeting mix")
    w("")
    w("Extra seconds for a 60-minute meeting vs the baseline (median over calm rounds), pricing each family's own turns:")
    w("")
    fnames = [s["source"] for s in turns["sources"] if s["source"].startswith("nemotron-lab") and "pooled" not in s["source"]]
    extra_srcs = [n for n in ("ami (human labels)", "icsi (human labels)") if n in src]
    cols = fnames + extra_srcs
    w("| model | " + " | ".join(f"{n.replace('nemotron-lab ', '')} ({src[n]['turns_per_hour']}/h)" for n in cols) + " | pooled, no window overlap |")
    w("|---|" + "---|" * (len(cols) + 1))
    for mid in ids:
        if mid == BASELINE_ID or mid not in summary:
            continue
        cells = []
        for n in cols:
            cells.append(f"{_med([x for _, x in per_round(mid, lambda m, b, n=n: cost_per_hour(m, n) - cost_per_hour(b, n))]):+.1f} s")
        cells.append(f"{_med([x for _, x in per_round(mid, lambda m, b: cost_per_hour(m, hop='windows_hop10') - cost_per_hour(b))]):+.1f} s")
        w(f"| {mid} | " + " | ".join(cells) + " |")
    w("")

    # ---------------- load / memory / size / device
    w("## 4. Load time, memory, size, compute device")
    w("")
    w("**Load time is the real cost here, not the per-window time.** Every model was loaded in a fresh process each round. `warm load` is the "
      "constructor plus the first prediction for a model Core ML has already planned for this Mac (what every app launch after the first costs): "
      "median over the calm rounds, with the slowest round in brackets. `first-ever` is a content-changed copy that Core ML has never planned "
      "(the first launch after install), 2 runs each, measured while other jobs kept the Mac at load 140 to 180. `all lengths` also loads and runs the graph for "
      "every input length the model takes. The wespeaker builds are one graph with 13 enumerated lengths on the Neural Engine; that whole load lands in "
      "the constructor (it probably plans every enumerated length, which would make fewer lengths load faster; not tested). The ReDimNet builds are 10 "
      "separate per-length functions on the GPU, about 4 s each, loaded as each length is first needed. Load and compile run on the CPU, so all of these "
      "are slower when the Mac is busy.")
    w("")
    w("| model | warm load + first predict | warm, all lengths ready | first-ever load + first predict | first-ever, all lengths | model size on disk | ops planned on ANE / GPU / CPU |")
    w("|---|---|---|---|---|---|---|")
    for mid in ids:
        rs = per_model[mid]
        plan = plan_of(mid)
        if "Embedding" in plan:
            e = plan["Embedding"]
            comp = f"embedding net {e.get('ane', 0)} / {e.get('gpu', 0)} / {e.get('cpu', 0)}; FBank pinned to CPU"
        elif plan and "error" not in plan:
            nd = plan.get("no_device", 0)
            comp = f"{plan.get('ane', 0)} / {plan.get('gpu', 0)} / {plan.get('cpu', 0)}" + (f" (+{nd} untagged)" if nd else "")
        else:
            comp = plan.get("error", "n/a")
        wa, wa_worst = warm_load(mid)
        wb, wb_worst = warm_load(mid, "all")
        c1, c2 = cold_load(mid), cold_load(mid, "all")
        w(f"| {mid} | {wa:.1f} s ({wa_worst:.0f} s) | {wb:.1f} s ({wb_worst:.0f} s) | "
          f"{'not run' if c1 is None else f'{c1:.1f} s'} | {'not run' if c2 is None else f'{c2:.1f} s'} | {rs[0]['model_mb']:.1f} MB | {comp} |")
    w("")
    w("Memory: macOS `phys_footprint` of the worker process, minus the same process before the model was loaded (Python + coremltools, torch blocked). "
      "\"One graph\" is after loading the 4 s graph or function and running it; \"all lengths\" is the peak after every length was loaded and run.")
    w("")
    w("| model | growth, one graph loaded | growth, all lengths (peak) | note |")
    w("|---|---|---|---|")
    for mid in ids:
        rs = per_model[mid]
        note = ("FBank (CPU) + embedding net (GPU); one fixed 10 s shape" if mid == BASELINE_ID else
                "one function per length, each holds its own GPU buffers" if _is_multifunction(rs[0]) else
                "one graph, 13 enumerated lengths on the ANE (ANE memory is outside the process footprint, so read this as a floor)")
        w(f"| {mid} | {peak_growth(mid, True):+.0f} MB | {peak_growth(mid):+.0f} MB | {note} |")
    w("")
    w("An app that loads only the ReDimNet lengths it needs, or unloads them after the meeting, sits near the \"one graph\" figure per length.")
    w("")

    # ---------------- raw rounds
    w("## 5. Raw rounds")
    w("")
    w("Per round: median ms at 4 s and 10 s and the stream mean, the load average when the worker started (1 / 5 minute), and the ratio to the "
      "baseline in that round. A model that is fast in a low-load round and slow in a high-load one is showing contention, not the model.")
    w("")
    w("| round | calm? | model | load avg (1 / 5 min) | 4 s | 10 s | stream mean | ratio at 4 s | ratio at 10 s |")
    w("|---|---|---|---|---|---|---|---|---|")
    for rid in sorted(rounds):
        d = rounds[rid]
        b = d.get(BASELINE_ID)
        for mid in ids:
            r = d.get(mid)
            if not r:
                continue
            l4, l10 = _len_stat(r, 4), _len_stat(r, 10)
            rr4 = f"{l4/_len_stat(b, 10):.2f}x" if b else "-"
            rr10 = f"{l10/_len_stat(b, 10):.2f}x" if b else "-"
            la = r["load_avg_start"]
            w(f"| {rid} | {'calm' if rid in calm_rounds else 'contended'} | {mid} | {la[0]:.0f} / {la[1]:.0f} | {l4:.1f} | {l10:.1f} | "
              f"{r['stream']['mean']:.1f} | {rr4} | {rr10} |")
    w("")
    if errors:
        w("Runs that failed: " + "; ".join(f"{e['id']}: {e['error'][:120]}" for e in errors))
        w("")
    w("## Method notes")
    w("")
    w("- Warm latency: `CompiledMLModel.predict` on real speech (AMI clips) at a fixed length, repeated. Every length a model accepts is timed, so the cost model rounds a window up the way `CoreMLSpeakerSegmentEmbedder` does (tile to the next accepted length). 2, 4, 8 and 10 s get 10 warm-ups plus 50 timed calls; the other lengths get 4 plus 20.")
    w("- The baseline is the app's own pair (`FBank.mlmodelc` on CPU, `Embedding.mlmodelc` on ALL), run as `runtimes/fluid_coreml.py` builds it, on a real 10 s window with the mask over the turn. This is the app's meeting path, one full 10 s call per piece.")
    w("- Turns are Nemotron's raw segments with the app's join/drop rules re-applied; the app runs the same rules on frame probabilities, so counts should be close, not identical. AMI/ICSI rows do not resolve overlapped speech, so they are upper bounds on turn count.")
    w("- One process per (model, round), `OMP_NUM_THREADS=3`, one model at a time, start order rotated each round, baseline in every round.")
    w("- Compute device comes from Core ML's compute plan for ALL (`MLComputePlan`): the device it prefers per op. \"Untagged\" ops are shape/const bookkeeping with no device.")
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
