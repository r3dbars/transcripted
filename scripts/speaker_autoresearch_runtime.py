"""Frozen-input, build, checkpoint, and evaluator execution support."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import sys
from typing import Any

from speaker_autoresearch_contract import EVALUATOR_SCHEMA_VERSION

def verify_manifest(manifest: pathlib.Path, input_root: pathlib.Path) -> int:
    try:
        root = input_root.resolve(strict=True)
    except OSError as error:
        raise SystemExit(f"input root is unavailable: {input_root}: {error}") from error
    if not root.is_dir():
        raise SystemExit(f"input root is not a directory: {root}")
    try:
        lines = manifest.read_text().splitlines()
    except OSError as error:
        raise SystemExit(f"cannot read manifest {manifest}: {error}") from error

    count = 0
    seen: set[pathlib.Path] = set()
    for line_number, raw in enumerate(lines, 1):
        if not raw.strip():
            continue
        fields = raw.split(maxsplit=1)
        if len(fields) != 2:
            raise SystemExit(f"bad manifest line {line_number}: expected SHA256 and relative path")
        expected, relative = fields
        expected = expected.lower()
        if len(expected) != 64 or any(character not in "0123456789abcdef" for character in expected):
            raise SystemExit(f"bad manifest SHA256 on line {line_number}")
        relative_path = pathlib.Path(relative)
        if relative_path.is_absolute():
            raise SystemExit(f"manifest path must be relative on line {line_number}: {relative}")
        try:
            path = (root / relative_path).resolve(strict=True)
            path.relative_to(root)
        except (OSError, ValueError) as error:
            raise SystemExit(
                f"manifest path escapes input root or is missing on line {line_number}: {relative}"
            ) from error
        if not path.is_file():
            raise SystemExit(f"manifest input missing: {path}")
        if path in seen:
            raise SystemExit(f"duplicate manifest input on line {line_number}: {relative}")
        seen.add(path)
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise SystemExit(f"manifest checksum mismatch: {path}")
        count += 1
    if not count:
        raise SystemExit("manifest contains no inputs")
    return count


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def evaluator_source_sha256(root: pathlib.Path) -> str:
    candidates = [
        root / "scripts/run_speaker_autoresearch.py",
        root / "scripts/speaker_autoresearch_contract.py",
        root / "scripts/speaker_autoresearch_runtime.py",
        root / "Package.swift",
        root / "Tools/SpeakerEvalHarness/Package.swift",
    ]
    candidates.extend(sorted((root / "Sources/TranscriptedCore").rglob("*.swift")))
    candidates.extend(sorted((root / "Tools/SpeakerEvalHarness/Sources").rglob("*.swift")))
    digest = hashlib.sha256()
    for path in candidates:
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix().encode()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def binary_source_stamp(binary: pathlib.Path) -> pathlib.Path:
    return binary.parent / f"{binary.name}.source-sha256"


def runtime_identity(
    *,
    root: pathlib.Path,
    binary: pathlib.Path,
    manifest: pathlib.Path,
    input_root: pathlib.Path,
) -> dict[str, Any]:
    return {
        "evaluatorSchemaVersion": EVALUATOR_SCHEMA_VERSION,
        "binarySHA256": file_sha256(binary),
        "evaluatorSourceSHA256": evaluator_source_sha256(root),
        "runnerSHA256": file_sha256(pathlib.Path(__file__).resolve()),
        "manifestSHA256": file_sha256(manifest),
        "manifestPath": str(manifest.resolve()),
        "inputRoot": str(input_root.resolve()),
    }


def require_current_binary_source(root: pathlib.Path, binary: pathlib.Path) -> None:
    stamp = binary_source_stamp(binary)
    current = evaluator_source_sha256(root)
    try:
        built_from = stamp.read_text().strip()
    except OSError as error:
        raise SystemExit(
            f"--skip-build cannot verify evaluator source identity; rebuild without --skip-build: {error}"
        ) from error
    if built_from != current:
        raise SystemExit(
            "--skip-build binary is stale for the current evaluator source; rebuild without --skip-build"
        )


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def build_harness(root: pathlib.Path) -> pathlib.Path:
    subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", "Tools/SpeakerEvalHarness"],
        cwd=root,
        check=True,
    )
    binary = root / "Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
    if not binary.is_file():
        raise SystemExit(f"harness build succeeded but binary is missing: {binary}")
    binary_source_stamp(binary).write_text(evaluator_source_sha256(root) + "\n")
    return binary


def report_configs(path: pathlib.Path) -> dict[str, dict[str, Any]]:
    try:
        return {
            item["config"]["id"]: item["config"]
            for item in json.loads(path.read_text())["reports"]
        }
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        return {}


def checkpoint_identity(
    *,
    runtime: dict[str, Any],
    split: str,
    configs: dict[str, dict[str, Any]],
    result_path: pathlib.Path,
) -> dict[str, Any]:
    return {
        **runtime,
        "split": split,
        "configs": configs,
        "resultSHA256": file_sha256(result_path),
    }


def checkpoint_validation_error(
    *,
    result_path: pathlib.Path,
    identity_path: pathlib.Path,
    runtime: dict[str, Any],
    split: str,
    expected_configs: dict[str, dict[str, Any]] | None = None,
) -> str | None:
    if not result_path.is_file():
        return f"missing result {result_path}"
    if not identity_path.is_file():
        return f"missing identity {identity_path}"
    try:
        payload = json.loads(result_path.read_text())
        saved_identity = json.loads(identity_path.read_text())
        configs = {
            item["config"]["id"]: item["config"]
            for item in payload["reports"]
        }
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        return f"unreadable checkpoint: {error}"
    if payload.get("schemaVersion") != EVALUATOR_SCHEMA_VERSION:
        return "evaluator schema version changed"
    if payload.get("split") != split:
        return f"checkpoint split is {payload.get('split')!r}, expected {split!r}"
    if expected_configs is not None and configs != expected_configs:
        return "checkpoint configs changed"
    expected_identity = checkpoint_identity(
        runtime=runtime,
        split=split,
        configs=configs,
        result_path=result_path,
    )
    if saved_identity != expected_identity:
        return "manifest, input root, evaluator, binary, runner, configs, or result identity changed"
    return None


def require_checkpoint_identity(
    *,
    result_path: pathlib.Path,
    identity_path: pathlib.Path,
    runtime: dict[str, Any],
    split: str,
    expected_configs: dict[str, dict[str, Any]] | None = None,
) -> None:
    error = checkpoint_validation_error(
        result_path=result_path,
        identity_path=identity_path,
        runtime=runtime,
        split=split,
        expected_configs=expected_configs,
    )
    if error is not None:
        raise SystemExit(f"stale or invalid checkpoint {result_path.name}: {error}")


def run_eval(
    *,
    root: pathlib.Path,
    binary: pathlib.Path,
    manifest: pathlib.Path,
    input_root: pathlib.Path,
    state: pathlib.Path,
    name: str,
    split: str,
    configs: list[dict[str, Any]],
    resume: bool,
    runtime: dict[str, Any],
) -> pathlib.Path:
    config_path = state / "checkpoints" / f"{name}-configs.json"
    identity_path = state / "checkpoints" / f"{name}-identity.json"
    result_path = state / "results" / f"{name}.json"
    log_path = state / "logs" / f"{name}.log"
    expected_configs = {item["id"]: item for item in configs}
    write_json(config_path, configs)
    if resume and result_path.is_file():
        error = checkpoint_validation_error(
            result_path=result_path,
            identity_path=identity_path,
            runtime=runtime,
            split=split,
            expected_configs=expected_configs,
        )
        if error is None:
            print(f"AUTO_RESEARCH resume {name}: existing result identity verified")
            return result_path
        print(f"AUTO_RESEARCH rerun {name}: {error}")

    command = [
        str(binary),
        "autoeval",
        "--manifest",
        str(manifest),
        "--input-root",
        str(input_root),
        "--configs",
        str(config_path),
        "--split",
        split,
        "--out",
        str(result_path),
    ]
    environment = os.environ.copy()
    environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        log.write("command: " + " ".join(command) + "\n")
        process = subprocess.Popen(
            command,
            cwd=root,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            if line.startswith("AUTOEVAL "):
                print(line, end="")
        return_code = process.wait()
    if return_code:
        raise SystemExit(f"{name} failed with exit {return_code}; see {log_path}")
    if report_configs(result_path) != expected_configs:
        raise SystemExit(f"{name} produced incomplete or mismatched configs; see {result_path}")
    write_json(
        identity_path,
        checkpoint_identity(
            runtime=runtime,
            split=split,
            configs=expected_configs,
            result_path=result_path,
        ),
    )
    return result_path


def load_reports(path: pathlib.Path) -> dict[str, dict[str, Any]]:
    payload = json.loads(path.read_text())
    return {item["config"]["id"]: item for item in payload["reports"]}
