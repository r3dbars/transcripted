#!/usr/bin/env python3
"""Turn "Known traps" from AGENTS.md into checks, where a trap is mechanical.

A trap an agent has to remember is a trap it will eventually hit. Each check
here replaces one sentence of "remember to..." with a failure that says what to
do:

  tools-ci       Every Tools/* Swift package runs in a GitHub workflow and has
                 a rule in .agents/test-matrix.yml. ("Adding a Tools package
                 means giving it CI ... Nothing fails if you forget either.")
  root-wrappers  Every root *.sh command is listed in docs/repo-layout.md, so
                 agents can find the command surface.
  agent-docs     Agent guides live in AGENTS.md only. Claude Code reads
                 AGENTS.md natively (v2.1.277+), so a CLAUDE.md may only be the
                 one-line `@AGENTS.md` stub next to an AGENTS.md. Anything
                 else in a CLAUDE.md is a second copy of the rules that drifts.
                 Only tracked CLAUDE.md files count. A CLAUDE.local.md anywhere
                 on disk fails too: Claude Code reads it instead of AGENTS.md.

Other traps already have their own checks: source-text tests
(check-test-shape.py), source lists (check-build-source-lists.py plus the
compile-failure explainer), telemetry keys (check-telemetry-keys.py).

    python3 scripts/dev/check-known-traps.py
    python3 scripts/dev/check-known-traps.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import os
import subprocess
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


# Claude Code reads AGENTS.md on its own, so no folder needs a CLAUDE.md. Flip
# this to True if that ever stops being true: then every folder with an
# AGENTS.md must carry the `@AGENTS.md` stub.
CLAUDE_STUBS_REQUIRED = False
CLAUDE_STUB = "@AGENTS.md"
# Build output and tool state, not repo docs.
AGENT_DOC_SKIP_DIRS = {".git", ".build", "build", ".claude", "node_modules", "deps-libs", "deps-modules", "deps-frameworks"}


def _walk_files(root: Path, name: str) -> list[Path]:
    found: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in AGENT_DOC_SKIP_DIRS)
        if name in filenames:
            found.append(Path(dirpath) / name)
    return found


def _agent_doc_files(root: Path, name: str) -> list[Path]:
    """Tracked files called `name`, so an untracked or vendored copy (a venv,
    scratch notes) can't fail a local run that CI would pass. When `root`
    isn't the top of a git checkout (say a temp dir under build/), walk it."""
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}

    def git(*args: str) -> str:
        return subprocess.run(
            ["git", "-C", str(root), *args], capture_output=True, check=True, env=env,
        ).stdout.decode("utf-8", errors="replace")

    try:
        if Path(git("rev-parse", "--show-toplevel").strip()).resolve() != root.resolve():
            return _walk_files(root, name)
        out = git("ls-files", "-z", "--", name, f"**/{name}")
    except (OSError, subprocess.CalledProcessError):
        return _walk_files(root, name)
    paths = {root / rel for rel in out.split("\0") if rel}
    return sorted(p for p in paths if p.is_file())


def check_agent_docs(root: Path, stubs_required: bool | None = None) -> list[str]:
    required = CLAUDE_STUBS_REQUIRED if stubs_required is None else stubs_required
    problems: list[str] = []
    for claude in _agent_doc_files(root, "CLAUDE.md"):
        rel = claude.relative_to(root).as_posix()
        if claude.read_text(encoding="utf-8", errors="replace").strip() != CLAUDE_STUB:
            problems.append(
                f"{rel} has content. Agent rules live in AGENTS.md: move it to "
                f"{claude.parent.relative_to(root).as_posix() or '.'}/AGENTS.md and delete the CLAUDE.md."
            )
        elif not (claude.parent / "AGENTS.md").is_file():
            problems.append(f"{rel} imports an AGENTS.md that isn't there. Delete it or add the AGENTS.md.")
    # CLAUDE.local.md is gitignored, so it only ever exists on disk. Look there:
    # Claude Code reads it instead of AGENTS.md, and no repo rules load.
    for local in _walk_files(root, "CLAUDE.local.md"):
        rel = local.relative_to(root).as_posix()
        problems.append(
            f"{rel} makes Claude Code skip AGENTS.md, so no repo rules load. "
            "Keep personal notes outside the repo and delete it."
        )
    if required:
        for agents in _agent_doc_files(root, "AGENTS.md"):
            if not (agents.parent / "CLAUDE.md").is_file():
                rel = agents.parent.relative_to(root).as_posix() or "."
                problems.append(f"{rel}/ has an AGENTS.md but no CLAUDE.md stub. Add one containing only `{CLAUDE_STUB}`.")
    return problems


CHECKS = (
    ("tools-ci", check_tools_ci),
    ("root-wrappers", check_root_wrappers),
    ("agent-docs", check_agent_docs),
)


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

        (root / "AGENTS.md").write_text("# rules\n", encoding="utf-8")
        (root / "Tools/Alpha/AGENTS.md").write_text("# alpha\n", encoding="utf-8")
        assert check_agent_docs(root, stubs_required=False) == []
        problems = check_agent_docs(root, stubs_required=True)
        assert len(problems) == 2 and all("no CLAUDE.md stub" in p for p in problems), problems
        (root / "CLAUDE.md").write_text("@AGENTS.md\n", encoding="utf-8")
        (root / "Tools/Alpha/CLAUDE.md").write_text("@AGENTS.md\n", encoding="utf-8")
        assert check_agent_docs(root, stubs_required=True) == []
        assert check_agent_docs(root, stubs_required=False) == []
        (root / "Tools/Alpha/CLAUDE.md").write_text("@AGENTS.md\n\nAlso never do X.\n", encoding="utf-8")
        problems = check_agent_docs(root, stubs_required=False)
        assert len(problems) == 1 and "Tools/Alpha/CLAUDE.md has content" in problems[0], problems
        (root / "Tools/Alpha/CLAUDE.md").unlink()
        (root / "docs/CLAUDE.md").write_text("@AGENTS.md\n", encoding="utf-8")
        problems = check_agent_docs(root, stubs_required=False)
        assert len(problems) == 1 and "isn't there" in problems[0], problems
        (root / "docs/CLAUDE.md").unlink()
        (root / ".build").mkdir()
        (root / ".build/CLAUDE.md").write_text("vendored\n", encoding="utf-8")
        assert check_agent_docs(root, stubs_required=False) == []
        (root / "CLAUDE.local.md").write_text("my notes\n", encoding="utf-8")
        problems = check_agent_docs(root, stubs_required=False)
        assert len(problems) == 1 and "CLAUDE.local.md makes Claude Code skip" in problems[0], problems
        (root / "CLAUDE.local.md").unlink()

    # In a git checkout only tracked CLAUDE.md files count.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        subprocess.run(["git", "init", "-q", str(root)], check=True, env=env)
        (root / "AGENTS.md").write_text("# rules\n", encoding="utf-8")
        (root / "venv/lib").mkdir(parents=True)
        (root / "venv/lib/CLAUDE.md").write_text("vendored notes\n", encoding="utf-8")
        assert check_agent_docs(root, stubs_required=False) == []
        (root / "docs").mkdir()
        (root / "docs/CLAUDE.md").write_text("tracked rules\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "docs/CLAUDE.md"], check=True, env=env)
        problems = check_agent_docs(root, stubs_required=False)
        assert len(problems) == 1 and "docs/CLAUDE.md has content" in problems[0], problems
        (root / "CLAUDE.local.md").write_text("my notes\n", encoding="utf-8")
        problems = check_agent_docs(root, stubs_required=False)
        assert len(problems) == 2 and any("CLAUDE.local.md" in p for p in problems), problems
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
