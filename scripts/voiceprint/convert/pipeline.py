"""Conversion, parity and latency helpers for scripts/voiceprint/convert_coreml.py."""
from __future__ import annotations

import collections
import json
import os
import shutil
import statistics
import subprocess
import time
from pathlib import Path

import numpy as np

SR = 16000
PARITY_SETS = ("vox1o", "ami", "libri")


# --------------------------------------------------------------------------- coremltools fixes
def patch_coremltools():
    """coremltools 9 + numpy 2.5: `int(np.array([n]))` now raises inside the torch
    frontend's `int` cast (shape arithmetic like c*f in a reshape). Fold size-1 arrays."""
    import coremltools  # noqa: F401
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch import ops as _ops

    if getattr(_ops, "_vp_patched", False):
        return
    orig = _ops._cast

    def _cast_fixed(context, node, dtype, dtype_name):
        x = _ops._get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and not isinstance(x.val, dtype) and np.size(x.val) == 1:
            val = np.asarray(x.val).reshape(-1)[0].item()
            context.add(mb.const(val=dtype(val), name=node.name), node.name)
            return
        return orig(context, node, dtype, dtype_name)

    _ops._cast = _cast_fixed
    _ops._vp_patched = True


# --------------------------------------------------------------------------- clips
def select_parity_clips(vp: Path, n: int = 60, seed: int = 1234) -> list[dict]:
    """n clips, split evenly over vox1o / ami / libri clean, rotating 2 / 4 / 8 s buckets,
    one clip per speaker where possible. Deterministic."""
    rng = np.random.default_rng(seed)
    per_set = n // len(PARITY_SETS)
    out = []
    for si, s in enumerate(PARITY_SETS):
        rows = [json.loads(l) for l in (vp / "sets" / s / "segments.jsonl").read_text().splitlines() if l.strip()]
        by_bucket = {b: [r for r in rows if int(r["bucket"]) == b] for b in (2, 4, 8)}
        k = per_set + (1 if si < n % len(PARITY_SETS) else 0)
        used_spk = set()
        for i in range(k):
            b = (2, 4, 8)[(i + si) % 3]
            cands = [r for r in by_bucket[b] if r["speaker"] not in used_spk] or by_bucket[b]
            r = cands[int(rng.integers(len(cands)))]
            used_spk.add(r["speaker"])
            out.append(r)
    return out


def load_wav(vp: Path, row: dict) -> np.ndarray:
    import soundfile as sf

    wav, sr = sf.read(vp / row["clip"], dtype="float32", always_2d=False)
    if wav.ndim > 1:
        wav = wav.mean(axis=1)
    assert sr == SR, sr
    return np.ascontiguousarray(wav, dtype=np.float32)


def cos(a, b) -> float:
    a = np.asarray(a, np.float64).reshape(-1)
    b = np.asarray(b, np.float64).reshape(-1)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def stats(xs) -> dict:
    xs = [float(x) for x in xs]
    return {"min": round(min(xs), 6), "mean": round(float(np.mean(xs)), 6), "n": len(xs)}


# --------------------------------------------------------------------------- conversion
def enumerated_lengths(spec: str) -> list[int]:
    """'2,4,8,10' or '1:10:0.5' (seconds) -> sorted sample counts."""
    if ":" in spec:
        a, b, st = (float(x) for x in spec.split(":"))
        secs = list(np.arange(a, b + 1e-9, st))
    else:
        secs = [float(x) for x in spec.split(",") if x.strip()]
    return sorted({int(round(s * SR)) for s in secs})


def function_name(n: int) -> str:
    return f"len_{n}"


def convert(fused, *, example_len: int, shapes: str, lengths: list[int], precision: str,
            fp32_scopes: list[str], out_path: Path, range_bounds=(16000, 160000), log=print):
    """shapes: "enum" (one graph, EnumeratedShapes), "range" (RangeDim) or "multi"
    (one static-shape function per length in a multifunction package; weights shared)."""
    import tempfile

    import coremltools as ct
    import torch
    from coremltools.converters.mil.mil.scope import ScopeSource

    patch_coremltools()
    kept_fp32 = {"n": 0}

    def op_selector(op):
        names = []
        try:
            names = op.scopes.get(ScopeSource.TORCHSCRIPT_MODULE_NAME, []) or []
        except Exception:
            pass
        flat = "/".join(str(x) for x in names)
        parts = set(flat.replace(".", "/").split("/"))
        if any(s in parts for s in fp32_scopes):
            kept_fp32["n"] += 1
            return False
        return True

    if precision == "fp16":
        cp = ct.transform.FP16ComputePrecision(op_selector=op_selector) if fp32_scopes else ct.precision.FLOAT16
    else:
        cp = ct.precision.FLOAT32

    def one(example_n, shape):
        example = torch.randn(1, example_n) * 0.05
        with torch.no_grad():
            traced = torch.jit.trace(fused, example, check_trace=False)
        ml = ct.convert(
            traced,
            inputs=[ct.TensorType(name="audio", shape=shape, dtype=np.float32)],
            outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
            convert_to="mlprogram",
            compute_precision=cp,
            compute_units=ct.ComputeUnit.ALL,
            minimum_deployment_target=ct.target.macOS15 if shapes == "multi" else ct.target.macOS14,
        )
        ml.short_description = "Fused voiceprint model: raw 16 kHz mono float audio -> speaker embedding"
        return ml

    t0 = time.time()
    if out_path.exists():
        shutil.rmtree(out_path)
    if shapes == "multi":
        from coremltools.models.utils import MultiFunctionDescriptor, save_multifunction

        with tempfile.TemporaryDirectory(dir=str(out_path.parent)) as td:
            desc = MultiFunctionDescriptor()
            for n in lengths:
                p = Path(td) / f"f{n}.mlpackage"
                one(n, (1, n)).save(str(p))
                desc.add_function(str(p), src_function_name="main", target_function_name=function_name(n))
            desc.default_function_name = function_name(example_len if example_len in lengths else lengths[0])
            save_multifunction(desc, str(out_path))
        ml = None
    else:
        if shapes == "enum" and len(lengths) == 1:
            shape = (1, lengths[0])
        elif shapes == "enum":
            default = example_len if example_len in lengths else lengths[len(lengths) // 2]
            shape = ct.EnumeratedShapes(shapes=[(1, n) for n in lengths], default=(1, default))
        else:
            lo, hi = range_bounds
            shape = (1, ct.RangeDim(lower_bound=lo, upper_bound=hi, default=example_len))
        ml = one(example_len, shape)
        ml.save(str(out_path))
    log(f"[convert] {precision} {shapes} -> {out_path.name} in {time.time() - t0:.0f}s "
        f"(fp32-kept ops: {kept_fp32['n']})")
    return ml, kept_fp32["n"]


def compile_model(mlpackage: Path) -> Path:
    out_dir = mlpackage.parent
    target = out_dir / (mlpackage.stem + ".mlmodelc")
    if target.exists():
        shutil.rmtree(target)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(mlpackage), str(out_dir)],
                   check=True, stdout=subprocess.DEVNULL)
    return target


def dir_mb(p: Path) -> float:
    if p.is_file():
        return p.stat().st_size / 1e6
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) / 1e6


# --------------------------------------------------------------------------- evaluation
def load_compiled(mlmodelc: Path, units: str, function: str | None = None):
    import coremltools as ct

    cu = {"ALL": ct.ComputeUnit.ALL, "CPU_ONLY": ct.ComputeUnit.CPU_ONLY,
          "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU, "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE}[units]
    if function:
        return ct.models.CompiledMLModel(str(mlmodelc), compute_units=cu, function_name=function)
    return ct.models.CompiledMLModel(str(mlmodelc), compute_units=cu)


# Core ML (E5) releases a prediction's input MLFeatureValue later on a GCD thread
# ("resetAfterLingering"); if that drops the last reference to the numpy buffer, the
# free runs without the GIL and segfaults (seen with multifunction models). So inputs
# and loaded models are kept alive for the life of the process.
_KEEP_INPUTS = collections.deque(maxlen=256)
_KEEP_MODELS = []


def predict(model, wav: np.ndarray) -> np.ndarray:
    arr = np.ascontiguousarray(wav.reshape(1, -1), dtype=np.float32)
    _KEEP_INPUTS.append(arr)
    out = model.predict({"audio": arr})
    return np.asarray(out["embedding"], dtype=np.float32).reshape(-1)


class Predictor:
    """One compiled model, or (multifunction) one loaded function per input length."""

    def __init__(self, mlmodelc: Path, units: str, multi: bool):
        self.mlmodelc, self.units, self.multi = mlmodelc, units, multi
        self.models = {}
        self.load_s = 0.0

    def __call__(self, wav: np.ndarray) -> np.ndarray:
        key = function_name(len(wav)) if self.multi else None
        m = self.models.get(key)
        if m is None:
            t0 = time.time()
            m = self.models[key] = load_compiled(self.mlmodelc, self.units, key)
            _KEEP_MODELS.append(m)
            self.load_s += time.time() - t0
        return predict(m, wav)


def parity(mlmodelc: Path, wavs: list[np.ndarray], refs: list[np.ndarray], multi: bool = False,
           log=print) -> dict:
    res = {}
    embs = {}
    for units in ("ALL", "CPU_ONLY"):
        pr = Predictor(mlmodelc, units, multi)
        e = []
        bad = 0
        t0 = time.time()
        for w in wavs:
            v = pr(w)
            if not np.all(np.isfinite(v)):
                bad += 1
            e.append(v)
        embs[units] = e
        cs = [cos(a, b) for a, b in zip(refs, e)]
        res[units] = {**stats(cs), "nonfinite": bad, "load_s": round(pr.load_s, 2),
                      "wall_s": round(time.time() - t0, 1)}
        log(f"[parity] {units}: min {res[units]['min']:.6f} mean {res[units]['mean']:.6f} nonfinite {bad}")
        del pr
    res["ALL_vs_CPU_ONLY"] = stats([cos(a, b) for a, b in zip(embs["ALL"], embs["CPU_ONLY"])])
    return res, embs


def per_bucket(rows, refs, embs) -> dict:
    out = {}
    for b in (2, 4, 8):
        idx = [i for i, r in enumerate(rows) if int(r["bucket"]) == b]
        if idx:
            out[f"{b}s"] = stats([cos(refs[i], embs[i]) for i in idx])
    return out


def latency(mlmodelc: Path, wav4: np.ndarray, wav10: np.ndarray, reps: int = 10, multi: bool = False,
            mixed: list | None = None, log=print) -> dict:
    """Median ms at a fixed 4 s / 10 s length, plus (mixed) ms per clip when lengths
    alternate 2/4/8 s: an enumerated-shape model can re-plan on every length change."""
    res = {"load_avg_start": [round(x, 1) for x in os.getloadavg()]}
    for units in ("ALL", "CPU_AND_GPU", "CPU_ONLY"):
        pr = Predictor(mlmodelc, units, multi)
        r = {}
        if mixed:
            for w in mixed:
                pr(w)
            t0 = time.perf_counter()
            for w in mixed:
                pr(w)
            r["mixed_2_4_8s_ms_per_clip"] = round((time.perf_counter() - t0) * 1000 / len(mixed), 1)
        for name, w in (("4s", wav4), ("10s", wav10)):
            t0 = time.perf_counter()
            pr(w)
            first = (time.perf_counter() - t0) * 1000
            for _ in range(2):
                pr(w)
            ts = []
            for _ in range(reps):
                t0 = time.perf_counter()
                pr(w)
                ts.append((time.perf_counter() - t0) * 1000)
            r[name] = {"median_ms": round(statistics.median(ts), 1), "min_ms": round(min(ts), 1),
                       "first_call_ms_incl_load": round(first, 1)}
        res[units] = r
        log(f"[latency] {units}: 4s median {r['4s']['median_ms']} ms (min {r['4s']['min_ms']}), "
            f"10s median {r['10s']['median_ms']} ms (min {r['10s']['min_ms']}), "
            f"mixed 2/4/8 s {r.get('mixed_2_4_8s_ms_per_clip')} ms/clip")
        del pr
    res["load_avg_end"] = [round(x, 1) for x in os.getloadavg()]
    return res


def compute_plan(mlmodelc: Path, function: str = "main") -> dict:
    """Which device Core ML prefers per op with compute units ALL (cost-weighted)."""
    try:
        import coremltools as ct
        from coremltools.models.compute_plan import MLComputePlan
        from coremltools.models.compute_device import (MLCPUComputeDevice, MLGPUComputeDevice,
                                                       MLNeuralEngineComputeDevice)
    except Exception as exc:  # pragma: no cover
        return {"error": f"{type(exc).__name__}: {exc}"}
    try:
        plan = MLComputePlan.load_from_path(path=str(mlmodelc), compute_units=ct.ComputeUnit.ALL)
        prog = plan.model_structure.program
        fn = prog.functions.get(function) or next(iter(prog.functions.values()))
        ops = fn.block.operations
        counts = {"ane": 0, "gpu": 0, "cpu": 0, "unknown": 0}
        cost = {"ane": 0.0, "gpu": 0.0, "cpu": 0.0, "unknown": 0.0}
        cpu_ops = {}
        for op in ops:
            if op.operator_name in ("const",):
                continue
            u = plan.get_compute_device_usage_for_mlprogram_operation(op)
            c = plan.get_estimated_cost_for_mlprogram_operation(op)
            w = c.weight if c is not None else 0.0
            if u is None:
                k = "unknown"
            else:
                d = u.preferred_compute_device
                k = ("ane" if isinstance(d, MLNeuralEngineComputeDevice) else
                     "gpu" if isinstance(d, MLGPUComputeDevice) else
                     "cpu" if isinstance(d, MLCPUComputeDevice) else "unknown")
            counts[k] += 1
            cost[k] += w
            if k in ("cpu", "gpu"):
                cpu_ops[op.operator_name] = cpu_ops.get(op.operator_name, 0) + 1
        return {"ops": counts, "cost_frac": {k: round(v, 4) for k, v in cost.items()},
                "non_ane_op_types": dict(sorted(cpu_ops.items(), key=lambda kv: -kv[1])[:15])}
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"}
