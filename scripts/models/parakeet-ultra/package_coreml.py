#!/usr/bin/env python3
"""Package converted Parakeet Ultra Core ML models the way Transcripted loads them.

Takes mobius's convert-parakeet.py output for the Ultra checkpoint and
installs a folder that FluidAudio's AsrModels.load(from:version: .v3) accepts:

  <install-root>/parakeet-ultra/parakeet-tdt-0.6b-v3/
      Encoder.mlmodelc          Ultra encoder (8-bit k-means palettized by default, or fp16)
      Decoder.mlmodelc          Ultra prediction network
      JointDecisionv3.mlmodelc  Ultra joint + decision head (with top-k outputs)
      Preprocessor.mlmodelc     copied from stock v3 (fixed mel frontend, no weights Ultra changed)
      config.json, parakeet_v3_vocab.json, parakeet_vocab.json  copied from stock v3 (same tokenizer)
      transcripted-model.json   written last; the app ignores the folder without it
  <install-root>/parakeet-ultra/ATTRIBUTION.txt

Before installing, every compiled model's inputs and outputs are compared with
the stock v3 model of the same name, so a converter change that FluidAudio
could not run fails here instead of inside the app. Runs on macOS only
(xcrun coremlcompiler), inside the mobius uv environment for coremltools.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

MARKER = "transcripted-model.json"
LOAD_FOLDER = "parakeet-tdt-0.6b-v3"
INSTALL_FOLDER = "parakeet-ultra"

# mobius package name -> FluidAudio 0.15.x file name
CONVERTED = {
    "parakeet_encoder": "Encoder.mlmodelc",
    "parakeet_decoder": "Decoder.mlmodelc",
    "parakeet_joint_decision_single_step": "JointDecisionv3.mlmodelc",
}
COPIED_FROM_STOCK = ["Preprocessor.mlmodelc", "config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json"]

ATTRIBUTION = """Parakeet Ultra by Moondream (M87 Labs)
https://huggingface.co/moondream/parakeet-ultra
License: CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/)

Parakeet Ultra is a post-trained version of NVIDIA's parakeet-tdt-0.6b-v3
(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3, CC-BY-4.0).

Changes: converted from Transformers to NeMo weight names, exported to Core ML
with FluidInference/mobius, encoder weights {encoder_change}, and packaged for
Transcripted's FluidAudio runtime. Preprocessor and vocabulary files come from
FluidInference/parakeet-tdt-0.6b-v3-coreml, which shares Ultra's tokenizer.

This build:
  Ultra commit:             {revision}
  model.safetensors sha256: {safetensors_sha256}
  NVIDIA base commit:       {base_revision}
  Converter:                {converter}
  Encoder quantization:     {encoder_quantization}
"""

# Human-readable encoder quantization, recorded in the marker, ATTRIBUTION.txt
# and the comparison report so a quantization difference isn't read as a
# weights difference.
ENCODER_QUANTIZATION = {
    "palettize8": "8-bit k-means palettization (coremltools OpPalettizerConfig mode=kmeans nbits=8)",
    "fp16": "none (float16 weights)",
}


def palettize_encoder(package: Path, output: Path) -> None:
    import coremltools as ct
    from coremltools.optimize.coreml import OpPalettizerConfig, OptimizationConfig, palettize_weights

    print("Palettizing the encoder to 8 bits with k-means (stock v3's encoder is 8-bit too)...")
    model = ct.models.MLModel(str(package), skip_model_load=True)
    config = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=8))
    palettize_weights(model, config).save(str(output))


def compile_package(package: Path, destination: Path) -> None:
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), scratch], check=True)
        compiled = Path(scratch) / f"{package.stem}.mlmodelc"
        if not compiled.is_dir():
            sys.exit(f"coremlcompiler did not produce {compiled.name}")
        shutil.move(str(compiled), str(destination))


def io_contract(compiled: Path) -> dict:
    """Input/output names, types and shapes from a compiled model's metadata."""
    metadata = json.loads((compiled / "metadata.json").read_text())
    entry = metadata[0] if isinstance(metadata, list) else metadata

    def describe(schema: list[dict]) -> list[tuple]:
        return sorted(
            (f.get("name"), f.get("dataType"), f.get("shape") or f.get("formattedType"))
            for f in schema
        )

    return {"inputs": describe(entry.get("inputSchema", [])), "outputs": describe(entry.get("outputSchema", []))}


def resolve_stock_dir(candidates: list[Path]) -> Path:
    for candidate in candidates:
        if all((candidate / name).exists() for name in [*CONVERTED.values(), *COPIED_FROM_STOCK]):
            return candidate
    needed = [*CONVERTED.values(), *COPIED_FROM_STOCK]
    searched = "\n  ".join(
        f"{c} (missing: {', '.join(n for n in needed if not (c / n).exists())})"
        if c.is_dir() else f"{c} (not found)"
        for c in candidates
    )
    sys.exit(
        "Could not find a complete stock Parakeet V3 model to copy the frontend from and check against.\n"
        f"Open Transcripted once so it has Parakeet V3, then rerun. Looked in:\n  {searched}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--coreml-dir", type=Path, required=True, help="mobius convert-parakeet.py --output-dir")
    parser.add_argument("--stock-dir", type=Path, action="append", required=True,
                        help="Stock parakeet-tdt-0.6b-v3 folder(s) to try, in order")
    parser.add_argument("--build-info", type=Path, required=True, help="build-info.json from build_ultra_nemo.py")
    parser.add_argument("--install-root", type=Path, required=True, help="Transcripted's models folder")
    parser.add_argument("--mobius-commit", required=True)
    parser.add_argument("--encoder", choices=["palettize8", "fp16"], default="palettize8")
    args = parser.parse_args()

    stock = resolve_stock_dir(args.stock_dir)
    print(f"Stock Parakeet V3: {stock}")
    build_info = json.loads(args.build_info.read_text())

    args.install_root.mkdir(parents=True, exist_ok=True)
    staging_root = Path(tempfile.mkdtemp(prefix=f".{INSTALL_FOLDER}-staging-", dir=args.install_root))
    try:
        load_dir = staging_root / LOAD_FOLDER
        load_dir.mkdir()

        with tempfile.TemporaryDirectory() as scratch:
            for package_name, file_name in CONVERTED.items():
                package = args.coreml_dir / f"{package_name}.mlpackage"
                if not package.exists():
                    sys.exit(f"Missing {package.name} in {args.coreml_dir}; did convert-parakeet.py finish?")
                if package_name == "parakeet_encoder" and args.encoder == "palettize8":
                    palettized = Path(scratch) / "parakeet_encoder.mlpackage"
                    palettize_encoder(package, palettized)
                    package = palettized
                print(f"Compiling {package.name} -> {file_name}")
                compile_package(package, load_dir / file_name)

        mismatches = []
        for file_name in CONVERTED.values():
            ours, theirs = io_contract(load_dir / file_name), io_contract(stock / file_name)
            if ours != theirs:
                mismatches.append(f"{file_name}\n    Ultra: {ours}\n    stock: {theirs}")
            else:
                print(f"{file_name}: inputs and outputs match stock v3")
        if mismatches:
            sys.exit("Converted models don't match what FluidAudio loads for v3:\n  " + "\n  ".join(mismatches))

        for name in COPIED_FROM_STOCK:
            source = stock / name
            if source.is_dir():
                shutil.copytree(source, load_dir / name, symlinks=False)
            else:
                shutil.copy2(source, load_dir / name)

        converter = f"FluidInference/mobius@{args.mobius_commit}"
        encoder_quantization = ENCODER_QUANTIZATION[args.encoder]
        (staging_root / "ATTRIBUTION.txt").write_text(ATTRIBUTION.format(
            encoder_change="8-bit palettized" if args.encoder == "palettize8" else "kept at float16",
            revision=build_info.get("revision", "unknown"),
            safetensors_sha256=build_info.get("safetensors_sha256", "unknown"),
            base_revision=build_info.get("base_revision", "unknown"),
            converter=converter,
            encoder_quantization=encoder_quantization,
        ))
        pinned_keys = ("model", "revision", "safetensors_sha256", "base_model", "base_revision", "license")
        marker = {
            **{k: build_info[k] for k in pinned_keys if k in build_info},
            "attribution": "Parakeet Ultra by Moondream (M87 Labs), CC-BY-4.0. See ../ATTRIBUTION.txt.",
            "converter": converter,
            "encoder": args.encoder,
            "encoder_quantization": encoder_quantization,
            "installed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        # Written last: the app only treats the folder as Ultra once this exists.
        (load_dir / MARKER).write_text(json.dumps(marker, indent=2) + "\n")

        final = args.install_root / INSTALL_FOLDER
        previous = args.install_root / f".{INSTALL_FOLDER}-previous"
        if previous.exists():
            shutil.rmtree(previous)
        if final.exists():
            final.rename(previous)
        staging_root.rename(final)
        if previous.exists():
            shutil.rmtree(previous)
        print(f"Installed Parakeet Ultra at {final / LOAD_FOLDER}")
    finally:
        if staging_root.exists():
            shutil.rmtree(staging_root, ignore_errors=True)


if __name__ == "__main__":
    main()
