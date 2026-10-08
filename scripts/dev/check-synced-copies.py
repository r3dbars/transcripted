#!/usr/bin/env python3
"""Keep byte-identical synced copies identical.

CaptureLibraryPathSafety.swift exists as three real files, one per build unit
that cannot share a module with the others (a git symlink breaks checkouts with
core.symlinks=false). If one copy drifts, the build units disagree about which
paths are safe for the capture library. Edit all three together.

    python3 scripts/dev/check-synced-copies.py
    python3 scripts/dev/check-synced-copies.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

SYNCED_GROUPS = [
    [
        "Sources/Support/CaptureLibraryPathSafety.swift",
        "Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift",
        "Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift",
    ],
]


def check_group(root: Path, group: list[str]) -> list[str]:
    problems: list[str] = []
    contents: dict[str, bytes] = {}
    for rel in group:
        path = root / rel
        if path.is_symlink() or not path.is_file():
            problems.append(f"{rel}: expected a real (non-symlink) file")
            continue
        contents[rel] = path.read_bytes()
    if not contents:
        return problems
    reference_rel = next(iter(contents))
    for rel, data in contents.items():
        if data != contents[reference_rel]:
            problems.append(
                f"{rel} has drifted from {reference_rel}. Edit all copies together: {', '.join(group)}"
            )
    return problems


def run(root: Path, groups: list[list[str]]) -> int:
    problems = [p for group in groups for p in check_group(root, group)]
    if problems:
        print("Synced copies are out of sync:")
        for item in problems:
            print(f"  - {item}")
        return 1
    count = sum(len(g) for g in groups)
    print(f"synced copies OK: {count} file(s) in {len(groups)} group(s) are byte-identical.")
    return 0


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        group = ["a/X.swift", "b/X.swift", "c/X.swift"]
        for rel in group:
            (root / rel).parent.mkdir(parents=True)
            (root / rel).write_text("let x = 1\n")
        assert check_group(root, group) == []
        (root / "b/X.swift").write_text("let x = 1 \n")  # one byte of drift
        problems = check_group(root, group)
        assert len(problems) == 1 and "b/X.swift" in problems[0]
        (root / "b/X.swift").write_text("let x = 1\n")
        (root / "c/X.swift").unlink()
        (root / "c/X.swift").symlink_to(root / "a/X.swift")
        assert any("non-symlink" in p for p in check_group(root, group))
        (root / "c/X.swift").unlink()
        assert any("non-symlink" in p for p in check_group(root, group))
    print("check-synced-copies self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    return run(REPO_ROOT, SYNCED_GROUPS)


if __name__ == "__main__":
    sys.exit(main())
