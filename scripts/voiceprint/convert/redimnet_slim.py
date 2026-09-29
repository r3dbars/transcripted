#!/usr/bin/env python3
"""Slim ReDimNet2 b4 Core ML builds: fewer per-length functions and/or fp16.

The shipped candidate (VP/coreml/redimnet2-b4-vox2-lm/, from convert_coreml.py) is a
multifunction package with one static-shape function per whole second, 1-10 s. With all
ten loaded, a process grows by ~1.7 GB (VP/results/latency.md). This script builds and
measures cheaper variants and writes VP/results/redimnet_memory.md.

Subcommands (all write under VP only; nothing touches app state):

  build     --tag T --lengths 2,4,8 [--precision fp32|fp16] [--from DIR] [--fp32-pool] [--stable-var]
            VP/coreml/redimnet2-b4-vox2-lm-<T>/{model.mlpackage, model.mlmodelc, report.json}.
            --from copies those functions out of an existing multifunction build (identical
            graphs, weights stored once); otherwise the torch model is converted afresh
            (convert/builders.py + convert/pipeline.py, same static-shape patch).
            --fp32-pool keeps the ASTP pooling fp32 in an fp16 build; --stable-var computes the
            ASTP variance as E[a (x - mean)^2] instead of E[a x^2] - mean^2 (same math, no
            cancellation in fp16). Parity: per function, 12 clips fitted to its length the way
            the Swift embedder does, vs the torch runtime, for ALL / CPU_AND_GPU / CPU_ONLY.
  register  --tag T --id ID     VP/models/<ID>/model.json, status "eval" (the daemon skips it)
  embed     --tag T --id ID [--sets ..] [--conds clean,opus12] [--turnlen]
            re-embeds clips the way CoreMLSpeakerSegmentEmbedder does (window = longest length,
            hop = window, each piece tiled up to the next accepted length, unit vectors pooled by
            talk time) into VP/emb/<ID>/<set>__<cond>.npz. --turnlen first crops every clip to a
            real turn length (Nemotron lab turn distribution, truncated to the clip; the same
            crop for every condition of a clip), to price tiling on the lengths the app sees.
  tiling    cosine of a tiled piece vs the exact-length embedding (torch), 200 clips
  memprobe  compile the Swift probe (MLModel per function, like the app) into VP/logs/redimnet_slim/
  memory    fresh-process memory scenarios, interleaved rounds
  latency   ms per window at 1/2/4/8/10 s per build, interleaved rounds
  report    VP/results/redimnet_memory.md from the JSON results

Usage: VP/venv/bin/python scripts/voiceprint/convert/redimnet_slim.py <subcommand> ...
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "3")
os.environ.setdefault("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1")

import numpy as np  # noqa: E402

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
REPO = HERE.parents[2]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
sys.path.insert(0, str(SCRIPTS))

SR = 16000
SRC_ID = "redimnet2-b4-vox2-lm"
FULL_DIR = VP / "coreml" / SRC_ID
WORK = VP / "logs" / "redimnet_slim"
RES = VP / "results" / "redimnet_slim"
HUMAN_SETS = ("ami", "icsi", "libri", "vox1o")

# Nemotron lab turn lengths, pooled over 45 meetings (VP/results/latency_turns.json):
# quantile -> seconds. Turns under 0.25 s are dropped by the app; 30 s caps the tail.
TURN_QUANTILES = [(0.0, 0.25), (0.10, 0.39), (0.25, 0.66), (0.50, 1.54), (0.75, 3.02),
                  (0.90, 4.91), (0.95, 6.47), (0.99, 12.42), (1.0, 30.0)]


def log(msg: str):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def out_dir_for(tag: str) -> Path:
    return VP / "coreml" / f"{SRC_ID}-{tag}"


def secs_to_samples(spec: str) -> list[int]:
    return sorted({int(round(float(s) * SR)) for s in spec.split(",") if s.strip()})


def fn_name(n: int) -> str:
    return f"len_{n}"


def cos(a, b) -> float:
    a = np.asarray(a, np.float64).reshape(-1)
    b = np.asarray(b, np.float64).reshape(-1)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def cstats(xs) -> dict:
    xs = np.asarray([float(x) for x in xs])
    return {"min": round(float(xs.min()), 6), "p1": round(float(np.percentile(xs, 1)), 6),
            "mean": round(float(xs.mean()), 6), "n": int(xs.size)}


def dir_mb(p: Path) -> float:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e6


# ============================================================================ Swift-embedder semantics
def next_length(lengths: list[int], n: int) -> int:
    """CoreMLSpeakerEmbeddingPlan.callLength: the next accepted length, else the longest."""
    for L in lengths:
        if L >= n:
            return L
    return lengths[-1]


def tile(x: np.ndarray, target: int) -> np.ndarray:
    """CoreMLSpeakerSegmentEmbedder.tile: repeat until target long; longer input unchanged."""
    if x.shape[0] == 0 or x.shape[0] >= target:
        return x
    reps = -(-target // x.shape[0])
    return np.tile(x, reps)[:target]


def window_bounds(n: int, window: int, hop: int) -> list[tuple[int, int]]:
    out, start = [], 0
    while True:
        end = min(start + window, n)
        out.append((start, end))
        if end >= n:
            break
        start += hop
    return out


def swift_pieces(x: np.ndarray, lengths: list[int], window: int | None = None, hop: int | None = None):
    """[(call input, weight)] exactly as CoreMLSpeakerSegmentEmbedder.embed forms them."""
    window = window or lengths[-1]
    hop = hop or window
    return [(tile(x[s:e], next_length(lengths, e - s)), float(e - s)) for s, e in window_bounds(len(x), window, hop)]


def pool_talk_time(vecs: list[np.ndarray], weights: list[float]) -> np.ndarray:
    units = [v / (np.linalg.norm(v) or 1.0) for v in vecs]
    s = np.sum([u * w for u, w in zip(units, weights)], axis=0)
    return (s / (np.linalg.norm(s) or 1.0)).astype(np.float32)


# ============================================================================ Core ML helpers
_KEEP = []  # Core ML frees prediction inputs on its own threads; keep numpy buffers alive


def load_fn(mlc: Path, units: str, fn: str):
    import coremltools as ct

    cu = getattr(ct.ComputeUnit, units)
    return ct.models.CompiledMLModel(str(mlc), compute_units=cu, function_name=fn)


class Runner:
    """One loaded function per length, loaded on first use (like the app's router)."""

    def __init__(self, mlc: Path, lengths: list[int], units: str = "ALL", enum: bool | None = None):
        self.mlc, self.lengths, self.units = mlc, lengths, units
        if enum is None:
            rep = mlc.parent / "report.json"
            enum = rep.exists() and json.loads(rep.read_text()).get("shapes", {}).get("kind") == "enumerated"
        self.enum = enum
        self.models = {}

    def __call__(self, x: np.ndarray) -> np.ndarray:
        n = x.shape[0]
        if n not in self.lengths:
            raise ValueError(f"no function for {n} samples")
        key = "main" if self.enum else n
        m = self.models.get(key)
        if m is None:
            if self.enum:
                import coremltools as ct

                m = ct.models.CompiledMLModel(str(self.mlc), compute_units=getattr(ct.ComputeUnit, self.units),
                                              optimization_hints={"reshapeFrequency": ct.ReshapeFrequency.Frequent})
            else:
                m = load_fn(self.mlc, self.units, fn_name(n))
            self.models[key] = m
            _KEEP.append(m)
        arr = np.ascontiguousarray(x.reshape(1, -1), dtype=np.float32)
        _KEEP.append(arr)
        if len(_KEEP) > 4096:
            del _KEEP[: len(_KEEP) - 2048]
        return np.asarray(m.predict({"audio": arr})["embedding"], np.float32).reshape(-1)


def build_lengths(mlc_dir: Path) -> list[int]:
    rep = json.loads((mlc_dir / "report.json").read_text())
    return sorted(int(n) for n in rep["shapes"]["samples"])


# ============================================================================ build
def _torch_ref_embedder():
    from convert import builders

    meta = json.loads((VP / "models" / SRC_ID / "model.json").read_text())
    rt = builders.load_runtime(meta["runtime"])
    saved = os.environ.pop("REDIMNET_DEVICE", None)
    try:
        return rt.Embedder(VP / "models" / SRC_ID, dict(meta, device="cpu"), threads=3)
    finally:
        if saved is not None:
            os.environ["REDIMNET_DEVICE"] = saved


def _stable_astp(module) -> int:
    """ASTP variance as E[a (x - mean)^2]: identical math, no fp16 cancellation."""
    import types

    import torch

    def astp_fwd(self, x):
        if x.dim() == 4:
            x = x.reshape(1, int(x.shape[1]) * int(x.shape[2]), -1)
        if self.global_context_att:
            mean = torch.mean(x, dim=-1, keepdim=True)
            std = torch.sqrt(torch.var(x, dim=-1, keepdim=True) + 1e-7)
            zero = x * 0.0
            x_in = torch.cat((x, zero + mean, zero + std), dim=1)
        else:
            x_in = x
        alpha = torch.tanh(self.linear1(x_in))
        alpha = torch.softmax(self.linear2(alpha), dim=2)
        mean = torch.sum(alpha * x, dim=2, keepdim=True)
        var = torch.sum(alpha * (x - mean) ** 2, dim=2)
        std = torch.sqrt(var.clamp(min=1e-7))
        return torch.cat([mean.squeeze(2), std], dim=1)

    n = 0
    for m in module.modules():
        if type(m).__name__ == "ASTP":
            m.forward = types.MethodType(astp_fwd, m)
            n += 1
    return n


def _parity_inputs(lengths: list[int], per_fn: int = 12) -> dict[int, list[np.ndarray]]:
    from convert import pipeline

    rows = pipeline.select_parity_clips(VP, 60)
    wavs = [pipeline.load_wav(VP, r) for r in rows]
    out = {}
    for L in lengths:
        xs = []
        for w in wavs[::max(1, len(wavs) // per_fn)]:
            if len(w) >= L:
                s = (len(w) - L) // 2
                xs.append(np.ascontiguousarray(w[s:s + L]))
            else:
                xs.append(tile(w, L))
            if len(xs) >= per_fn:
                break
        out[L] = xs
    return out


def cmd_build(args) -> int:
    import coremltools as ct
    import torch

    from convert import builders, pipeline

    torch.set_num_threads(3)
    lengths = secs_to_samples(args.lengths)
    out = out_dir_for(args.tag)
    out.mkdir(parents=True, exist_ok=True)
    pkg, mlc = out / "model.mlpackage", out / "model.mlmodelc"
    rep = {"model_id": f"{SRC_ID}-{args.tag}", "source_model_id": SRC_ID, "tag": args.tag,
           "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "load_avg_start": [round(x, 1) for x in os.getloadavg()],
           "versions": {"torch": torch.__version__, "coremltools": ct.__version__, "numpy": np.__version__},
           "precision": args.precision, "dim": 192,
           "shapes": {"kind": "multifunction" if args.shapes == "multi" else "enumerated", "samples": lengths,
                      "seconds": [n / SR for n in lengths],
                      "functions": {str(n): fn_name(n) for n in lengths} if args.shapes == "multi" else None},
           "notes": []}
    t0 = time.time()
    if args.src:
        src = (VP / "coreml" / args.src) if not Path(args.src).is_absolute() else Path(args.src)
        src_rep = json.loads((src / "report.json").read_text())
        src_prec = src_rep.get("precision")
        if src_prec != args.precision:
            raise SystemExit(f"--from {src.name} is {src_prec}, not {args.precision}")
        have = {int(n) for n in src_rep["shapes"]["samples"]}
        if not set(lengths) <= have:
            raise SystemExit(f"--from {src.name} lacks {sorted(set(lengths) - have)}")
        from coremltools.models.utils import MultiFunctionDescriptor, save_multifunction

        if pkg.exists():
            shutil.rmtree(pkg)
        desc = MultiFunctionDescriptor()
        for n in lengths:
            desc.add_function(str(src / "model.mlpackage"), src_function_name=fn_name(n), target_function_name=fn_name(n))
        default = 64000 if 64000 in lengths else lengths[len(lengths) // 2]
        desc.default_function_name = fn_name(default)
        save_multifunction(desc, str(pkg))
        rep["built_from"] = f"functions {[fn_name(n) for n in lengths]} copied from VP/coreml/{src.name}/model.mlpackage " \
                            "(MultiFunctionDescriptor; graphs unchanged, weights deduplicated)"
        for k in ("fp32_scopes", "stable_var", "frontend"):
            if k in src_rep:
                rep[k] = src_rep[k]
        rep["notes"] = list(src_rep.get("notes", []))
    else:
        meta = json.loads((VP / "models" / SRC_ID / "model.json").read_text())
        built = builders.build(SRC_ID, meta, VP / "models" / SRC_ID)
        built.prepare(lengths)
        scopes = list(built.fp32_scopes) + (["pool"] if args.fp32_pool else [])
        if args.stable_var:
            rep["notes"].append(f"ASTP variance as E[a (x-mean)^2] ({_stable_astp(built.module)} module)")
        rep["notes"] += list(built.notes)
        rep["fp32_scopes"] = scopes if args.precision == "fp16" else []
        rep["stable_var"] = bool(args.stable_var)
        rep["frontend"] = built.frontend
        _, kept = pipeline.convert(built.module, example_len=64000, shapes=args.shapes, lengths=lengths,
                                   precision=args.precision, fp32_scopes=scopes, out_path=pkg, log=log)
        rep["fp32_kept_ops"] = kept
        rep["built_from"] = "fresh conversion of the torch checkpoint (convert/builders.py + convert/pipeline.py)"
    rep["convert_s"] = round(time.time() - t0, 1)
    t0 = time.time()
    if mlc.exists():
        shutil.rmtree(mlc)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(out)], check=True, stdout=subprocess.DEVNULL)
    rep["compile_s"] = round(time.time() - t0, 1)
    log(f"[build] {out.name}: converted in {rep['convert_s']} s, compiled in {rep['compile_s']} s")
    rep["size_mb"] = {"mlpackage": round(dir_mb(pkg), 2), "mlmodelc": round(dir_mb(mlc), 2),
                      "weight_bin": round((mlc / "weights" / "weight.bin").stat().st_size / 1e6, 2),
                      "model_mil": round((mlc / "model.mil").stat().st_size / 1e6, 2)}
    (out / "report.json").write_text(json.dumps(rep, indent=1))

    # parity per function vs the torch runtime on the same fitted input
    if not args.no_parity:
        inputs = _parity_inputs(lengths)
        ref = _torch_ref_embedder()
        refs = {L: [ref.embed(x) for x in xs] for L, xs in inputs.items()}
        par = {}
        for units in ("ALL", "CPU_AND_GPU", "CPU_ONLY"):
            r = Runner(mlc, lengths, units)
            per, allc, bad = {}, [], 0
            t0 = time.time()
            for L, xs in inputs.items():
                cs = []
                for x, e in zip(xs, refs[L]):
                    v = r(x)
                    bad += int(not np.all(np.isfinite(v)))
                    cs.append(cos(v, e))
                per[f"{L / SR:g}s"] = cstats(cs)
                allc += cs
            par[units] = {**cstats(allc), "nonfinite": bad, "wall_s": round(time.time() - t0, 1), "per_function": per}
            log(f"[parity] {units}: min {par[units]['min']:.6f} mean {par[units]['mean']:.6f} nonfinite {bad}")
            del r
        rep["parity_vs_torch"] = par
        rep["parity_clips"] = "12 of the convert_coreml.py parity clips (vox1o/ami/libri) per function, " \
                              "tiled up (shorter) or centre-cropped (longer) to the function's length"
    rep["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    (out / "report.json").write_text(json.dumps(rep, indent=1))
    return 0


# ============================================================================ register
def cmd_register(args) -> int:
    d = FULL_DIR if args.tag == "full10" else out_dir_for(args.tag)
    rep = json.loads((d / "report.json").read_text())
    lengths = sorted(int(n) for n in rep["shapes"]["samples"])
    reg_dir = VP / "models" / args.id
    reg_dir.mkdir(parents=True, exist_ok=True)
    reg = {
        "model_id": args.id, "family": "redimnet2", "runtime": "coreml_fused",
        "files": [f"../../coreml/{d.name}/model.mlpackage"], "compiled": f"../../coreml/{d.name}/model.mlmodelc",
        "source_model_id": SRC_ID, "dim": 192, "params_m": 6.66, "baseline": False, "device": "ane",
        "status": "eval",
        "coreml": {"input": "audio", "output": "embedding", "precision": rep["precision"], "shapes": "multifunction",
                   "enumerated_samples": lengths, "functions": {str(n): fn_name(n) for n in lengths},
                   "range_samples": None},
        "notes": (f"Temporary eval registration (scripts/voiceprint/convert/redimnet_slim.py): {rep['precision']} "
                  f"multifunction build with lengths {[n / SR for n in lengths]} s. Embeddings in VP/emb/{args.id}/ "
                  "were made with the Swift embedder's rules (tile up to the next length, window = longest length, "
                  "talk-time pooling), not runtimes/coreml_fused.py's centre crop. "
                  + (args.note or "")),
    }
    (reg_dir / "model.json").write_text(json.dumps(reg, indent=1))
    log(f"[register] models/{args.id}/model.json (status eval)")
    return 0


# ============================================================================ embed
def turn_length(seg_id: str, max_s: float) -> float:
    """Deterministic turn length for a clip: the Nemotron turn distribution truncated to max_s."""
    qs = np.array([q for q, _ in TURN_QUANTILES])
    ss = np.array([s for _, s in TURN_QUANTILES])
    ls = np.log(ss)
    fmax = float(np.interp(np.log(max_s), ls, qs))
    h = int(hashlib.sha1(("turnlen|" + seg_id).encode()).hexdigest()[:12], 16) / float(16 ** 12)
    u = h * fmax
    return float(min(max_s, np.exp(np.interp(u, qs, ls))))


def turn_crop(seg_id: str, n: int) -> tuple[int, int]:
    L = max(int(round(0.25 * SR)), int(round(turn_length(seg_id, n / SR) * SR)))
    L = min(L, n)
    h = int(hashlib.sha1(("turnstart|" + seg_id).encode()).hexdigest()[:12], 16) / float(16 ** 12)
    s = int(h * (n - L))
    return s, s + L


def _read_wav(path: Path) -> np.ndarray:
    import soundfile as sf

    w, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if w.ndim > 1:
        w = w.mean(axis=1)
    assert sr == SR, (path, sr)
    return np.ascontiguousarray(w, dtype=np.float32)


def cmd_embed(args) -> int:
    d = out_dir_for(args.tag) if args.tag != "full10" else FULL_DIR
    mlc = d / "model.mlmodelc"
    lengths = build_lengths(d) if args.tag != "full10" else build_lengths(FULL_DIR)
    if args.lengths:
        lengths = [n for n in lengths if n in set(secs_to_samples(args.lengths))]
    run = Runner(mlc, lengths, args.units)
    emb_dir = VP / "emb" / args.id
    emb_dir.mkdir(parents=True, exist_ok=True)
    for s in args.sets.split(","):
        rows = [json.loads(l) for l in (VP / "sets" / s / "segments.jsonl").read_text().splitlines() if l.strip()]
        for cond in args.conds.split(","):
            out = emb_dir / f"{s}__{cond}.npz"
            if out.exists() and not args.force:
                log(f"[embed] {out.name} exists, skipped")
                continue
            t0, calls, audio_s = time.time(), 0, 0.0
            ids, embs = [], []
            # group by call-length signature so each function stays hot
            jobs = []
            for r in rows:
                clip = VP / "clips" / s / cond / f"{Path(r['clip']).name}" if cond != "clean" else VP / r["clip"]
                jobs.append((r["seg_id"], clip))
            for i, (sid, clip) in enumerate(jobs):
                w = _read_wav(clip)
                if args.turnlen:
                    a, b = turn_crop(sid, len(w))
                    w = np.ascontiguousarray(w[a:b])
                audio_s += len(w) / SR
                pieces = swift_pieces(w, lengths)
                vecs = [run(p) for p, _ in pieces]
                calls += len(pieces)
                embs.append(pool_talk_time(vecs, [wt for _, wt in pieces]))
                ids.append(sid)
                if (i + 1) % 1000 == 0:
                    log(f"[embed] {args.id} {s}/{cond}: {i + 1}/{len(jobs)} ({(time.time() - t0) / (i + 1) * 1000:.1f} ms/clip)")
            dt = time.time() - t0
            tmp = emb_dir / f".{s}__{cond}.tmp.npz"
            np.savez(tmp, seg_id=np.array(ids), emb=np.stack(embs).astype(np.float32))
            os.replace(tmp, out)
            (emb_dir / f"{s}__{cond}.json").write_text(json.dumps({
                "model_id": args.id, "dim": 192, "clips": len(ids), "seconds_audio": round(audio_s, 1),
                "seconds_compute": round(dt, 1), "device": f"coreml:{args.units}", "threads": 3, "calls": calls,
                "lengths_s": [n / SR for n in lengths], "turnlen_crop": bool(args.turnlen),
                "rules": "Swift CoreMLSpeakerSegmentEmbedder: window=longest, hop=window, tile up, talk-time pooling",
                "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=1))
            log(f"[embed] {args.id} {s}/{cond}: {len(ids)} clips, {calls} calls in {dt:.0f} s")
    return 0



# ============================================================================ Swift probe
# Loads functions exactly as the app does (MLModel(contentsOf:configuration:) with
# MLModelConfiguration.functionName), so memory and timing are the app's, without Python.
PROBE_SWIFT = r"""
import CoreML
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func footprint() -> (Double, Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (-1, -1) }
    return (Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6)
}

func emit(_ d: [String: Any]) {
    var d = d
    let (fp, peak) = footprint()
    d["fp"] = (fp * 10).rounded() / 10
    d["peak"] = (peak * 10).rounded() / 10
    let data = try! JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: memprobe <model.mlmodelc> <ALL|CPU_AND_GPU|CPU_ONLY> <audio.f32> steps..."); exit(2) }
let modelURL = URL(fileURLWithPath: args[1])
// units, optionally "+frequent" (MLOptimizationHints.reshapeFrequency = .frequent, for one enumerated graph)
let unitParts = args[2].split(separator: "+").map(String.init)
let units: MLComputeUnits = ["ALL": .all, "CPU_AND_GPU": .cpuAndGPU, "CPU_ONLY": .cpuOnly, "CPU_AND_NE": .cpuAndNeuralEngine][unitParts[0]] ?? .all
let frequentReshape = unitParts.contains("frequent")
let audioData = try! Data(contentsOf: URL(fileURLWithPath: args[3]))
let audio: [Float] = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

var models: [String: MLModel] = [:]

// "len_32000" is a function of a multifunction build; "main@32000" is the single graph at 32000 samples
func samples(of name: String) -> Int {
    if let at = name.firstIndex(of: "@") { return Int(name[name.index(after: at)...])! }
    return Int(name.split(separator: "_").last!)!
}
func modelKey(_ name: String) -> String { name.split(separator: "@").first.map(String.init) ?? name }

func input(for name: String, offset: Int = 0) -> MLDictionaryFeatureProvider {
    let n = samples(of: name)
    let arr = try! MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
    let p = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
    let start = (offset * 7919 + n * 3) % max(1, audio.count - n)
    for i in 0..<n { p[i] = audio[start + i] }
    return try! MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: arr)])
}

func load(_ name: String) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    autoreleasepool {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = units
        if frequentReshape { cfg.optimizationHints.reshapeFrequency = .frequent }
        let key = modelKey(name)
        if key != "main" { cfg.functionName = key }
        models[key] = try! MLModel(contentsOf: modelURL, configuration: cfg)
    }
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
}

// Everything, input construction included, inside one autorelease pool: top-level code has no
// run loop, so autoreleased MLFeatureValue / MLMultiArray objects would otherwise pile up.
func predict(_ name: String, offset: Int = 0) -> Double {
    var ms = 0.0
    autoreleasepool {
        let feats = input(for: name, offset: offset)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let out = try! models[modelKey(name)]!.prediction(from: feats)
        let e = out.featureValue(for: "embedding")!.multiArrayValue!
        ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        precondition(e.count == 192)
    }
    return ms
}

emit(["step": "start", "pid": Int(getpid())])
for step in args[4...] {
    let parts = step.split(separator: ":").map(String.init)
    switch parts[0] {
    case "load":  // load + first predict
        let ms = load(parts[1])
        let p = predict(parts[1])
        emit(["step": step, "load_ms": ms, "first_predict_ms": p])
    case "loadonly":
        emit(["step": step, "load_ms": load(parts[1])])
    case "pred":
        emit(["step": step, "ms": predict(parts[1])])
    case "time":  // time:NAME:WARM:N
        let name = parts[1], warm = Int(parts[2])!, n = Int(parts[3])!
        for i in 0..<warm { _ = predict(name, offset: i) }
        var ts: [Double] = []
        for i in 0..<n { ts.append(predict(name, offset: warm + i)) }
        let s = ts.sorted()
        emit(["step": step, "median": s[s.count / 2], "p10": s[s.count / 10], "min": s[0],
              "mean": ts.reduce(0, +) / Double(ts.count), "n": n])
    case "drop":
        autoreleasepool { models[modelKey(parts[1])] = nil }
        emit(["step": step])
    case "dropall":
        autoreleasepool { models.removeAll() }
        emit(["step": step])
    case "sleep":
        Thread.sleep(forTimeInterval: Double(parts[1])!)
        emit(["step": step])
    case "snap":
        let label = parts.count > 1 ? parts[1] : "snap"
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        proc.arguments = ["-p", "\(getpid())", "-f", "bytes"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try! proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        emit(["step": step, "label": label, "footprint_tool": String(data: data, encoding: .utf8) ?? ""])
    default:
        print("unknown step \(step)"); exit(2)
    }
}
emit(["step": "end"])
"""


def probe_binary() -> Path:
    WORK.mkdir(parents=True, exist_ok=True)
    src, exe = WORK / "memprobe.swift", WORK / "memprobe"
    if not exe.exists() or not src.exists() or src.read_text() != PROBE_SWIFT:
        src.write_text(PROBE_SWIFT)
        subprocess.run(["swiftc", "-O", "-o", str(exe), str(src)], check=True)
    return exe


def probe_audio() -> Path:
    """60 s of real speech (AMI 8 s clips, one per speaker) as raw float32."""
    p = WORK / "speech60.f32"
    if not p.exists():
        rows = [json.loads(l) for l in (VP / "sets" / "ami" / "segments.jsonl").read_text().splitlines()
                if l.strip() and '"bucket": 8' in l]
        rng = np.random.default_rng(7)
        rng.shuffle(rows)
        seen, chunks = set(), []
        for r in rows:
            if r["speaker"] in seen:
                continue
            seen.add(r["speaker"])
            chunks.append(_read_wav(VP / r["clip"]))
            if sum(len(c) for c in chunks) >= 60 * SR:
                break
        np.concatenate(chunks)[: 60 * SR].astype(np.float32).tofile(p)
    return p


def run_probe(mlc: Path, units: str, steps: list[str], timeout: int = 1800) -> list[dict]:
    exe = probe_binary()
    env = dict(os.environ, TRANSCRIPTED_DISABLE_FILE_LOGGER="1")
    cp = subprocess.run([str(exe), str(mlc), units, str(probe_audio())] + steps, capture_output=True, text=True,
                        timeout=timeout, env=env)
    out = []
    for line in cp.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            out.append(json.loads(line))
    if cp.returncode != 0:
        out.append({"step": "error", "rc": cp.returncode, "stderr": cp.stderr[-2000:]})
    return out


def parse_footprint_tool(text: str) -> dict:
    """footprint -f bytes: category -> dirty and reclaimable MB, plus the total footprint."""
    import re

    cats, total = {}, None
    for line in text.splitlines():
        m = re.match(r"\s*(\d+) B\s+(\d+) B\s+(\d+) B\s+(\d+)\s+(.+?)\s*$", line)
        if m and m.group(5) != "TOTAL":
            cats[m.group(5)] = {"dirty": round(int(m.group(1)) / 1e6, 1), "reclaimable": round(int(m.group(3)) / 1e6, 1)}
        m = re.match(r"\s*phys_footprint:\s+(\d+) B", line)
        if m:
            total = round(int(m.group(1)) / 1e6, 1)
    return {"categories": cats, "total_mb": total, "raw": text}



# ============================================================================ bench (memory + latency)
def _fns(secs) -> list[str]:
    return [fn_name(int(round(float(x) * SR))) for x in secs]


def bench_configs() -> list[dict]:
    """name, build dir, units, functions to load (in order), functions to time, 'kind'."""
    all10 = list(range(1, 11))
    cfgs = []

    def add(name, d, units="ALL", load=None, timed=(), kind="memory"):
        if not (d / "model.mlmodelc").is_dir():
            log(f"[bench] {name}: {d.name} not built, skipped")
            return
        lens = build_lengths(d) if d != FULL_DIR else [n * SR for n in all10]
        load = load or [n / SR for n in lens]
        cfgs.append({"name": name, "dir": str(d), "units": units, "load": _fns(load), "time": _fns(timed),
                     "cycle": _fns([x for x in (2, 4, 8) if x in load] or load[:3]), "kind": kind})

    add("full10-fp32", FULL_DIR, timed=all10, kind="both")
    add("full10-fp16a", out_dir_for("fp16a-all10"), timed=all10, kind="both")
    add("full10-fp16b", out_dir_for("fp16b-all10"), timed=all10, kind="both")
    add("s248-fp32", out_dir_for("s248-fp32"), timed=(2, 4, 8), kind="both")
    add("s248-fp16", out_dir_for("s248-fp16"), timed=(2, 4, 8), kind="both")
    add("s2510-fp32", out_dir_for("s2510-fp32"))
    add("s310-fp32", out_dir_for("s310-fp32"))
    add("s12348-fp32", out_dir_for("s12348-fp32"))
    add("s24-fp32", out_dir_for("s24-fp32"))
    add("s24-fp16", out_dir_for("s24-fp16"))
    add("s4-fp16", out_dir_for("s4-fp16"))
    add("s1248-fp16", out_dir_for("s1248-fp16"), timed=(1, 2, 4, 8), kind="both")
    add("s124-fp16", out_dir_for("s124-fp16"), timed=(1, 2, 4), kind="both")
    add("s1248-fp16-gpu", out_dir_for("s1248-fp16"), units="CPU_AND_GPU", timed=(1, 2, 4, 8), kind="both")
    add("s1248-fp32", out_dir_for("s1248-fp32"), timed=(1, 2, 4, 8), kind="both")
    add("full10-fp32-3of10", FULL_DIR, load=[2, 4, 8])
    add("full10-fp32-1s", FULL_DIR, load=[1])
    add("full10-fp32-10s", FULL_DIR, load=[10])
    add("full10-fp32-cpu", FULL_DIR, units="CPU_ONLY")
    return cfgs


def _bench_steps(cfg: dict, with_time: bool) -> list[str]:
    steps = ["snap:base"] + [f"load:{f}" for f in cfg["load"]] + ["snap:loaded"]
    if with_time:
        steps += [f"time:{f}:10:50" for f in cfg["time"]]
        steps += ["snap:timed"]
    steps += ["dropall", "sleep:3", "snap:dropped"]
    for _ in range(2):  # unload/reload cycles: does memory come back each time?
        steps += [f"load:{f}" for f in cfg["cycle"]] + ["dropall", "sleep:1"]
    steps += ["snap:final"]
    return steps


def cmd_bench(args) -> int:
    RES.mkdir(parents=True, exist_ok=True)
    raw = RES / "bench_raw.jsonl"
    cfgs = [c for c in bench_configs() if not args.only or c["name"] in args.only.split(",")]
    if args.kind != "all":
        cfgs = [c for c in cfgs if c["kind"] in (args.kind, "both")]
    stamp = time.strftime("%Y%m%d-%H%M%S")
    for rnd in range(args.rounds):
        order = cfgs[rnd % len(cfgs):] + cfgs[: rnd % len(cfgs)] if rnd else list(cfgs)
        if rnd % 2 == 1:
            order = order[::-1]
        for c in order:
            with_time = args.kind != "memory" and bool(c["time"])
            la = [round(x, 1) for x in os.getloadavg()]
            t0 = time.time()
            recs = run_probe(Path(c["dir"]) / "model.mlmodelc", c["units"], _bench_steps(c, with_time))
            for r in recs:
                if "footprint_tool" in r:
                    r["footprint_categories"] = parse_footprint_tool(r.pop("footprint_tool"))
            row = {"round_id": f"{stamp}-r{rnd}", "round": rnd, "config": c["name"], "units": c["units"],
                   "load_avg_start": la, "wall_s": round(time.time() - t0, 1), "timed": with_time, "records": recs}
            with raw.open("a") as f:
                f.write(json.dumps(row) + "\n")
            fp = {r.get("label"): r["fp"] for r in recs if r.get("step", "").startswith("snap")}
            err = [r for r in recs if r.get("step") == "error"]
            log(f"[bench] r{rnd} {c['name']} ({c['units']}): footprint {fp} in {row['wall_s']} s"
                + (f" ERROR {err[0]['stderr'][-300:]}" if err else ""))
    return 0


# ============================================================================ tiling
def cmd_tiling(args) -> int:
    """Cosine of each clip's embedding when a piece is tiled up to T seconds, vs its exact-length embedding."""
    rng = np.random.default_rng(11)
    rows = []
    for s in HUMAN_SETS:
        rs_ = [json.loads(l) for l in (VP / "sets" / s / "segments.jsonl").read_text().splitlines()
               if l.strip() and '"bucket": 8' in l]
        rng.shuffle(rs_)
        seen = set()
        for r in rs_:
            if r["speaker"] in seen:
                continue
            seen.add(r["speaker"])
            rows.append(r)
            if len(seen) >= args.n // len(HUMAN_SETS):
                break
    crop_s = [float(x) for x in args.crops.split(",")]
    wavs = [_read_wav(VP / r["clip"]) for r in rows]
    # exact-length reference: the torch runtime at the crop's own length (no tiling)
    from convert import builders

    meta = json.loads((VP / "models" / SRC_ID / "model.json").read_text())
    rt = builders.load_runtime(meta["runtime"])
    ref = rt.Embedder(VP / "models" / SRC_ID, dict(meta, device=args.ref_device), threads=3)
    fp32 = Runner(FULL_DIR / "model.mlmodelc", [n * SR for n in range(1, 11)], "ALL")
    extra = {}
    for tag in (args.extra or "").split(","):
        if tag:
            d = out_dir_for(tag)
            extra[tag] = Runner(d / "model.mlmodelc", build_lengths(d), "ALL")
    res = {"clips": [r["seg_id"] for r in rows], "crops_s": crop_s, "cos": {}}
    t0 = time.time()
    for ci, c in enumerate(crop_s):
        n = int(round(c * SR))
        xs = [np.ascontiguousarray(w[:n]) for w in wavs]
        exact = [ref.embed(x) for x in xs]
        for T in range(1, 11):
            if T * SR < n:
                continue
            res["cos"][f"{c:g}|{T}|fp32"] = [cos(fp32(tile(x, T * SR)), e) for x, e in zip(xs, exact)]
            for tag, run in extra.items():
                if T * SR in run.lengths:
                    res["cos"][f"{c:g}|{T}|{tag}"] = [cos(run(tile(x, T * SR)), e) for x, e in zip(xs, exact)]
        log(f"[tiling] crop {c:g} s done ({time.time() - t0:.0f} s)")
    res["ref"] = f"torch runtime ({args.ref_device}) at the exact crop length"
    (RES / "tiling.json").write_text(json.dumps(res))
    return 0



# ============================================================================ analysis
def turn_windows(lengths: list[int], n_turns: int = 50000, seed: int = 3) -> list[int]:
    """Call lengths (samples) for a sample of real turns under the Swift rules for `lengths`."""
    rng = np.random.default_rng(seed)
    qs = np.array([q for q, _ in TURN_QUANTILES])
    ls = np.log(np.array([s_ for _, s_ in TURN_QUANTILES]))
    turns = np.exp(np.interp(rng.random(n_turns), qs, ls))
    calls = []
    for t in turns:
        n = int(round(t * SR))
        for a, b in window_bounds(n, lengths[-1], lengths[-1]):
            calls.append(next_length(lengths, b - a))
    return calls


def bench_summary() -> dict:
    """Per config: memory (median over rounds) and latency (ratios to full10-fp32 inside a round)."""
    rows = [json.loads(l) for l in (RES / "bench_raw.jsonl").read_text().splitlines() if l.strip()]
    by_cfg: dict = {}
    for r in rows:
        recs = r["records"]
        if any(x.get("step") == "error" for x in recs):
            continue
        snaps = {x.get("label"): x for x in recs if x.get("step", "").startswith("snap")}
        base = snaps["base"]["fp"]
        loads = [x for x in recs if x.get("step", "").startswith("load:")]
        first = loads[: len(loads) - 2 * len(_cycle_of(r, loads))] if loads else []
        d = {
            "round_id": r["round_id"], "load_avg": r["load_avg_start"], "timed_run": bool(r.get("timed")),
            "units": r.get("units"),
            "base": base, "loaded": snaps["loaded"]["fp"] - base,
            "peak": max(x["peak"] for x in recs) - base,
            "dropped": snaps["dropped"]["fp"] - base, "final": snaps["final"]["fp"] - base,
            "per_load": [(x["step"].split(":")[1], round(x["fp"] - base, 1), round(x["load_ms"] / 1000, 2),
                          round(x["first_predict_ms"], 1)) for x in first],
            "cats_loaded": snaps["loaded"].get("footprint_categories", {}).get("categories", {}),
            "cats_dropped": snaps["dropped"].get("footprint_categories", {}).get("categories", {}),
            "cats_base": snaps["base"].get("footprint_categories", {}).get("categories", {}),
            "time": {x["step"].split(":")[1]: {k: x[k] for k in ("median", "p10", "min", "mean")}
                     for x in recs if x.get("step", "").startswith("time:")},
        }
        if "timed" in snaps:
            d["timed"] = snaps["timed"]["fp"] - base
        by_cfg.setdefault(r["config"], []).append(d)
    return by_cfg


def _cycle_of(r: dict, loads: list) -> list:
    # the cycle reloads 2/4/8 (or the first three) twice after dropall; they are the last loads
    names = [x["step"].split(":")[1] for x in loads]
    for k in (3, 2, 1):
        if len(names) >= 3 * k and names[-k:] == names[-2 * k:-k]:
            return names[-k:]
    return []



def _med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def latency_table(summary: dict, latest_only: bool = True) -> dict:
    """ms per call per (config, length): median over rounds of the per-round median, plus the
    per-round ratio to full10-fp32 at the same length (the trustworthy part on a loaded Mac).
    latest_only: only the rounds of the most recent latency run (every config in it ran
    interleaved, in the same conditions)."""
    stamps = sorted({d["round_id"].rsplit("-r", 1)[0] for ds in summary.values() for d in ds if d["time"]})
    keep = (lambda rid: rid.startswith(stamps[-1])) if (latest_only and stamps) else (lambda rid: True)
    ref = {d["round_id"]: d["time"] for d in summary.get("full10-fp32", []) if d["time"] and keep(d["round_id"])}
    out = {}
    for cfg, ds in summary.items():
        per = {}
        for d in ds:
            if not keep(d["round_id"]):
                continue
            for fn, t in d["time"].items():
                sec = int(fn.split("_")[1]) / SR
                e = per.setdefault(sec, {"median": [], "p10": [], "ratio": []})
                e["median"].append(t["median"])
                e["p10"].append(t["p10"])
                r = ref.get(d["round_id"], {}).get(fn)
                if r:
                    e["ratio"].append(t["median"] / r["median"])
        if per:
            out[cfg] = {sec: {k: _med(v) for k, v in e.items()} for sec, e in sorted(per.items())}
    return out



def cmd_accuracy(args) -> int:
    """Pull TAR@1e-3 / EER (raw cosine, human sets) and paired deltas out of score_verify.py's
    per-model JSON (run on a VP root holding only these models, --baseline the reference)."""
    root = Path(args.root)
    out = {"root_note": "score_verify.py on a scratch VP root (4 human sets, clean + opus12 only, raw cosine)",
           "baseline": args.baseline, "models": {}}
    for m in args.models.split(","):
        d = json.loads((root / "results" / "verify" / f"{m}.json").read_text())
        pooled = d["pooled"]
        rec = {}
        for scope in ("human", "human@b2", "human@b4", "human@b8"):
            for g in ("cross", "clean", "opus12"):
                e = pooled.get(scope, {}).get(g, {}).get("cos")
                if not e:
                    continue
                for metric in ("tar@1e-3", "eer"):
                    x = e["metrics"][metric]
                    dl = x.get("delta") or {}
                    rec[f"{scope}|{g}|{metric}"] = {"value": x["value"], "ci": x.get("ci"),
                                                    "delta": dl.get("value"), "delta_ci": dl.get("ci"),
                                                    "n_cells": e["n_cells"]}
        out["models"][m] = rec
    (RES / f"accuracy_{args.name}.json").write_text(json.dumps(out, indent=1))
    log(f"[accuracy] wrote {RES / f'accuracy_{args.name}.json'}")
    return 0



# ============================================================================ report
# (config, bench name, build tag, lengths s, precision, accuracy ids (bake-off, turn-length crops))
REPORT_ROWS = [
    # label, bench config (memory; latency when timed), lengths s, precision,
    # (bake-off accuracy id, turn-crop accuracy id); "=ref" = same graphs as the reference on those clips,
    # "~<id>" = borrowed from a build that makes identical calls on those clips (see the notes under the table)
    ("all 10 lengths, fp32 (shipped today)", "full10-fp32", list(range(1, 11)), "fp32",
     ("redimnet2-b4-vox2-lm", "redimnet2-b4-eval-full10-turnlen")),
    ("all 10 lengths, fp16", "full10-fp16a", list(range(1, 11)), "fp16", ("~redimnet2-b4-eval-s248-fp16", None)),
    ("{2, 5, 10} s, fp32", "s2510-fp32", [2, 5, 10], "fp32", ("redimnet2-b4-eval-s2510-fp32", None)),
    ("{3, 10} s, fp32", "s310-fp32", [3, 10], "fp32", ("redimnet2-b4-eval-s310-fp32", None)),
    ("{2, 4, 8} s, fp32", "s248-fp32", [2, 4, 8], "fp32", ("=ref", "redimnet2-b4-eval-s248-fp32-turnlen")),
    ("{1, 2, 4, 8} s, fp32", "s1248-fp32", [1, 2, 4, 8], "fp32", ("=ref", "~redimnet2-b4-eval-s1248-fp16-turnlen")),
    ("{1, 2, 3, 4, 8} s, fp32", "s12348-fp32", [1, 2, 3, 4, 8], "fp32", ("=ref", None)),
    ("{2, 4, 8} s, fp16", "s248-fp16", [2, 4, 8], "fp16",
     ("redimnet2-b4-eval-s248-fp16", "~redimnet2-b4-eval-s248-fp32-turnlen")),
    ("{1, 2, 4, 8} s, fp16, ALL", "s1248-fp16", [1, 2, 4, 8], "fp16",
     ("~redimnet2-b4-eval-s248-fp16", "redimnet2-b4-eval-s1248-fp16-turnlen")),
    ("**{1, 2, 4, 8} s, fp16, CPU_AND_GPU (recommended)**", "s1248-fp16-gpu", [1, 2, 4, 8], "fp16",
     ("~redimnet2-b4-eval-s248-fp16", "~redimnet2-b4-eval-s1248-fp16-turnlen")),
    ("{1, 2, 4} s, fp16", "s124-fp16", [1, 2, 4], "fp16",
     ("~redimnet2-b4-eval-s24-fp16", "redimnet2-b4-eval-s124-fp16-turnlen")),
    ("{2, 4} s, fp32", "s24-fp32", [2, 4], "fp32", ("~redimnet2-b4-eval-s24-fp16", "~redimnet2-b4-eval-s24-fp16-turnlen")),
    ("{2, 4} s, fp16", "s24-fp16", [2, 4], "fp16", ("redimnet2-b4-eval-s24-fp16", "redimnet2-b4-eval-s24-fp16-turnlen")),
    ("{4} s only, fp16", "s4-fp16", [4], "fp16", (None, None)),
]


def _fmt(x, nd=0, sign=False):
    if x is None:
        return "–"
    f = f"{{:{'+' if sign else ''}.{nd}f}}"
    return f.format(x)


def _pp(d):  # fraction delta -> percentage points with CI
    if d is None or d.get("delta") is None:
        return "–"
    v = d["delta"] * 100
    ci = d.get("delta_ci")
    star = "*" if ci and (ci[0] > 0 or ci[1] < 0) else ""
    return f"{v:+.2f}{star}" + (f" [{ci[0] * 100:+.2f}, {ci[1] * 100:+.2f}]" if ci else "")



FINDINGS_STATIC = """
## Answers

**1. Fewer functions.** The length that matters is **1 s**. 38% of real turns are under 1 s. Without a 1 s function they get tiled up to 2 s, and EER on real turn lengths rises 0.6 pp ({2, 4, 8}: +0.60* [+0.46, +0.77]; {2, 4}: +0.62*). TAR@1e-3 doesn't move (+0.5, n.s.). Adding the 1 s function back ({1, 2, 4, 8}) removes all of it, and it's cheap: about 40 MB fp32, and the 1 s call is the fastest one. Dropping 3, 5, 6, 7, 9 and 10 s costs nothing measurable: crops from the 8 s clips score 14.78% EER with {1, 2, 4, 8} vs 14.77% with all ten. The builds that keep 10 s are worse on both counts. {2, 5, 10} and {3, 10} use more memory than {2, 4, 8}, because the 10 s function is the most expensive one. They also lose accuracy on the bake-off clips: tiling 4 s up to 5 s costs -1.0 pp TAR on 4 s clips, and 2 s up to 3 s costs -1.9 pp on 2 s clips.

What tiling does to one clip (200 clips, cosine vs the exact-length embedding, table at the end): tiling to an exact multiple of the piece length is nearly free (2→4 s 0.994, 4→8 s 0.998). A partial repeat costs more (2→3 s 0.980, 3→4 s 0.985). Sub-second pieces suffer most: a 0.5 s piece gives 0.940 tiled to 1 s, 0.890 to 2 s and 0.840 to 8 s. That lines up with where the verification cost showed up.

**2. fp16.** On the GPU, fp16 matches fp32. The minimum cosine vs the torch fp32 model is 0.99993 over all 23,738 bake-off clips (4 human sets, clean + opus12). Per-function parity on CPU_AND_GPU is ≥ 0.99999, and verification Δ is 0.00. On CPU_ONLY the 8 s function still drifts: min cosine 0.973 on one parity clip, while the other functions stay ≥ 0.9998. That's where the old 0.991 came from. Keeping the ASTP pooling in fp32 with a cancellation-free variance (build `fp16b-s1248`) doesn't fix it, so the pooling isn't the cause. Two rules follow: never run the fp16 build with `.cpuOnly`, and don't use `.all` either, because with ALL the fp16 1 s function runs 2.7x slower than fp32. My guess is Core ML sends part of it off the GPU. With `.cpuAndGPU` every fp16 function is faster than fp32.

**3. Where the 1.7 GB comes from.** It's per-function GPU memory. In today's build, about 1345 of the ~1507 MB loaded sits in `IOAccelerator (graphics)` and `Owned physical footprint (unmapped) (graphics)`. With CPU_ONLY and all ten functions loaded, the process grows only about +34 MB (peak about +220). Each loaded function is its own MLModel with its own GPU plan and buffers, sized by its input length. About 200 MB is paid once for the first GPU function, then roughly 20 MB more per second of input for each function. Loaded alone, the 1 s function is about +260 MB and the 10 s one about +540 MB. (The +1.7 GB in latency.md was the process peak after long timing runs, with Python.)

Deallocating does return it. Three seconds after every MLModel is released, the process sits at +35 to +45 MB, with the GPU rows back to 2 to 6 MB and what's left mostly malloc. Five load → run → release cycles in one process ended at +42, +43, +43, +44, +44 MB (`lifecycle.json`), so nothing piles up. That supports "load after the meeting, unload when done".

**4. Weight sharing.** On disk, yes: `weight.bin` is 27.61 MB whether the package holds 2, 3, 4, 5 or 10 functions (fp32; fp16 is 14.27 MB), and each extra function adds about 0.4 MB of MIL. In memory, no. Every function loads as a separate MLModel with its own GPU copy and buffers, so memory scales with the number of functions and their lengths (growth line under Memory detail).

**Also tried.** A single enumerated graph (1-10 s, build `enum10-fp32`) with `MLOptimizationHints.reshapeFrequency = .frequent` still re-plans on every change of input length (1 to 2.7 s each), and warm calls were 3-6x slower, so it isn't an option. Loading one function at a time (windows sorted by length, release in between) barely lowers the peak (about +458 vs +480 to +520 MB for all four at once), because the 8 s function dominates.

## What the Swift embedder should change

1. **Load `redimnet2-b4-vox2-lm-slim`** (functions `len_16000`, `len_32000`, `len_64000`, `len_128000`). Routing needs no change, because `CoreMLVoiceprintFunctions` reads the names from the model. The long-turn window becomes 8 s (the longest length). If a config pins `windowSamples` to 10 s, change it to 8 s: `CoreMLSpeakerEmbeddingPlan.resolve` rejects a window that isn't one of the lengths. Turns over 8 s (about 2 to 3%) get more than one window.
2. **`computeUnits = .cpuAndGPU`** for this model, not `.all` (slow 1 s function) and never `.cpuOnly` (the fp16 8 s function drifts).
3. **Scope it to the post-meeting speaker pass.** Build the embedder when the pass starts and drop it, with every MLModel the router cached, when the pass ends. Today `CoreMLVoiceprintFunctionRouter` keeps every loaded function for the life of the process, and `init` preloads the window-length function. That's the 10 s one today, the most expensive single function at about +540 MB alone. Either make the embedder per job or add an `unloadAll()` to the router. Cost per meeting: about 1.2 s to load all four functions in a fresh process with a warm cache, plus about 0.3 s for each first prediction. Memory is back to +35 to +45 MB about 3 s after release.
4. **Wrap each prediction in `autoreleasepool {}`**, covering the input `MLMultiArray`, `MLFeatureValue` and the output provider. `CoreMLVoiceprintModel.predict` doesn't do this today. In a long loop without a run loop, those objects stay alive until the loop ends. The probe grew about 200 MB over about 600 calls until the pool was added.
5. Window order doesn't matter for a multifunction build (switching lengths doesn't re-plan), so there's no need to sort by length.

## Caveats

- Accuracy used clean + opus12 trials only, raw cosine only (no cohort), on a scratch VP root, so the shared `verify_summary.md` wasn't touched. The turn-length test is a proxy. Clips are cut to turn lengths drawn from the Nemotron lab distribution, and the naming pipeline wasn't run.
- The Mac was loaded (load 90 to 200) for the first memory rounds and fairly quiet (10 to 40) for the last ones. Memory moves about ±50 MB from round to round. Latency numbers come only from the last interleaved run.
- The "first-ever" load of a content-changed copy took 1.1 s per function for the slim build and 26 s for all ten (`lifecycle.json`), but Core ML may still have reused a cached plan. latency.md measured about 15 s per function on a busy Mac.
- `runtimes/coreml_fused.py` centre-crops a piece down to the longest length that fits, while Swift tiles it up to the next length. The eval embeddings here follow Swift (`redimnet_slim.py embed`).
- Temporary registrations `VP/models/redimnet2-b4-eval-*` have status `eval`, with embeddings in `VP/emb/redimnet2-b4-eval-*`. The `-turnlen` ids are cropped clips and can't be compared with bake-off numbers.
"""


def findings_md(summ, lat, acc, mem, hour_cost) -> str:
    rec, ref, floor = "s1248-fp16-gpu", "full10-fp32", "s124-fp16"

    def a(which, mid, metric):
        r = acc[which]["models"].get(mid, {}).get(f"human|cross|{metric}") or {}
        d, ci = r.get("delta"), r.get("delta_ci")
        return f"{d * 100:+.2f} pp [{ci[0] * 100:+.2f}, {ci[1] * 100:+.2f}]" if d is not None and ci else "–"

    c_rec = hour_cost([1, 2, 4, 8], "fp16", rec)[1]
    c_ref = hour_cost(list(range(1, 11)), "fp32", ref)[1]
    ratios = [e.get("ratio") for e in (lat.get(rec) or {}).values() if e.get("ratio")]
    b8 = acc["bake"]["models"].get("redimnet2-b4-eval-s24-fp16", {}).get("human@b8|cross|eer", {})
    r8 = acc["bake"]["models"].get("redimnet2-b4-vox2-lm", {}).get("human@b8|cross|eer", {})
    head = f"""## Recommendation

Ship **{{1, 2, 4, 8}} s, fp16, run with compute units CPU_AND_GPU**: `VP/coreml/redimnet2-b4-vox2-lm-slim/` (report.json next to it).

- **Memory:** +{mem(rec, 'loaded'):.0f} MB loaded, +{mem(rec, 'peak'):.0f} MB peak, vs +{mem(ref, 'loaded'):.0f} / +{mem(ref, 'peak'):.0f} MB for today's 10-function fp32 build ({mem(rec, 'loaded') / mem(ref, 'loaded'):.0%} of it). Released after the meeting it drops to about +{mem(rec, 'dropped'):.0f} MB.
- **Accuracy:** no measurable cost. Bake-off clips: Δ TAR@1e-3 cross {a('bake', 'redimnet2-b4-eval-s248-fp16', 'tar@1e-3')}, Δ EER {a('bake', 'redimnet2-b4-eval-s248-fp16', 'eer')}. Real turn lengths: Δ TAR {a('turn', 'redimnet2-b4-eval-s1248-fp16-turnlen', 'tar@1e-3')}, Δ EER {a('turn', 'redimnet2-b4-eval-s1248-fp16-turnlen', 'eer')}.
- **Speed:** every call is faster than today's ({min(ratios):.2f}x to {max(ratios):.2f}x). An hour of meeting costs {c_rec:.1f} s instead of {c_ref:.1f} s. Loading all 4 functions takes about 1.2 s in a fresh process with a warm Core ML cache, and reloading in the same process takes 0.02 s per function.
- **If memory has to go lower:** {{1, 2, 4}} fp16 is +{mem(floor, 'loaded'):.0f} MB ({mem(floor, 'loaded') / mem(ref, 'loaded'):.0%} of today). It's unchanged on real turn lengths (Δ EER {a('turn', 'redimnet2-b4-eval-s124-fp16-turnlen', 'eer')}), but on 8 s clips EER goes from {r8.get('value', 0) * 100:.2f}% to {b8.get('value', 0) * 100:.2f}% (pooled bake-off Δ EER {a('bake', 'redimnet2-b4-eval-s24-fp16', 'eer')}) because long turns get split into 4 s windows.
"""
    return head


def cmd_report(args) -> int:
    summ = bench_summary()
    lat = latency_table(summ)
    acc = {}
    for name in ("bake", "turn"):
        f = RES / f"accuracy_{name}.json"
        acc[name] = json.loads(f.read_text()) if f.exists() else {"models": {}}
    til = json.loads((RES / "tiling.json").read_text()) if (RES / "tiling.json").exists() else None

    def mem(cfg, key):  # memory-only runs (the timing runs prefill thousands of inputs)
        ds = [d for d in summ.get(cfg) or [] if not d["timed_run"]]
        return _med([d[key] for d in ds]) if ds else None

    def gpu(cfg):
        ds = [d for d in summ.get(cfg) or [] if not d["timed_run"]]
        return _med([sum(v["dirty"] for k, v in d["cats_loaded"].items() if "graphics" in k) for d in ds]) if ds else None

    def ms_at(prec, sec, bench=None):
        """The same function timed in the latest interleaved run: fp32 from the all-10 build (the
        slim fp32 builds hold identical graphs), fp16 from the {1,2,4,8} fp16 build on CPU_AND_GPU
        (the units we recommend), except the row that is explicitly fp16 on ALL."""
        if prec == "fp32":
            t = lat.get("full10-fp32", {})
        else:
            t = lat.get("s1248-fp16" if bench == "s1248-fp16" else "s1248-fp16-gpu", {})
        return (t.get(float(sec)) or {}).get("median")

    def hour_cost(lengths, prec, bench=None):
        L = [n * SR for n in lengths]
        calls = turn_windows(L)
        ms = [ms_at(prec, c / SR, bench) for c in calls]
        if any(m is None for m in ms):
            return None, None
        per_turn = len(calls) / 50000
        return float(np.mean(ms)), 942 * per_turn * float(np.mean(ms)) / 1000

    ref_cost = hour_cost(list(range(1, 11)), "fp32")[1]
    lines = []
    w = lines.append
    w("# ReDimNet2 b4: cheaper Core ML builds\n")
    w(f"Generated {time.strftime('%Y-%m-%d %H:%M')} by `scripts/voiceprint/convert/redimnet_slim.py report`. "
      "Raw data: `VP/results/redimnet_slim/` (bench_raw.jsonl, tiling.json, accuracy_*.json). Builds: `VP/coreml/redimnet2-b4-vox2-lm-<tag>/`.\n")
    w(findings_md(summ, lat, acc, mem, hour_cost))
    w("## The table\n")
    w("How to read it. **Memory**: growth of the process's `phys_footprint` over the same process before any model "
      "was loaded, from a small Swift probe that loads each function exactly as the app does "
      "(`MLModel(contentsOf:configuration:)` with `functionName`), one fresh process per build and round, median over "
      "the memory-only rounds (3 to 5 per build, interleaved). `loaded` = every function of the build loaded and run once; "
      "`peak` = the process's peak; `GPU` = the `IOAccelerator (graphics)` + `Owned physical footprint (unmapped) "
      "(graphics)` rows of `footprint`; `after unload` = 3 s after every MLModel was released. Round-to-round spread is "
      "about ±50 MB. fp16 rows were measured with compute units ALL except the CPU_AND_GPU row. **ms per window**: the "
      "call a 2 / 4 / 8 s window makes in that build (tiled up to the next length it has; `2 × 4 s` = two windows), "
      "median of 4 interleaved rounds (50 calls after 10 warm-ups each) run while the Mac was fairly quiet (load 10 to 40); "
      "fp32 rows use the all-10 build's functions (the slim fp32 builds hold identical graphs), fp16 rows use the "
      "{1, 2, 4, 8} fp16 build on CPU_AND_GPU except the row marked ALL. **s / 60-min**: every window of an hour of real "
      "turns (942 turns, the Nemotron-lab distribution) priced at its call length, window = the build's longest length, "
      "hop = window (the Swift default); in brackets vs today. **Accuracy**: deltas vs the shipped build, raw cosine, "
      "pooled over the 4 human sets, clean + opus12 trials (cross = enroll clean, test opus12), paired 95% bootstrap CI "
      "over speakers, `*` = CI excludes 0, pp = percentage points. `bake-off clips` are the exact 2 / 4 / 8 s clips; "
      "`turn crops` first cut every clip to a real turn length (median 1.5 s, 38% under 1 s, same crop for clean and "
      "opus12), which is where missing lengths mean more tiling. `0 (same graphs)` = the build makes exactly the "
      "reference's calls on those clips. `†` = borrowed from a build that makes the same calls on those clips (fp16 vs "
      "fp32 on the GPU agrees to cosine ≥ 0.99993 on all 23,738 clips; a {1, 2, 4} build never uses its 1 s function on "
      "2 / 4 / 8 s clips).\n")
    w("| config | functions | precision | memory loaded (MB) | peak (MB) | of which GPU (MB) | after unload (MB) | "
      "ms per window 2 / 4 / 8 s | s / 60-min | Δ TAR@1e-3 cross, bake-off clips (pp) | Δ EER cross, bake-off (pp) | "
      "Δ TAR@1e-3 cross, turn-length crops (pp) | Δ EER cross, turn-length crops (pp) |")
    w("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for label, bench, lengths, prec, (acc_b, acc_t) in REPORT_ROWS:
        if bench not in summ:
            continue
        mss = [ms_at(prec, next_length([n * SR for n in lengths], s * SR) / SR, bench) if s <= lengths[-1] else None
               for s in (2, 4, 8)]
        ms_txt = " / ".join(_fmt(m, 1) if m is not None else "2 × 4 s" for m in mss)
        _, cost = hour_cost(lengths, prec, bench)

        def acc_cell(which, mid, metric):
            if mid is None:
                return "–"
            if mid == "=ref":
                return "0 (same graphs)"
            ref_id = acc[which].get("baseline")
            if mid == ref_id:
                return "ref"
            borrowed = mid.startswith("~")
            rec = acc[which]["models"].get(mid.lstrip("~"), {}).get(f"human|cross|{metric}")
            return _pp(rec) + (" †" if borrowed and rec else "")

        w(f"| {label} | {len(lengths)} | {prec} | {_fmt(mem(bench, 'loaded'))} | {_fmt(mem(bench, 'peak'))} | "
          f"{_fmt(gpu(bench))} | {_fmt(mem(bench, 'dropped'))} | {ms_txt} | {_fmt(cost, 1)}"
          f"{f' ({cost / ref_cost:.2f}x)' if cost and ref_cost else ''} | "
          f"{acc_cell('bake', acc_b, 'tar@1e-3')} | {acc_cell('bake', acc_b, 'eer')} | "
          f"{acc_cell('turn', acc_t, 'tar@1e-3')} | {acc_cell('turn', acc_t, 'eer')} |")
    w("")
    # absolute accuracy of the references
    for which, title in (("bake", "bake-off clips"), ("turn", "turn-length crops")):
        a = acc[which]
        ref = a["models"].get(a.get("baseline"), {})
        if ref:
            t = ref.get("human|cross|tar@1e-3", {}).get("value")
            e = ref.get("human|cross|eer", {}).get("value")
            w(f"Reference (all 10 lengths, fp32) on {title}: TAR@1e-3 cross {t * 100:.2f}%, EER cross {e * 100:.2f}%.  ")
    w("")
    w(FINDINGS_STATIC)
    # memory detail
    w("## Memory detail\n")
    w("Per build, median over its memory-only rounds (MB over the empty process). `malloc` = the Malloc rows of "
      "`footprint`, with the part it marks reclaimable in brackets; `load` = constructor + first prediction for all of "
      "the build's functions in a fresh process with a warm Core ML cache (last round).\n")
    w("| build | units | rounds | loaded | peak | GPU | malloc (reclaimable) | after unload | load, all functions (s) |")
    w("|---|---|---|---|---|---|---|---|---|")
    for cfg, ds in summ.items():
        ds = [d for d in ds if not d["timed_run"]]
        if not ds:
            continue
        mal = _med([sum(v["dirty"] for k, v in d["cats_loaded"].items() if k.startswith("Malloc")) for d in ds])
        rec = _med([sum(v["reclaimable"] for k, v in d["cats_loaded"].items() if k.startswith("Malloc")) for d in ds])
        ld = [sum(x[2] + x[3] / 1000 for x in d["per_load"]) for d in ds]
        w(f"| {cfg} | {ds[0].get('units') or 'ALL'} | {len(ds)} | {_fmt(mem(cfg, 'loaded'))} | {_fmt(mem(cfg, 'peak'))} | "
          f"{_fmt(gpu(cfg))} | {_fmt(mal)} ({_fmt(rec)}) | {_fmt(mem(cfg, 'dropped'))} | {_fmt(ld[-1], 1)} |")
    w("")
    fs = [d for d in summ.get("full10-fp32") or [] if not d["timed_run"] and len(d["per_load"]) == 10]
    if fs:
        steps = [[d["per_load"][i][1] for d in fs] for i in range(10)]
        w(f"Growth as each function of the all-10 fp32 build is loaded in turn (1 s first), MB over the empty process, "
          f"median of {len(fs)} rounds: " + ", ".join(f"+{i + 1} s → {_med(v):.0f}" for i, v in enumerate(steps))
          + ". Each extra function adds roughly 20 MB per second of input it takes (the 2 s one about 40 MB, the "
          "10 s one about 200 MB); loaded alone, the 1 s function costs about 260 MB and the 10 s one about 540 MB, "
          "so about 200 MB is paid once for the first GPU function.\n")
    # latency detail
    if lat:
        w("## Latency detail\n")
        w("Median ms per call at each length (median over rounds of each round's median of 50 calls after 10 warm-ups), "
          "and fp16 / fp32 inside the same round.\n")
        secs = sorted({s_ for t in lat.values() for s_ in t})
        w("| build | units | " + " | ".join(f"{s_:g} s" for s_ in secs) + " |")
        w("|---|---|" + "---|" * len(secs))
        for cfg, t in lat.items():
            units = "CPU_AND_GPU" if cfg.endswith("-gpu") else "ALL"
            cells = []
            for s_ in secs:
                e = t.get(s_)
                cells.append("" if not e else f"{e['median']:.1f}" + (f" ({e['ratio']:.2f}x)" if cfg != "full10-fp32" and e.get("ratio") else ""))
            w(f"| {cfg} | {units} | " + " | ".join(cells) + " |")
        w("")
        w("In brackets: the median of (this build's ms / the all-10 fp32 build's ms at the same length, same round). fp16 "
          "on ALL runs its 1 s function 2.7x slower than fp32 (probably partly off the GPU); on CPU_AND_GPU every fp16 "
          "function is faster than fp32 (0.6x to 0.76x).\n")
    # tiling
    if til:
        w("## What tiling does to one clip\n")
        w(f"{len(til['clips'])} clean 8 s clips (50 per human set, one per speaker). Each is cut to a piece of the "
          "listed length, the piece is tiled (repeated) up to T seconds and run through the fp32 function for T, and "
          "the result is compared (cosine) with the piece's exact-length embedding from the torch model. Cells: mean "
          "cosine (5th percentile).\n")
        crops = til["crops_s"]
        w("| piece | " + " | ".join(f"T = {T} s" for T in range(1, 11)) + " |")
        w("|---|" + "---|" * 10)
        for c in crops:
            cells = []
            for T in range(1, 11):
                xs = til["cos"].get(f"{c:g}|{T}|fp32")
                cells.append(f"{np.mean(xs):.3f} ({np.percentile(xs, 5):.3f})" if xs else "")
            w(f"| {c:g} s | " + " | ".join(cells) + " |")
        w("")
        w("Per build: the cosine each piece length gets under that build's rule (tile up to the next length it has).\n")
        sets_ = []
        for lbl, bench, lengths, prec, _acc in REPORT_ROWS:
            if lengths not in sets_:
                sets_.append(lengths)
        w("| piece | " + " | ".join("{" + ", ".join(map(str, L_)) + "}" for L_ in sets_) + " |")
        w("|---|" + "---|" * len(sets_))
        for c in crops:
            cells = []
            for lengths in sets_:
                L = [n * SR for n in lengths]
                n = int(round(c * SR))
                if n > L[-1]:
                    cells.append("2 windows")
                    continue
                T = next_length(L, n) // SR
                xs = til["cos"].get(f"{c:g}|{T}|fp32")
                cells.append(f"{np.mean(xs):.3f} ({np.percentile(xs, 5):.3f})" if xs else "–")
            w(f"| {c:g} s | " + " | ".join(cells) + " |")
        w("")
    out = VP / "results" / "redimnet_memory.md"
    out.write_text("\n".join(lines) + "\n")
    log(f"[report] wrote {out}")
    return 0


# ============================================================================ main
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--tag", required=True)
    b.add_argument("--lengths", required=True, help="seconds, e.g. 2,4,8")
    b.add_argument("--precision", choices=["fp32", "fp16"], default="fp32")
    b.add_argument("--from", dest="src", default=None, help="copy functions out of VP/coreml/<dir>")
    b.add_argument("--fp32-pool", action="store_true")
    b.add_argument("--stable-var", action="store_true")
    b.add_argument("--no-parity", action="store_true")
    b.add_argument("--shapes", choices=["multi", "enum"], default="multi",
                   help="enum: one graph with enumerated lengths (run with reshapeFrequency=.frequent)")
    r = sub.add_parser("register")
    r.add_argument("--tag", required=True)
    r.add_argument("--id", required=True)
    r.add_argument("--note", default="")
    e = sub.add_parser("embed")
    e.add_argument("--tag", required=True, help="build tag, or full10 for the shipped 10-function build")
    e.add_argument("--id", required=True)
    e.add_argument("--sets", default=",".join(HUMAN_SETS))
    e.add_argument("--conds", default="clean,opus12")
    e.add_argument("--lengths", default=None, help="restrict the build's lengths (seconds)")
    e.add_argument("--units", default="ALL")
    e.add_argument("--turnlen", action="store_true")
    e.add_argument("--force", action="store_true")
    bb = sub.add_parser("bench")
    bb.add_argument("--rounds", type=int, default=2)
    bb.add_argument("--kind", choices=["memory", "latency", "all"], default="all")
    bb.add_argument("--only", default="")
    t = sub.add_parser("tiling")
    t.add_argument("--n", type=int, default=200)
    t.add_argument("--crops", default="0.5,1,1.5,2,2.5,3,4,5,6,7,8")
    t.add_argument("--ref-device", default="cpu")
    t.add_argument("--extra", default="", help="build tags whose functions are also compared (e.g. s248-fp16)")
    rp = sub.add_parser("report")
    rp.add_argument("--extra-md", default=None, help="hand-written findings / recommendation inserted after the table")
    ac = sub.add_parser("accuracy")
    ac.add_argument("--root", required=True)
    ac.add_argument("--baseline", required=True)
    ac.add_argument("--models", required=True)
    ac.add_argument("--name", required=True)
    args = ap.parse_args()
    return {"report": cmd_report, "accuracy": cmd_accuracy, "build": cmd_build, "register": cmd_register, "embed": cmd_embed, "bench": cmd_bench,
            "tiling": cmd_tiling}[args.cmd](args)


if __name__ == "__main__":
    rc = main()
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)
