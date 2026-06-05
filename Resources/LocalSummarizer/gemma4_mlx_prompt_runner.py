#!/usr/bin/env python3
"""Run one local Gemma 4 MLX prompt without putting transcript text in argv."""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Transcripted local Gemma prompt runner")
    parser.add_argument("--jobs-file")
    parser.add_argument("--prompt-file")
    parser.add_argument("--output-file")
    parser.add_argument("--metrics-file")
    parser.add_argument("--model", default="mlx-community/gemma-4-12B-it-4bit")
    parser.add_argument("--max-tokens", type=int, default=800)
    parser.add_argument("--max-kv-size", type=int, default=8192)
    parser.add_argument("--cooldown-seconds", type=float, default=0.0)
    return parser.parse_args()


def load_jobs(args: argparse.Namespace) -> list[dict[str, object]]:
    if args.jobs_file:
        jobs = json.loads(Path(args.jobs_file).read_text(encoding="utf-8"))
        if not isinstance(jobs, list) or not jobs:
            raise ValueError("jobs-file must contain a non-empty list")
        return jobs

    missing = [
        name
        for name in ("prompt_file", "output_file", "metrics_file")
        if getattr(args, name) is None
    ]
    if missing:
        raise ValueError(f"missing required arguments: {', '.join(missing)}")

    return [
        {
            "label": "prompt",
            "prompt_file": args.prompt_file,
            "output_file": args.output_file,
            "metrics_file": args.metrics_file,
            "max_tokens": args.max_tokens,
        }
    ]


def run_job(job: dict[str, object], model, processor, generate_func, max_kv_size: int, mx) -> None:
    label = str(job.get("label") or "prompt")
    prompt_file = Path(str(job["prompt_file"]))
    output_file = Path(str(job["output_file"]))
    metrics_file = Path(str(job["metrics_file"]))
    max_tokens = int(job.get("max_tokens") or 800)

    prompt = prompt_file.read_text(encoding="utf-8", errors="replace")
    chat_prompt = processor.tokenizer.apply_chat_template(
        [{"role": "user", "content": prompt}],
        tokenize=False,
        add_generation_prompt=True,
    )

    started = time.time()
    try:
        result = generate_func(
            model,
            processor,
            chat_prompt,
            max_tokens=max_tokens,
            temperature=0.0,
            max_kv_size=max_kv_size,
            verbose=False,
        )
    except Exception as exc:
        raise RuntimeError(f"{label}: {exc}") from exc
    elapsed = time.time() - started

    output_file.write_text(result.text.strip() + "\n", encoding="utf-8")
    metrics = {
        "label": label,
        "seconds": round(elapsed, 2),
        "prompt_tokens": getattr(result, "prompt_tokens", None),
        "generation_tokens": getattr(result, "generation_tokens", None),
        "peak_memory_gb": getattr(result, "peak_memory", None),
        "finish_reason": getattr(result, "finish_reason", None),
        "output_chars": len(result.text),
    }
    metrics_file.write_text(json.dumps(metrics, indent=2), encoding="utf-8")

    if mx is not None:
        try:
            mx.clear_cache()
        except Exception:
            pass


def main() -> int:
    args = parse_args()
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    from mlx_vlm.generate.dispatch import generate
    from mlx_vlm.utils import load

    try:
        import mlx.core as mx
    except Exception:
        mx = None

    model, processor = load(args.model)
    jobs = load_jobs(args)
    for index, job in enumerate(jobs):
        run_job(job, model, processor, generate, args.max_kv_size, mx)
        if args.cooldown_seconds > 0 and index < len(jobs) - 1:
            time.sleep(args.cooldown_seconds)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
