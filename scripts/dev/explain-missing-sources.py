#!/usr/bin/env python3
"""Turn "cannot find 'X' in scope" compile errors into the file to add.

Several test runners compile a hand-kept list of app sources instead of the
whole app (run-tests.sh's APP_SOURCES, the Parakeet lifecycle smoke). When a
change moves code into a new file, those runners fail with "cannot find 'X' in
scope" and nothing says why. This reads the compile log, finds where each
missing name is declared under Sources/, and prints the file to add and the
list to add it to.

    python3 scripts/dev/explain-missing-sources.py --log build/x.log --list "APP_SOURCES in scripts/entrypoints/run-tests.sh"
    python3 scripts/dev/explain-missing-sources.py --self-test

Prints nothing when the log has no such errors or no declaration is found, so
a real typo still reads as a normal compile error. Always exits 0: it explains
a failure, it never causes one.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MISSING = re.compile(r"error: cannot find (?:type )?'([A-Za-z_][A-Za-z0-9_]*)' in scope")
MODIFIERS = r"(?:(?:public|internal|private|fileprivate|open|final|nonisolated|static|indirect|@[A-Za-z_]+(?:\([^)]*\))?)\s+)*"


def missing_names(log_text: str) -> list[str]:
    return list(dict.fromkeys(MISSING.findall(log_text)))


def declaring_files(name: str, root: Path) -> list[str]:
    escaped = re.escape(name)
    type_decl = re.compile(rf"^\s*{MODIFIERS}(?:class|struct|enum|protocol|actor|typealias)\s+{escaped}\b", re.M)
    top_level_decl = re.compile(rf"^{MODIFIERS}(?:func|let|var)\s+{escaped}\b", re.M)
    hits: list[str] = []
    for path in sorted((root / "Sources").rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if name not in text:
            continue
        if type_decl.search(text) or top_level_decl.search(text):
            hits.append(path.relative_to(root).as_posix())
    return hits


def explain(log_text: str, list_owner: str, root: Path) -> list[str]:
    lines: list[str] = []
    for name in missing_names(log_text):
        files = declaring_files(name, root)
        if not files:
            continue
        where = files[0] if len(files) == 1 else " or ".join(files)
        lines.append(f"  '{name}' is declared in {where}.")
    if lines:
        lines.insert(0, f"Likely cause: these names live in files this runner doesn't compile. Add the file(s) to {list_owner}:")
    return lines


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Sources/Speech").mkdir(parents=True)
        (root / "Sources/Speech/PinnedPath.swift").write_text(
            "import Foundation\n\nenum PinnedPath {\n    static func isOff() -> Bool { false }\n}\n", encoding="utf-8"
        )
        (root / "Sources/Speech/Helpers.swift").write_text(
            "func makeThing() -> Int { 1 }\nextension PinnedPath {}\nstruct Other { let makeLocal = 1 }\n",
            encoding="utf-8",
        )
        log = (
            "Sources/Speech/Policy.swift:76:60: error: cannot find 'PinnedPath' in scope\n"
            "Sources/Speech/Policy.swift:80:10: error: cannot find 'PinnedPath' in scope\n"
            "Sources/Speech/Policy.swift:90:10: error: cannot find type 'makeThing' in scope\n"
            "Sources/Speech/Policy.swift:91:10: error: cannot find 'typoedName' in scope\n"
            "Sources/Speech/Policy.swift:92:10: error: cannot find 'makeLocal' in scope\n"
        )
        assert missing_names(log) == ["PinnedPath", "makeThing", "typoedName", "makeLocal"]
        assert declaring_files("PinnedPath", root) == ["Sources/Speech/PinnedPath.swift"]  # extension is not a declaration
        assert declaring_files("makeThing", root) == ["Sources/Speech/Helpers.swift"]
        assert declaring_files("typoedName", root) == []
        assert declaring_files("makeLocal", root) == []  # a member, not a top-level name
        out = explain(log, "APP_SOURCES", root)
        assert len(out) == 3 and "APP_SOURCES" in out[0], out
        assert explain("warning: nothing to see\n", "APP_SOURCES", root) == []
    print("explain-missing-sources self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", type=Path, help="compile output to read")
    parser.add_argument("--list", default="the runner's source list", help="where the source list lives, in words")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.log or not args.log.exists():
        return 0
    for line in explain(args.log.read_text(encoding="utf-8", errors="replace"), args.list, REPO_ROOT):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
