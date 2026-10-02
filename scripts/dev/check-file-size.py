#!/usr/bin/env python3
"""File-size ratchet: no new Swift file over 800 lines, and big ones only shrink.

Big files are where agents lose the thread and where merges collide. This check
counts lines (the same count as `wc -l`) in every Swift file under `Sources/`
and `Tools/*/Sources/` (skipping `.build`). Files already over the limit are
grandfathered in `.agents/file-size-baseline.json` with their line count.

  - A file over 800 lines that isn't in the baseline fails. Split it.
  - A baselined file that grew past its baseline count fails.
  - A baselined file that is gone or back under the limit fails until you run
    --shrink, so the baseline never carries dead entries.
  - A baselined file that shrank but is still over the limit passes; --shrink
    lowers its count so it can't grow back.

    python3 scripts/dev/check-file-size.py              # check
    python3 scripts/dev/check-file-size.py --shrink     # lower counts, drop files that left
    python3 scripts/dev/check-file-size.py --hotspots   # files over 1,500 lines, largest first
    python3 scripts/dev/check-file-size.py --self-test

--shrink never raises a count or adds a file. Growing the baseline is a human
edit made in review, with the reason in the PR. Offline, python3 stdlib only,
writes nothing except the baseline on --shrink.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINE_PATH = REPO_ROOT / ".agents/file-size-baseline.json"
LIMIT = 800
HOTSPOT = 1500


def swift_files(root: Path) -> list[Path]:
    found = list((root / "Sources").rglob("*.swift"))
    tools = root / "Tools"
    if tools.is_dir():
        for package in sorted(p for p in tools.iterdir() if p.is_dir()):
            if (package / "Sources").is_dir():
                found += (package / "Sources").rglob("*.swift")
    return sorted(p for p in found if ".build" not in p.relative_to(root).parts)


def line_count(path: Path) -> int:
    return path.read_bytes().count(b"\n")


def measure(root: Path) -> dict[str, int]:
    return {p.relative_to(root).as_posix(): line_count(p) for p in swift_files(root)}


def load_baseline(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    return {k: int(v) for k, v in json.loads(path.read_text(encoding="utf-8")).get("files", {}).items()}


def save_baseline(path: Path, files: dict[str, int]) -> None:
    payload = {
        "_comment": (
            f"Swift files over {LIMIT} lines, grandfathered at their line count. "
            "scripts/dev/check-file-size.py --shrink only lowers counts or drops files; raising one is a reviewed human edit."
        ),
        "limit": LIMIT,
        "files": dict(sorted(files.items())),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def run(root: Path, baseline_path: Path, mode: str = "check") -> int:
    sizes = measure(root)
    baseline = load_baseline(baseline_path)
    over = {path: n for path, n in sizes.items() if n > LIMIT}

    if mode == "hotspots":
        for path, n in sorted(over.items(), key=lambda item: -item[1]):
            if n > HOTSPOT:
                print(f"{n:>6}  {path}")
        return 0
    if mode == "write-baseline":
        save_baseline(baseline_path, over)
        print(f"Baseline written: {len(over)} files over {LIMIT} lines")
        return 0

    new = sorted(path for path in over if path not in baseline)
    grew = sorted(path for path in over if path in baseline and over[path] > baseline[path])
    left = sorted(path for path in baseline if path not in over)
    shrank = sorted(path for path in over if path in baseline and over[path] < baseline[path])

    if mode == "shrink":
        if new or grew:
            print("Refusing to shrink while files are over their limit; fix those first:")
            for path in new + grew:
                print(f"  {path}: {over[path]} lines")
            return 1
        save_baseline(baseline_path, {path: min(over[path], baseline[path]) for path in over})
        print(f"Baseline updated: {len(over)} files over {LIMIT} lines")
        return 0

    for path in new:
        print(
            f"FAIL {path}: {over[path]} lines, over the {LIMIT}-line limit for a new file. "
            "Split it by responsibility (see docs/repo-layout.md, Hotspots)."
        )
    for path in grew:
        print(f"FAIL {path}: grew to {over[path]} lines (baseline {baseline[path]}). Move the new code into its own file.")
    for path in left:
        now = sizes.get(path)
        state = "is gone" if now is None else f"is down to {now} lines"
        print(f"FAIL {path} {state}; drop it from the baseline with --shrink.")
    for path in shrank:
        print(f"note {path}: {over[path]} lines, under its baseline {baseline[path]}; --shrink locks that in.")
    if new or grew or left:
        return 1
    print(f"file sizes OK: {len(sizes)} Swift files, {len(over)} grandfathered over {LIMIT} lines")
    return 0


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        base = root / "baseline.json"

        def write(rel: str, lines: int) -> None:
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("let x = 1\n" * lines, encoding="utf-8")

        write("Sources/A/Small.swift", 10)
        write("Sources/A/Big.swift", LIMIT + 50)
        write("Tools/Pkg/Sources/Pkg/Tool.swift", LIMIT + 5)
        write("Tools/Pkg/.build/checkouts/Dep/Sources/Huge.swift", LIMIT * 3)
        write("Tools/Pkg/Sources/Pkg/.build/Gen.swift", LIMIT * 3)
        assert measure(root)["Sources/A/Small.swift"] == 10
        assert not any(".build" in p for p in measure(root))
        quiet = io.StringIO()
        with contextlib.redirect_stdout(quiet):
            assert run(root, base) == 1  # two new files over the limit
            save_baseline(base, {"Sources/A/Big.swift": LIMIT + 50, "Tools/Pkg/Sources/Pkg/Tool.swift": LIMIT + 5})
            assert run(root, base) == 0
            write("Sources/A/Big.swift", LIMIT + 51)  # grew
            assert run(root, base) == 1
            assert run(root, base, "shrink") == 1  # never raises
            write("Sources/A/Big.swift", LIMIT + 20)  # shrank, still big: passes
            assert run(root, base) == 0
            assert run(root, base, "shrink") == 0
            assert load_baseline(base)["Sources/A/Big.swift"] == LIMIT + 20
            write("Sources/A/Big.swift", 100)  # split: stale entry fails until shrunk
            assert run(root, base) == 1
            assert run(root, base, "shrink") == 0
            assert "Sources/A/Big.swift" not in load_baseline(base)
            assert run(root, base) == 0
            write("Sources/A/New.swift", LIMIT + 1)
            assert run(root, base) == 1
            write("Sources/A/New.swift", LIMIT)  # exactly at the limit is fine
            assert run(root, base) == 0
    print("check-file-size self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shrink", action="store_true", help="lower baseline counts to match the tree (never raises)")
    parser.add_argument("--hotspots", action="store_true", help=f"print files over {HOTSPOT} lines")
    parser.add_argument("--write-baseline", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    mode = "shrink" if args.shrink else "hotspots" if args.hotspots else "write-baseline" if args.write_baseline else "check"
    return run(REPO_ROOT, BASELINE_PATH, mode)


if __name__ == "__main__":
    sys.exit(main())
