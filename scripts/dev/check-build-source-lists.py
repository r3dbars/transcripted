#!/usr/bin/env python3
"""Validate raw-swiftc source-list contracts with clear, fast failures."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def read_text(path: str) -> str:
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def extract_shell_array(script_path: str, array_name: str) -> list[str]:
    contents = read_text(script_path)
    match = re.search(rf"^{re.escape(array_name)}=\(\n(.*?)^\)", contents, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"{script_path}: missing {array_name}=(...) array")
    return re.findall(r'"([^"\n]+)"', match.group(1))


def validate_paths(label: str, paths: list[str]) -> list[str]:
    failures: list[str] = []
    if not paths:
        failures.append(f"{label}: source list is empty")
        return failures
    for path in paths:
        if path.startswith(("Sources/", "Tests/", "Tools/")) and not (REPO_ROOT / path).is_file():
            failures.append(f"{label}: missing source {path}")
    return failures


def app_source_files_from_shared_args() -> list[str]:
    command = r'''
set -euo pipefail
source scripts/entrypoints/lib/swiftc-app-args.sh
build_app_swiftc_args
printf '%s\n' "${APP_SOURCE_FILES[@]}"
'''
    result = subprocess.run(
        ["bash", "-lc", command],
        cwd=REPO_ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "failed to build shared app swiftc args")
    return sorted(line for line in result.stdout.splitlines() if line)


def expected_app_sources() -> list[str]:
    return sorted(
        str(path.relative_to(REPO_ROOT))
        for path in (REPO_ROOT / "Sources").rglob("*.swift")
        if "Sources/TranscriptedCore/" not in str(path.relative_to(REPO_ROOT))
    )


def validate_fast_manifest() -> list[str]:
    failures: list[str] = []
    manifest = read_text("Tests/FastTests.manifest")
    entries = [
        line.strip()
        for line in manifest.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    manifest_files = sorted(entry.split(":", 1)[0] for entry in entries if ":" in entry)
    actual_files = sorted(path.name for path in (REPO_ROOT / "Tests").glob("*Tests.swift"))
    if manifest_files != actual_files:
        failures.append("Tests/FastTests.manifest does not match root Tests/*Tests.swift files")

    for entry in entries:
        if ":" not in entry:
            failures.append(f"Tests/FastTests.manifest: malformed entry {entry!r}")
            continue
        filename, function = entry.split(":", 1)
        test_path = REPO_ROOT / "Tests" / filename
        if not test_path.is_file():
            failures.append(f"Tests/FastTests.manifest: missing Tests/{filename}")
            continue
        if f"func {function}(" not in test_path.read_text(encoding="utf-8"):
            failures.append(f"Tests/FastTests.manifest: missing entry function {function} in {filename}")
    return failures


def main() -> int:
    failures: list[str] = []

    app_sources = app_source_files_from_shared_args()
    expected_sources = expected_app_sources()
    if app_sources != expected_sources:
        failures.append("scripts/entrypoints/lib/swiftc-app-args.sh APP_SOURCE_FILES drifted from Sources/*.swift discovery")
        missing = sorted(set(expected_sources) - set(app_sources))
        extra = sorted(set(app_sources) - set(expected_sources))
        failures.extend(f"  missing app source: {path}" for path in missing[:20])
        failures.extend(f"  unexpected app source: {path}" for path in extra[:20])
    if any(path.startswith("Sources/TranscriptedCore/") for path in app_sources):
        failures.append("APP_SOURCE_FILES must not compile Sources/TranscriptedCore directly; Core links via libDraftDeps.a")

    for script_path, array_name in [
        ("scripts/entrypoints/run-tests.sh", "APP_SOURCES"),
        ("scripts/entrypoints/run-e2e-smoke.sh", "SWIFT_SOURCES"),
        ("scripts/entrypoints/run-slow-pasteback-smoke.sh", "SWIFT_SOURCES"),
    ]:
        try:
            failures.extend(validate_paths(f"{script_path} {array_name}", extract_shell_array(script_path, array_name)))
        except (RuntimeError, ValueError) as error:
            failures.append(str(error))

    failures.extend(validate_fast_manifest())

    if failures:
        print("Build source-list validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("Build source-list validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
