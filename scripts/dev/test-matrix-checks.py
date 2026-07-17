#!/usr/bin/env python3
"""Select verification commands from .agents/test-matrix.yml.

The matrix intentionally uses a tiny YAML subset: rules contain quoted path
globs followed by quoted check commands. Keeping the parser here dependency-
free lets agent-preflight execute the canonical matrix without maintaining a
second copy of every rule in shell.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MATRIX = REPO_ROOT / ".agents/test-matrix.yml"


@dataclass(frozen=True)
class Rule:
    paths: tuple[str, ...]
    checks: tuple[str, ...]


def _quoted_value(raw_line: str, line_number: int) -> str:
    stripped = raw_line.strip()
    if not stripped.startswith("- "):
        raise ValueError(f"line {line_number}: expected a list item")
    value = stripped[2:].strip()
    if not value.startswith('"') or not value.endswith('"'):
        raise ValueError(f"line {line_number}: matrix list values must be double-quoted")
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError(f"line {line_number}: invalid quoted value: {error.msg}") from error
    if not isinstance(decoded, str) or not decoded:
        raise ValueError(f"line {line_number}: matrix list values must be non-empty strings")
    return decoded


def parse_matrix(path: Path) -> list[Rule]:
    rules: list[Rule] = []
    current_paths: list[str] | None = None
    current_checks: list[str] | None = None
    section: str | None = None
    in_rules = False

    def finish_rule() -> None:
        nonlocal current_paths, current_checks
        if current_paths is None and current_checks is None:
            return
        if not current_paths or not current_checks:
            raise ValueError("each matrix rule must contain at least one path and one check")
        rules.append(Rule(tuple(current_paths), tuple(current_checks)))
        current_paths = None
        current_checks = None

    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "rules:":
            in_rules = True
            continue
        if stripped == "notes:":
            finish_rule()
            in_rules = False
            section = None
            continue
        if not in_rules:
            continue
        if stripped == "- paths:":
            finish_rule()
            current_paths = []
            current_checks = []
            section = "paths"
            continue
        if stripped == "checks:":
            if current_paths is None:
                raise ValueError(f"line {line_number}: checks must follow a paths list")
            section = "checks"
            continue
        if stripped.startswith("- "):
            value = _quoted_value(raw_line, line_number)
            if section == "paths" and current_paths is not None:
                current_paths.append(value)
            elif section == "checks" and current_checks is not None:
                current_checks.append(value)
            else:
                raise ValueError(f"line {line_number}: list item is outside paths/checks")
            continue
        raise ValueError(f"line {line_number}: unsupported matrix syntax: {stripped}")

    finish_rule()
    if not rules:
        raise ValueError("matrix contains no rules")
    return rules


def glob_regex(pattern: str) -> re.Pattern[str]:
    """Compile the matrix's *, **, and ? path-glob subset."""
    pieces = ["^"]
    index = 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            pieces.append("(?:[^/]+/)*")
            index += 3
        elif pattern.startswith("**", index):
            pieces.append(".*")
            index += 2
        elif pattern[index] == "*":
            pieces.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            pieces.append("[^/]")
            index += 1
        else:
            pieces.append(re.escape(pattern[index]))
            index += 1
    pieces.append("$")
    return re.compile("".join(pieces))


def select_checks(rules: list[Rule], changed_paths: list[str]) -> list[str]:
    compiled = [(rule, [glob_regex(pattern) for pattern in rule.paths]) for rule in rules]
    selected: list[str] = []
    seen: set[str] = set()
    for rule, patterns in compiled:
        if not any(regex.match(path) for path in changed_paths for regex in patterns):
            continue
        for check in rule.checks:
            if check not in seen:
                seen.add(check)
                selected.append(check)
    return selected


def self_test(matrix_path: Path) -> None:
    rules = parse_matrix(matrix_path)
    if len(rules) < 20:
        raise AssertionError(f"expected the full verification matrix, found only {len(rules)} rules")

    matching_cases = {
        "Tests/RepoCommandContractTests.swift": {
            "bash build.sh --no-open",
            "bash run-tests.sh",
        },
        "Tests/Benchmarks/HomeRecentCaptureBenchmark.swift": {
            "bash build.sh --no-open",
            "bash run-tests.sh",
            "scripts/dev/benchmark-home-recent-captures.sh --max-average-load-ms 750 --max-cancellation-ms 100",
        },
        "Tests/E2E/TranscriptedE2ESmoke.swift": {
            "bash build.sh --no-open",
            "bash run-tests.sh",
            "bash run-e2e-smoke.sh",
        },
        "Tests/E2E/SlowPastebackSmoke.swift": {
            "bash build.sh --no-open",
            "bash run-tests.sh",
            "bash run-e2e-smoke.sh",
            "bash run-slow-pasteback-smoke.sh",
        },
        "Sources/Meeting/Nested/Foo.swift": {
            "bash build-deps.sh --force",
            "bash build.sh --no-open",
            "bash run-tests.sh",
            "bash run-integration-smoke.sh",
        },
        "scripts/ops/nightly-security-check.py": {
            "python3 -m py_compile scripts/ops/nightly-security-check.py",
        },
        "scripts/release/bump-release-version.py": {
            "python3 -m py_compile scripts/release/bump-release-version.py",
            "python3 scripts/release/bump-release-version.py --self-test",
            "python3 scripts/release/bump-release-version.py --version 1.1.49 --dry-run",
        },
        "Tools/TranscriptedMCP/Sources/TranscriptedMCP/Foo.swift": {
            "swift test --package-path Tools/TranscriptedMCP",
            "bash run-e2e-smoke.sh",
        },
        ".github/workflows/example.yml": {"scripts/dev/agent-preflight.sh"},
    }
    for changed_path, expected_checks in matching_cases.items():
        actual = select_checks(rules, [changed_path])
        missing = expected_checks.difference(actual)
        if missing:
            raise AssertionError(f"{changed_path} is missing checks: {sorted(missing)}")
        if len(actual) != len(set(actual)):
            raise AssertionError(f"{changed_path} produced duplicate checks")

    if select_checks(rules, ["unmapped.file"]):
        raise AssertionError("an unmapped path unexpectedly selected checks")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="changed repo-relative paths; reads stdin when omitted")
    parser.add_argument("--matrix", type=Path, default=DEFAULT_MATRIX)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            self_test(args.matrix)
            print("Test matrix selector self-test passed.")
            return 0
        changed_paths = args.paths or [line.strip() for line in sys.stdin if line.strip()]
        for check in select_checks(parse_matrix(args.matrix), changed_paths):
            print(check)
        return 0
    except (OSError, ValueError, AssertionError) as error:
        print(f"Test matrix selection failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
