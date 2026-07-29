#!/usr/bin/env python3
"""Run mapped Transcripted checks sequentially and write a bounded proof report."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[2]
CONTEXT_COMMAND = REPO_ROOT / "scripts/dev/agent-context.py"
DEFAULT_REPORT = REPO_ROOT / "build/agent-proof.json"
TRUSTED_MATRIX_PATH = ".agents/test-matrix.yml"
TRUSTED_SELECTOR_PATH = "scripts/dev/test-matrix-checks.py"
PLACEHOLDER_PATTERN = re.compile(r"<[^>\n]+>")
PREFLIGHT_COMMAND_PATTERN = re.compile(
    r"^(?:bash[ \t]+)?scripts/dev/agent-preflight\.sh(?:[ \t]|$)"
)
MAX_COMMAND_LENGTH = 512
MANUAL_COMMAND_FRAGMENTS = (
    "run-live-capture-smoke.sh",
)
ALLOWED_EXECUTABLES = {"bash", "python3", "ruby", "swift"}
BOOTSTRAP_COMMANDS = {
    "python3 -m py_compile scripts/dev/agent-check.py",
    "python3 scripts/dev/agent-check.py --self-test",
}


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


def git_bytes(*arguments: str) -> bytes:
    result = subprocess.run(
        ["git", *arguments],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ProofError("could not capture git proof state")
    return result.stdout


def git_file(base_sha: str, relative_path: str) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{base_sha}:{relative_path}"],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ProofError("trusted base is missing a proof dependency")
    return result.stdout


def trusted_matrix_commands(base_sha: str) -> set[str]:
    commands: set[str] = set()
    in_checks = False
    matrix = git_file(base_sha, TRUSTED_MATRIX_PATH).decode("utf-8")
    for raw_line in matrix.splitlines():
        stripped = raw_line.strip()
        if stripped == "checks:":
            in_checks = True
            continue
        if stripped in {"- paths:", "notes:"}:
            in_checks = False
            continue
        if not in_checks or not stripped.startswith("- "):
            continue
        try:
            value = json.loads(stripped[2:].strip())
        except json.JSONDecodeError as error:
            raise ProofError("trusted test matrix is invalid") from error
        if not isinstance(value, str) or not value:
            raise ProofError("trusted test matrix contains an invalid command")
        commands.add(value)
    if not commands:
        raise ProofError("trusted test matrix contains no commands")
    return commands


def select_checks_from_matrix(
    matrix: bytes,
    selector: bytes,
    paths: list[str],
    failure_message: str,
) -> list[str]:
    if not paths:
        return []
    with tempfile.TemporaryDirectory(prefix="transcripted-agent-proof-") as directory:
        temporary_root = Path(directory)
        matrix_path = temporary_root / "test-matrix.yml"
        selector_path = temporary_root / "test-matrix-checks.py"
        matrix_path.write_bytes(matrix)
        selector_path.write_bytes(selector)
        result = subprocess.run(
            [
                sys.executable,
                str(selector_path),
                "--matrix",
                str(matrix_path),
                *paths,
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        raise ProofError(failure_message)
    return [line for line in result.stdout.splitlines() if line]


def trusted_checks_for_paths(base_sha: str, paths: list[str]) -> list[str]:
    return select_checks_from_matrix(
        git_file(base_sha, TRUSTED_MATRIX_PATH),
        git_file(base_sha, TRUSTED_SELECTOR_PATH),
        paths,
        "trusted base check selection failed",
    )


def branch_checks_for_paths(base_sha: str, paths: list[str]) -> list[str]:
    return select_checks_from_matrix(
        (REPO_ROOT / TRUSTED_MATRIX_PATH).read_bytes(),
        git_file(base_sha, TRUSTED_SELECTOR_PATH),
        paths,
        "branch check selection failed",
    )


def normalize_repo_path(raw_path: str) -> str:
    candidate = Path(raw_path)
    resolved = candidate.resolve(strict=False) if candidate.is_absolute() else (
        REPO_ROOT / candidate
    ).resolve(strict=False)
    try:
        return resolved.relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError as error:
        raise ProofError("proof path must stay inside the repo") from error


def git_path_list(*arguments: str) -> list[str]:
    output = git_bytes(*arguments)
    return [
        normalize_repo_path(raw_path.decode("utf-8"))
        for raw_path in output.split(b"\0")
        if raw_path
    ]


def changed_repo_paths(base_ref: str) -> list[str]:
    merge_base_sha = git_value("merge-base", "HEAD", base_ref)
    paths = set(git_path_list("diff", "--name-only", "-z", f"{merge_base_sha}...HEAD"))
    paths.update(git_path_list("diff", "--cached", "--name-only", "-z"))
    paths.update(git_path_list("diff", "--name-only", "-z"))
    paths.update(git_path_list("ls-files", "--others", "--exclude-standard", "-z"))
    return sorted(paths)


def proof_commands(selected: list[str], required: list[str]) -> list[str]:
    return list(dict.fromkeys([*required, *selected]))


def path_state_fingerprint(paths: list[str]) -> str:
    digest = hashlib.sha256()
    repo_root = REPO_ROOT.resolve()
    for relative_path in sorted(paths):
        resolved = (REPO_ROOT / relative_path).resolve(strict=False)
        try:
            resolved.relative_to(repo_root)
        except ValueError as error:
            raise ProofError("proof path must stay inside the repo") from error
        digest.update(relative_path.encode("utf-8"))
        digest.update(b"\0")
        if not resolved.exists():
            digest.update(b"missing\0")
            continue
        stat_result = resolved.stat()
        digest.update(f"{stat_result.st_mode:o}".encode("ascii"))
        digest.update(b"\0")
        if resolved.is_file():
            with resolved.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            digest.update(b"non-file")
        digest.update(b"\0")
    return digest.hexdigest()


def capture_source_snapshot(base_ref: str, paths: list[str]) -> dict[str, Any]:
    head_sha = git_value("rev-parse", "HEAD")
    base_sha = git_value("rev-parse", base_ref)
    merge_base_sha = git_value("merge-base", "HEAD", base_ref)
    worktree_state = git_bytes("status", "--porcelain=v1", "-z", "--untracked-files=all")
    return {
        "head_sha": head_sha,
        "base_ref": base_ref,
        "base_sha": base_sha,
        "merge_base_sha": merge_base_sha,
        "worktree_clean": not worktree_state,
        "worktree_state_sha256": hashlib.sha256(worktree_state).hexdigest(),
        "path_state_sha256": path_state_fingerprint(paths),
    }


def source_snapshot_is_stable(snapshot: dict[str, Any], paths: list[str]) -> bool:
    try:
        return capture_source_snapshot(snapshot["base_ref"], paths) == snapshot
    except (OSError, ProofError):
        return False


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


def command_argv(command: str) -> list[str]:
    try:
        arguments = shlex.split(command)
    except ValueError as error:
        raise ProofError("invalid command syntax") from error
    if not arguments:
        raise ProofError("empty command")
    executable = arguments[0]
    if executable not in ALLOWED_EXECUTABLES and not executable.startswith("scripts/"):
        raise ProofError("command executable is not allowed")
    if executable.startswith("scripts/"):
        resolved = (REPO_ROOT / executable).resolve(strict=False)
        try:
            resolved.relative_to(REPO_ROOT.resolve())
        except ValueError as error:
            raise ProofError("command executable must stay inside the repo") from error
    return arguments


def classify_command(
    command: str,
    trusted_commands: set[str] | None = None,
) -> tuple[str, str | None]:
    if not command or len(command) > MAX_COMMAND_LENGTH or "\n" in command:
        return "BLOCKED", "invalid-command"
    if PREFLIGHT_COMMAND_PATTERN.search(command):
        return "SKIPPED", "orchestration-command"
    if PLACEHOLDER_PATTERN.search(command):
        return "BLOCKED", "operator-input-required"
    if any(fragment in command for fragment in MANUAL_COMMAND_FRAGMENTS):
        return "BLOCKED", "manual-proof-required"
    if trusted_commands is not None and (
        command not in trusted_commands and command not in BOOTSTRAP_COMMANDS
    ):
        return "BLOCKED", "untrusted-matrix-command"
    try:
        command_argv(command)
    except ProofError:
        return "BLOCKED", "invalid-command"
    return "RUN", None


def command_runner(command: str) -> int:
    return subprocess.run(
        command_argv(command),
        cwd=REPO_ROOT,
        check=False,
    ).returncode


def run_commands(
    commands: list[str],
    trusted_commands: set[str] | None = None,
    runner: Callable[[str], int] = command_runner,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    runnable_total = sum(
        classify_command(command, trusted_commands)[0] == "RUN" for command in commands
    )
    runnable_index = 0

    for command in commands:
        disposition, reason = classify_command(command, trusted_commands)
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
    source_snapshot: dict[str, Any],
    context: dict[str, Any],
    results: list[dict[str, Any]],
    source_stable: bool,
) -> dict[str, Any]:
    manual_requirements = context.get("manual_proof", [])
    return {
        "schema_version": 1,
        "head_sha": source_snapshot["head_sha"],
        "base": {
            "ref": source_snapshot["base_ref"],
            "sha": source_snapshot["base_sha"],
            "merge_base_sha": source_snapshot["merge_base_sha"],
        },
        "source": {
            "worktree_clean": source_snapshot["worktree_clean"],
            "worktree_state_sha256": source_snapshot["worktree_state_sha256"],
            "path_state_sha256": source_snapshot["path_state_sha256"],
            "stable": source_stable,
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
    report_root = (REPO_ROOT / "build").resolve(strict=False)
    try:
        resolved.relative_to(REPO_ROOT.resolve())
        resolved.relative_to(report_root)
    except ValueError as error:
        raise ProofError("report path must stay inside the build directory") from error
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
        "python3 scripts/dev/untrusted-proof.py": ("RUN", None),
    }
    for command, expected in classifications.items():
        actual = classify_command(command)
        if actual != expected:
            raise ProofError(f"unexpected command classification: {actual}")

    untrusted_command = "python3 scripts/dev/test-matrix-checks.py --self-test"
    if classify_command(
        "python3 scripts/dev/untrusted-proof.py",
        trusted_commands=set(),
    ) != ("BLOCKED", "untrusted-matrix-command"):
        raise ProofError("commands absent from the trusted base must fail closed")

    pass_command = "python3 scripts/dev/agent-check.py --self-test"
    exit_codes = {pass_command: 0, untrusted_command: 7}
    results = run_commands(
        [
            "bash scripts/dev/agent-preflight.sh",
            pass_command,
            untrusted_command,
            "release <operator>",
        ],
        trusted_commands={untrusted_command},
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

    trusted_commands = trusted_matrix_commands(git_value("rev-parse", "HEAD"))
    if "bash build.sh --no-open" not in trusted_commands:
        raise ProofError("trusted matrix commands were not loaded from git")
    required_checks = trusted_checks_for_paths(
        git_value("rev-parse", "HEAD"),
        ["Tests/RepoCommandContractTests.swift"],
    )
    if not {"bash build.sh --no-open", "bash run-tests.sh"}.issubset(
        required_checks
    ):
        raise ProofError("trusted path-specific checks were not selected")
    merged_checks = proof_commands(
        ["python3 scripts/dev/agent-check.py --self-test"],
        required_checks,
    )
    if merged_checks[:2] != ["bash build.sh --no-open", "bash run-tests.sh"]:
        raise ProofError("trusted path-specific checks must run before branch additions")

    new_check = "python3 scripts/dev/new-proof-check.py --self-test"
    new_matrix = f"""rules:
  - paths:
      - "scripts/dev/new-proof-check.py"
    checks:
      - "{new_check}"
""".encode()
    selected_new_checks = select_checks_from_matrix(
        new_matrix,
        git_file(git_value("rev-parse", "HEAD"), TRUSTED_SELECTOR_PATH),
        ["scripts/dev/new-proof-check.py"],
        "new matrix check selection failed",
    )
    if selected_new_checks != [new_check]:
        raise ProofError("branch matrix additions must be selectable before merge")
    if classify_command(
        new_check,
        trusted_commands=trusted_commands.union(selected_new_checks),
    ) != ("RUN", None):
        raise ProofError("selected branch matrix additions must be runnable")

    source_snapshot = capture_source_snapshot(
        "HEAD",
        ["scripts/dev/agent-check.py"],
    )
    if not source_snapshot_is_stable(
        source_snapshot,
        ["scripts/dev/agent-check.py"],
    ):
        raise ProofError("an unchanged source snapshot must remain stable")
    changed_snapshot = dict(source_snapshot)
    changed_snapshot["head_sha"] = "0" * 40
    if source_snapshot_is_stable(
        changed_snapshot,
        ["scripts/dev/agent-check.py"],
    ):
        raise ProofError("a changed source snapshot must fail closed")

    report = build_report(
        source_snapshot,
        {"paths": ["scripts/dev/agent-check.py"], "areas": [], "manual_proof": []},
        results,
        source_stable=True,
    )
    if report["head_sha"] != source_snapshot["head_sha"]:
        raise ProofError("proof reports must retain the pre-run source identity")
    if report["source"]["stable"] is not True:
        raise ProofError("proof reports must record source stability")
    serialized_report = json.dumps(report)
    if any(key in serialized_report for key in forbidden_keys):
        raise ProofError("proof reports must not retain output or environment")

    try:
        normalize_report_path(REPO_ROOT.parent / "private-proof.json")
    except ProofError as error:
        if str(REPO_ROOT.parent) in str(error):
            raise ProofError("outside-repo report errors must not echo absolute paths") from error
    else:
        raise ProofError("outside-repo report paths must fail closed")
    try:
        normalize_report_path(REPO_ROOT / "AGENT_START.md")
    except ProofError:
        pass
    else:
        raise ProofError("report paths must not overwrite repository source")
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
        initial_head_sha = git_value("rev-parse", "HEAD")
        initial_base_sha = git_value("rev-parse", args.base)
        requested_paths = (
            sorted({normalize_repo_path(path) for path in args.paths})
            if args.paths
            else changed_repo_paths(args.base)
        )
        context = load_context(args.base, requested_paths)
        checks = context.get("checks")
        if not isinstance(checks, list) or any(not isinstance(check, str) for check in checks):
            raise ProofError("agent context returned invalid checks")
        context_paths = context.get("paths")
        if not isinstance(context_paths, list) or any(
            not isinstance(path, str) or not path for path in context_paths
        ):
            raise ProofError("agent context returned invalid paths")
        if context_paths != requested_paths:
            raise ProofError("agent context changed the requested proof paths")

        report_path = normalize_report_path(args.report)
        source_snapshot = capture_source_snapshot(args.base, context_paths)
        if (
            source_snapshot["head_sha"] != initial_head_sha
            or source_snapshot["base_sha"] != initial_base_sha
        ):
            raise ProofError("source identity changed during proof setup")
        trusted_commands = trusted_matrix_commands(source_snapshot["base_sha"])
        required_checks = trusted_checks_for_paths(
            source_snapshot["base_sha"],
            context_paths,
        )
        branch_checks = branch_checks_for_paths(
            source_snapshot["base_sha"],
            context_paths,
        )
        if checks != branch_checks:
            raise ProofError("agent context changed the branch matrix checks")
        trusted_commands.update(branch_checks)
        commands = proof_commands(checks, required_checks)
        results = run_commands(commands, trusted_commands=trusted_commands)
        source_stable = source_snapshot_is_stable(source_snapshot, context_paths)
        if not source_stable:
            results.append(
                {
                    "command": "source-stability",
                    "status": "FAIL",
                    "exit_code": None,
                    "duration_ms": 0,
                    "reason": "source-changed-during-proof",
                }
            )
        report = build_report(
            source_snapshot,
            context,
            results,
            source_stable=source_stable,
        )
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
