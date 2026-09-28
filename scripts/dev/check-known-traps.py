#!/usr/bin/env python3
"""Turn "Known traps" from CLAUDE.md into checks, where a trap is mechanical.

A trap an agent has to remember is a trap it will eventually hit. Each check
here replaces one sentence of "remember to..." with a failure that says what to
do:

  tools-ci       Every Tools/* Swift package runs in a GitHub workflow and has
                 a rule in .agents/test-matrix.yml. ("Adding a Tools package
                 means giving it CI ... Nothing fails if you forget either.")
  root-wrappers  Every root *.sh command is listed in docs/repo-layout.md, so
                 agents can find the command surface.

Other traps already have their own checks: source-text tests
(check-test-shape.py), source lists (check-build-source-lists.py plus the
compile-failure explainer), telemetry keys (check-telemetry-keys.py).

    python3 scripts/dev/check-known-traps.py
    python3 scripts/dev/check-known-traps.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Packages deliberately kept out of CI, each with the reason. Adding one here is
# a human decision made in review.
TOOLS_WITHOUT_CI = {
    "SpeakerEvalHarness": (
        "needs the AMI corpus and prebuilt native deps; verified through its "
        ".agents/test-matrix.yml rule instead of hosted CI"
    ),
}


def check_tools_ci(root: Path) -> list[str]:
    problems: list[str] = []
    workflows = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for path in sorted((root / ".github/workflows").glob("*.yml"))
    )
    matrix_path = root / ".agents/test-matrix.yml"
    matrix = matrix_path.read_text(encoding="utf-8") if matrix_path.exists() else ""
    for manifest in sorted((root / "Tools").glob("*/Package.swift")):
        name = manifest.parent.name
        ref = f"Tools/{name}"
        if ref not in matrix:
            problems.append(f"{ref} has no rule in .agents/test-matrix.yml. Add one with its swift test command.")
        if ref not in workflows and name not in TOOLS_WITHOUT_CI:
            problems.append(
                f"{ref} never runs in CI. Add `swift test --package-path {ref}` to the Tools step in "
                ".github/workflows/swift-ci.yml (or its own workflow), or list it in TOOLS_WITHOUT_CI "
                "in scripts/dev/check-known-traps.py with the reason."
            )
    for name in sorted(TOOLS_WITHOUT_CI):
        if not (root / "Tools" / name / "Package.swift").exists():
            problems.append(f"TOOLS_WITHOUT_CI lists {name}, which no longer exists. Remove it.")
    return problems


def check_root_wrappers(root: Path) -> list[str]:
    layout_path = root / "docs/repo-layout.md"
    layout = layout_path.read_text(encoding="utf-8") if layout_path.exists() else ""
    return [
        f"{script.name} is a root command but docs/repo-layout.md doesn't list it. Add it to the root wrapper list."
        for script in sorted(root.glob("*.sh"))
        if f"`{script.name}`" not in layout
    ]


CHECKS = (("tools-ci", check_tools_ci), ("root-wrappers", check_root_wrappers))


def run(root: Path) -> int:
    failed = False
    for name, check in CHECKS:
        problems = check(root)
        if problems:
            failed = True
            print(f"FAIL {name}")
            for problem in problems:
                print(f"  - {problem}")
        else:
            print(f"ok   {name}")
    return 1 if failed else 0


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / ".github/workflows").mkdir(parents=True)
        (root / ".agents").mkdir()
        (root / "docs").mkdir()
        for name in ("Alpha", "SpeakerEvalHarness"):
            (root / "Tools" / name).mkdir(parents=True)
            (root / "Tools" / name / "Package.swift").write_text("// swift-tools-version: 5.9\n", encoding="utf-8")
        (root / ".agents/test-matrix.yml").write_text('- "Tools/Alpha/**"\n- "Tools/SpeakerEvalHarness/**"\n', encoding="utf-8")
        (root / ".github/workflows/ci.yml").write_text("run: echo nothing\n", encoding="utf-8")
        problems = check_tools_ci(root)
        assert len(problems) == 1 and "Tools/Alpha never runs in CI" in problems[0], problems
        (root / ".github/workflows/ci.yml").write_text("run: swift test --package-path Tools/Alpha\n", encoding="utf-8")
        assert check_tools_ci(root) == []
        (root / ".agents/test-matrix.yml").write_text('- "Tools/SpeakerEvalHarness/**"\n', encoding="utf-8")
        assert any("no rule in .agents/test-matrix.yml" in p for p in check_tools_ci(root))

        (root / "build.sh").write_text("#!/bin/bash\n", encoding="utf-8")
        (root / "check.sh").write_text("#!/bin/bash\n", encoding="utf-8")
        (root / "docs/repo-layout.md").write_text("- `build.sh` — builds\n", encoding="utf-8")
        problems = check_root_wrappers(root)
        assert len(problems) == 1 and problems[0].startswith("check.sh"), problems
    print("check-known-traps self-test passed")


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
