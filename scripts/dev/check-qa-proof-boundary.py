#!/usr/bin/env python3
"""The QA bench, its two docs and the QA gates must all say that mocked
Bluetooth route contracts are policy proof and that real AirPods proof stays
manual, so a report never reads as hardware proof.

This was a source-text test in Tests/BluetoothRouteContractTests.swift. It
compares a shell script, Markdown and YAML only (no Swift), so a script is the
honest layer.

    python3 scripts/dev/check-qa-proof-boundary.py
    python3 scripts/dev/check-qa-proof-boundary.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

QA_FILES = (
    "scripts/ops/transcripted-qa-bench.sh",
    "docs/qa-test-bench.md",
    "docs/audio-reliability-daily-check.md",
    ".agents/qa-gates.yml",
)
QA_PHRASES = (
    "Mocked Bluetooth/AirPods route contracts are automated policy proof, not hardware proof.",
    "Real connected AirPods/Bluetooth hardware remains manual proof.",
)


def check_qa_proof_boundary(root: Path) -> list[str]:
    problems: list[str] = []
    for rel in QA_FILES:
        path = root / rel
        if not path.is_file():
            problems.append(f"qa-proof-boundary: {rel} is missing")
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for phrase in QA_PHRASES:
            if phrase not in text:
                problems.append(f'qa-proof-boundary: {rel} must say "{phrase}"')
    return problems


def run(root: Path) -> int:
    problems = check_qa_proof_boundary(root)
    if problems:
        print("qa proof boundary FAILED:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print("qa proof boundary OK: stated in the bench, both docs and the gates.")
    return 0


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for rel in QA_FILES:
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("\n".join(QA_PHRASES) + "\n")
        assert check_qa_proof_boundary(root) == [], "files with both phrases pass"

        (root / QA_FILES[1]).write_text(QA_PHRASES[0] + "\n")
        assert len(check_qa_proof_boundary(root)) == 1, "a missing manual-proof phrase is reported"
        (root / QA_FILES[2]).unlink()
        assert len(check_qa_proof_boundary(root)) == 2, "a missing file is reported"
    print("check-qa-proof-boundary self-test OK")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    return run(REPO_ROOT)


if __name__ == "__main__":
    sys.exit(main())
