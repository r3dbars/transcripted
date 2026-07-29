#!/usr/bin/env python3
"""Run mapped Transcripted checks sequentially and write a bounded proof report."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[2]
CONTEXT_COMMAND = REPO_ROOT / "scripts/dev/agent-context.py"
DEFAULT_REPORT = REPO_ROOT / "build/agent-proof.json"
PLACEHOLDER_PATTERN = re.compile(r"<[^>\n]+>")
PREFLIGHT_COMMAND_PATTERN = re.compile(
    r"^(?:bash[ \t]+)?scripts/dev/agent-preflight\.sh(?:[ \t]|$)"
)
MAX_COMMAND_LENGTH = 512
MANUAL_COMMAND_FRAGMENTS = (
    "run-live-capture-smoke.sh",
)


class ProofError(ValueError):
    pass


def git_value(*arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ProofError("could not resolve git proof identity")
    return result.stdout.strip()


def load_context(base_ref: str, paths: list[str]) -> dict[str, Any]:
    arguments = [sys.executable, str(CONTEXT_COMMAND), "--json"]
    if paths:
        arguments.extend(paths)
    else:
        arguments.extend(["--base", base_ref])
    result = subprocess.run(
        arguments,
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ProofError("agent context selection failed")
    try:
        context = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ProofError("agent context returned invalid JSON") from error
    if not isinstance(context, dict):
        raise ProofError("agent context must return an object")
    return context


def classify_command(command: str) -> tuple[str, str | None]:
    if not command or len(command) > MAX_COMMAND_LENGTH or "\n" in command:
        return "BLOCKED", "invalid-command"
    if PREFLIGHT_COMMAND_PATTERN.search(command):
        return "SKIPPED", "orchestration-command"
    if PLACEHOLDER_PATTERN.search(command):
        return "BLOCKED", "operator-input-required"
    if any(fragment in command for fragment in MANUAL_COMMAND_FRAGMENTS):
        return "BLOCKED", "manual-proof-required"
    return "RUN", None


def shell_runner(command: str) -> int:
    return subprocess.run(
        ["/bin/bash", "-lc", command],
        cwd=REPO_ROOT,
        check=False,
    ).returncode


def run_commands(
    commands: list[str],
    runner: Callable[[str], int] = shell_runner,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    runnable_total = sum(classify_command(command)[0] == "RUN" for command in commands)
    runnable_index = 0

    for command in commands:
        disposition, reason = classify_command(command)
        if disposition != "RUN":
            results.append(
                {
                    "command": command,
                    "status": disposition,
                    "exit_code": None,
                    "duration_ms": 0,
                    "reason": reason,
                }
            )
            continue

        runnable_index += 1
        print(f"\n[{runnable_index}/{runnable_total}] {command}", flush=True)
        started = time.monotonic()
        exit_code = runner(command)
        duration_ms = max(0, round((time.monotonic() - started) * 1000))
        results.append(
            {
                "command": command,
                "status": "PASS" if exit_code == 0 else "FAIL",
                "exit_code": exit_code,
                "duration_ms": duration_ms,
                "reason": None,
            }
        )

    return results


def deterministic_status(results: list[dict[str, Any]]) -> str:
    statuses = {result["status"] for result in results}
    if "FAIL" in statuses:
        return "FAIL"
    if "BLOCKED" in statuses:
        return "BLOCKED"
    if "PASS" in statuses:
        return "PASS"
    return "NO_CHECKS"


def build_report(
    base_ref: str,
    context: dict[str, Any],
    results: list[dict[str, Any]],
) -> dict[str, Any]:
    manual_requirements = context.get("manual_proof", [])
    return {
        "schema_version": 1,
        "head_sha": git_value("rev-parse", "HEAD"),
        "base": {
            "ref": base_ref,
            "sha": git_value("rev-parse", base_ref),
            "merge_base_sha": git_value("merge-base", "HEAD", base_ref),
        },
        "paths": context.get("paths", []),
        "areas": [area.get("id") for area in context.get("areas", [])],
        "proof": {
            "deterministic": {
                "status": deterministic_status(results),
                "checks": results,
            },
            "hosted": {
                "status": "UNKNOWN",
                "reason": "hosted checks are verified separately",
            },
            "manual": {
                "status": "UNKNOWN" if manual_requirements else "NOT_REQUIRED",
                "requirements": manual_requirements,
            },
        },
    }


def normalize_report_path(raw_path: Path) -> Path:
    resolved = raw_path.resolve(strict=False) if raw_path.is_absolute() else (
        REPO_ROOT / raw_path
    ).resolve(strict=False)
    try:
        resolved.relative_to(REPO_ROOT.resolve())
    except ValueError as error:
        raise ProofError("report path must stay inside the repo") from error
    return resolved


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temporary_path = Path(handle.name)
    os.replace(temporary_path, path)


def self_test() -> None:
    classifications = {
        "bash scripts/dev/agent-preflight.sh": ("SKIPPED", "orchestration-command"),
        "bash -n scripts/dev/agent-preflight.sh": ("RUN", None),
        "SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name>": (
            "BLOCKED",
            "operator-input-required",
        ),
        "python3 -m py_compile scripts/dev/agent-check.py": ("RUN", None),
        "bash run-live-capture-smoke.sh --skip-build": (
            "BLOCKED",
            "manual-proof-required",
        ),
        "echo first\necho second": ("BLOCKED", "invalid-command"),
    }
    for command, expected in classifications.items():
        actual = classify_command(command)
        if actual != expected:
            raise ProofError(f"unexpected command classification: {actual}")

    exit_codes = {"pass": 0, "fail": 7}
    results = run_commands(
        [
            "bash scripts/dev/agent-preflight.sh",
            "pass",
            "fail",
            "release <operator>",
        ],
        runner=lambda command: exit_codes[command],
    )
    if [result["status"] for result in results] != [
        "SKIPPED",
        "PASS",
        "FAIL",
        "BLOCKED",
    ]:
        raise ProofError("check execution statuses are incorrect")
    if deterministic_status(results) != "FAIL":
        raise ProofError("a failed check must fail deterministic proof")
    forbidden_keys = {"stdout", "stderr", "environment", "cwd"}
    if any(forbidden_keys.intersection(result) for result in results):
        raise ProofError("proof results must not retain command output or environment")
    try:
        normalize_report_path(REPO_ROOT.parent / "private-proof.json")
    except ProofError as error:
        if str(REPO_ROOT.parent) in str(error):
            raise ProofError("outside-repo report errors must not echo absolute paths") from error
    else:
        raise ProofError("outside-repo report paths must fail closed")
    print("Agent proof runner self-test passed.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="optional repo-relative changed paths")
    parser.add_argument("--base", default="origin/main", help="verified git base ref")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            self_test()
            return 0
        context = load_context(args.base, args.paths)
        checks = context.get("checks")
        if not isinstance(checks, list) or any(not isinstance(check, str) for check in checks):
            raise ProofError("agent context returned invalid checks")
        results = run_commands(checks)
        report_path = normalize_report_path(args.report)
        report = build_report(args.base, context, results)
        write_report(report_path, report)
        deterministic = report["proof"]["deterministic"]["status"]
        print(f"\nDeterministic proof: {deterministic}")
        print(f"Proof report: {report_path.relative_to(REPO_ROOT)}")
        if report["proof"]["manual"]["status"] == "UNKNOWN":
            print("Manual proof: UNKNOWN")
        return 1 if deterministic in {"FAIL", "BLOCKED"} else 0
    except (OSError, ProofError) as error:
        print(f"Agent proof failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
