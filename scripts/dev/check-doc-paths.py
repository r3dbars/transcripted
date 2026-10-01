#!/usr/bin/env python3
"""Keep the docs from rotting: every path a doc names must exist.

Agents follow the paths docs give them. A doc that names a file that moved or
never existed sends the agent hunting, or worse, lets it trust a rule for code
that isn't there anymore. This check reads every tracked Markdown file, pulls
out the `backticked` things that look like repo paths, and fails when one
doesn't exist. It also keeps the always-loaded entry files small.

A path counts as existing when it resolves from the repo root, from the doc's
own folder or any folder above it (so `Tools/<package>/CLAUDE.md` can name
package-relative paths), or, for a bare file name like `build.sh`, when any
tracked file has that name. Globs and placeholders (`*`, `<name>`, `{a,b}`,
`$VAR`, `...`) are skipped.

    python3 scripts/dev/check-doc-paths.py
    python3 scripts/dev/check-doc-paths.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

# Docs that aren't about this tree, each with the reason.
SKIP_DOCS = {
    "CHANGELOG.md": "release history; names files as they were at the time",
    "THIRD_PARTY_LICENSES.md": "license texts",
    "docs/writing-port-ledger.md": "names files in the Tilde repo being ported",
    "docs/writing-plan.md": "names files in the Tilde repo being ported",
    "Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md": "finished bake-off record; its scripts were removed",
    "Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md": "finished bake-off record; its scripts were removed",
}

# Always-loaded entry files and their line budgets. Every agent session reads
# these before doing anything, so growth here costs every session.
LINE_BUDGETS = {
    "AGENTS.md": 110,
    "CLAUDE.md": 12,
}

PATH_PREFIXES = ("Sources/", "Tests/", "Tools/", "scripts/", "docs/", ".agents/", ".github/", "Resources/", "config/", "Casks/")
# Bare names are only checked for code. A bare `report.json` or `resume.md` is
# usually something a tool writes, not a file in the repo.
BARE_FILE = re.compile(r"[A-Za-z0-9_.-]+\.(?:sh|py|swift|rb)")
BACKTICKED = re.compile(r"`([^`\n]+)`")
# A line that says the file is gone is history, not a pointer.
SAYS_GONE = re.compile(
    r"\b(?:removed|dissolved|deleted|retired|renamed|no longer|never (?:has|had) been|not in the repo|used to)\b",
    re.I,
)
PLACEHOLDER = re.compile(r"[*<>{}$…|]|\.\.\.|YYYY|Foo")


def candidate_paths(text: str) -> list[str]:
    found: list[str] = []
    live_lines = "\n".join(line for line in text.splitlines() if not SAYS_GONE.search(line))
    for raw in BACKTICKED.findall(live_lines):
        token = raw.strip().rstrip(".,:;)")
        if " " in token or PLACEHOLDER.search(token):
            continue
        token = token.split("#", 1)[0]
        token = re.sub(r":\d+(?:[-:]\d+)?$", "", token)  # file.swift:42, file.sh:68-72
        if token.startswith(PATH_PREFIXES) or BARE_FILE.fullmatch(token):
            found.append(token)
    return found


def exists(token: str, doc: Path, root: Path, basenames: set[str]) -> bool:
    if (root / token).exists():
        return True
    for folder in (root / doc).parents:
        if (folder / token).exists():
            return True
        if folder == root:
            break
    return "/" not in token.rstrip("/") and token in basenames


def tracked_markdown(root: Path) -> tuple[list[str], set[str]]:
    listed = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True, text=True, check=True).stdout.split("\n")
    files = [f for f in listed if f]
    return [f for f in files if f.endswith(".md")], {Path(f).name for f in files}


def run(root: Path, docs: list[str], basenames: set[str]) -> int:
    problems: list[str] = []
    for doc in docs:
        if doc in SKIP_DOCS:
            continue
        path = root / doc
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for token in sorted(set(candidate_paths(text))):
            if not exists(token, Path(doc), root, basenames):
                problems.append(f"{doc}: `{token}` doesn't exist. Fix the path, or drop the mention if the file is gone.")
        budget = LINE_BUDGETS.get(doc)
        if budget is not None:
            lines = text.count("\n")
            if lines > budget:
                problems.append(
                    f"{doc}: {lines} lines, over its {budget}-line budget. Every agent session reads it first; "
                    "move detail to the folder CLAUDE.md or the reference doc that owns it."
                )
    if problems:
        print("Docs name things that aren't there:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"doc paths OK: {len(docs) - len(SKIP_DOCS)} Markdown files checked")
    return 0


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Sources/Speech").mkdir(parents=True)
        (root / "Sources/Speech/Engine.swift").write_text("", encoding="utf-8")
        (root / "Tools/Pkg/Sources/Pkg").mkdir(parents=True)
        (root / "Tools/Pkg/Sources/Pkg/Thing.swift").write_text("", encoding="utf-8")
        (root / "scripts").mkdir()
        (root / "scripts/build.sh").write_text("", encoding="utf-8")
        basenames = {"Engine.swift", "Thing.swift", "build.sh"}

        (root / "AGENTS.md").write_text(
            "See `Sources/Speech/Engine.swift:42`, `build.sh`, `Sources/<area>/CLAUDE.md`, and `bash check.sh quick`.\n",
            encoding="utf-8",
        )
        (root / "Tools/Pkg/CLAUDE.md").write_text("Owns `Sources/Pkg/Thing.swift`.\n", encoding="utf-8")
        assert run(root, ["AGENTS.md", "Tools/Pkg/CLAUDE.md"], basenames) == 0

        (root / "docs").mkdir()
        (root / "docs/old.md").write_text("Moved: `Sources/Text/Style.swift` and `gone.sh`.\n", encoding="utf-8")
        (root / "docs/out.md").write_text("Writes `report.json` and `summary.md`; see `scripts/build.sh:10-12`.\n", encoding="utf-8")
        assert run(root, ["docs/out.md"], basenames) == 0
        assert run(root, ["docs/old.md"], basenames) == 1

        (root / "CLAUDE.md").write_text("line\n" * 40, encoding="utf-8")
        assert run(root, ["CLAUDE.md"], basenames) == 1

        assert candidate_paths("`Sources/*/CLAUDE.md` `$HOME/x.sh` `a b.sh` `docs/x.md#part`") == ["docs/x.md"]
        assert candidate_paths("`Old.swift` was dissolved into pages.\n`scripts/x.sh` is not in the repo.\n") == []
    print("check-doc-paths self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        import contextlib
        import io

        with contextlib.redirect_stdout(io.StringIO()):
            self_test()
        print("check-doc-paths self-test passed")
        return 0
    docs, basenames = tracked_markdown(REPO_ROOT)
    return run(REPO_ROOT, docs, basenames)


if __name__ == "__main__":
    sys.exit(main())
