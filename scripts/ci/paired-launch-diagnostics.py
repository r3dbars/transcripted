#!/usr/bin/env python3
"""Diagnostic-only, fixed-sample base/candidate launch comparison on hosted CI.

Uses the existing reviewed launch bench. Never changes a required check verdict.
Only bounded numbers, fixed labels and commit/toolchain identities leave the runner.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys


BASE_SHA = "5231152092d3146cdd14450d115265a4feb7a28a"
CANDIDATE_SHA = "7943364d5d4f9cf0ec66140fecf21cb102b203f0"
ORDER = ("base", "candidate", "candidate", "base", "candidate", "base", "base", "candidate")
SAMPLES_PER_BLOCK = 5
SHA = re.compile(r"[0-9a-f]{40}")


class InvalidEvidence(ValueError):
    """Deliberately fixed messages: never include untrusted payloads or paths."""


def checked_block(payload, index):
    arm = ORDER[index]
    label = f"{arm}-block-{index + 1}"
    if not isinstance(payload, dict):
        raise InvalidEvidence("invalid_block_shape")
    if (payload.get("label") != label or payload.get("homeMode") != "fresh"
            or type(payload.get("requestedSamples")) is not int
            or type(payload.get("collectedSamples")) is not int
            or payload["requestedSamples"] != SAMPLES_PER_BLOCK
            or payload["collectedSamples"] != SAMPLES_PER_BLOCK):
        raise InvalidEvidence("incomplete_or_mismatched_block")
    samples = payload.get("samples")
    if not isinstance(samples, list) or len(samples) != SAMPLES_PER_BLOCK:
        raise InvalidEvidence("incomplete_samples")
    try:
        invalid_number = any(type(value) not in (int, float) or not math.isfinite(value) or value < 0
                             for value in samples)
    except OverflowError:
        invalid_number = True
    if invalid_number:
        raise InvalidEvidence("invalid_numeric_sample")
    return {
        "block": index + 1, "arm": arm,
        "source_sha": BASE_SHA if arm == "base" else CANDIDATE_SHA,
        "warmup_launches_requested": 0,
        "samples_ms": list(samples),
    }


def summary(samples):
    ordered = sorted(samples)
    def percentile(q):
        return ordered[max(0, math.ceil(q * len(ordered)) - 1)]
    return {
        "count": len(samples), "first_scored_sample_ms": samples[0],
        "min_ms": ordered[0], "p50_ms": percentile(0.50),
        "p90_ms": percentile(0.90), "p95_ms": percentile(0.95),
        "max_ms": ordered[-1], "mean_ms": round(statistics.fmean(samples), 3),
        "stdev_ms": round(statistics.stdev(samples), 3),
    }


def aggregate(payloads, workflow_sha):
    if not isinstance(workflow_sha, str) or not SHA.fullmatch(workflow_sha):
        raise InvalidEvidence("invalid_workflow_identity")
    if len(payloads) != len(ORDER):
        raise InvalidEvidence("incomplete_block_sequence")
    blocks = [checked_block(payload, index) for index, payload in enumerate(payloads)]
    samples = {arm: [v for block in blocks if block["arm"] == arm for v in block["samples_ms"]]
               for arm in ("base", "candidate")}
    pairs = []
    for index in range(0, len(blocks), 2):
        by_arm = {block["arm"]: block for block in blocks[index:index + 2]}
        pairs.append({
            "pair": index // 2 + 1,
            "candidate_minus_base_mean_ms": round(
                statistics.fmean(by_arm["candidate"]["samples_ms"])
                - statistics.fmean(by_arm["base"]["samples_ms"]), 3),
            "candidate_minus_base_p50_ms": round(
                statistics.median(by_arm["candidate"]["samples_ms"])
                - statistics.median(by_arm["base"]["samples_ms"]), 3),
        })
    return {
        "complete": True, "purpose": "diagnosis_only", "workflow_sha": workflow_sha,
        "harness_sha": CANDIDATE_SHA, "base_sha": BASE_SHA, "candidate_sha": CANDIDATE_SHA,
        "home_mode": "fresh_per_sample", "order": list(ORDER),
        "warmup_launches_requested": 0,
        "samples_per_arm": 20, "blocks": blocks,
        "summary": {arm: summary(values) for arm, values in samples.items()},
        "paired_block_differences": pairs,
        "sampling_scope": "Fresh processes and HOME directories; no cold-boot or filesystem-cache reset.",
        "original_required_check": {
            "run_id": 41658599408, "job_id": 125995622826,
            "merge_sha": "1b81c912aabdd77fa916d63552285fd4626c854e",
            "status": "failed", "launch_ms": 3206.3, "budget_ms": 3000,
        },
        "release_verdict": "HOLD: diagnostic samples do not clear the original required check or release gates.",
        "limitations": [
            "No per-phase launch profile, real UI interaction, picker import, or hardware proof.",
            "Twenty samples describe this hosted runner; they do not establish a fleet percentile.",
            "Build launch smoke is explicitly skipped only for diagnostic build preparation.",
            "The existing benchmark extracts a numeric report; required UI-structure checks remain separate.",
        ],
    }


def write_receipt(path, receipt):
    path.write_text(json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n")


def verify_source(root, expected):
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True)
    if result.stdout.strip() != expected:
        raise InvalidEvidence("source_identity_mismatch")
    result = subprocess.run(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"],
                            check=True, capture_output=True, text=True)
    if result.stdout:
        raise InvalidEvidence("tracked_source_modified")
    if not (root / "build/Transcripted.app/Contents/MacOS/Transcripted").is_file():
        raise InvalidEvidence("built_app_missing")


def run(args):
    if (os.environ.get("CI") != "true" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"
            or platform.machine() != "arm64" or platform.system() != "Darwin"):
        raise InvalidEvidence("requires_hosted_apple_silicon")
    if not SHA.fullmatch(args.workflow_sha):
        raise InvalidEvidence("invalid_workflow_identity")
    roots = {"base": args.base_root.resolve(), "candidate": args.candidate_root.resolve()}
    verify_source(roots["base"], BASE_SHA)
    verify_source(roots["candidate"], CANDIDATE_SHA)
    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    payloads = []
    partial = {"complete": False, "purpose": "diagnosis_only", "workflow_sha": args.workflow_sha,
               "base_sha": BASE_SHA, "candidate_sha": CANDIDATE_SHA, "blocks": [],
               "release_verdict": "HOLD: incomplete diagnostic; original required check remains failed."}
    receipt_path = out / "paired-launch-receipt.json"
    write_receipt(receipt_path, partial)
    bench = roots["candidate"] / "scripts/dev/bench-launch-latency.sh"
    try:
        for index, arm in enumerate(ORDER):
            label = f"{arm}-block-{index + 1}"
            block_path = out / f"{label}.json"
            command = ["bash", str(bench), "--app", str(roots[arm] / "build/Transcripted.app"),
                       "--samples", str(SAMPLES_PER_BLOCK), "--warmups", "0",
                       "--label", label, "--out", str(block_path)]
            # Raw launch output stays on this disposable runner, never in the uploaded artifact.
            with (out / f"{label}.log").open("w") as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode != 0:
                raise InvalidEvidence("benchmark_block_failed")
            try:
                payload = json.loads(block_path.read_text())
            except (OSError, ValueError):
                raise InvalidEvidence("benchmark_evidence_unreadable") from None
            block = checked_block(payload, index)
            payloads.append(payload)
            partial["blocks"].append(block)
            write_receipt(receipt_path, partial)
            print(f"Block {index + 1}/8: {arm}, five complete finite samples retained.", flush=True)
        receipt = aggregate(payloads, args.workflow_sha)
        receipt["runner"] = {"environment": "github-hosted", "os": "macos-26", "arch": "arm64"}
        receipt["toolchain_fingerprints"] = {}
        for key, command in (("swift_sha256", ["swiftc", "--version"]),
                             ("xcode_sha256", ["xcodebuild", "-version"])):
            value = subprocess.run(command, check=True, capture_output=True).stdout
            receipt["toolchain_fingerprints"][key] = hashlib.sha256(value).hexdigest()
        verify_source(roots["base"], BASE_SHA)
        verify_source(roots["candidate"], CANDIDATE_SHA)
        write_receipt(receipt_path, receipt)
        print(json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False))
    except InvalidEvidence as error:
        partial["failure_code"] = str(error)
        write_receipt(receipt_path, partial)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-root", type=Path, required=True)
    parser.add_argument("--candidate-root", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--workflow-sha", required=True)
    args = parser.parse_args()
    try:
        run(args)
    except (InvalidEvidence, OSError, ArithmeticError, subprocess.SubprocessError):
        # Never print exception payloads: OS/subprocess errors can include raw paths.
        print("Paired launch diagnostic failed or is incomplete; original required check remains failed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
