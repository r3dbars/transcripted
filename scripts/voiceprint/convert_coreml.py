#!/usr/bin/env python3
"""Convert a voiceprint bake-off model to ONE fused Core ML model.

    raw 16 kHz mono float32 audio "audio" [1, N]  ->  "embedding" [1, D] (raw, not normalized)

The model's whole front end (fbank / mel, its normalization) is inside the graph, so
the Swift app feeds samples and gets a vector: no Python, ONNX or FFT code in Swift.
Same idea as scripts/convert_eres2net_fused.py, generalized over the bake-off runtimes
(see scripts/voiceprint/convert/builders.py for what each front end reproduces).

Usage:
    VP/venv/bin/python scripts/voiceprint/convert_coreml.py --model redimnet2-b6-vox2-lm

Steps:
  1. build the fused torch module; gate it against the model's Python runtime
     (scripts/voiceprint/runtimes/<runtime>.py) on a few clips (cosine >= 0.9999)
  2. trace + convert (mlprogram). Input length, --shapes:
       enum   one graph, EnumeratedShapes (--enum-sec). Default. Core ML runs it on
              ANE / GPU only if the graph has no runtime-computed shapes: true for the
              WeSpeaker ResNets, and for ReDimNet2 after builders' static-shape patch
       multi  one static-shape function per length in one multifunction package
              (weights shared; Swift picks MLModelConfiguration.functionName
              "len_<samples>"). For graphs full of mask / shape math (TitaNet, CAM++)
              whose enum build Core ML keeps on the CPU
       range  RangeDim (CPU only in practice)
  3. precision "auto": fp16 (front end kept fp32) if parity holds, else fp32
  4. parity on 60 clean clips (vox1o / ami / libri, 2/4/8 s) vs the Python runtime,
     for compute units ALL and CPU_ONLY; ALL vs CPU_ONLY; latency 4 s / 10 s
  5. write VP/coreml/<id>/model.mlpackage, model.mlmodelc, report.json; when mean
     parity >= 0.999, register VP/models/<id>-coreml/model.json (runtime coreml_fused)

Writes only under VP/coreml/ and VP/models/<id>-coreml/. Never touches app state.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
import traceback
from pathlib import Path

os.environ.setdefault("OMP_NUM_THREADS", "3")
os.environ.setdefault("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1")

import numpy as np  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
sys.path.insert(0, str(HERE))

from convert import builders, pipeline  # noqa: E402

MEAN_TARGET = 0.999
MIN_TARGET = 0.995
DEFAULT_ENUM = "1,1.5,2,2.5,3,3.5,4,5,6,7,8,9,10"


def log(msg: str):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def reference_embeddings(model_id, meta, model_dir, rows, wavs, out_dir: Path) -> list[np.ndarray]:
    """Embeddings from the model's own Python runtime; cached per clip list."""
    cache = out_dir / "ref_embs.npz"
    ids = [r["seg_id"] for r in rows]
    if cache.exists():
        z = np.load(cache, allow_pickle=False)
        if list(z["seg_id"]) == ids and z.get("runtime_sig") is not None and \
                str(z["runtime_sig"]) == _runtime_sig(meta):
            return list(z["emb"])
    rt = builders.load_runtime(meta["runtime"])
    emb = rt.Embedder(model_dir, meta, threads=3)
    t0 = time.time()
    refs = [np.asarray(emb.embed(w), np.float32).reshape(-1) for w in wavs]
    log(f"[ref] {len(refs)} clips via runtimes/{meta['runtime']}.py in {time.time() - t0:.0f}s "
        f"(device {getattr(emb, 'device', 'cpu')})")
    np.savez(cache, seg_id=np.array(ids), emb=np.stack(refs), runtime_sig=np.array(_runtime_sig(meta)))
    return refs


def _runtime_sig(meta) -> str:
    import hashlib

    h = hashlib.sha1(json.dumps({k: meta.get(k) for k in ("runtime", "files", "level_norm_dbfs", "dim")},
                                sort_keys=True).encode())
    h.update((builders.RUNTIMES / f"{meta['runtime']}.py").read_bytes())
    return h.hexdigest()[:16]


def torch_gate(built, wavs, refs, n=6) -> dict:
    import torch

    cs = []
    with torch.no_grad():
        for w, r in zip(wavs[:n], refs[:n]):
            out = built.module(torch.from_numpy(w)[None]).numpy().reshape(-1)
            cs.append(pipeline.cos(out, r))
    return pipeline.stats(cs)


def frontend_check(built, meta, wavs) -> dict | None:
    """Fused front end vs the reference feature code, where one exists in Python."""
    import torch

    if built.frontend.get("kind") != "torchaudio_kaldi":
        return None
    from convert.frontends import torchaudio_kaldi_fbank

    diffs = []
    for w in wavs[:4]:
        ref = torchaudio_kaldi_fbank(w, scale=32768.0, window="hamming", low_freq=20.0, high_freq=0.0)
        with torch.no_grad():
            mine = built.module.frontend(torch.from_numpy(w)[None]).numpy()[0]
        assert mine.shape == ref.shape, (mine.shape, ref.shape)
        diffs.append(float(np.abs(mine - ref).max()))
    return {"max_abs_diff": max(diffs)}


def passes(p: dict) -> bool:
    return p["ALL"]["mean"] >= MEAN_TARGET and p["ALL"]["min"] >= MIN_TARGET and \
        p["CPU_ONLY"]["mean"] >= MEAN_TARGET and p["CPU_ONLY"]["min"] >= MIN_TARGET and \
        p["ALL"]["nonfinite"] == 0 and p["CPU_ONLY"]["nonfinite"] == 0


def register(model_id, meta, out_dir: Path, report: dict):
    reg_id = f"{model_id}-coreml"
    reg_dir = VP / "models" / reg_id
    reg_dir.mkdir(parents=True, exist_ok=True)
    p = report["parity"]
    lat = report.get("latency", {})
    ms4 = lat.get("ALL", {}).get("4s", {}).get("median_ms")
    reg = {
        "model_id": reg_id,
        "family": meta.get("family"),
        "runtime": "coreml_fused",
        "files": [f"../../coreml/{model_id}/model.mlpackage"],
        "compiled": f"../../coreml/{model_id}/model.mlmodelc",
        "source_model_id": model_id,
        "dim": report["dim"],
        "params_m": meta.get("params_m"),
        "train_data": meta.get("train_data"),
        "source_url": meta.get("source_url"),
        "baseline": False,
        "device": "ane",
        "status": "ready",
        "coreml": {
            "input": "audio", "output": "embedding", "precision": report["precision"],
            "shapes": report["shapes"]["kind"],
            "enumerated_samples": report["shapes"].get("samples"),
            "functions": report["shapes"].get("functions"),
            "range_samples": report["shapes"].get("range"),
        },
        "notes": (
            f"Fused Core ML build of {model_id} (scripts/voiceprint/convert_coreml.py): raw 16 kHz audio in, "
            f"front end inside the graph, {report['precision']}, compute units ALL. Parity vs the Python runtime "
            f"({meta['runtime']}) on {p['ALL']['n']} clean clips (vox1o/ami/libri, 2/4/8 s): ALL min "
            f"{p['ALL']['min']:.5f} mean {p['ALL']['mean']:.5f}; CPU_ONLY min {p['CPU_ONLY']['min']:.5f} mean "
            f"{p['CPU_ONLY']['mean']:.5f}; ALL vs CPU_ONLY min {p['ALL_vs_CPU_ONLY']['min']:.5f}. "
            f"~{ms4} ms per 4 s clip on ALL (load avg {lat.get('load_avg_start')}). Input lengths: "
            f"{report['shapes']['kind']} {report['shapes'].get('seconds') or report['shapes'].get('range')}; "
            "other lengths are cropped (centre) to the nearest lower length or tiled up by the runtime, "
            "and clips over the max are windowed and mean-pooled. Report: VP/coreml/"
            f"{model_id}/report.json."),
    }
    (reg_dir / "model.json").write_text(json.dumps(reg, indent=1))
    log(f"[register] wrote models/{reg_id}/model.json")
    return reg_id


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--precision", choices=["auto", "fp16", "fp32"], default="auto")
    ap.add_argument("--shapes", choices=["enum", "range", "multi"], default=None,
                    help="enum: one graph with enumerated lengths; multi: one static function per "
                         "length (for graphs whose shape math keeps enum builds off GPU/ANE); range: RangeDim. "
                         "Default: the builder's choice, else enum")
    ap.add_argument("--enum-sec", default=None,
                    help=f"enumerated input lengths in seconds (default {DEFAULT_ENUM}, or the builder's)")
    ap.add_argument("--range-sec", default="1,10", help="RangeDim bounds in seconds (min,max)")
    ap.add_argument("--nclips", type=int, default=60)
    ap.add_argument("--reps", type=int, default=10)
    ap.add_argument("--no-register", action="store_true")
    ap.add_argument("--out-suffix", default="", help="write to VP/coreml/<id><suffix>/ (experiments)")
    args = ap.parse_args()

    import torch

    torch.set_num_threads(3)
    model_id = args.model
    model_dir = VP / "models" / model_id
    meta = json.loads((model_dir / "model.json").read_text())
    out_dir = VP / "coreml" / f"{model_id}{args.out_suffix}"
    out_dir.mkdir(parents=True, exist_ok=True)
    report = {"model_id": model_id, "source_runtime": meta["runtime"], "converted": False,
              "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "load_avg_start": list(os.getloadavg())}

    def save_report():
        report["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        (out_dir / "report.json").write_text(json.dumps(report, indent=1, default=str))

    try:
        import coremltools as ct

        report["versions"] = {"torch": torch.__version__, "coremltools": ct.__version__,
                              "numpy": np.__version__}
        rows = pipeline.select_parity_clips(VP, args.nclips)
        wavs = [pipeline.load_wav(VP, r) for r in rows]
        refs = reference_embeddings(model_id, meta, model_dir, rows, wavs, out_dir)

        built = builders.build(model_id, meta, model_dir)
        report.update(dim=built.dim, frontend=built.frontend, notes=list(built.notes))
        shapes = args.shapes or built.default_shapes or "enum"
        if shapes in ("enum", "multi"):
            lengths = pipeline.enumerated_lengths(args.enum_sec or built.default_enum or DEFAULT_ENUM)
            for need in (4 * 16000, 10 * 16000):
                if need not in lengths:
                    lengths = sorted(set(lengths) | {need})
            if built.prepare is not None:
                built.prepare(lengths)
                report["notes"] = list(built.notes)
        fc = frontend_check(built, meta, wavs)
        if fc is not None:
            report["frontend_check"] = fc
            log(f"[gate] front end vs reference fbank: max abs diff {fc['max_abs_diff']:.2e}")
        gate = torch_gate(built, wavs, refs)
        report["torch_gate"] = gate
        log(f"[gate] fused torch fp32 vs runtime: min {gate['min']:.6f} mean {gate['mean']:.6f}")
        if gate["min"] < 0.9999:
            report["error"] = f"fused torch model does not match the runtime (min cosine {gate['min']:.5f})"
            save_report()
            log(f"[FAIL] {report['error']}")
            return 2

        if shapes in ("enum", "multi"):
            report["shapes"] = {"kind": "enumerated" if shapes == "enum" else "multifunction",
                                "samples": lengths, "seconds": [n / 16000 for n in lengths]}
            if shapes == "multi":
                report["shapes"]["functions"] = {str(n): pipeline.function_name(n) for n in lengths}
            rng = None
        else:
            lo, hi = (int(float(x) * 16000) for x in args.range_sec.split(","))
            rng = (lo, hi)
            lengths = []
            report["shapes"] = {"kind": "range", "range": [lo, hi]}

        order = {"auto": ["fp16", "fp32"], "fp16": ["fp16"], "fp32": ["fp32"]}[args.precision]
        tried = {}
        chosen = None
        for prec in order:
            pkg = out_dir / f"model_{prec}.mlpackage"
            _, kept = pipeline.convert(built.module, example_len=64000, shapes=shapes, lengths=lengths,
                                       precision=prec, fp32_scopes=built.fp32_scopes, out_path=pkg,
                                       range_bounds=rng or (16000, 160000), log=log)
            t0 = time.time()
            mlc = pipeline.compile_model(pkg)
            log(f"[compile] {mlc.name} in {time.time() - t0:.0f}s")
            p, embs = pipeline.parity(mlc, wavs, refs, multi=shapes == "multi", log=log)
            p["per_bucket_ALL"] = pipeline.per_bucket(rows, refs, embs["ALL"])
            p["fp32_kept_ops"] = kept
            tried[prec] = p
            if passes(p) or prec == order[-1]:
                chosen = prec
                break
            log(f"[precision] {prec} misses parity target; trying next")
        report["precision_trials"] = tried
        report["precision"] = chosen
        report["parity"] = tried[chosen]
        report["parity_clips"] = {"n": len(rows), "sets": list(pipeline.PARITY_SETS),
                                  "seg_ids": [r["seg_id"] for r in rows]}

        # final names: model.mlpackage / model.mlmodelc (drop rejected variants)
        final_pkg, final_mlc = out_dir / "model.mlpackage", out_dir / "model.mlmodelc"
        for p_ in (final_pkg, final_mlc):
            if p_.exists():
                shutil.rmtree(p_)
        for prec in tried:
            pkg = out_dir / f"model_{prec}.mlpackage"
            mlc = out_dir / f"model_{prec}.mlmodelc"
            if prec == chosen:
                pkg.rename(final_pkg)
                mlc.rename(final_mlc)
            else:
                shutil.rmtree(pkg, ignore_errors=True)
                shutil.rmtree(mlc, ignore_errors=True)
        report["files"] = {"mlpackage": "model.mlpackage", "mlmodelc": "model.mlmodelc"}
        report["size_mb"] = {"mlpackage": round(pipeline.dir_mb(final_pkg), 1),
                             "mlmodelc": round(pipeline.dir_mb(final_mlc), 1)}

        # latency: a 4 s parity clip, and 10 s built from two clips of the same set
        i4 = next(i for i, r in enumerate(rows) if int(r["bucket"]) == 4)
        i8 = next(i for i, r in enumerate(rows) if int(r["bucket"]) == 8)
        i2 = next(i for i, r in enumerate(rows) if int(r["bucket"]) == 2)
        wav10 = np.concatenate([wavs[i8], wavs[i2]])[:160000]
        report["latency"] = pipeline.latency(final_mlc, wavs[i4], wav10, reps=args.reps,
                                             multi=shapes == "multi", log=log)
        report["compute_plan_ALL"] = pipeline.compute_plan(
            final_mlc, pipeline.function_name(64000) if shapes == "multi" else "main")
        log(f"[plan] {report['compute_plan_ALL'].get('ops')} cost {report['compute_plan_ALL'].get('cost_frac')}")
        report["converted"] = True
        report["meets_target"] = passes(report["parity"])
        save_report()
        if report["meets_target"] and not args.no_register and not args.out_suffix:
            report["registered_as"] = register(model_id, meta, out_dir, report)
            save_report()
        log(f"[done] {model_id}: {chosen}, ALL mean {report['parity']['ALL']['mean']:.5f} "
            f"min {report['parity']['ALL']['min']:.5f}, size {report['size_mb']['mlpackage']} MB")
        return 0 if report["meets_target"] else 1
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
        report["traceback"] = traceback.format_exc()[-4000:]
        save_report()
        traceback.print_exc()
        return 3


if __name__ == "__main__":
    rc = main()
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(rc)  # skip interpreter teardown: Core ML frees prediction buffers on its own threads
