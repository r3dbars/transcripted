#!/usr/bin/env python3
"""Validate hand-maintained swiftc source lists point at files that exist.

The app build's APP_SOURCE_FILES is discovered with `find` and needs no
checking; the lists below are curated by hand and can rot when files move.
run-tests.sh re-derives fast-test conventions itself before compiling, so
convention checks live there, not here.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def extract_shell_array(script_path: str, array_name: str) -> list[str]:
    contents = (REPO_ROOT / script_path).read_text(encoding="utf-8")
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


def main() -> int:
    failures: list[str] = []

    for script_path, array_name in [
        ("scripts/entrypoints/run-tests.sh", "APP_SOURCES"),
        ("scripts/entrypoints/run-e2e-smoke.sh", "SWIFT_SOURCES"),
        ("scripts/entrypoints/run-slow-pasteback-smoke.sh", "SWIFT_SOURCES"),
    ]:
        try:
            failures.extend(validate_paths(f"{script_path} {array_name}", extract_shell_array(script_path, array_name)))
        except (OSError, ValueError) as error:
            failures.append(str(error))

    if failures:
        print("Build source-list validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("Build source-list validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
