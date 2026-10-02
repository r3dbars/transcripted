#!/usr/bin/env python3
"""Count Swift concurrency warnings per Sources/ folder and ratchet a baseline.

Reads the compiler log written by scripts/dev/concurrency-census.sh. A warning
counts as a concurrency warning when its diagnostic group or text is about
Sendable, actor isolation, global actors, or data races. Each (file, line,
message) is counted once even if the compiler repeats it.

    python3 scripts/dev/concurrency-census.py --log build/concurrency-census.log [--mode report|check|shrink]
    python3 scripts/dev/concurrency-census.py --log LOG --counts-out counts.json   # write this log's counts
    python3 scripts/dev/concurrency-census.py --log LOG --mode check --allow-up-to base-counts.json

--allow-up-to is for CI: a folder above the baseline still passes when it is no
higher than the same census run on the PR's base with the same compiler. That
keeps a runner toolchain that reports more warnings than the dev Mac from
failing every PR, while a PR that adds a warning still fails.
    python3 scripts/dev/concurrency-census.py --self-test
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINE = REPO_ROOT / ".agents/concurrency-baseline.json"

WARNING = re.compile(r"^(?P<path>[^:\n]+\.swift):(?P<line>\d+):\d+: warning: (?P<message>.+)$", re.M)
CONCURRENCY = re.compile(
    r"Sendable|sendable|actor-isolated|actor isolated|main actor|MainActor|global actor|nonisolated|"
    r"isolation|isolated|data race|concurrency-safe|concurrently-executing|'sending'|"
    r"#(?:SendableClosureCaptures|SendingRisksDataRace|ActorIsolatedCall|ConformanceIsolation|"
    r"StrictConcurrency|MutableGlobalVariable|PreconcurrencyImport|IsolatedConformances)"
)


def folder_of(path: str) -> str | None:
    marker = "Sources/"
    index = path.find(marker)
    if index == -1:
        return None
    parts = path[index:].split("/")
    return "/".join(parts[:2]) if len(parts) > 2 else parts[0]


def count(log_text: str) -> dict[str, int]:
    seen: set[tuple[str, str, str]] = set()
    totals: dict[str, int] = {}
    for match in WARNING.finditer(log_text):
        message = match.group("message")
        if not CONCURRENCY.search(message):
            continue
        folder = folder_of(match.group("path"))
        if folder is None:
            continue
        key = (match.group("path"), match.group("line"), message)
        if key in seen:
            continue
        seen.add(key)
        totals[folder] = totals.get(folder, 0) + 1
    return dict(sorted(totals.items()))


def load(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    return {k: int(v) for k, v in json.loads(path.read_text(encoding="utf-8")).items()}


def save(path: Path, counts: dict[str, int]) -> None:
    path.write_text(json.dumps(dict(sorted(counts.items())), indent=2) + "\n", encoding="utf-8")


def run(log_text: str, mode: str, baseline_path: Path, allow_up_to: dict[str, int] | None = None) -> int:
    current = count(log_text)
    baseline = load(baseline_path)
    allow_up_to = allow_up_to or {}
    folders = sorted(set(current) | set(baseline))
    print(f"{'folder':40} {'now':>6} {'baseline':>9}")
    grew = []
    for folder in folders:
        now, was = current.get(folder, 0), baseline.get(folder)
        mark = ""
        if was is not None and now > was:
            if now <= allow_up_to.get(folder, -1):
                mark = f"  UP, but base has {allow_up_to[folder]}"
            else:
                mark = "  UP"
                grew.append(folder)
        elif was is not None and now < was:
            mark = "  down"
        print(f"{folder:40} {now:>6} {('-' if was is None else was):>9}{mark}")
    print(f"{'total':40} {sum(current.values()):>6} {sum(baseline.values()) if baseline else '-':>9}")

    if mode == "shrink":
        if grew:
            print("Refusing to shrink while these folders went up: " + ", ".join(grew))
            return 1
        merged = {f: min(current.get(f, 0), baseline.get(f, current.get(f, 0))) for f in folders}
        save(baseline_path, {f: n for f, n in merged.items() if n > 0})
        print(f"Baseline updated: {baseline_path.relative_to(REPO_ROOT) if baseline_path.is_relative_to(REPO_ROOT) else baseline_path}")
        return 0
    if mode == "check":
        new_folders = [
            f for f in current if f not in baseline and baseline and current[f] > allow_up_to.get(f, 0)
        ]
        if grew or new_folders:
            print("More concurrency warnings than the baseline in: " + ", ".join(grew + new_folders))
            print("Fix the new ones (see build/concurrency-census.log), don't add to the backlog.")
            return 1
    return 0


def self_test() -> None:
    log = (
        "/r/Sources/Speech/A.swift:10:5: warning: capture of 'x' with non-Sendable type 'Y' in a '@Sendable' closure [#SendableClosureCaptures]\n"
        "/r/Sources/Speech/A.swift:10:5: warning: capture of 'x' with non-Sendable type 'Y' in a '@Sendable' closure [#SendableClosureCaptures]\n"
        "/r/Sources/Speech/B.swift:3:1: warning: main actor-isolated property 'z' can not be referenced from a nonisolated context\n"
        "/r/Sources/UI/Overlay/C.swift:7:2: warning: 'authorized' was deprecated in macOS 14.0 [#DeprecatedDeclaration]\n"
        "/r/Sources/UI/Overlay/C.swift:9:2: warning: static property 'shared' is not concurrency-safe because it is nonisolated global shared mutable state\n"
        "/r/Tests/D.swift:1:1: warning: non-Sendable thing\n"
    )
    assert count(log) == {"Sources/Speech": 2, "Sources/UI": 1}, count(log)
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp) / "b.json"
        assert run(log, "report", base) == 0
        save(base, {"Sources/Speech": 2, "Sources/UI": 1})
        assert run(log, "check", base) == 0
        save(base, {"Sources/Speech": 1, "Sources/UI": 1})
        assert run(log, "check", base) == 1
        assert run(log, "shrink", base) == 1
        assert run(log, "check", base, allow_up_to={"Sources/Speech": 2}) == 0
        assert run(log, "check", base, allow_up_to={"Sources/Speech": 1}) == 1
        save(base, {"Sources/Speech": 5, "Sources/UI": 1})
        assert run(log, "shrink", base) == 0
        assert load(base) == {"Sources/Speech": 2, "Sources/UI": 1}
    print("concurrency-census self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--mode", default="report", choices=["report", "check", "shrink"])
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--counts-out", type=Path, help="write this log's per-folder counts as JSON and exit")
    parser.add_argument("--allow-up-to", type=Path, help="counts JSON from the base commit (CI); see above")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            self_test()
        print("concurrency-census self-test passed")
        return 0
    if not args.log or not args.log.exists():
        print("--log is required and must exist", file=sys.stderr)
        return 2
    log_text = args.log.read_text(encoding="utf-8", errors="replace")
    if args.counts_out:
        save(args.counts_out, count(log_text))
        print(f"Counts written: {args.counts_out}")
        return 0
    allow = load(args.allow_up_to) if args.allow_up_to else None
    return run(log_text, args.mode, args.baseline, allow)


if __name__ == "__main__":
    sys.exit(main())
